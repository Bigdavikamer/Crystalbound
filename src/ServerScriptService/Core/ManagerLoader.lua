--!strict
--[[
	ManagerLoader

	Loads the Manager tier from ServerScriptService/Managers.

	Managers control collections of objects and world systems. They initialise
	first, so a Manager may only depend on other Managers - depending on a
	Service is a tier violation and is rejected at boot.

	All discovery and validation is delegated to SystemLoader - this module
	only supplies the Manager tier's configuration.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SystemLoader = require(script.Parent.SystemLoader)
local EngineTypes = require(ReplicatedStorage.Shared.Types.EngineTypes)

type SystemDescriptor = EngineTypes.SystemDescriptor

local CONFIG: SystemLoader.LoaderConfig = {
	Suffix = "Manager",
	Tier = 1,
	TierName = "Manager",
}

local ManagerLoader = {}

function ManagerLoader.Load(folder: Instance?): { [string]: SystemDescriptor }
	return SystemLoader.LoadFolder(folder, CONFIG)
end

return ManagerLoader
