--!strict
--[[
	StatResolver

	The single implementation of Crystalbound's stat combination formula.

	A PURE MODULE. Given identical inputs it always produces identical outputs.
	It keeps no state between calls, owns no cache, and has no lifecycle - no
	Initialize, no Start.

	=========================================================================
	 NON-RESPONSIBILITIES
	=========================================================================

	This module must NEVER:

		read or write PlayerData, Inventory or Equipment
		call any Service, or CrystalEngine:GetService
		fire events
		cache results
		mutate item instances
		allocate ids
		persist data
		perform networking
		know that players exist

	If any of those become necessary, the architecture is wrong rather than this
	module being incomplete.

	It also must never require Logger. Logger lives in ServerScriptService/Core,
	which the client cannot see, and this module runs identically on both sides -
	that is precisely why resolved stats never need to cross the wire.

	=========================================================================
	 WHAT IT KNOWS, AND WHAT IT REFUSES TO KNOW
	=========================================================================

	It knows only what is derivable from an ItemId plus Config: base stats, and
	in later phases affix rolls and evolution multipliers.

	Everything Service-owned - upgrades, buffs, debuffs, world modifiers, event
	bonuses - arrives already normalised as StatModifiers. That boundary is what
	keeps this module free of Service dependencies while remaining the only place
	stats are combined (Sprint03Specification II-2).

	It does not know about SLOTS. Instances arrive as a flat array inside a
	StatContext, never as a slot map. "Pickaxe" and "Mantle" are
	EquipmentService's vocabulary. Equipment layout, ownership and validity are
	settled before data arrives here; this module assumes its inputs are valid.

	=========================================================================
	 WHY IT DOES NOT VALIDATE MODIFIERS
	=========================================================================

	A modifier naming a stat key that does not exist contributes nothing, and
	this module says nothing about it. That is deliberate, and it is only correct
	because validation belongs where modifiers are CONSTRUCTED:

		Item definitions   validated by ItemRegistry at boot
		Runtime modifiers  validated by the service that builds them

	An unknown stat key in a modifier is a CODE error, not a data error, so it
	should fail at the line that wrote it - with that service's context - rather
	than deep inside a consumer that cannot say who sent it.

	Erroring here was rejected for two concrete reasons. This module runs on the
	client, where one malformed modifier would break all stat display rather than
	one buff. And an environment-dependent check such as RunService:IsStudio()
	would make behaviour differ by where the code runs, which directly violates
	the determinism requirement above.

	This module also does NOT provide a modifier constructor. Modifiers are
	gameplay objects belonging to the systems that produce them, and a
	consumer-owned constructor would both invert that ownership and force every
	producer to depend on the resolver for no other reason. A producer validates
	its own key against StatKeys - one line - before emitting.

	The general rule is R-20: every system validates the objects it produces;
	downstream consumers assume trusted inputs.

	=========================================================================
	 THE FORMULA
	=========================================================================

		per stat key k:

			flat    = StatKeys[k].Default
			        + sum over equipped instances of
			              BaseStats[k] * evolutionMultiplier(instance)
			        + sum of Flat modifiers for k

			percent = sum of Percent modifiers for k

			value   = flat * (1 + percent)
			value   = clamp(value, Min, Max)

	Additive-before-multiplicative, applied once. Combining per-source instead
	produces wildly different balance, and two implementations drifting is a bug
	class that is nearly undiagnosable from player reports - which is why this
	formula exists in exactly one place.

	Evolution scales an item's FLAT contributions only (II-6). Scaling its
	percent contributions as well would compound multiplicatively in a way that
	is very difficult to balance.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ItemRegistry = require(ReplicatedStorage.Modules.ItemRegistry)
local StatKeys = require(ReplicatedStorage.Config.StatKeys)
local ItemTypes = require(ReplicatedStorage.Shared.Types.ItemTypes)

type ItemInstance = ItemTypes.ItemInstance
type StatBlock = ItemTypes.StatBlock

export type ModifierMode = "Flat" | "Percent"

--[[
	One normalised stat contribution from a Service-owned source.

	Sources translate their own domain into modifiers; this module combines them.
	That split is what lets buffs, world modifiers and events be added later
	without StatResolver learning anything about them.

	Source is provenance for debugging - "why is my mining power 47?" - and is
	never persisted or transmitted.
]]
export type StatModifier = {
	StatKey: string,
	Mode: ModifierMode,
	Value: number,
	Source: string?,
}

--[[
	Everything that contributes to one resolution, in one object.

	A context rather than positional parameters so that future contribution
	sources - natures, crystal pets, temporary buffs, guild bonuses - can be
	added without widening the signature and rewriting every call site.

	Most such sources will not need a new field at all: anything a service can
	express as a normalised contribution belongs in Modifiers. A new field is
	warranted only for a source that genuinely combines differently, and the
	context is what makes adding one a non-event.

	Instances is a FLAT ARRAY. Slot layout never reaches this module.
]]
export type StatContext = {
	Instances: { ItemInstance },
	Modifiers: { StatModifier }?,
}

local StatResolver = {}

--[[
	The evolution multiplier for one instance.

	Phase II stub: EvolutionLines Config does not exist until Phase V, so every
	instance resolves at 1.0. The seam is present so the formula's final shape is
	visible now, and Phase V replaces one function rather than restructuring the
	accumulation loop.
]]
local function evolutionMultiplier(instance: ItemInstance): number
	return 1
end

--[[
	Accumulates flat and percent contributions from every source.

	Mutates the two tables it is given. They are locals created per call in
	resolve, so nothing survives between calls.

	Iteration is over the instances array and the modifiers array in order, so
	floating-point summation is performed in a stable sequence and the result is
	reproducible.
]]
local function accumulate(
	instances: { ItemInstance },
	modifiers: { StatModifier }?,
	flat: { [string]: number },
	percent: { [string]: number }
)
	for _, instance in instances do
		local definition = ItemRegistry.get(instance.ItemId)

		-- An instance whose item was removed from Config contributes nothing
		-- rather than raising. Consistent with IB-7: unknown items degrade
		-- gracefully and are never destroyed.
		if definition == nil or definition.BaseStats == nil then
			continue
		end

		local multiplier = evolutionMultiplier(instance)

		for statKey, baseValue in definition.BaseStats do
			flat[statKey] = (flat[statKey] or 0) + baseValue * multiplier
		end

		-- Affix contributions attach here in Phase III, once AffixRegistry can
		-- translate { Id, Roll } into a value via Min + (Max - Min) * Roll.
		-- Instances may already carry affixes; they contribute nothing until
		-- those definitions exist, because there is nothing to resolve against.
	end

	if modifiers == nil then
		return
	end

	for _, modifier in modifiers do
		if modifier.Mode == "Flat" then
			flat[modifier.StatKey] = (flat[modifier.StatKey] or 0) + modifier.Value
		elseif modifier.Mode == "Percent" then
			percent[modifier.StatKey] = (percent[modifier.StatKey] or 0) + modifier.Value
		end
	end
end

--[[
	Resolves a context into a stat block.

	Returns a brand-new frozen table containing every key in StatKeys, always.
	A player with nothing equipped receives a full block of defaults, so
	consumers never need to nil-check a stat.

	Contributions addressed to a stat key that does not exist in StatKeys are
	discarded. Item definitions cannot carry one - ItemRegistry rejects unknown
	stat keys at boot - so this applies only to runtime modifiers, whose
	correctness is owned at the point they are constructed, not here.

	The context is assumed valid. A malformed one fails loudly rather than
	resolving to something plausible-looking, which is the right trade for a
	caller bug.
]]
function StatResolver.resolve(context: StatContext): StatBlock
	local flat: { [string]: number } = {}
	local percent: { [string]: number } = {}

	accumulate(context.Instances, context.Modifiers, flat, percent)

	local resolved: StatBlock = {}

	for statKey, keyDefinition in StatKeys do
		local value = (keyDefinition.Default + (flat[statKey] or 0)) * (1 + (percent[statKey] or 0))

		if keyDefinition.Min ~= nil and value < keyDefinition.Min then
			value = keyDefinition.Min
		end
		if keyDefinition.Max ~= nil and value > keyDefinition.Max then
			value = keyDefinition.Max
		end

		resolved[statKey] = value
	end

	-- A brand-new immutable table: flat numbers only, so a shallow freeze is
	-- total. No metatables, no methods, and no reference to anything this module
	-- retains.
	return table.freeze(resolved)
end

return StatResolver
