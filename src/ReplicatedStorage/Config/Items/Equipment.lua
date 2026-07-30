--!strict
--[[
	Items / Equipment

	Equipment definitions. Data only.

	Equipment is NOT stackable. Each copy is an ItemInstance in
	Inventory.Instances, carrying its own affix rolls, evolution state, lock and
	favourite flags, and Origin.

	BaseStats keys must exist in StatKeys - ItemRegistry enforces that at boot.

	This is a minimal starting set. pick_starter exists because the v1 to v2
	migration needs a valid target for the legacy "pickaxe_starter" value found
	in pre-migration saves.
]]

return {
	--[[
		The starter pickaxe.

		AffixSlots is { Min = 0, Max = 0 }: starter gear rolls no affixes. This
		matches the migration, which gives pre-affix items an empty affix list
		rather than retroactively rolling them free power.

		Value 0 and an empty SalvageYield make it worthless to sell or break
		down, which is correct for an item every player is given.
	]]
	pick_starter = {
		Id = "pick_starter",
		Category = "Equipment",
		Slot = "Pickaxe",
		Rarity = "Common",
		Tier = 1,

		Stackable = false,
		MaxStack = 1,

		BaseStats = {
			MiningPower = 3,
			MiningSpeed = 1,
		},

		AffixSlots = { Min = 0, Max = 0 },

		Tags = { "pickaxe", "starter" },
		SalvageYield = {},
		Value = 0,

		Display = {
			Name = "Worn Pickaxe",
			Icon = "",
			Description = "Chipped, loose in the haft, and entirely yours.",
		},
	},

	--[[
		A second definition, present so registry validation and slot lookup are
		exercised against more than one entry. Rolls affixes; not obtainable by
		any means until Phase III implements loot generation.
	]]
	pick_ironclad = {
		Id = "pick_ironclad",
		Category = "Equipment",
		Slot = "Pickaxe",
		Rarity = "Rare",
		Tier = 3,

		Stackable = false,
		MaxStack = 1,

		BaseStats = {
			MiningPower = 12,
			MiningSpeed = 1,
		},

		AffixSlots = { Min = 1, Max = 3 },

		Tags = { "pickaxe", "metal" },
		SalvageYield = {
			{ ItemId = "mat_iron_scrap", Count = 2 },
		},
		Value = 120,

		Display = {
			Name = "Ironclad Pickaxe",
			Icon = "",
			Description = "Banded in cold iron. Heavier than it looks, and it bites deeper for it.",
		},
	},
}
