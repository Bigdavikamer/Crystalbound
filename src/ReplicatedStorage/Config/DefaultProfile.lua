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
	--
	-- v2 (Sprint 03 Phase I): equipment slots hold InstanceIds instead of
	-- ItemIds, and Inventory.Instances exists. See Sprint03Specification 15.
	Version = 2,

	-- Identity and session lifecycle. Written only by PlayerDataService.
	Profile = {
		UserId = 0,
		CreatedAt = 0, -- unix seconds, set once on first join
		LastLoginAt = 0,
		LastSavedAt = 0,

		-- Allocator for instance IDs. Profile-local counter; IDs are stored as
		-- strings and never reused within a profile (R-4).
		--
		-- Strings matter: DataStore serialisation converts numeric table keys to
		-- strings on write, so a numeric ID would return as a string and every
		-- subsequent lookup would silently miss.
		NextInstanceId = 1,
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

	--[[
		Two storage strategies, chosen by item Category (specification 3.6).

		Items     - stackable and fungible: materials, crystals, consumables.
		Instances - unique copies: equipment. Each carries its own affix rolls,
		            evolution state, lock and favourite flags, and Origin.

		Capacity and InstanceCapacity are the player's OWNED slot counts.
		Effective capacity including equipment and upgrade bonuses is resolved at
		runtime and never saved.
	]]
	Inventory = {
		Capacity = 50, -- distinct stackable ItemIds
		Items = {}, -- [itemId] = count

		InstanceCapacity = 50, -- unique instances
		Instances = {}, -- [instanceId] = ItemInstance
	},

	--[[
		Equipped InstanceIds - NOT ItemIds. Changed in v2.

		An equipped instance stays in Inventory.Instances; equipping is a
		reference, not a move.

		Every slot is deliberately absent rather than set to nil, since a nil
		field creates no key. An absent slot means nothing is equipped, and
		validation must never treat that as corruption.

		New profiles start with every slot empty. A starter loadout is gameplay
		content requiring EquipmentService, which is Phase II - nothing can equip
		anything yet. Pre-v2 saves carrying "pickaxe_starter" are handled by the
		v1 to v2 migration, which converts it to a real instance.
	]]
	Equipment = {},

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
