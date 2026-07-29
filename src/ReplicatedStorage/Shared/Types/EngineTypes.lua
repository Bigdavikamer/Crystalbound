--!strict
--[[
	EngineTypes

	Type definitions shared by every CrystalEngine system.

	This module exports types only. It contains no runtime behaviour and no
	gameplay logic, so it is safe for both the server engine and the future
	ClientEngine to depend on.
]]

--[[
	Lifecycle state of a single loadable system.

	Registered  - discovered and validated, Initialize has not run yet
	Initialized - Initialize completed successfully
	Failed      - Initialize raised an error
	Blocked     - skipped because one of its dependencies Failed or was Blocked
]]
export type SystemState = "Registered" | "Initialized" | "Failed" | "Blocked"

--[[
	Lifecycle state of the engine itself.

	Stopped      - not booted, or the boot was aborted
	Initializing - resolving dependencies and running Initialize
	Initialized  - every system has completed Initialize
	Starting     - dispatching Start
	Running      - boot complete
]]
export type EngineState = "Stopped" | "Initializing" | "Initialized" | "Starting" | "Running"

--[[
	The shape every Service, Manager and Controller must return.

	Name and Version are required metadata. Dependencies, Initialize and Start
	are optional - a configuration-only system needs none of them.
]]
export type System = {
	Name: string,
	Version: number,
	Dependencies: { string }?,
	Initialize: ((any) -> ())?,
	Start: ((any) -> ())?,
}

--[[
	The engine's internal record for a registered system.

	Loaders produce these, DependencyResolver orders them, and CrystalEngine
	drives their lifecycle.
]]
export type SystemDescriptor = {
	Name: string,
	Version: number,
	Dependencies: { string },
	Module: System,
	Tier: number,
	TierName: string,
	State: SystemState,
	InitDuration: number,
}

return {}
