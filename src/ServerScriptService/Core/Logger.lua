--!strict
--[[
	Logger

	Centralised logging for CrystalEngine.

	Provides four levels - Debug, Info, Warning, Error - filtered against a
	threshold from EngineConstants. Output is standardised so every line is
	traceable to the system that produced it:

		[Crystalbound][INFO][MiningService] Started

	Logger reports; it never throws. Raising an error from inside the logger
	would unwind the boot sequence and cascade, which the engine specification
	explicitly forbids. Failure policy belongs to CrystalEngine.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local EngineConstants = require(ReplicatedStorage.Shared.Constants.EngineConstants)

export type LogLevel = "Debug" | "Info" | "Warning" | "Error"

export type ScopedLogger = {
	Debug: (message: string, ...any) -> (),
	Info: (message: string, ...any) -> (),
	Warning: (message: string, ...any) -> (),
	Error: (message: string, ...any) -> (),
}

local LEVEL_ORDER: { [string]: number } = {
	Debug = 1,
	Info = 2,
	Warning = 3,
	Error = 4,
}

local LEVEL_TAG: { [string]: string } = {
	Debug = "DEBUG",
	Info = "INFO",
	Warning = "WARN",
	Error = "ERROR",
}

local DEFAULT_SCOPE = "Engine"
local FALLBACK_LEVEL = "Info"

--[[
	Resolves the starting log level from configuration.

	EngineConstants is edited by hand, so an invalid level is a realistic
	mistake. Left unvalidated it would make every later comparison against
	LEVEL_ORDER fail, taking the boot down from inside the logger itself -
	before any diagnostic output exists to explain why.

	A bad log level must never be fatal: warn once, fall back, keep booting.
]]
local function resolveInitialLevel(): string
	local configured = EngineConstants.LogLevel

	if type(configured) == "string" and LEVEL_ORDER[configured] ~= nil then
		return configured
	end

	-- Logger is not usable yet, so this single line goes out through warn directly.
	warn(
		string.format(
			"[%s][WARN][Logger] EngineConstants.LogLevel is '%s', which is not a valid level. "
				.. "Falling back to '%s'. Valid levels: Debug, Info, Warning, Error.",
			tostring(EngineConstants.LogPrefix),
			tostring(configured),
			FALLBACK_LEVEL
		)
	)

	return FALLBACK_LEVEL
end

local activeLevel: string = resolveInitialLevel()

local Logger = {}

--[[
	Builds a formatted line, or returns nil when the level is below threshold.

	Formatting is only applied when varargs are supplied, so a message
	containing a literal '%' is safe to log on its own.
]]
local function compose(level: string, scope: string, message: string, ...: any): string?
	if LEVEL_ORDER[level] < LEVEL_ORDER[activeLevel] then
		return nil
	end

	local body = message
	if select("#", ...) > 0 then
		local ok, formatted = pcall(string.format, message, ...)
		if ok then
			body = formatted
		end
	end

	local prefix = string.format("[%s][%s][%s]", EngineConstants.LogPrefix, LEVEL_TAG[level], scope)
	if EngineConstants.ShowTimestamps then
		prefix = string.format("[%s]%s", os.date("%H:%M:%S"), prefix)
	end

	return prefix .. " " .. body
end

local function emit(level: string, scope: string, message: string, ...: any)
	local line = compose(level, scope, message, ...)
	if line == nil then
		return
	end

	if level == "Error" or level == "Warning" then
		warn(line)
	else
		print(line)
	end
end

function Logger.Debug(message: string, ...: any)
	emit("Debug", DEFAULT_SCOPE, message, ...)
end

function Logger.Info(message: string, ...: any)
	emit("Info", DEFAULT_SCOPE, message, ...)
end

function Logger.Warning(message: string, ...: any)
	emit("Warning", DEFAULT_SCOPE, message, ...)
end

function Logger.Error(message: string, ...: any)
	emit("Error", DEFAULT_SCOPE, message, ...)
end

--[[
	Returns a logger that tags every line with the given scope.

		local log = Logger.Scoped("MiningService")
		log.Info("Started")  --> [Crystalbound][INFO][MiningService] Started
]]
function Logger.Scoped(scope: string): ScopedLogger
	return {
		Debug = function(message: string, ...: any)
			emit("Debug", scope, message, ...)
		end,
		Info = function(message: string, ...: any)
			emit("Info", scope, message, ...)
		end,
		Warning = function(message: string, ...: any)
			emit("Warning", scope, message, ...)
		end,
		Error = function(message: string, ...: any)
			emit("Error", scope, message, ...)
		end,
	}
end

function Logger.SetLevel(level: LogLevel)
	if LEVEL_ORDER[level] == nil then
		Logger.Warning("Ignored unknown log level '%s'.", tostring(level))
		return
	end
	activeLevel = level
end

function Logger.GetLevel(): LogLevel
	return activeLevel :: LogLevel
end

return Logger
