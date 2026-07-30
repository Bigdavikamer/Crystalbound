--!strict
--[[
	DefaultProfile

	Starting values for a new player. Data only - no logic.

	Every field here is either OWNED state or PROGRESSION state. Nothing here is
	a calculated gameplay value. See Sprint02Specification 9.2 and 9.3.

	Version is the single source of truth for the schema version. Bumping the
	schema means bumping this field and CURRENT_VERSION in PlayerDataService
	together - the service asserts they match during Initialize.

	The returned table is frozen at the top level. Freezing is shallow, so nested
	sections remain writable: deepCopy before use is what actually protects the
	template, and it is mandatory. Recursive freezing is deferred to a hardening
	sprint.
]]

local DefaultProfile = {
	-- Save schema version. Owned exclusively by PlayerDataService.
	Version = 1,

	-- Identity and session lifecycle. Written only by PlayerDataService.
	Profile = {
		UserId = 0,
		CreatedAt = 0, -- unix seconds, set once on first join
		LastLoginAt = 0,
		LastSavedAt = 0,
	},

	-- Spendable balances only.
	-- Materials and crystals are Inventory items, not currency.
	--
	-- Intentionally empty. The game economy is not finalised and no currency
	-- names are assumed here. Adding a currency later is a purely ADDITIVE
	-- change (specification 10.2): a new key with a default of 0 is backfilled
	-- into every existing save on its next load, with no version bump and no
	-- migration. Deferring the economy costs nothing.
	--
	-- When names are decided, add them here as `<Name> = 0`.
	Currency = {},

	-- Progression the player has earned.
	-- Upgrades store OWNED LEVELS. The resulting multipliers are calculated at
	-- runtime from Config and never saved.
	Progression = {
		Level = 1,
		Experience = 0,
		Upgrades = {
			Luck = 0, -- level, not a luck multiplier
			MiningSpeed = 0, -- level, not a speed value
		},
	},

	-- Capacity and Items only.
	-- Capacity is the player's OWNED slot count. Effective capacity
	-- (base + equipment bonuses) is calculated at runtime, never saved.
	Inventory = {
		Capacity = 50,
		Items = {}, -- [itemId] = count
	},

	-- Equipped item IDs only. Stats are NEVER saved - they are read from Config
	-- by ID and recalculated after every load.
	--
	-- Only Pickaxe carries a starting value. The remaining slots - Bracelet,
	-- Hood, Hat, Mantle - are deliberately absent rather than set to nil, since
	-- a nil field creates no key. An absent slot means nothing is equipped, and
	-- validation must never treat that as corruption.
	Equipment = {
		Pickaxe = "pickaxe_starter",
	},

	-- What the player has DISCOVERED. Never completion percentages - those are
	-- calculated against Config's full catalogue at runtime.
	-- World ACCESS lives in Unlocks.Worlds; this is exploration progress.
	WorldExploration = {
		CurrentWorld = "world_starter",
		DiscoveredAreas = {}, -- [areaId] = true
		DiscoveredLandmarks = {}, -- [landmarkId] = true
	},

	-- Mission PROGRESS only. Objectives, targets and rewards live in Config.
	Missions = {
		Active = {}, -- [missionId] = { Progress = { [objectiveId] = number }, StartedAt = number }
		Completed = {}, -- [missionId] = completionCount, supports repeatables
		LastDailyReset = 0,
	},

	-- Permanent record of everything ever found, independent of Inventory.
	-- Inventory is what you HOLD; Collection is what you have EVER SEEN.
	-- Collection completion percentage is calculated, never stored.
	Collection = {
		Crystals = {}, -- [crystalId] = { FirstFoundAt = number, TimesFound = number }
		Materials = {}, -- [materialId] = { FirstFoundAt = number, TimesFound = number }
		Equipment = {}, -- [equipmentId] = { FirstObtainedAt = number }
	},

	-- Access and entitlement flags.
	-- Recipes stores WHICH recipes are known. Recipe contents are Config.
	Unlocks = {
		Worlds = { world_starter = true },
		Features = {}, -- [featureId] = true
		Recipes = {}, -- [recipeId] = true
		Achievements = {}, -- [achievementId] = true
	},

	-- Lifetime counters that CANNOT be reconstructed from other sections.
	-- Deliberately excluded: MissionsCompleted (derive from Missions.Completed),
	-- CrystalsDiscovered (derive from Collection.Crystals). Storing a derivable
	-- value creates two sources of truth that will drift.
	Statistics = {
		TotalPlayTime = 0, -- seconds
		SessionCount = 0,
		OresMined = 0,
		ItemsCrafted = 0,
		LuckiestRoll = 0,
	},

	-- Player preferences. The only section a client may request changes to, and
	-- therefore the only section needing input clamping on write.
	Settings = {
		MusicVolume = 1,
		SfxVolume = 1,
		ScreenShake = true,
		RarityNotifications = true,
	},
}

return table.freeze(DefaultProfile)
