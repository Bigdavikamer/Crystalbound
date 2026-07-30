--!strict
--[[
	Items / Materials

	Stackable material definitions. Data only.

	Materials are fungible: one mat_iron_scrap is any other, so they live in
	Inventory.Items as [itemId] = count and carry no instance.

	Because they have no instance, a material's Origin is a property of the item
	KIND, declared here as NativeOrigin (specification 4.4, R-11). A generic
	material has no NativeOrigin and needs none.

	This is a minimal starting set. The item catalogue itself is content work,
	not Phase I infrastructure.
]]

return {
	-- Generic material. No NativeOrigin: it belongs to no particular world.
	mat_iron_scrap = {
		Id = "mat_iron_scrap",
		Category = "Material",
		Rarity = "Common",
		Tier = 1,

		Stackable = true,
		MaxStack = 999,

		Tags = { "metal", "scrap" },
		SalvageYield = {},
		Value = 2,

		Display = {
			Name = "Iron Scrap",
			Icon = "",
			Description = "Rough fragments of worked iron. Common, and always useful.",
		},
	},

	-- World-native material. NativeOrigin is how a recipe requiring a material
	-- "from the Crystal Caverns" is satisfied without a per-copy field.
	mat_azure_shard = {
		Id = "mat_azure_shard",
		Category = "Material",
		Rarity = "Uncommon",
		Tier = 2,

		Stackable = true,
		MaxStack = 999,

		NativeOrigin = "world_crystal_caverns",

		Tags = { "crystalline", "azure" },
		SalvageYield = {},
		Value = 11,

		Display = {
			Name = "Azure Shard",
			Icon = "",
			Description = "A splinter of cavern crystal that holds the cold long after it is mined.",
		},
	},
}
