--!strict
--[[
	Main

	Crystalbound server entry point.

	This script starts CrystalEngine and nothing else. All discovery, ordering
	and lifecycle work belongs to the engine - Bootstrap only points it at the
	folders it should load from.

	Keep this file minimal. If logic starts accumulating here, it belongs in a
	Service or a Manager instead.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

-- Dotted instance paths, not WaitForChild. On the server the DataModel is fully
-- loaded before any script runs, so waiting buys nothing - and WaitForChild
-- returns an opaque Instance, which costs the analyser its ability to resolve
-- the required module's type under --!strict.
local CrystalEngine = require(ServerScriptService.Core.CrystalEngine)
local EngineConstants = require(ReplicatedStorage.Shared.Constants.EngineConstants)

local FOLDERS = EngineConstants.Folders

CrystalEngine:RegisterManagers(ServerScriptService:FindFirstChild(FOLDERS.Managers))
CrystalEngine:RegisterServices(ServerScriptService:FindFirstChild(FOLDERS.Services))
CrystalEngine:RegisterControllers(ServerScriptService:FindFirstChild(FOLDERS.Controllers))

CrystalEngine:Start()
