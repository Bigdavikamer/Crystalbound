--!strict
--[[
	Migrations

	Stepwise save migrations, plus the runner that applies them.

	Steps is an ordered registry keyed by the version being migrated FROM:

		Steps[1] = function(profile) -> profile   -- migrates version 1 to 2

	A profile at version 1 loading into a build at version 4 runs 1->2, then
	2->3, then 3->4. There is never a 1->4 shortcut. Stepwise migration means
	each function only has to understand two adjacent schema versions, and adding
	a new one never requires revisiting an old one.

	Requirements on every step (specification 11.4):
		- Pure. Profile in, profile out. No DataStore, no Player, no side effects.
		- Total. Must tolerate a partial profile at the source version.
		- Never destructive without transfer. Move data before deleting it.
		- Permanent. Once shipped, a step is never edited or deleted - a player
		  returning after a year enters at whatever version they left.

	Each step must set profile.Version to the version it produced. The runner
	enforces this, which is also what makes an accidental infinite loop
	impossible.

	SELF-CONTAINMENT. Because steps are frozen forever, each one inlines the
	constants and construction logic it needs rather than calling shared helpers.
	A step that called a helper whose behaviour later changed would silently
	change with it, years after it was reviewed.

	The one deliberate exception is ItemRegistry: specification 15.4 requires the
	v1 to v2 step to consult it, precisely so that an item removed from the game
	degrades gracefully instead of being resurrected.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ItemRegistry = require(ReplicatedStorage.Modules.ItemRegistry)

local Migrations = {}

--[[
	A step returns the migrated profile plus an optional list of warnings.

	Steps do NOT log. A migration is a pure transformation: profile in, profile
	and observations out. PlayerDataService logs the warnings once the migration
	has completed successfully, which keeps every step free of side effects and
	makes a step trivially testable in isolation.

	This supersedes the `(profile) -> profile` signature in
	Sprint02Specification 11.1.
]]
export type MigrationStep = ({ [any]: any }) -> ({ [any]: any }, { string }?)

Migrations.Steps = {} :: { [number]: MigrationStep }

--// 1 -> 2 //-----------------------------------------------------------------

--[[
	Equipment slots move from holding ItemIds to holding InstanceIds.

	Frozen constants. The v1 slot set is inlined rather than read from anywhere
	current, so adding a sixth slot in a later sprint cannot retroactively change
	what this step does to a v1 profile.
]]
local V1_SLOTS = table.freeze({ "Pickaxe", "Bracelet", "Hood", "Hat", "Mantle" })

--[[
	Legacy ItemIds that predate the prefix convention in specification 5.1.

	"pickaxe_starter" was the value shipped in the v1 DefaultProfile, and real
	Sprint 02 test saves contain it. Without this remap the lookup below would
	miss and the player's starter pickaxe would be silently deleted.
]]
local V1_LEGACY_ITEM_IDS = table.freeze({
	pickaxe_starter = "pick_starter",
})

Migrations.Steps[1] = function(profile: { [any]: any }): ({ [any]: any }, { string }?)
	local warnings: { string } = {}

	-- Total: tolerate a partial v1 profile. Backfill has not run yet, so any
	-- section may legitimately be absent (specification 11.4).
	local meta = profile.Profile
	if type(meta) ~= "table" then
		meta = {}
		profile.Profile = meta
	end

	local inventory = profile.Inventory
	if type(inventory) ~= "table" then
		inventory = {}
		profile.Inventory = inventory
	end

	local instances = inventory.Instances
	if type(instances) ~= "table" then
		instances = {}
		inventory.Instances = instances
	end

	local equipment = profile.Equipment
	if type(equipment) ~= "table" then
		equipment = {}
		profile.Equipment = equipment
	end

	local nextInstanceId = meta.NextInstanceId
	if type(nextInstanceId) ~= "number" then
		nextInstanceId = 1
	end

	-- Deterministic: no os.time(). A migration that produced a different result
	-- on each run could not be reasoned about after the fact.
	local createdAt = if type(meta.CreatedAt) == "number" then meta.CreatedAt else 0

	for _, slot in V1_SLOTS do
		local legacyValue = equipment[slot]
		if type(legacyValue) ~= "string" or legacyValue == "" then
			continue
		end

		local itemId = V1_LEGACY_ITEM_IDS[legacyValue] or legacyValue

		if not ItemRegistry.exists(itemId) then
			-- The item no longer exists in the game. Clear the slot rather than
			-- failing: a removed item must never lock a player out of their
			-- account permanently (specification 15.4 step b).
			table.insert(
				warnings,
				string.format("cleared slot %s: item '%s' is not in the item registry", slot, legacyValue)
			)
			equipment[slot] = nil
			continue
		end

		local instanceId = tostring(nextInstanceId)
		nextInstanceId += 1

		instances[instanceId] = {
			ItemId = itemId,

			-- Pre-affix items receive NO affixes. Retroactively rolling them
			-- would hand veteran players free power based on nothing.
			Affixes = {},

			Stage = 1,
			Experience = 0,

			-- nil is correct and legitimate: these items predate world tracking,
			-- so their origin is genuinely unknown (specification 4.2).
			Origin = nil,

			Locked = false,
			Favorite = false,
			CreatedAt = createdAt,

			-- Metadata is deliberately absent, not {}. It is a reserved
			-- extension point stored sparsely (specification 3.9.2).
		}

		equipment[slot] = instanceId
	end

	meta.NextInstanceId = nextInstanceId
	profile.Version = 2

	return profile, warnings
end

--[[
	Applies every step needed to bring a profile from fromVersion to targetVersion.

	Returns success, the migrated profile, and a reason on failure.

	On any failure the caller must NOT save. The profile is in an unknown
	intermediate state, and writing it would make the corruption permanent. The
	stored data is still intact and must be left that way.
]]
function Migrations.run(
	profile: { [any]: any },
	fromVersion: number,
	targetVersion: number
): (boolean, { [any]: any }?, string?, { string })
	local working = profile
	local current = fromVersion

	-- Accumulated across every step, and returned on both success and failure -
	-- warnings from completed steps are diagnostic even when a later step fails.
	local warnings: { string } = {}

	while current < targetVersion do
		local step = Migrations.Steps[current]

		if step == nil then
			return false,
				nil,
				string.format("no migration registered for version %d -> %d", current, current + 1),
				warnings
		end

		local ok, result, stepWarnings = pcall(step, working)

		if not ok then
			return false,
				nil,
				string.format("migration %d -> %d raised an error: %s", current, current + 1, tostring(result)),
				warnings
		end

		if type(result) ~= "table" then
			return false,
				nil,
				string.format(
					"migration %d -> %d returned %s, expected a table",
					current,
					current + 1,
					typeof(result)
				),
				warnings
		end

		-- Warnings are tagged with the step that produced them, so a chain of
		-- several migrations stays readable in the log.
		if type(stepWarnings) == "table" then
			for _, warning in stepWarnings do
				table.insert(warnings, string.format("[%d->%d] %s", current, current + 1, tostring(warning)))
			end
		end

		working = result

		-- A step that does not advance Version would loop forever. Treat it as
		-- a bug in the migration rather than spinning.
		local produced = working.Version
		if type(produced) ~= "number" or produced <= current then
			return false,
				nil,
				string.format(
					"migration %d -> %d did not advance Version (got %s)",
					current,
					current + 1,
					tostring(produced)
				),
				warnings
		end

		current = produced
	end

	if current > targetVersion then
		return false,
			nil,
			string.format("migration overshot: reached version %d, target was %d", current, targetVersion),
			warnings
	end

	return true, working, nil, warnings
end

return Migrations
