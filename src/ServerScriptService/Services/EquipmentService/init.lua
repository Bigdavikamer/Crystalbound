--!strict
--[[
	EquipmentService

	Owns write authority over profile.Equipment, and the per-player resolved stat
	cache.

	Does NOT own item instances - those belong to InventoryService (R-14) - and
	does NOT own the stat formula, which lives in StatResolver. It reaches
	instances through InventoryService's API rather than reading
	Inventory.Instances directly, so ownership stays enforced by frozen copies
	rather than by convention (IIa-4).

	ONE WRITE PATH

	Every write to profile.Equipment passes through applyLoadout, following
	validate -> apply -> notify (R-19). Cache invalidation happens inside the
	APPLY phase, not the notify phase: an onLoadoutChanged subscriber will very
	likely call getEquipmentStats, and invalidating after notification would hand
	it a stale block.

	WHY getEquipmentStats AND NOT getStats

	Buffs, upgrades, world modifiers and event bonuses are not equipment. Naming
	this accessor for what it actually resolves keeps it correct forever: a future
	StatService can own the aggregate without EquipmentService changing at all
	(II-4).

	SLOT VOCABULARY

	Slot names come from ItemRegistry.SLOTS, the single runtime taxonomy. This
	service does not keep its own copy.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local CrystalEngine = require(ServerScriptService.Core.CrystalEngine)
local Logger = require(ServerScriptService.Core.Logger)

local ItemRegistry = require(ReplicatedStorage.Modules.ItemRegistry)
local StatResolver = require(ReplicatedStorage.Modules.StatResolver)
local ItemTypes = require(ReplicatedStorage.Shared.Types.ItemTypes)

type ItemInstance = ItemTypes.ItemInstance
type StatBlock = ItemTypes.StatBlock

--[[
	A described loadout change.

	One Kind covers everything: SetSlot with a nil InstanceId clears the slot, so
	equip, unequip and swap are all the same operation. Separate Equip and Unequip
	kinds would need a third for swap, or an ordering rule between two mutations.
]]
export type LoadoutMutation = {
	Kind: string, -- "SetSlot"
	Slot: string,
	InstanceId: string?, -- nil clears the slot
}

export type LoadoutChange = {
	Slot: string,
	PreviousInstanceId: string?,
	InstanceId: string?,
}

local log = Logger.Scoped("EquipmentService")

local Service = {}

Service.Name = "EquipmentService"
Service.Version = 1
Service.Dependencies = { "PlayerDataService", "InventoryService" }

Service.Codes = table.freeze({
	ProfileNotLoaded = "ProfileNotLoaded",
	UnknownSlot = "UnknownSlot",
	UnknownInstance = "UnknownInstance",
	NotEquippable = "NotEquippable",
	SlotMismatch = "SlotMismatch",
	SlotEmpty = "SlotEmpty",
	InvariantViolation = "InvariantViolation",
})

local CODES = Service.Codes

local playerData: any = nil
local inventory: any = nil

--[[
	Resolved stats per player.

	Begins absent on profile load and is populated lazily by the first
	getEquipmentStats call. Invalidation always removes the WHOLE entry - never a
	partial or incremental update (R-21).
]]
local statCache: { [Player]: StatBlock } = {}

local changeCallbacks: { (Player, LoadoutChange) -> () } = {}

--// Access //-----------------------------------------------------------------

local function getProfile(player: Player): any?
	if playerData == nil then
		return nil
	end
	return playerData:getProfile(player)
end

local function slotValue(equipment: any, slot: string): string?
	local value = equipment[slot]
	return if type(value) == "string" and value ~= "" then value else nil
end

--// Cache //------------------------------------------------------------------

--[[
	Drops a player's cached stats entirely.

	Whole-entry only. An incremental cache would have to model every dependency
	correctly forever; a whole-entry cache only has to know THAT something
	changed. Correctness and simplicity beat micro-optimising recomputation
	(R-21).
]]
local function invalidateCache(player: Player)
	statCache[player] = nil
end

--[[
	Builds the equipped-instance array and resolves it.

	A slot pointing at a missing instance contributes nothing rather than raising.
	Load-time repair clears such slots, and destroyInstance refuses to remove an
	equipped instance, so this should be unreachable - but silently resolving
	fewer items beats erroring on a stat read.
]]
local function computeStats(player: Player, profile: any): StatBlock
	local equipment = profile.Equipment
	local instances: { ItemInstance } = {}

	for _, slot in ItemRegistry.SLOTS do
		local instanceId = slotValue(equipment, slot)
		if instanceId == nil then
			continue
		end

		local instance = inventory:getInstance(player, instanceId)
		if instance ~= nil then
			table.insert(instances, instance)
		end
	end

	return StatResolver.resolve({ Instances = instances })
end

--// Notification //-----------------------------------------------------------

local function fireChanged(player: Player, change: LoadoutChange)
	for _, callback in changeCallbacks do
		task.spawn(function()
			local ok, err = pcall(callback, player, change)
			if not ok then
				log.Error("An onLoadoutChanged callback errored for %s: %s", player.Name, tostring(err))
			end
		end)
	end
end

--// THE LOADOUT FUNNEL //-----------------------------------------------------

local function violation(player: Player, detail: string): (boolean, string?, { LoadoutChange }?)
	-- An invariant failure means a public method let something through. That is
	-- a bug in this service, not a player error, so it is logged loudly.
	log.Error("Loadout mutation rejected for %s: %s", player.Name, detail)
	return false, CODES.InvariantViolation, nil
end

--[[
	The only path that writes profile.Equipment.

		Phase 1  VALIDATE   invariants against a projection; nothing written.
		                    No-ops are filtered here, so equipping what is already
		                    equipped produces no change and no event.
		Phase 2  APPLY      write slots, then invalidate the cache.
		Phase 3  NOTIFY     fire observers, once state is consistent.

	Takes a list though every current caller passes one entry. Loadout presets
	and set swaps will pass several, and atomicity belongs in one place.
]]
local function applyLoadout(
	player: Player,
	mutations: { LoadoutMutation }
): (boolean, string?, { LoadoutChange }?)
	local profile = getProfile(player)
	if profile == nil then
		return false, CODES.ProfileNotLoaded, nil
	end

	local equipment = profile.Equipment

	--// Phase 1: invariants against a projection //--

	-- Lua cannot distinguish "not projected" from "projected to nil", so touched
	-- tracks which slots the batch has already assigned.
	local projectedValue: { [string]: string } = {}
	local projectedTouched: { [string]: boolean } = {}

	local function projectedSlot(slot: string): string?
		if projectedTouched[slot] then
			return projectedValue[slot]
		end
		return slotValue(equipment, slot)
	end

	local effective: { LoadoutMutation } = {}

	for index, mutation in mutations do
		if mutation.Kind ~= "SetSlot" then
			return violation(player, string.format("mutation %d has unknown Kind '%s'", index, tostring(mutation.Kind)))
		end

		local slot = mutation.Slot
		if type(slot) ~= "string" or not ItemRegistry.isSlot(slot) then
			return violation(player, string.format("mutation %d names unknown slot '%s'", index, tostring(slot)))
		end

		local instanceId = mutation.InstanceId
		if instanceId ~= nil and (type(instanceId) ~= "string" or instanceId == "") then
			return violation(player, string.format("mutation %d InstanceId must be a non-empty string or nil", index))
		end

		-- Idempotent: setting a slot to what it already holds is not a change.
		if projectedSlot(slot) == instanceId then
			continue
		end

		projectedTouched[slot] = true
		if instanceId ~= nil then
			projectedValue[slot] = instanceId
		else
			projectedValue[slot] = nil
		end

		table.insert(effective, mutation)
	end

	-- One instance must never occupy two slots. Unreachable through equip, since
	-- a definition declares exactly one Slot, but reachable through a corrupted
	-- profile or a malformed batch.
	local occupiedBy: { [string]: string } = {}
	for _, slot in ItemRegistry.SLOTS do
		local value = projectedSlot(slot)
		if value ~= nil then
			if occupiedBy[value] ~= nil then
				return violation(
					player,
					string.format("instance '%s' would occupy both %s and %s", value, occupiedBy[value], slot)
				)
			end
			occupiedBy[value] = slot
		end
	end

	if #effective == 0 then
		return true, nil, {}
	end

	--// Phase 2: apply, then invalidate //--

	local changes: { LoadoutChange } = {}

	for _, mutation in effective do
		local slot = mutation.Slot
		local previous = slotValue(equipment, slot)

		equipment[slot] = mutation.InstanceId

		table.insert(changes, {
			Slot = slot,
			PreviousInstanceId = previous,
			InstanceId = mutation.InstanceId,
		})
	end

	-- Invalidation belongs to APPLY, not NOTIFY. A subscriber reacting to the
	-- events below will very likely call getEquipmentStats, and must not be
	-- handed a block resolved from the previous loadout.
	invalidateCache(player)

	--// Phase 3: notify //--

	for _, change in changes do
		fireChanged(player, change)
	end

	return true, nil, changes
end

--// Mutation //---------------------------------------------------------------

--[[
	Equips an instance into the slot its definition declares.

	The caller never names a slot: it is derived from the item, so a mismatch is
	impossible here by construction. SlotMismatch exists for stored data that
	disagrees, which load-time repair handles.

	Idempotent - equipping something already equipped returns true and changes
	nothing, so a duplicated client request cannot produce a spurious failure.
]]
function Service:equip(player: Player, instanceId: string): (boolean, string?)
	local profile = getProfile(player)
	if profile == nil then
		return false, CODES.ProfileNotLoaded
	end

	if type(instanceId) ~= "string" or instanceId == "" then
		return false, CODES.UnknownInstance
	end

	local instance = inventory:getInstance(player, instanceId)
	if instance == nil then
		return false, CODES.UnknownInstance
	end

	local definition = ItemRegistry.get(instance.ItemId)
	if definition == nil or definition.Category ~= "Equipment" or definition.Slot == nil then
		return false, CODES.NotEquippable
	end

	local ok, reason = applyLoadout(player, {
		{ Kind = "SetSlot", Slot = definition.Slot, InstanceId = instanceId },
	})

	return ok, reason
end

--[[
	Clears a slot. The instance stays in the player's inventory - equipping is a
	reference, not a move.
]]
function Service:unequip(player: Player, slot: string): (boolean, string?)
	local profile = getProfile(player)
	if profile == nil then
		return false, CODES.ProfileNotLoaded
	end

	if type(slot) ~= "string" or not ItemRegistry.isSlot(slot) then
		return false, CODES.UnknownSlot
	end

	if slotValue(profile.Equipment, slot) == nil then
		return false, CODES.SlotEmpty
	end

	local ok, reason = applyLoadout(player, {
		{ Kind = "SetSlot", Slot = slot, InstanceId = nil },
	})

	return ok, reason
end

--// Query //------------------------------------------------------------------

function Service:getEquipped(player: Player, slot: string): string?
	local profile = getProfile(player)
	if profile == nil then
		return nil
	end
	return slotValue(profile.Equipment, slot)
end

--[[
	A frozen copy of the occupied slots. Never the live Equipment table.
]]
function Service:getLoadout(player: Player): { [string]: string }
	local profile = getProfile(player)
	if profile == nil then
		return table.freeze({})
	end

	local loadout: { [string]: string } = {}
	for _, slot in ItemRegistry.SLOTS do
		local instanceId = slotValue(profile.Equipment, slot)
		if instanceId ~= nil then
			loadout[slot] = instanceId
		end
	end

	return table.freeze(loadout)
end

--[[
	Whether an instance occupies any slot, and which one.

	Centralises loadout searches so future systems do not each write the loop.

	InventoryService must NOT call this. It needs the same answer to refuse
	destroying an equipped instance, but calling here would make
	Inventory -> Equipment -> Inventory a cycle the engine rejects at boot. It
	reads Equipment slots directly under R-18 instead, which is precisely the
	case R-18 exists for.
]]
function Service:isEquipped(player: Player, instanceId: string): (boolean, string?)
	local profile = getProfile(player)
	if profile == nil or type(instanceId) ~= "string" then
		return false, nil
	end

	for _, slot in ItemRegistry.SLOTS do
		if slotValue(profile.Equipment, slot) == instanceId then
			return true, slot
		end
	end

	return false, nil
end

--// Stats //------------------------------------------------------------------

--[[
	The player's resolved equipment stats.

	EPHEMERAL SNAPSHOT. The returned table is the cached instance and is valid at
	the moment of the call. Consume it immediately. Do NOT retain it across an
	equipment change - it will be silently stale, because invalidation drops the
	cache entry rather than mutating the table you hold. onLoadoutChanged is the
	signal to re-read.

	Lazily computed: the cache begins absent on profile load, and the first call
	populates it. Returns nil only when no profile is loaded.
]]
function Service:getEquipmentStats(player: Player): StatBlock?
	local profile = getProfile(player)
	if profile == nil then
		return nil
	end

	local cached = statCache[player]
	if cached ~= nil then
		return cached
	end

	local resolved = computeStats(player, profile)
	statCache[player] = resolved

	return resolved
end

--[[
	Drops the cached stats for a player.

	Public so a future ProgressionService, BuffService or world modifier can force
	recomputation without EquipmentService needing to know they exist.
]]
function Service:invalidate(player: Player)
	invalidateCache(player)
end

--// Notification //-----------------------------------------------------------

--[[
	Registers a callback fired on every real loadout transition.

	TRANSITIONS ONLY. No synthetic initial-state events and no IsInitial flag
	(IIb-2 Option B): "loadout changed" is a transition, and replaying it would
	mean emitting a change that did not happen, which a subscriber could
	double-process.

	A consumer needing current state calls getLoadout first, then subscribes.

	Returns a function that unregisters the callback.
]]
function Service:onLoadoutChanged(callback: (Player, LoadoutChange) -> ()): () -> ()
	table.insert(changeCallbacks, callback)

	return function()
		local index = table.find(changeCallbacks, callback)
		if index ~= nil then
			table.remove(changeCallbacks, index)
		end
	end
end

--// Load-time repair //-------------------------------------------------------

--[[
	Clears slots that cannot be honoured, routed through the funnel so it cannot
	bypass invalidation.

	Domain validation, correctly here rather than in ProfileValidator: deciding
	whether an instance is legal in a slot needs the registry and the player's
	inventory, neither of which schema validation may reach (6.1.1).
]]
local function repairLoadout(player: Player, profile: any)
	-- Equipment is guaranteed to be a table: ProfileValidator rejects a
	-- present-but-mistyped section, and backfill supplies an empty one when it is
	-- absent. Re-checking here would mean writing outside the funnel to repair a
	-- state that cannot arrive - R-20, the producer already validated.
	local equipment = profile.Equipment

	local clears: { LoadoutMutation } = {}
	local occupiedBy: { [string]: string } = {}

	for _, slot in ItemRegistry.SLOTS do
		local raw = equipment[slot]
		if raw == nil then
			continue
		end

		local reason: string? = nil
		local instanceId = slotValue(equipment, slot)

		if instanceId == nil then
			reason = string.format("value is %s, expected a string", typeof(raw))
		elseif occupiedBy[instanceId] ~= nil then
			reason = string.format("instance also occupies slot %s", occupiedBy[instanceId])
		else
			local instance = inventory:getInstance(player, instanceId)
			if instance == nil then
				reason = "instance is not in the player's inventory"
			else
				local definition = ItemRegistry.get(instance.ItemId)
				if definition == nil then
					reason = string.format("item '%s' is unknown to the registry", tostring(instance.ItemId))
				elseif definition.Slot ~= slot then
					reason = string.format("item '%s' belongs in slot %s", instance.ItemId, tostring(definition.Slot))
				end
			end
		end

		if reason ~= nil then
			log.Warning("Clearing %s slot '%s' for %s: %s", slot, tostring(raw), player.Name, reason)
			table.insert(clears, { Kind = "SetSlot", Slot = slot, InstanceId = nil })
		elseif instanceId ~= nil then
			occupiedBy[instanceId] = slot
		end
	end

	if #clears > 0 then
		applyLoadout(player, clears)
	end
end

--// Lifecycle //--------------------------------------------------------------

function Service:Initialize()
	playerData = CrystalEngine:GetService("PlayerDataService")
	inventory = CrystalEngine:GetService("InventoryService")

	table.clear(statCache)

	log.Debug("Initialized.")
end

function Service:Start()
	playerData:onProfileLoaded(function(player: Player, profile: any)
		repairLoadout(player, profile)

		-- The cache is deliberately NOT warmed here. It begins absent and the
		-- first getEquipmentStats call populates it, so a player who never has
		-- their stats read never pays for a resolution.
	end)

	playerData:onProfileReleasing(function(player: Player)
		invalidateCache(player)
	end)

	--[[
		Second invalidation layer (IIa-3).

		The funnel covers writes this service performs. This covers writes it did
		not: Phase V evolution mutates an instance's Stage and ItemId, and under
		R-14 that mutation belongs to InventoryService, not here. Listening to the
		owner means invalidation happens regardless of who changed the data.
	]]
	inventory:onInventoryChanged(function(player: Player, change: any)
		if change.InstanceId == nil then
			return
		end

		local equipped = Service:isEquipped(player, change.InstanceId)
		if equipped then
			invalidateCache(player)
		end
	end)

	log.Info("Started.")
end

return Service
