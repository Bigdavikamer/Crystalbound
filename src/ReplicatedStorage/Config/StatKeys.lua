--!strict
--[[
	StatKeys

	The canonical set of stat keys. Data only - no logic.

	Every stat referenced by an item's BaseStats or by an affix must appear here.
	ItemRegistry validates that at boot, so a typo in a stat name fails loudly
	rather than silently contributing nothing.

	Adding a stat is a Config entry with no code change.

	Mode describes how contributions combine in StatResolver (Phase II):
		Additive       - flat contributions summed
		Multiplicative - percentage contributions summed, then applied once

	The canonical combination is specified in Sprint03Specification 7.2 and must
	exist in exactly one implementation.
]]

local StatKeys = {
	MiningPower = {
		Mode = "Additive",
		Default = 0,
		Min = 0,
	},

	MiningSpeed = {
		Mode = "Multiplicative",
		Default = 1,
		Min = 0.1,
	},

	Luck = {
		Mode = "Multiplicative",
		Default = 1,
		Min = 1,
	},

	CrystalFind = {
		Mode = "Multiplicative",
		Default = 0,
		Min = 0,
	},

	StackCapacity = {
		Mode = "Additive",
		Default = 0,
		Min = 0,
	},

	InstanceCapacity = {
		Mode = "Additive",
		Default = 0,
		Min = 0,
	},

	ExperienceGain = {
		Mode = "Multiplicative",
		Default = 1,
		Min = 0,
	},
}

return table.freeze(StatKeys)
