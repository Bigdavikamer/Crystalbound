--!strict
--[[
	ServiceLoader

	Loads the Service tier from ServerScriptService/Services.

	Services own gameplay logic. They initialise after Managers, so a Service
	may depend on Managers and on other Services.

	All discovery and validation is delegated to SystemLoader - this module
	only supplies the Service tier's configuration.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SystemLoader = require(script.Parent.SystemLoader)
local EngineTypes = require(ReplicatedStorage.Shared.Types.EngineTypes)

type SystemDescriptor = EngineTypes.SystemDescriptor

local CONFIG: SystemLoader.LoaderConfig = {
	Suffix = "Service",
	Tier = 2,
	TierName = "Service",
}

local ServiceLoader = {}

function ServiceLoader.Load(folder: Instance?): { [string]: SystemDescriptor }
	return SystemLoader.LoadFolder(folder, CONFIG)
end

return ServiceLoader
