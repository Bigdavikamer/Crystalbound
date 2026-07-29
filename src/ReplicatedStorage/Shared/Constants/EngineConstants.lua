--!strict
--[[
	EngineConstants

	Adjustable engine configuration. Data only - no logic.

	These values control how CrystalEngine boots and reports. They are kept
	out of the engine modules so behaviour can be tuned without editing code.
]]

local EngineConstants = {
	-- Prefix applied to every Logger line.
	LogPrefix = "Crystalbound",

	-- Minimum level the Logger will emit: "Debug" | "Info" | "Warning" | "Error".
	-- Raise to "Info" for production to silence per-system boot chatter.
	LogLevel = "Debug",

	-- Prepend HH:MM:SS to every log line.
	ShowTimestamps = false,

	-- true  : a structural error (circular dependency, missing dependency,
	--         tier violation) aborts the entire boot.
	-- false : the offending tier is skipped and the boot continues.
	StrictBoot = true,

	-- Names of the ServerScriptService folders the engine loads systems from.
	Folders = table.freeze({
		Managers = "Managers",
		Services = "Services",
		Controllers = "Controllers",
	}),
}

return table.freeze(EngineConstants)
