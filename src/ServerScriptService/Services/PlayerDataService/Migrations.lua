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

	EMPTY AT VERSION 1. CURRENT_VERSION is 1 and there is no earlier version to
	migrate from, so there is nothing to register yet.
]]

local Migrations = {}

export type MigrationStep = ({ [any]: any }) -> { [any]: any }

Migrations.Steps = {} :: { [number]: MigrationStep }

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
): (boolean, { [any]: any }?, string?)
	local working = profile
	local current = fromVersion

	while current < targetVersion do
		local step = Migrations.Steps[current]

		if step == nil then
			return false,
				nil,
				string.format("no migration registered for version %d -> %d", current, current + 1)
		end

		local ok, result = pcall(step, working)

		if not ok then
			return false,
				nil,
				string.format("migration %d -> %d raised an error: %s", current, current + 1, tostring(result))
		end

		if type(result) ~= "table" then
			return false,
				nil,
				string.format(
					"migration %d -> %d returned %s, expected a table",
					current,
					current + 1,
					typeof(result)
				)
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
				)
		end

		current = produced
	end

	if current > targetVersion then
		return false,
			nil,
			string.format("migration overshot: reached version %d, target was %d", current, targetVersion)
	end

	return true, working, nil
end

return Migrations
