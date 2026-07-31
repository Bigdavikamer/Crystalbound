--!strict
--[[
	StatKeys

	The canonical set of stat keys. Data only - no logic.

	Every stat referenced by an item's BaseStats or by an affix must appear here.
	ItemRegistry validates that at boot, so a typo in a stat name fails loudly
	rather than silently contributing nothing.

	Adding a stat is a Config entry with no code change.

	FIELDS

		Default  the stat's value with nothing equipped and no modifiers.
		         0 for stats that accumulate from zero, 1 for stats that are
		         ratios and must start neutral.
		Min      lower clamp, applied after combination. Optional.
		Max      upper clamp, applied after combination. Optional.

	A per-key "Mode" field was removed in Phase II. It was redundant with Default
	- 0 versus 1 already says whether a stat accumulates or is a ratio - and it
	sat confusingly next to StatModifier.Mode, which means something else
	entirely (whether a single contribution is Flat or Percent).

	ONE FORMULA FOR EVERY STAT (Sprint03Specification 7.2):

		value = (Default + flatTotal) * (1 + percentTotal), clamped

	Default participating in the flat term is what lets one formula serve both
	shapes. MiningPower starts at 0 and accumulates; MiningSpeed starts at 1, so
	a +0.2 flat and a +10% modifier resolve to (1 + 0.2) * 1.1 = 1.32.

	That formula exists in exactly one place: StatResolver.
]]

local StatKeys = {
	MiningPower = {
		Default = 0,
		Min = 0,
	},

	MiningSpeed = {
		Default = 1,
		Min = 0.1,
	},

	Luck = {
		Default = 1,
		Min = 1,
	},

	CrystalFind = {
		Default = 0,
		Min = 0,
	},

	StackCapacity = {
		Default = 0,
		Min = 0,
	},

	InstanceCapacity = {
		Default = 0,
		Min = 0,
	},

	ExperienceGain = {
		Default = 1,
		Min = 0,
	},
}

return table.freeze(StatKeys)
