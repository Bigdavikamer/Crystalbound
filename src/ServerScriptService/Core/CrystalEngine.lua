--!strict
--[[
	CrystalEngine

	The framework that powers Crystalbound.

	The engine provides tools. Gameplay systems use those tools. No gameplay
	logic belongs in this module or anywhere else in Core.

	Responsibilities:
		- own the Manager, Service and Controller registries
		- validate the dependency graph before any system code runs
		- drive the two-phase Initialize / Start lifecycle
		- expose systems to one another through GetService / GetManager
		- track and report engine lifecycle state

	Discovery lives in the loaders, ordering lives in DependencyResolver, and
	output formatting lives in Logger. This module orchestrates them.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local DependencyResolver = require(script.Parent.DependencyResolver)
local Logger = require(script.Parent.Logger)
local ManagerLoader = require(script.Parent.ManagerLoader)
local ServiceLoader = require(script.Parent.ServiceLoader)
local SystemLoader = require(script.Parent.SystemLoader)

local EngineConstants = require(ReplicatedStorage.Shared.Constants.EngineConstants)
local EngineTypes = require(ReplicatedStorage.Shared.Types.EngineTypes)

type EngineState = EngineTypes.EngineState
type System = EngineTypes.System
type SystemDescriptor = EngineTypes.SystemDescriptor

local CONTROLLER_CONFIG: SystemLoader.LoaderConfig = {
	Suffix = "Controller",
	Tier = 3,
	TierName = "Controller",
}

local log = Logger.Scoped("CrystalEngine")

-- Per-tier registries. These tables are never reassigned - loaders merge into
-- them - so the ordered TIERS list below stays valid for the engine's lifetime.
local managers: { [string]: SystemDescriptor } = {}
local services: { [string]: SystemDescriptor } = {}
local controllers: { [string]: SystemDescriptor } = {}

-- Tier order is fixed by CrystalEngineSpecification: Managers, then Services,
-- then Controllers.
local TIERS = {
	{ Name = "Manager", Registry = managers },
	{ Name = "Service", Registry = services },
	{ Name = "Controller", Registry = controllers },
}

-- Every registered system across all tiers, rebuilt at boot.
local registry: { [string]: SystemDescriptor } = {}

-- Resolved initialisation order, produced during Start.
local bootOrder: { string } = {}

local CrystalEngine = {
	State = "Stopped" :: EngineState,
}

--// Internal helpers //--------------------------------------------------------

local function countOf(collection: { [string]: SystemDescriptor }): number
	local total = 0
	for _ in collection do
		total += 1
	end
	return total
end

local function merge(target: { [string]: SystemDescriptor }, source: { [string]: SystemDescriptor })
	for name, descriptor in source do
		target[name] = descriptor
	end
end

local function canRegister(tierName: string): boolean
	if CrystalEngine.State ~= "Stopped" then
		log.Error("Cannot register %ss while the engine is '%s'.", tierName, CrystalEngine.State)
		return false
	end
	return true
end

local function rebuildRegistry()
	table.clear(registry)
	for _, tier in TIERS do
		for name, descriptor in tier.Registry do
			registry[name] = descriptor
		end
	end
end

--[[
	Clears per-system lifecycle state so a boot attempt always starts clean.

	Start() can run again after an aborted boot, and descriptors survive between
	attempts. Without this reset a system left Blocked or Failed by the previous
	attempt would be skipped forever, even once the underlying problem is fixed.
]]
local function resetSystemStates()
	for _, descriptor in registry do
		descriptor.State = "Registered"
		descriptor.InitDuration = 0
	end
end

--[[
	Tiers are hard boundaries. Managers initialise before Services, so a Manager
	that depends on a Service could never have that reference satisfied.

	Catching this at boot with an explicit message beats a nil index at runtime.
]]
local function findTierViolation(): string?
	for name, descriptor in registry do
		for _, dependency in descriptor.Dependencies do
			local target = registry[dependency]
			if target ~= nil and target.Tier > descriptor.Tier then
				return string.format(
					"%s '%s' cannot depend on %s '%s'. %ss initialise before %ss - invert the dependency.",
					descriptor.TierName,
					name,
					target.TierName,
					dependency,
					descriptor.TierName,
					target.TierName
				)
			end
		end
	end
	return nil
end

--[[
	Returns the name of the first dependency that is unavailable.

	Because bootOrder is topological, a dependency is always evaluated before
	its dependents. Blocked therefore propagates forward on its own, and the
	failure of one system disables exactly the subtree that relied on it
	instead of producing a cascade of unrelated errors.
]]
local function firstUnavailableDependency(descriptor: SystemDescriptor): string?
	for _, dependency in descriptor.Dependencies do
		local target = registry[dependency]
		if target ~= nil and (target.State == "Failed" or target.State == "Blocked") then
			return dependency
		end
	end
	return nil
end

local function abort(reason: string)
	log.Error("Boot aborted: %s", reason)
	CrystalEngine.State = "Stopped"
end

--[[
	Phase 2 - resolve an initialisation order for every tier.

	Returns false when a structural error stops the boot.
]]
local function resolveBootOrder(): boolean
	table.clear(bootOrder)

	-- Names satisfied by tiers already resolved. A dependency found here needs
	-- no ordering constraint inside the current tier.
	local available: { [string]: boolean } = {}

	for _, tier in TIERS do
		local resolved, reason = DependencyResolver.Resolve(tier.Registry, available)

		if resolved == nil then
			if EngineConstants.StrictBoot then
				abort(tostring(reason))
				return false
			end

			log.Error("Skipping the %s tier: %s", tier.Name, tostring(reason))

			local skipped = 0
			for name, descriptor in tier.Registry do
				descriptor.State = "Blocked"

				-- Publish the name as satisfied even though the system will never
				-- initialise. Later tiers then resolve cleanly and report the real
				-- problem during Initialize - "dependency 'OreManager' is
				-- unavailable" - instead of claiming a system that plainly exists
				-- on disk was not found.
				available[name] = true
				skipped += 1
			end

			log.Warning(
				"%d %s(s) marked Blocked. Systems in later tiers that depend on them will be skipped.",
				skipped,
				tier.Name
			)
			continue
		end

		for _, name in resolved do
			table.insert(bootOrder, name)
			available[name] = true
		end
	end

	return true
end

--[[
	Phase 3 - Initialize, in resolved order.

	Sequential and blocking. Systems prepare state here but must not begin
	gameplay. Each call is protected so one failure cannot take down the boot.
]]
local function runInitializePhase()
	for _, name in bootOrder do
		local descriptor = registry[name]

		local blocker = firstUnavailableDependency(descriptor)
		if blocker ~= nil then
			descriptor.State = "Blocked"
			log.Warning("Skipped %s - dependency '%s' is unavailable.", name, blocker)
			continue
		end

		local initialize = descriptor.Module.Initialize
		if initialize == nil then
			descriptor.State = "Initialized"
			continue
		end

		local began = os.clock()
		local ok, err = pcall(initialize, descriptor.Module)
		descriptor.InitDuration = os.clock() - began

		if ok then
			descriptor.State = "Initialized"
			log.Debug("Initialized %s (%.2f ms)", name, descriptor.InitDuration * 1000)
		else
			descriptor.State = "Failed"
			log.Error("%s failed to initialize: %s", name, tostring(err))
		end
	end
end

--[[
	Phase 4 - Start, dispatched in resolved order.

	Each Start runs inside task.spawn. The specification permits Start to begin
	loops, and a system running `while true do` would deadlock a blocking
	sequence and the game would never finish booting.

	The resulting contract:
		Initialize guarantees every system EXISTS.
		Start guarantees every system has been DISPATCHED, not that it finished.
	A system must never assume another system's Start has completed.
]]
local function runStartPhase()
	for _, name in bootOrder do
		local descriptor = registry[name]
		if descriptor.State ~= "Initialized" then
			continue
		end

		local start = descriptor.Module.Start
		if start == nil then
			continue
		end

		task.spawn(function()
			local ok, err = pcall(start, descriptor.Module)
			if not ok then
				log.Error("%s failed to start: %s", name, tostring(err))
			end
		end)
	end
end

--[[
	Startup diagnostics, logged once the boot completes.
]]
local function reportStartup(bootBegan: number)
	local failed, blocked = 0, 0
	for _, descriptor in registry do
		if descriptor.State == "Failed" then
			failed += 1
		elseif descriptor.State == "Blocked" then
			blocked += 1
		end
	end

	local controllerCount = countOf(controllers)

	log.Info("CrystalEngine online")
	log.Info("  %-11s : %d", "Managers", countOf(managers))
	log.Info("  %-11s : %d", "Services", countOf(services))
	if controllerCount > 0 then
		log.Info("  %-11s : %d", "Controllers", controllerCount)
	end
	log.Info("  %-11s : %.2f ms", "Boot", (os.clock() - bootBegan) * 1000)
	log.Info("  %-11s : %s", "State", CrystalEngine.State)

	if failed > 0 or blocked > 0 then
		log.Warning("  %d system(s) failed to initialize, %d blocked by a failed dependency.", failed, blocked)
	end
end

local function fetch(
	collection: { [string]: SystemDescriptor },
	tierName: string,
	name: string
): System
	local descriptor = collection[name]
	if descriptor == nil then
		error(
			string.format(
				"Unknown %s '%s'. Check that it exists in ServerScriptService/%ss and that its Name matches its ModuleScript.",
				tierName,
				name,
				tierName
			),
			3
		)
	end
	return descriptor.Module
end

--// Registration //------------------------------------------------------------

function CrystalEngine:RegisterManagers(folder: Instance?)
	if not canRegister("Manager") then
		return
	end
	merge(managers, ManagerLoader.Load(folder))
end

function CrystalEngine:RegisterServices(folder: Instance?)
	if not canRegister("Service") then
		return
	end
	merge(services, ServiceLoader.Load(folder))
end

function CrystalEngine:RegisterControllers(folder: Instance?)
	if not canRegister("Controller") then
		return
	end
	merge(controllers, SystemLoader.LoadFolder(folder, CONTROLLER_CONFIG))
end

--// Lifecycle //---------------------------------------------------------------

--[[
	Boots the engine.

	Structural errors - circular dependencies, missing dependencies, tier
	violations - abort before any system code runs. A broken graph means the
	codebase is wrong, and booting a half-valid game would hide that.

	Runtime errors inside a single Initialize or Start are contained: that
	system and its dependents are disabled, everything else still runs.
]]
function CrystalEngine:Start()
	if CrystalEngine.State ~= "Stopped" then
		log.Error("Start() called while the engine is '%s'. Ignoring.", CrystalEngine.State)
		return
	end

	local bootBegan = os.clock()

	CrystalEngine.State = "Initializing"

	rebuildRegistry()
	resetSystemStates()

	local violation = findTierViolation()
	if violation ~= nil then
		abort(violation)
		return
	end

	if not resolveBootOrder() then
		return
	end

	runInitializePhase()
	CrystalEngine.State = "Initialized"

	CrystalEngine.State = "Starting"
	runStartPhase()

	CrystalEngine.State = "Running"
	reportStartup(bootBegan)
end

--// Accessors //---------------------------------------------------------------

function CrystalEngine:GetService(name: string): System
	return fetch(services, "Service", name)
end

function CrystalEngine:GetManager(name: string): System
	return fetch(managers, "Manager", name)
end

function CrystalEngine:GetController(name: string): System
	return fetch(controllers, "Controller", name)
end

function CrystalEngine:GetState(): EngineState
	return CrystalEngine.State
end

function CrystalEngine:IsStarted(): boolean
	return CrystalEngine.State == "Running"
end

return CrystalEngine
