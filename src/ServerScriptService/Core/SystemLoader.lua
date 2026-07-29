--!strict
--[[
	SystemLoader

	Generic discovery and validation for every loadable tier.

	Services, Managers and Controllers differ only in the folder they live in,
	the suffix their name must carry, and their tier rank. That shared work
	lives here so ServiceLoader and ManagerLoader stay thin instead of being
	near-identical copies of one another.

	Validation is deliberately strict. Enforcing the naming rules at boot turns
	CodingStandards from a document people are asked to remember into a rule
	the engine checks on every run.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Logger = require(script.Parent.Logger)
local EngineTypes = require(ReplicatedStorage.Shared.Types.EngineTypes)

type System = EngineTypes.System
type SystemDescriptor = EngineTypes.SystemDescriptor

export type LoaderConfig = {
	Suffix: string,
	Tier: number,
	TierName: string,
}

local log = Logger.Scoped("SystemLoader")

local SystemLoader = {}

--[[
	Checks that a required module matches the contract in CrystalEngineSpecification.

	Returns the validated system, or nil plus the reason it was rejected.
]]
local function validate(moduleScript: ModuleScript, value: any, config: LoaderConfig): (System?, string?)
	if type(value) ~= "table" then
		return nil, string.format("must return a table, got %s", typeof(value))
	end

	local system = value :: System

	if type(system.Name) ~= "string" or system.Name == "" then
		return nil, "must define a non-empty string 'Name'"
	end

	if system.Name ~= moduleScript.Name then
		return nil,
			string.format(
				"declares Name '%s' but the ModuleScript is named '%s'",
				system.Name,
				moduleScript.Name
			)
	end

	-- The length check rejects a name that is exactly the suffix. string.sub
	-- clamps on a negative index, so "Service" would otherwise match the
	-- "Service" suffix and register a system with no descriptive name at all.
	if #system.Name <= #config.Suffix or string.sub(system.Name, -#config.Suffix) ~= config.Suffix then
		return nil,
			string.format(
				"must end with '%s' and carry a descriptive prefix, for example 'Mining%s'",
				config.Suffix,
				config.Suffix
			)
	end

	if type(system.Version) ~= "number" then
		return nil, "must define a numeric 'Version'"
	end

	if system.Dependencies ~= nil then
		if type(system.Dependencies) ~= "table" then
			return nil, "'Dependencies' must be an array of strings"
		end
		for index, dependency in system.Dependencies do
			if type(dependency) ~= "string" then
				return nil, string.format("'Dependencies[%d]' must be a string", index)
			end
		end
	end

	if system.Initialize ~= nil and type(system.Initialize) ~= "function" then
		return nil, "'Initialize' must be a function when present"
	end

	if system.Start ~= nil and type(system.Start) ~= "function" then
		return nil, "'Start' must be a function when present"
	end

	return system, nil
end

--[[
	Requires and validates every ModuleScript directly inside a folder.

	A module that fails to require or fails validation is reported and excluded.
	The boot continues - one malformed system should not take the game down.

	No lifecycle method is called here.
]]
function SystemLoader.LoadFolder(folder: Instance?, config: LoaderConfig): { [string]: SystemDescriptor }
	local registry: { [string]: SystemDescriptor } = {}

	if folder == nil then
		log.Warning("No '%s' folder found - skipping the %s tier.", config.TierName, config.TierName)
		return registry
	end

	for _, child in folder:GetChildren() do
		if not child:IsA("ModuleScript") then
			continue
		end

		local ok, result = pcall(require, child)
		if not ok then
			log.Error("Failed to require %s: %s", child:GetFullName(), tostring(result))
			continue
		end

		local system, reason = validate(child, result, config)
		if system == nil then
			log.Error("Rejected %s: %s", child:GetFullName(), tostring(reason))
			continue
		end

		if registry[system.Name] ~= nil then
			log.Error(
				"Duplicate %s name '%s' - ignoring %s.",
				config.TierName,
				system.Name,
				child:GetFullName()
			)
			continue
		end

		registry[system.Name] = {
			Name = system.Name,
			Version = system.Version,
			Dependencies = system.Dependencies or {},
			Module = system,
			Tier = config.Tier,
			TierName = config.TierName,
			State = "Registered",
			InitDuration = 0,
		}

		log.Debug("Registered %s v%s", system.Name, tostring(system.Version))
	end

	return registry
end

return SystemLoader
