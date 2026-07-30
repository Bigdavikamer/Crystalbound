--!strict
--[[
	Registry

	The shared foundation for every Config registry in Crystalbound.

	ItemRegistry, and the WorldRegistry, RecipeRegistry, AffixRegistry and
	EvolutionRegistry that follow, all need the same mechanics: aggregate several
	Config source files, detect duplicate Ids across them, validate every entry,
	report every problem at once, and expose read-only lookup.

	Only the per-entry validation differs. That is the callback each registry
	supplies; everything else lives here, so a new registry is roughly thirty
	lines rather than three hundred.

	WHAT THIS MODULE GUARANTEES

	1. Read-only by construction. Every registered entry is DEEP FROZEN, so a
	   consumer cannot mutate Config through a lookup. Without this, one stray
	   `ItemRegistry.get(id).Value = 0` would corrupt that definition for every
	   player on the server until it restarted.

	2. All problems at once. A malformed Config fails the boot with a complete
	   list, so one boot surfaces every error instead of one per fix cycle.

	3. Deterministic messages. Sources and keys are iterated in sorted order, so
	   error output is identical between boots rather than following hash order.

	WHAT THIS MODULE MUST NEVER CONTAIN

	Gameplay logic of any kind. A registry answers "what is defined?" and nothing
	else. Resolution, calculation, generation and mutation belong to Services.
]]

export type Problems = { string }

export type RegistryConfig = {
	-- Used in error messages. Conventionally the registry's module name.
	Name: string,

	-- Map of source name to that source's entries, keyed by Id. The source name
	-- appears in error messages, which is why an index module should return a
	-- map rather than a pre-merged table.
	Sources: { [string]: { [string]: any } },

	-- Called once per entry. Append a description to `problems` for each fault
	-- found; do not raise.
	Validate: (sourceName: string, key: string, entry: any, problems: Problems) -> (),

	-- Optional second pass, run once every entry is known. For checks that need
	-- the whole set, such as cross-references between entries.
	ValidateReferences: ((entries: { [string]: any }, problems: Problems) -> ())?,
}

export type RegistryHandle = {
	get: (id: string) -> any?,
	getOrError: (id: string) -> any,
	exists: (id: string) -> boolean,
	all: () -> { [string]: any },
	where: (predicate: (entry: any) -> boolean) -> { any },
	count: () -> number,
	sourceOf: (id: string) -> string?,
}

local Registry = {}

--[[
	Recursively freezes a table and everything it contains.

	Registry entries are read directly by consumers rather than copied, so a
	shallow freeze would still leave every nested field writable. This differs
	deliberately from DefaultProfile, which is shallow-frozen because it is always
	deep-copied before use.

	The isfrozen guard makes this safe for tables shared between entries, which
	would otherwise be visited more than once.
]]
local function deepFreeze(value: any)
	if type(value) ~= "table" then
		return
	end

	for _, child in value do
		deepFreeze(child)
	end

	if not table.isfrozen(value) then
		table.freeze(value)
	end
end

local function sortedKeys(source: { [string]: any }, problems: Problems, label: string): { string }
	local keys: { string } = {}

	for key in source do
		if type(key) ~= "string" then
			table.insert(problems, string.format("%s has a non-string key (%s)", label, typeof(key)))
		else
			table.insert(keys, key)
		end
	end

	table.sort(keys)
	return keys
end

--[[
	Builds a registry from Config, validating everything, and returns its handle.

	Raises on any problem. Because registries are required at module load, that
	raise propagates outward and fails the boot - which is the intended
	behaviour: a malformed Config should be discovered at startup, not when a
	player first encounters the affected entry.
]]
function Registry.build(config: RegistryConfig): RegistryHandle
	local entries: { [string]: any } = {}
	local sourceOf: { [string]: string } = {}
	local problems: Problems = {}
	local total = 0

	local sourceNames = sortedKeys(config.Sources, problems, config.Name .. " sources")

	for _, sourceName in sourceNames do
		local source = config.Sources[sourceName]

		if type(source) ~= "table" then
			table.insert(
				problems,
				string.format("source '%s' must return a table, got %s", sourceName, typeof(source))
			)
			continue
		end

		for _, key in sortedKeys(source, problems, sourceName) do
			if sourceOf[key] ~= nil then
				table.insert(
					problems,
					string.format(
						"duplicate Id '%s' in %s (already defined in %s)",
						key,
						sourceName,
						sourceOf[key]
					)
				)
				continue
			end

			config.Validate(sourceName, key, source[key], problems)

			sourceOf[key] = sourceName
			entries[key] = source[key]
			total += 1
		end
	end

	if config.ValidateReferences ~= nil then
		config.ValidateReferences(entries, problems)
	end

	if #problems > 0 then
		error(
			string.format(
				"%s found %d problem(s) in Config:\n  - %s",
				config.Name,
				#problems,
				table.concat(problems, "\n  - ")
			),
			0
		)
	end

	deepFreeze(entries)
	table.freeze(sourceOf)

	local handle = {}

	function handle.get(id: string): any?
		return entries[id]
	end

	function handle.exists(id: string): boolean
		return entries[id] ~= nil
	end

	--[[
		For call sites where a missing entry is a bug rather than a possibility.

		Prefer `exists` wherever missing Config must degrade gracefully - the
		v1 to v2 migration is the canonical example, since an item removed from
		the game must not raise.
	]]
	function handle.getOrError(id: string): any
		local entry = entries[id]
		if entry == nil then
			error(string.format("%s has no entry '%s'.", config.Name, tostring(id)), 3)
		end
		return entry
	end

	-- Returns the frozen table itself, not a copy. Safe because it is frozen.
	function handle.all(): { [string]: any }
		return entries
	end

	function handle.where(predicate: (entry: any) -> boolean): { any }
		local found: { any } = {}
		for _, entry in entries do
			if predicate(entry) then
				table.insert(found, entry)
			end
		end
		return found
	end

	function handle.count(): number
		return total
	end

	-- Which Config file defined an Id. Diagnostics only.
	function handle.sourceOf(id: string): string?
		return sourceOf[id]
	end

	return handle
end

return Registry
