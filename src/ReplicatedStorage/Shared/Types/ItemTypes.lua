--!strict
--[[
	ItemTypes

	Type definitions for the item system.

	Exports types only - no runtime behaviour - so both the server systems and
	the future client may depend on it.

	These types encode the architectural pillar in Sprint03Specification section
	3: an ItemDefinition is immutable game data living in Config, an ItemInstance
	is one unique copy living in a player's save, and a resolved value is neither.
]]

export type ItemCategory = "Material" | "Crystal" | "Equipment" | "Consumable" | "Cosmetic"

export type EquipmentSlot = "Pickaxe" | "Bracelet" | "Hood" | "Hat" | "Mantle"

export type Rarity = "Common" | "Uncommon" | "Rare" | "Epic" | "Legendary"

export type AffixSlotRange = {
	Min: number,
	Max: number,
}

export type ItemDisplay = {
	Name: string,
	Icon: string,
	Description: string,
}

export type SalvageEntry = {
	ItemId: string,
	Count: number,
}

--[[
	Immutable game data for one item KIND. Lives in Config. Never written to a
	save. Identical for every player.
]]
export type ItemDefinition = {
	Id: string,
	Category: ItemCategory,
	Slot: EquipmentSlot?,
	Rarity: Rarity,
	Tier: number,

	Stackable: boolean,
	MaxStack: number,

	BaseStats: { [string]: number }?,
	AffixSlots: AffixSlotRange?,
	EvolutionLine: string?,

	-- The world this item KIND belongs to. How stackables carry Origin, since
	-- they have no instance to hold it (specification 4.4, R-11).
	NativeOrigin: string?,

	Tags: { string },
	SalvageYield: { SalvageEntry },
	Value: number,
	Display: ItemDisplay,
}

--[[
	One rolled affix on one instance.

	Roll is a normalised position in [0, 1] within the affix's Config range. The
	resolved value is Min + (Max - Min) * Roll, computed at runtime and never
	stored - this is what keeps Config rebalancing retroactive (specification 1.2).
]]
export type InstanceAffix = {
	Id: string,
	Roll: number,
}

--[[
	One unique COPY of an item, owned by one player, stored in their save.

	Origin is optional: nil means "no meaningful origin" and must always be
	handled as unknown, never as corruption (specification 4.2).

	Metadata is a RESERVED extension point with no behaviour in any current
	phase. It is stored sparsely - absent when empty, never written as {} -
	and is governed by specification 3.9.3.
]]
export type ItemInstance = {
	ItemId: string,
	Affixes: { InstanceAffix },
	Stage: number,
	Experience: number,
	Origin: string?,
	Locked: boolean,
	Favorite: boolean,
	CreatedAt: number,
	Metadata: { [string]: any }?,
}

--[[
	A resolved stat block. Runtime only - never persisted, never transmitted.
	Present here so Phase II has a name to use.
]]
export type StatBlock = { [string]: number }

return {}
