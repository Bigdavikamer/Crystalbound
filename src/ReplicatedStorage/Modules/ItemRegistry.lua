--!strict
--[[
	ItemRegistry

	Read-only lookup for every item definition.

	A Shared module rather than a Service: both server and client need definition
	lookup, and it holds no mutable state.

	Placed in ReplicatedStorage/Modules per Architecture.md, which defines Modules
	as the home for reusable modules. Sprint03Specification 14.1 said
	Shared/Modules; that folder does not exist and Shared is scoped to Constants,
	Types and Utilities.

	READ-ONLY BY CONSTRUCTION

	This module answers "what is defined?" and nothing else. Every definition it
	returns is deep frozen by Registry, so Config cannot be mutated through a
	lookup.

	It must NEVER contain:
		- stat resolution           -> StatResolver        (Phase II)
		- equipment calculations    -> EquipmentService    (Phase II)
		- affix resolution          -> AffixResolver       (Phase III)
		- loot generation           -> LootService         (Phase III)
		- evolution logic           -> EquipmentService    (Phase V)
		- item instance handling    -> InventoryService    (Phase I, step 2)
		- any player or instance state

	The only computation permitted here is over the taxonomy the registry itself
	owns - see compareRarity.

	THE REGISTRY PATTERN

	All mechanics - source aggregation, duplicate detection, problem collection,
	deep freezing, error formatting, lookup surface - live in Registry. This
	module supplies only its Sources and its per-entry validator.

	WorldRegistry, RecipeRegistry, AffixRegistry and EvolutionRegistry should be
	written the same way: a validator function, a Registry.build call, and any
	domain-specific finders built on handle.where.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Registry = require(ReplicatedStorage.Modules.Registry)

local ItemSources = require(ReplicatedStorage.Config.Items)
local StatKeys = require(ReplicatedStorage.Config.StatKeys)
local ItemTypes = require(ReplicatedStorage.Shared.Types.ItemTypes)

type ItemDefinition = ItemTypes.ItemDefinition
type Problems = Registry.Problems

--[[
	Structural taxonomy, not balance data, so it lives with the validator rather
	than in Config.

	Rarity order is significant - Phase IV's MinRarity comparison depends on it -
	and may move to Config if rarities ever gain gameplay properties of their own.
]]
local CATEGORIES: { [string]: boolean } = {
	Material = true,
	Crystal = true,
	Equipment = true,
	Consumable = true,
	Cosmetic = true,
}

local SLOTS: { [string]: boolean } = {
	Pickaxe = true,
	Bracelet = true,
	Hood = true,
	Hat = true,
	Mantle = true,
}

local RARITY_ORDER: { string } = { "Common", "Uncommon", "Rare", "Epic", "Legendary" }

local RARITY_RANK: { [string]: number } = {}
for rank, rarity in RARITY_ORDER do
	RARITY_RANK[rarity] = rank
end

--// Validation //--------------------------------------------------------------

local function validateDefinition(sourceName: string, key: string, value: any, problems: Problems)
	local function fail(message: string)
		table.insert(problems, string.format("%s.%s %s", sourceName, key, message))
	end

	if type(value) ~= "table" then
		fail(string.format("must be a table, got %s", typeof(value)))
		return
	end

	local definition = value :: ItemDefinition

	-- Id must match its key, so a copy-pasted definition cannot silently shadow
	-- another entry.
	if type(definition.Id) ~= "string" or definition.Id == "" then
		fail("must define a non-empty string Id")
		return
	end
	if definition.Id ~= key then
		fail(string.format("declares Id '%s' but is keyed as '%s'", definition.Id, key))
	end

	if type(definition.Category) ~= "string" or not CATEGORIES[definition.Category] then
		fail(string.format("has unknown Category '%s'", tostring(definition.Category)))
	end

	if type(definition.Rarity) ~= "string" or RARITY_RANK[definition.Rarity] == nil then
		fail(string.format("has unknown Rarity '%s'", tostring(definition.Rarity)))
	end

	if type(definition.Tier) ~= "number" then
		fail("must define a numeric Tier")
	end

	if type(definition.Stackable) ~= "boolean" then
		fail("must define a boolean Stackable")
	end

	if type(definition.MaxStack) ~= "number" or definition.MaxStack < 1 then
		fail("must define MaxStack as a number of at least 1")
	elseif definition.Stackable == true and definition.MaxStack <= 1 then
		-- A stackable item that cannot stack is almost always a mistake.
		fail("is Stackable but has MaxStack of 1")
	elseif definition.Stackable == false and definition.MaxStack ~= 1 then
		fail("is not Stackable so MaxStack must be 1")
	end

	if definition.Category == "Equipment" then
		if type(definition.Slot) ~= "string" or not SLOTS[definition.Slot] then
			fail(string.format("is Equipment but has unknown Slot '%s'", tostring(definition.Slot)))
		end
		if definition.Stackable ~= false then
			fail("is Equipment and must not be Stackable")
		end
	elseif definition.Slot ~= nil then
		fail("declares a Slot but is not Equipment")
	end

	if definition.BaseStats ~= nil then
		if type(definition.BaseStats) ~= "table" then
			fail("BaseStats must be a table")
		else
			for statKey, statValue in definition.BaseStats do
				if type(statKey) ~= "string" or StatKeys[statKey] == nil then
					fail(string.format("BaseStats references unknown stat '%s'", tostring(statKey)))
				elseif type(statValue) ~= "number" then
					fail(string.format("BaseStats['%s'] must be a number", tostring(statKey)))
				end
			end
		end
	end

	if definition.AffixSlots ~= nil then
		local slots = definition.AffixSlots
		if type(slots) ~= "table" or type(slots.Min) ~= "number" or type(slots.Max) ~= "number" then
			fail("AffixSlots must be a table of { Min = number, Max = number }")
		elseif slots.Min < 0 or slots.Max < slots.Min then
			fail(string.format("AffixSlots range is invalid (Min %d, Max %d)", slots.Min, slots.Max))
		end
	end

	if type(definition.Tags) ~= "table" then
		fail("must define Tags as an array of strings")
	else
		for _, tag in definition.Tags do
			if type(tag) ~= "string" then
				fail("Tags must contain only strings")
				break
			end
		end
	end

	if type(definition.SalvageYield) ~= "table" then
		fail("must define SalvageYield as an array")
	else
		for index, entry in definition.SalvageYield do
			if type(entry) ~= "table" or type(entry.ItemId) ~= "string" or type(entry.Count) ~= "number" then
				fail(string.format("SalvageYield[%d] must be { ItemId = string, Count = number }", index))
				break
			end
		end
	end

	if type(definition.Value) ~= "number" then
		fail("must define a numeric Value")
	end

	if type(definition.Display) ~= "table" then
		fail("must define a Display table")
	else
		if type(definition.Display.Name) ~= "string" or definition.Display.Name == "" then
			fail("Display.Name must be a non-empty string")
		end
		if type(definition.Display.Icon) ~= "string" then
			fail("Display.Icon must be a string")
		end
		if type(definition.Display.Description) ~= "string" then
			fail("Display.Description must be a string")
		end
	end

	-- NativeOrigin is how a stackable carries Origin, since it has no instance
	-- (specification 4.4). Only its type is checked here; validating it against
	-- the set of real worlds needs WorldRegistry, which is Phase III.
	if definition.NativeOrigin ~= nil and type(definition.NativeOrigin) ~= "string" then
		fail("NativeOrigin must be a string when present")
	end

	if definition.EvolutionLine ~= nil and type(definition.EvolutionLine) ~= "string" then
		fail("EvolutionLine must be a string when present")
	end
end

--[[
	Second pass: checks that can only run once every definition is known.
]]
local function validateReferences(entries: { [string]: any }, problems: Problems)
	for id, definition in entries do
		if type(definition.SalvageYield) == "table" then
			for _, entry in definition.SalvageYield do
				if type(entry) == "table" and entries[entry.ItemId] == nil then
					table.insert(
						problems,
						string.format("%s SalvageYield references unknown item '%s'", id, tostring(entry.ItemId))
					)
				end
			end
		end
	end
end

--// Registry //----------------------------------------------------------------

local handle = Registry.build({
	Name = "ItemRegistry",
	Sources = ItemSources,
	Validate = validateDefinition,
	ValidateReferences = validateReferences,
})

local ItemRegistry = {}

ItemRegistry.RARITY_ORDER = table.freeze(RARITY_ORDER)

--// Lookup //-----------------------------------------------------------------

function ItemRegistry.get(itemId: string): ItemDefinition?
	return handle.get(itemId)
end

function ItemRegistry.exists(itemId: string): boolean
	return handle.exists(itemId)
end

function ItemRegistry.getOrError(itemId: string): ItemDefinition
	return handle.getOrError(itemId)
end

function ItemRegistry.all(): { [string]: ItemDefinition }
	return handle.all()
end

function ItemRegistry.count(): number
	return handle.count()
end

function ItemRegistry.sourceOf(itemId: string): string?
	return handle.sourceOf(itemId)
end

function ItemRegistry.isStackable(itemId: string): boolean
	local definition = handle.get(itemId)
	return definition ~= nil and definition.Stackable
end

--// Finders //----------------------------------------------------------------

function ItemRegistry.findByTag(tag: string): { ItemDefinition }
	return handle.where(function(definition)
		for _, candidate in definition.Tags do
			if candidate == tag then
				return true
			end
		end
		return false
	end)
end

function ItemRegistry.findBySlot(slot: string): { ItemDefinition }
	return handle.where(function(definition)
		return definition.Slot == slot
	end)
end

--[[
	Items whose KIND belongs to a world (specification 4.4).

	Instance-level Origin is a separate concept living in the save, and is not
	consulted here - that is InventoryService's data, not the registry's.
]]
function ItemRegistry.findByOrigin(worldId: string): { ItemDefinition }
	return handle.where(function(definition)
		return definition.NativeOrigin == worldId
	end)
end

--[[
	Orders two rarities.

	This is permitted here because rarity order is part of the taxonomy this
	registry owns, and the alternative is every caller reimplementing it. It is
	not a gameplay calculation: it consumes no player state and produces no
	gameplay value.
]]
function ItemRegistry.compareRarity(a: string, b: string): number
	return (RARITY_RANK[a] or 0) - (RARITY_RANK[b] or 0)
end

return ItemRegistry
