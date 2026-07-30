--!strict
--[[
	PlayerDataService

	Loads, stores, validates, provides and saves player data.

	Contains NO gameplay logic. It does not decide what an item does, what it is
	worth, how much luck a player has, or whether a mission is complete. It moves
	and guards data; meaning belongs to the systems above it.

	It also never touches Roblox persistence. Every read and write goes through
	StorageProvider, which owns key construction - this service passes a UserId
	and never sees a key.

	The rule underneath every failure path: a failure to READ must never become a
	decision to WRITE. Every ambiguous outcome fails closed.

	See docs/Sprint02Specification.md sections 5, 7 and 8.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Logger = require(ServerScriptService.Core.Logger)
local PersistenceConfig = require(ReplicatedStorage.Config.PersistenceConfig)
local ProfileTypes = require(ReplicatedStorage.Shared.Types.ProfileTypes)

local Migrations = require(script.Migrations)
local ProfileValidator = require(script.ProfileValidator)
local StorageProvider = require(script.StorageProvider)

type Profile = ProfileTypes.Profile
type ProfileCallback = (Player, Profile) -> ()

-- The schema version this build understands. Bumped together with
-- DefaultProfile.Version; Initialize asserts the two match.
local CURRENT_VERSION = 1

local MESSAGES = PersistenceConfig.Messages

local log = Logger.Scoped("PlayerDataService")

local Service = {}

Service.Name = "PlayerDataService"
Service.Version = 1
Service.Dependencies = {}

--// Session state //-----------------------------------------------------------

-- The authoritative in-memory profile per active session.
local profiles: { [Player]: Profile } = {}

-- Guards against a duplicate load for the same player.
local loading: { [Player]: boolean } = {}

-- One write per profile at a time (specification 8.8).
local saving: { [Player]: boolean } = {}

local loadedCallbacks: { ProfileCallback } = {}
local releasingCallbacks: { ProfileCallback } = {}

local connections: { RBXScriptConnection } = {}
local autosaveRunning = false

--// Internal helpers //--------------------------------------------------------

local function countProfiles(): number
	local total = 0
	for _ in profiles do
		total += 1
	end
	return total
end

--[[
	Snapshots the players who currently hold a profile.

	Callers that yield between saves must iterate a snapshot rather than the live
	table: a player leaving mid-iteration would otherwise invalidate the iterator.
]]
local function snapshotPlayers(): { Player }
	local players: { Player } = {}
	for player in profiles do
		table.insert(players, player)
	end
	return players
end

local function fireLoaded(player: Player, profile: Profile)
	for _, callback in loadedCallbacks do
		task.spawn(function()
			local ok, err = pcall(callback, player, profile)
			if not ok then
				log.Error("An onProfileLoaded callback errored for %s: %s", player.Name, tostring(err))
			end
		end)
	end
end

--[[
	Fires release callbacks SYNCHRONOUSLY.

	Deliberately not spawned: these callbacks exist so gameplay systems can write
	session state into the profile before the final save. Spawning them would let
	the save win the race.
]]
local function fireReleasing(player: Player, profile: Profile)
	for _, callback in releasingCallbacks do
		local ok, err = pcall(callback, player, profile)
		if not ok then
			log.Error("An onProfileReleasing callback errored for %s: %s", player.Name, tostring(err))
		end
	end
end

--// Save //--------------------------------------------------------------------

--[[
	Persists one player's profile.

	Every save path - autosave, leave, shutdown, and the public save method -
	funnels through here, which is what makes the one-write-at-a-time rule
	enforceable in a single place.
]]
local function saveProfile(player: Player, maxAttempts: number?): boolean
	local profile = profiles[player]
	if profile == nil then
		return false
	end

	if saving[player] then
		log.Debug("A save is already in flight for %s - skipping this request.", player.Name)
		return false
	end
	saving[player] = true

	profile.Profile.LastSavedAt = os.time()

	local ok, failure = StorageProvider.write(player.UserId, profile, maxAttempts)

	saving[player] = nil

	if not ok then
		log.Error("Failed to save %s (%d): %s", player.Name, player.UserId, tostring(failure))
	end

	return ok
end

--[[
	Waits, bounded, for an in-flight save to finish.

	Used before a final save so it is never dropped by the write lock. Losing a
	final save to a concurrent autosave would silently discard the session.
]]
local function waitForSaveSlot(player: Player)
	local deadline = os.clock() + PersistenceConfig.SaveSlotWaitLimit

	while saving[player] and os.clock() < deadline do
		task.wait(0.1)
	end

	if saving[player] then
		log.Warning("Timed out waiting for the save lock on %s; proceeding anyway.", player.Name)
		saving[player] = nil
	end
end

--// Load //--------------------------------------------------------------------

--[[
	Version-gates, migrates, validates and backfills a stored profile.

	Returns nil when the profile cannot be used safely. The caller has already
	been kicked and the failure logged. Nothing is ever written on this path.
]]
local function prepareStoredProfile(player: Player, stored: { [any]: any }): Profile?
	local version = stored.Version

	if type(version) ~= "number" then
		log.Error(
			"%s (%d) has stored data with no usable Version field (%s). Refusing to load.",
			player.Name,
			player.UserId,
			typeof(version)
		)
		player:Kick(MESSAGES.CorruptSave)
		return nil
	end

	-- Downgrade protection (specification 10.4). The player has been placed on an
	-- older build than the one that wrote their save. Loading it, then saving,
	-- would silently drop fields this build does not know about.
	if version > CURRENT_VERSION then
		log.Error(
			"%s (%d) has a profile at version %d but this build supports %d. Refusing to load.",
			player.Name,
			player.UserId,
			version,
			CURRENT_VERSION
		)
		player:Kick(MESSAGES.FutureSaveVersion)
		return nil
	end

	local working: { [any]: any } = stored

	if version < CURRENT_VERSION then
		local ok, migrated, reason = Migrations.run(stored, version, CURRENT_VERSION)

		if not ok or migrated == nil then
			log.Error(
				"Migration failed for %s (%d), %d -> %d: %s. Nothing was saved; stored data is untouched.",
				player.Name,
				player.UserId,
				version,
				CURRENT_VERSION,
				tostring(reason)
			)
			player:Kick(MESSAGES.CorruptSave)
			return nil
		end

		working = migrated
		log.Info("Migrated %s (%d) from version %d to %d.", player.Name, player.UserId, version, CURRENT_VERSION)
	end

	local valid, problem = ProfileValidator.validate(working)
	if not valid then
		log.Error(
			"Validation rejected the stored profile for %s (%d): %s",
			player.Name,
			player.UserId,
			tostring(problem)
		)
		player:Kick(MESSAGES.CorruptSave)
		return nil
	end

	return ProfileValidator.backfill(working)
end

local function loadProfile(player: Player)
	if profiles[player] ~= nil or loading[player] then
		return
	end
	loading[player] = true

	local userId = player.UserId
	local result, stored, reason = StorageProvider.read(userId)

	-- The read yields. The player may have left while it was in flight.
	if player.Parent == nil then
		loading[player] = nil
		log.Debug("Abandoned the load for %s - they left during the read.", player.Name)
		return
	end

	local profile: Profile? = nil

	if result == "Ok" and stored ~= nil then
		profile = prepareStoredProfile(player, stored)
		if profile == nil then
			loading[player] = nil
			return
		end
	elseif result == "NotFound" then
		profile = ProfileValidator.createDefault(userId)
		log.Info("Created a new profile for %s (%d).", player.Name, userId)
	elseif result == "Transient" then
		loading[player] = nil
		log.Error(
			"Transient read failure for %s (%d): %s. No profile was created and nothing was written.",
			player.Name,
			userId,
			tostring(reason)
		)
		player:Kick(MESSAGES.TransientLoadFailure)
		return
	else
		loading[player] = nil
		log.Error(
			"Corrupt stored data for %s (%d): %s. Stored data was left untouched.",
			player.Name,
			userId,
			tostring(reason)
		)
		player:Kick(MESSAGES.CorruptSave)
		return
	end

	-- Session stamps. These are the only fields this service writes.
	profile.Profile.UserId = userId
	profile.Profile.LastLoginAt = os.time()
	profile.Statistics.SessionCount += 1

	profiles[player] = profile
	loading[player] = nil

	log.Info(
		"Loaded %s (%d) at version %d, session %d.",
		player.Name,
		userId,
		profile.Version,
		profile.Statistics.SessionCount
	)

	fireLoaded(player, profile)
end

local function releaseProfile(player: Player)
	loading[player] = nil

	local profile = profiles[player]
	if profile == nil then
		return
	end

	fireReleasing(player, profile)
	waitForSaveSlot(player)

	local ok = saveProfile(player, PersistenceConfig.FinalSaveMaxAttempts)

	if not ok then
		log.Error(
			"FINAL SAVE FAILED for %s (%d). Progress since the last successful save is lost.",
			player.Name,
			player.UserId
		)
	else
		log.Info("Released %s (%d) after a successful final save.", player.Name, player.UserId)
	end

	profiles[player] = nil
	saving[player] = nil
end

--// Autosave //----------------------------------------------------------------

local function startAutosave()
	if autosaveRunning then
		return
	end
	autosaveRunning = true

	task.spawn(function()
		while autosaveRunning do
			task.wait(PersistenceConfig.AutosaveInterval)
			if not autosaveRunning then
				break
			end

			-- Staggered rather than simultaneous, to spread request budget.
			for _, player in snapshotPlayers() do
				if not autosaveRunning then
					break
				end

				-- The player may have left during the stagger delay.
				if profiles[player] ~= nil then
					task.spawn(saveProfile, player)
				end

				task.wait(PersistenceConfig.AutosaveStagger)
			end
		end
	end)
end

--// Shutdown //----------------------------------------------------------------

--[[
	Saves every cached profile before the server closes.

	Roblox allows roughly 30 seconds inside BindToClose. Saves run concurrently
	with a bounded worker count and an overall deadline, so a full server does not
	exceed the window and one hung write cannot consume it.
]]
local function onClose()
	autosaveRunning = false

	local pending = snapshotPlayers()
	if #pending == 0 then
		log.Info("Server closing with no profiles to save.")
		return
	end

	log.Warning("Server closing - saving %d profile(s).", #pending)

	local deadline = os.clock() + PersistenceConfig.ShutdownSaveDeadline
	local nextIndex = 0
	local active = 0
	local completed = 0

	while completed < #pending and os.clock() < deadline do
		while active < PersistenceConfig.ShutdownSaveConcurrency and nextIndex < #pending do
			nextIndex += 1
			local player = pending[nextIndex]
			active += 1

			task.spawn(function()
				saveProfile(player, PersistenceConfig.FinalSaveMaxAttempts)
				profiles[player] = nil
				active -= 1
				completed += 1
			end)
		end

		task.wait(0.1)
	end

	if completed < #pending then
		log.Error(
			"%d of %d profile(s) did not finish saving before the shutdown deadline.",
			#pending - completed,
			#pending
		)
	else
		log.Info("All %d profile(s) saved on shutdown.", #pending)
	end
end

--// Lifecycle //---------------------------------------------------------------

function Service:Initialize()
	-- A schema mismatch is a developer error, and continuing would version-stamp
	-- profiles inconsistently. Failing here means the engine marks this service
	-- Failed and Start never runs, so no player ever loads and nothing is
	-- written - broken, but with no risk of data loss.
	if ProfileValidator.TEMPLATE_VERSION ~= CURRENT_VERSION then
		error(
			string.format(
				"CURRENT_VERSION is %d but DefaultProfile.Version is %d. These must be bumped together "
					.. "- see Sprint02Specification 10.5.",
				CURRENT_VERSION,
				ProfileValidator.TEMPLATE_VERSION
			)
		)
	end

	table.clear(profiles)
	table.clear(loading)
	table.clear(saving)

	log.Debug("Initialized at schema version %d.", CURRENT_VERSION)
end

function Service:Start()
	table.insert(
		connections,
		Players.PlayerAdded:Connect(function(player)
			loadProfile(player)
		end)
	)

	table.insert(
		connections,
		Players.PlayerRemoving:Connect(function(player)
			releaseProfile(player)
		end)
	)

	-- Players who joined between Initialize and Start. In Studio the local player
	-- is always in this set, so without it the first player of every test session
	-- would load no data.
	for _, player in Players:GetPlayers() do
		task.spawn(loadProfile, player)
	end

	startAutosave()

	game:BindToClose(onClose)

	log.Info("Started. Autosave every %ds.", PersistenceConfig.AutosaveInterval)
end

--// Access //------------------------------------------------------------------

--[[
	Returns a player's profile, or nil when it is not loaded.

	Never yields and never errors. A player can be in the server with their data
	still in flight, and every caller must handle nil.
]]
function Service:getProfile(player: Player): Profile?
	return profiles[player]
end

function Service:isLoaded(player: Player): boolean
	return profiles[player] ~= nil
end

--[[
	Yields until the profile is ready, the timeout elapses, or the player leaves.

	This is the method gameplay systems should normally use.
]]
function Service:waitForProfile(player: Player, timeout: number?): Profile?
	local deadline = os.clock() + (timeout or PersistenceConfig.LoadTimeout)

	while os.clock() < deadline do
		local profile = profiles[player]
		if profile ~= nil then
			return profile
		end

		if player.Parent == nil then
			return nil
		end

		task.wait(0.1)
	end

	log.Warning("waitForProfile timed out for %s.", player.Name)
	return profiles[player]
end

--// Readiness notification //--------------------------------------------------

--[[
	Registers a callback fired when a profile finishes loading.

	Fires immediately for players already loaded, so a late subscriber cannot miss
	the event - Start is dispatched through task.spawn and Service start order is
	not guaranteed to complete in sequence.

	Returns a function that unregisters the callback.
]]
function Service:onProfileLoaded(callback: ProfileCallback): () -> ()
	table.insert(loadedCallbacks, callback)

	for player, profile in profiles do
		task.spawn(function()
			local ok, err = pcall(callback, player, profile)
			if not ok then
				log.Error("An onProfileLoaded callback errored for %s: %s", player.Name, tostring(err))
			end
		end)
	end

	return function()
		local index = table.find(loadedCallbacks, callback)
		if index ~= nil then
			table.remove(loadedCallbacks, index)
		end
	end
end

--[[
	Registers a callback fired before a profile's final save.

	Callbacks run synchronously, giving gameplay systems a last chance to write
	session state into the profile.

	Returns a function that unregisters the callback.
]]
function Service:onProfileReleasing(callback: ProfileCallback): () -> ()
	table.insert(releasingCallbacks, callback)

	return function()
		local index = table.find(releasingCallbacks, callback)
		if index ~= nil then
			table.remove(releasingCallbacks, index)
		end
	end
end

--// Persistence //-------------------------------------------------------------

function Service:save(player: Player): boolean
	return saveProfile(player)
end

function Service:saveAll()
	local pending = snapshotPlayers()
	log.Info("Saving %d profile(s) on request.", #pending)

	for _, player in pending do
		if profiles[player] ~= nil then
			task.spawn(saveProfile, player)
		end
		task.wait(PersistenceConfig.AutosaveStagger)
	end
end

--// Diagnostics //-------------------------------------------------------------

function Service:getLoadedCount(): number
	return countProfiles()
end

function Service:getSchemaVersion(): number
	return CURRENT_VERSION
end

return Service
