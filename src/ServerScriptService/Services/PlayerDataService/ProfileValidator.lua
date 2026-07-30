--!strict
--[[
	ProfileValidator

	Pure table work for player profiles: creation, validation, default
	backfilling, and deep copying.

	No DataStore access, no Player access, no yielding, no gameplay logic.

	Two rules govern this module, and both are easy to get backwards:

	1. Validation runs BEFORE backfill (specification 11.2). It must therefore
	   TOLERATE absent fields and reject only fields that are present with the
	   wrong TYPE. An absent key is normal - Roblox serialisation drops nil
	   values - and backfill is what fills it in.

	2. It validates TYPES, never VALUES. `Progression.Experience = "banana"` is
	   rejected because it is not a number. `Progression.Experience = 999999999`
	   is accepted, because deciding that is too high is a gameplay judgement
	   belonging to whichever system grants experience (specification 5.2).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local DefaultProfile = require(ReplicatedStorage.Config.DefaultProfile)
local ProfileTypes = require(ReplicatedStorage.Shared.Types.ProfileTypes)

type Profile = ProfileTypes.Profile

local ProfileValidator = {}

-- The schema version of the template. PlayerDataService asserts its own
-- CURRENT_VERSION matches this during Initialize, so the two cannot drift.
ProfileValidator.TEMPLATE_VERSION = DefaultProfile.Version

--// Copying //-----------------------------------------------------------------

--[[
	Recursively copies a table.

	Mandatory before any use of DefaultProfile. The template is frozen only at
	the top level, so a nested write would otherwise corrupt the defaults for
	every subsequent player in the server.
]]
local function deepCopy(source: { [any]: any }): { [any]: any }
	local result = {}
	for key, value in source do
		if type(value) == "table" then
			result[key] = deepCopy(value)
		else
			result[key] = value
		end
	end
	return result
end

ProfileValidator.deepCopy = deepCopy

--// Validation helpers //------------------------------------------------------

-- Each helper records a problem only when the field is PRESENT and mistyped.

local function expectType(
	container: any,
	key: string,
	expected: string,
	path: string,
	problems: { string }
)
	local value = container[key]
	if value ~= nil and type(value) ~= expected then
		table.insert(problems, string.format("%s must be a %s, got %s", path, expected, typeof(value)))
	end
end

local function expectTable(container: any, key: string, path: string, problems: { string }): any?
	local value = container[key]
	if value == nil then
		return nil
	end
	if type(value) ~= "table" then
		table.insert(problems, string.format("%s must be a table, got %s", path, typeof(value)))
		return nil
	end
	return value
end

-- Validates a map whose values must all share one primitive type.
local function expectMapOf(
	container: any,
	key: string,
	expected: string,
	path: string,
	problems: { string }
)
	local map = expectTable(container, key, path, problems)
	if map == nil then
		return
	end
	for mapKey, mapValue in map do
		if type(mapKey) ~= "string" then
			table.insert(problems, string.format("%s has a non-string key (%s)", path, typeof(mapKey)))
			break
		end
		if type(mapValue) ~= expected then
			table.insert(
				problems,
				string.format("%s['%s'] must be a %s, got %s", path, tostring(mapKey), expected, typeof(mapValue))
			)
			break
		end
	end
end

--[[
	Validates Inventory.Instances.

	Instances live in a dynamic map, so backfill cannot reach into them - the
	template holds an empty table and has no keys to merge. Every optional
	instance field must therefore be read nil-tolerantly by consumers, and this
	function only rejects fields that are PRESENT with the wrong type.

	ItemId is the single exception: it is required. Every other field has a
	sensible default, but an instance with no ItemId refers to nothing and cannot
	be interpreted at all.

	ItemIds are deliberately NOT checked against ItemRegistry. An item removed
	from Config would then fail validation and kick the player, which contradicts
	the graceful-degradation rule the migration follows.

	SCHEMA VALIDATION, NOT DOMAIN VALIDATION

	InventoryService is the long-term owner of item instances. This function is
	not an exception to that, because the two validate different things:

		here                - SCHEMA. Is this shaped like an instance? Is Roll a
		                      number in range? PlayerDataService must be able to
		                      validate a profile it just loaded without depending
		                      on any gameplay service.

		InventoryService    - DOMAIN. Does this ItemId exist? Is this instance
		                      legal in that slot? Are its affixes valid for this
		                      item? Should a malformed instance be pruned?

	The split is forced as well as principled: PlayerDataService declares no
	dependencies and InventoryService depends on it, so validating domain rules
	here would invert the dependency and the engine would reject the cycle.
]]
local function validateInstances(inventory: any, problems: { string })
	local instances = expectTable(inventory, "Instances", "Inventory.Instances", problems)
	if instances == nil then
		return
	end

	for instanceId, instance in instances do
		if type(instanceId) ~= "string" then
			table.insert(
				problems,
				string.format("Inventory.Instances has a non-string key (%s)", typeof(instanceId))
			)
			break
		end

		local path = string.format("Inventory.Instances['%s']", instanceId)

		if type(instance) ~= "table" then
			table.insert(problems, string.format("%s must be a table, got %s", path, typeof(instance)))
			break
		end

		if type(instance.ItemId) ~= "string" or instance.ItemId == "" then
			table.insert(problems, string.format("%s.ItemId must be a non-empty string", path))
		end

		expectType(instance, "Stage", "number", path .. ".Stage", problems)
		expectType(instance, "Experience", "number", path .. ".Experience", problems)
		expectType(instance, "Origin", "string", path .. ".Origin", problems)
		expectType(instance, "Locked", "boolean", path .. ".Locked", problems)
		expectType(instance, "Favorite", "boolean", path .. ".Favorite", problems)
		expectType(instance, "CreatedAt", "number", path .. ".CreatedAt", problems)

		-- Reserved extension point. Validated as a table when present, never
		-- inspected further - no phase of the current roadmap uses it.
		expectType(instance, "Metadata", "table", path .. ".Metadata", problems)

		local affixes = expectTable(instance, "Affixes", path .. ".Affixes", problems)
		if affixes ~= nil then
			for index, affix in affixes do
				local affixPath = string.format("%s.Affixes[%s]", path, tostring(index))

				if type(affix) ~= "table" then
					table.insert(
						problems,
						string.format("%s must be a table, got %s", affixPath, typeof(affix))
					)
					break
				end

				if type(affix.Id) ~= "string" or affix.Id == "" then
					table.insert(problems, string.format("%s.Id must be a non-empty string", affixPath))
					break
				end

				-- Roll is a normalised position in [0, 1]. Out of range would
				-- silently extrapolate past the affix's Config bounds.
				if type(affix.Roll) ~= "number" then
					table.insert(problems, string.format("%s.Roll must be a number", affixPath))
					break
				elseif affix.Roll < 0 or affix.Roll > 1 then
					table.insert(
						problems,
						string.format("%s.Roll must be within [0, 1], got %s", affixPath, tostring(affix.Roll))
					)
					break
				end
			end
		end
	end
end

--// Validation //--------------------------------------------------------------

--[[
	Checks that a profile is structurally usable.

	Returns false plus a description on the first set of problems found.
	Tolerates absent sections and absent fields - see the header.
]]
function ProfileValidator.validate(profile: any): (boolean, string?)
	if type(profile) ~= "table" then
		return false, string.format("profile must be a table, got %s", typeof(profile))
	end

	local problems: { string } = {}

	if type(profile.Version) ~= "number" then
		table.insert(problems, string.format("Version must be a number, got %s", typeof(profile.Version)))
	end

	local meta = expectTable(profile, "Profile", "Profile", problems)
	if meta ~= nil then
		expectType(meta, "UserId", "number", "Profile.UserId", problems)
		expectType(meta, "CreatedAt", "number", "Profile.CreatedAt", problems)
		expectType(meta, "LastLoginAt", "number", "Profile.LastLoginAt", problems)
		expectType(meta, "LastSavedAt", "number", "Profile.LastSavedAt", problems)
		expectType(meta, "NextInstanceId", "number", "Profile.NextInstanceId", problems)
	end

	-- Open map: currency names are not fixed, so only the value type is checked.
	-- An empty Currency table is valid and complete.
	expectMapOf(profile, "Currency", "number", "Currency", problems)

	local progression = expectTable(profile, "Progression", "Progression", problems)
	if progression ~= nil then
		expectType(progression, "Level", "number", "Progression.Level", problems)
		expectType(progression, "Experience", "number", "Progression.Experience", problems)
		expectMapOf(progression, "Upgrades", "number", "Progression.Upgrades", problems)
	end

	local inventory = expectTable(profile, "Inventory", "Inventory", problems)
	if inventory ~= nil then
		expectType(inventory, "Capacity", "number", "Inventory.Capacity", problems)
		expectMapOf(inventory, "Items", "number", "Inventory.Items", problems)

		expectType(inventory, "InstanceCapacity", "number", "Inventory.InstanceCapacity", problems)
		validateInstances(inventory, problems)
	end

	-- Every slot is optional. An absent slot means nothing is equipped.
	local equipment = expectTable(profile, "Equipment", "Equipment", problems)
	if equipment ~= nil then
		for _, slot in { "Pickaxe", "Bracelet", "Hood", "Hat", "Mantle" } do
			expectType(equipment, slot, "string", "Equipment." .. slot, problems)
		end
	end

	local exploration = expectTable(profile, "WorldExploration", "WorldExploration", problems)
	if exploration ~= nil then
		expectType(exploration, "CurrentWorld", "string", "WorldExploration.CurrentWorld", problems)
		expectMapOf(exploration, "DiscoveredAreas", "boolean", "WorldExploration.DiscoveredAreas", problems)
		expectMapOf(exploration, "DiscoveredLandmarks", "boolean", "WorldExploration.DiscoveredLandmarks", problems)
	end

	local missions = expectTable(profile, "Missions", "Missions", problems)
	if missions ~= nil then
		expectType(missions, "LastDailyReset", "number", "Missions.LastDailyReset", problems)
		expectMapOf(missions, "Completed", "number", "Missions.Completed", problems)

		local active = expectTable(missions, "Active", "Missions.Active", problems)
		if active ~= nil then
			for missionId, entry in active do
				local path = string.format("Missions.Active['%s']", tostring(missionId))
				if type(entry) ~= "table" then
					table.insert(problems, string.format("%s must be a table, got %s", path, typeof(entry)))
					break
				end
				expectType(entry, "StartedAt", "number", path .. ".StartedAt", problems)
				expectMapOf(entry, "Progress", "number", path .. ".Progress", problems)
			end
		end
	end

	local collection = expectTable(profile, "Collection", "Collection", problems)
	if collection ~= nil then
		for _, category in { "Crystals", "Materials", "Equipment" } do
			local entries = expectTable(collection, category, "Collection." .. category, problems)
			if entries ~= nil then
				for entryId, entry in entries do
					if type(entry) ~= "table" then
						table.insert(
							problems,
							string.format(
								"Collection.%s['%s'] must be a table, got %s",
								category,
								tostring(entryId),
								typeof(entry)
							)
						)
						break
					end
				end
			end
		end
	end

	local unlocks = expectTable(profile, "Unlocks", "Unlocks", problems)
	if unlocks ~= nil then
		for _, category in { "Worlds", "Features", "Recipes", "Achievements" } do
			expectMapOf(unlocks, category, "boolean", "Unlocks." .. category, problems)
		end
	end

	-- Open map so a new counter needs no change here, only in DefaultProfile.
	expectMapOf(profile, "Statistics", "number", "Statistics", problems)

	local settings = expectTable(profile, "Settings", "Settings", problems)
	if settings ~= nil then
		expectType(settings, "MusicVolume", "number", "Settings.MusicVolume", problems)
		expectType(settings, "SfxVolume", "number", "Settings.SfxVolume", problems)
		expectType(settings, "ScreenShake", "boolean", "Settings.ScreenShake", problems)
		expectType(settings, "RarityNotifications", "boolean", "Settings.RarityNotifications", problems)
	end

	if #problems > 0 then
		return false, table.concat(problems, "; ")
	end

	return true, nil
end

--// Backfill //----------------------------------------------------------------

--[[
	Recursively fills missing keys from the template.

	Existing values are never overwritten. Where both sides hold a table, the
	merge descends. Where the profile holds a value of a different type than the
	template, it is left alone - validate has already reported it.

	This is the mechanism that makes saves expandable: a new field added to
	DefaultProfile appears in every existing save on its next load, with no
	version bump and no migration (specification 10.2).
]]
local function merge(target: { [any]: any }, template: { [any]: any })
	for key, templateValue in template do
		local currentValue = target[key]

		if currentValue == nil then
			if type(templateValue) == "table" then
				target[key] = deepCopy(templateValue)
			else
				target[key] = templateValue
			end
		elseif type(currentValue) == "table" and type(templateValue) == "table" then
			merge(currentValue, templateValue)
		end
	end
end

--[[
	Backfills a profile against a template, defaulting to DefaultProfile.

	Mutates and returns the profile passed in.
]]
function ProfileValidator.backfill(profile: any, template: { [any]: any }?): Profile
	merge(profile, template or DefaultProfile)
	return profile :: Profile
end

--// Creation //----------------------------------------------------------------

--[[
	Builds a fresh profile for a player who has no stored data.

	The returned profile is a deep copy - it shares no table with the template.
]]
function ProfileValidator.createDefault(userId: number): Profile
	local profile = deepCopy(DefaultProfile) :: Profile

	local now = os.time()
	profile.Profile.UserId = userId
	profile.Profile.CreatedAt = now
	profile.Profile.LastLoginAt = now
	profile.Profile.LastSavedAt = 0

	return profile
end

return ProfileValidator
