--!strict
--[[
	ProfileTypes

	Type definitions for the player profile.

	This module exports types only. It contains no runtime behaviour, so it is
	safe for the server data layer, future gameplay services, and eventually the
	client to depend on.

	Every section here mirrors Sprint02Specification section 9.2. When the schema
	changes, this file and DefaultProfile.lua change together.
]]

-- Identity and session lifecycle. Written only by PlayerDataService.
export type ProfileMeta = {
	UserId: number,
	CreatedAt: number,
	LastLoginAt: number,
	LastSavedAt: number,
}

-- Spendable balances. Open map: currency names are not yet decided, and adding
-- one later is a purely additive change requiring no version bump.
export type Currency = { [string]: number }

-- Owned upgrade LEVELS. The multipliers they produce are calculated from Config
-- at runtime and never stored.
export type Upgrades = { [string]: number }

export type Progression = {
	Level: number,
	Experience: number,
	Upgrades: Upgrades,
}

-- Capacity is the player's OWNED slot count. Effective capacity including
-- equipment bonuses is calculated at runtime and never stored.
export type Inventory = {
	Capacity: number,
	Items: { [string]: number },
}

-- Equipped item IDs only. Stats are never stored - they are read from Config by
-- ID. An absent slot means nothing is equipped.
export type Equipment = {
	Pickaxe: string?,
	Bracelet: string?,
	Hood: string?,
	Hat: string?,
	Mantle: string?,
}

-- Discovered content only. Completion percentages are calculated against
-- Config's full catalogue and never stored.
export type WorldExploration = {
	CurrentWorld: string,
	DiscoveredAreas: { [string]: boolean },
	DiscoveredLandmarks: { [string]: boolean },
}

export type MissionProgress = {
	Progress: { [string]: number },
	StartedAt: number,
}

export type Missions = {
	Active: { [string]: MissionProgress },
	Completed: { [string]: number },
	LastDailyReset: number,
}

export type CollectionEntry = {
	FirstFoundAt: number?,
	TimesFound: number?,
	FirstObtainedAt: number?,
}

-- Permanent record of everything ever found. Distinct from Inventory:
-- Inventory is what the player HOLDS, Collection is what they have EVER SEEN.
export type Collection = {
	Crystals: { [string]: CollectionEntry },
	Materials: { [string]: CollectionEntry },
	Equipment: { [string]: CollectionEntry },
}

-- Access and entitlement flags. Recipes stores which recipes are KNOWN;
-- recipe contents live in Config.
export type Unlocks = {
	Worlds: { [string]: boolean },
	Features: { [string]: boolean },
	Recipes: { [string]: boolean },
	Achievements: { [string]: boolean },
}

-- Lifetime counters that cannot be reconstructed from other sections.
export type Statistics = {
	TotalPlayTime: number,
	SessionCount: number,
	OresMined: number,
	ItemsCrafted: number,
	LuckiestRoll: number,
}

export type Settings = {
	MusicVolume: number,
	SfxVolume: number,
	ScreenShake: boolean,
	RarityNotifications: boolean,
}

export type Profile = {
	Version: number,
	Profile: ProfileMeta,
	Currency: Currency,
	Progression: Progression,
	Inventory: Inventory,
	Equipment: Equipment,
	WorldExploration: WorldExploration,
	Missions: Missions,
	Collection: Collection,
	Unlocks: Unlocks,
	Statistics: Statistics,
	Settings: Settings,
}

return {}
