--!strict
--[[
	PersistenceConfig

	Adjustable configuration for the player data layer. Data only - no logic.

	DataStoreName and KeyPrefix are read ONLY by StorageProvider. No key string
	crosses the module boundary, so the key format can change here without
	touching any consumer (specification 6.4).
]]

local PersistenceConfig = {
	--// Storage //-------------------------------------------------------------

	DataStoreName = "Crystalbound_PlayerData",

	-- Combined with UserId by StorageProvider. Private to that module.
	KeyPrefix = "Player_",

	--// Autosave //------------------------------------------------------------

	-- Seconds between autosave sweeps.
	AutosaveInterval = 120,

	-- Seconds between individual players within one sweep. Staggering spreads
	-- DataStore request budget instead of spiking it.
	AutosaveStagger = 2,

	--// Retry //---------------------------------------------------------------

	-- Attempts for a normal read or autosave write.
	RetryMaxAttempts = 4,

	-- Exponential backoff, in seconds, doubling up to the maximum.
	RetryBaseBackoff = 1,
	RetryMaxBackoff = 8,

	-- Attempts for a final save on player leave or server shutdown. Higher than
	-- RetryMaxAttempts because this is the last chance to persist (spec 8.6).
	FinalSaveMaxAttempts = 6,

	-- Seconds to wait for DataStore request budget to recover before issuing a
	-- request anyway. Bounded so a starved budget cannot block a load forever.
	BudgetWaitLimit = 10,

	--// Timing //--------------------------------------------------------------

	-- Default ceiling for waitForProfile, in seconds.
	LoadTimeout = 30,

	-- Seconds to wait for an in-flight autosave to finish before a final save,
	-- so the final save is never skipped by the one-write-at-a-time lock.
	SaveSlotWaitLimit = 5,

	-- Concurrent saves during shutdown, and the deadline to finish them.
	-- Roblox allows roughly 30 seconds inside BindToClose.
	ShutdownSaveConcurrency = 8,
	ShutdownSaveDeadline = 25,

	--// Player-facing messages //----------------------------------------------

	-- Kick messages. Config data rather than inline strings, so wording can
	-- change without touching logic and a localisation layer has a seam.
	Messages = table.freeze({
		TransientLoadFailure = "Unable to load your data. Please try joining again in a moment.",
		CorruptSave = "Your save data could not be loaded safely. Please contact support if this continues.",
		FutureSaveVersion = "Your save was created with a newer version of Crystalbound. Please update the game and try again.",
	}),
}

return table.freeze(PersistenceConfig)
