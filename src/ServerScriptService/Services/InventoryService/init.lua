--!strict
--[[
	InventoryService

	The sole owner of ItemInstances and of the two inventory pools (R-14).

	Owns Inventory.Items (stackables) and Inventory.Instances (unique copies).
	Allocates instance IDs, enforces capacity, and is the only place instances
	are constructed outside the frozen v1 to v2 migration.

	Does NOT decide what items are worth, generate loot content, resolve stats,
	or know about worlds.

	ONE WRITE PATH

	Every mutation of Inventory.Items or Inventory.Instances flows through
	applyMutations. Public methods validate and describe the change they want;
	they never touch the profile themselves. That gives dirty flags,
	notifications, replication, analytics and last-line invariant checks a single
	home, and it makes the transactional guarantee in Sprint03Specification 6.5
	enforceable in one place rather than four.

	OWNERSHIP NOTE

	Profile.NextInstanceId is written here, not by PlayerDataService. The counter
	is inventory's allocator and was placed under Profile in Phase I - in
	hindsight Inventory would have been the better home. Relocating it now would
	cost a permanent v2 to v3 migration for tidiness alone, so it stays and the
	write ownership is documented instead. If a v2 to v3 migration is ever needed
	for another reason, move it then.

	Reads of other sections - Profile.NextInstanceId, Equipment slots - are
	permitted for validation under R-18. Writes to Equipment remain exclusively
	EquipmentService's.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local CrystalEngine = require(ServerScriptService.Core.CrystalEngine)
local Logger = require(ServerScriptService.Core.Logger)

local ItemRegistry = require(ReplicatedStorage.Modules.ItemRegistry)
local ItemTypes = require(ReplicatedStorage.Shared.Types.ItemTypes)
local TableUtil = require(ReplicatedStorage.Shared.Utilities.TableUtil)

local Capacity = require(script.Capacity)

type ItemInstance = ItemTypes.ItemInstance
type InstanceAffix = ItemTypes.InstanceAffix
type Usage = Capacity.Usage

--[[
	A described change, consumed by applyMutations.

	Adding a Kind later touches only the funnel, which is the point of having one.
]]
export type Mutation = {
	Kind: string, -- "StackDelta" | "InstanceAdd" | "InstanceRemove"
	ItemId: string?, -- StackDelta
	Delta: number?, -- StackDelta
	Instance: ItemInstance?, -- InstanceAdd; the funnel allocates the id
	InstanceId: string?, -- InstanceRemove
}

--[[
	Emitted after a mutation is applied and state is consistent.

	One normalised shape a future Remote can forward verbatim, rather than
	diffing snapshots (R-8 readiness).
]]
export type InventoryChange = {
	Kind: string, -- "StackChanged" | "InstanceAdded" | "InstanceRemoved"
	ItemId: string?,
	Delta: number?,
	Count: number?,
	InstanceId: string?,
}

export type CreateOptions = {
	Affixes: { InstanceAffix }?,
	Origin: string?,
	Stage: number?,
	Experience: number?,
}

local log = Logger.Scoped("InventoryService")

local Service = {}

Service.Name = "InventoryService"
Service.Version = 1
Service.Dependencies = { "PlayerDataService" }

--[[
	Stable failure codes. Player-facing, so codes rather than prose: greppable,
	forwardable to a client verbatim, and localisable without touching logic.
]]
Service.Codes = table.freeze({
	ProfileNotLoaded = "ProfileNotLoaded",
	UnknownItem = "UnknownItem",
	UnknownInstance = "UnknownInstance",
	NotStackable = "NotStackable",
	Stackable = "Stackable",
	InvalidCount = "InvalidCount",
	InvalidOptions = "InvalidOptions",
	InventoryFull = "InventoryFull",
	NotEnough = "NotEnough",
	Equipped = "Equipped",
	Locked = "Locked",
	InvariantViolation = "InvariantViolation",
})

local CODES = Service.Codes

local EQUIPMENT_SLOTS = table.freeze({ "Pickaxe", "Bracelet", "Hood", "Hat", "Mantle" })

local playerData: any = nil
local changeCallbacks: { (Player, InventoryChange) -> () } = {}

--// Access //-----------------------------------------------------------------

local function getProfile(player: Player): any?
	if playerData == nil then
		return nil
	end
	return playerData:getProfile(player)
end

--[[
	Which slot an instance is equipped in, or nil.

	Reads Equipment for validation only (R-18). Writing it is EquipmentService's
	exclusive right.
]]
local function equippedSlotFor(profile: any, instanceId: string): string?
	local equipment = profile.Equipment
	if type(equipment) ~= "table" then
		return nil
	end

	for _, slot in EQUIPMENT_SLOTS do
		if equipment[slot] == instanceId then
			return slot
		end
	end

	return nil
end

--// Instance ID allocation //-------------------------------------------------

--[[
	Allocates the next instance ID as a string.

	The collision loop should never advance after the load-time repair, but
	overwriting an existing instance would silently destroy a player's item -
	severe enough to check twice.
]]
local function allocateInstanceId(profile: any): string
	local meta = profile.Profile
	local candidate = meta.NextInstanceId

	if type(candidate) ~= "number" or candidate < 1 then
		candidate = 1
	end

	while profile.Inventory.Instances[tostring(candidate)] ~= nil do
		log.Warning("Instance id '%d' was already taken; advancing the allocator.", candidate)
		candidate += 1
	end

	meta.NextInstanceId = candidate + 1
	return tostring(candidate)
end

--// Notification //-----------------------------------------------------------

local function fireChanged(player: Player, change: InventoryChange)
	for _, callback in changeCallbacks do
		task.spawn(function()
			local ok, err = pcall(callback, player, change)
			if not ok then
				log.Error("An onInventoryChanged callback errored for %s: %s", player.Name, tostring(err))
			end
		end)
	end
end

--// THE MUTATION FUNNEL //----------------------------------------------------

local function violation(
	player: Player,
	index: number,
	detail: string
): (boolean, string?, { InventoryChange }?)
	-- An invariant failure means a public method let something through. That is a
	-- bug in this service, not a player error, so it is logged loudly.
	log.Error("Mutation %d rejected for %s: %s", index, player.Name, detail)
	return false, CODES.InvariantViolation, nil
end

--[[
	The only path that writes Inventory.Items or Inventory.Instances.

	Three phases, in order, with no yields anywhere between the first write and
	the last:

		1. Invariants, checked against a projection. Nothing is written, so a
		   batch that fails partway leaves the profile untouched. This is what
		   makes multi-item operations all-or-nothing.
		2. Apply, and collect change descriptors while the data still exists.
		3. Notify, once state is consistent - a subscriber must never observe a
		   half-applied batch.

	Takes a list even though every current caller passes one entry. Salvage and
	crafting will pass several, and the transactional guarantee has to live here
	rather than in each of them.

	Invariants are the last line of defence, not the primary check. Public methods
	own player-facing validation and return specific codes; anything reaching here
	malformed is a programming error.
]]
local function applyMutations(
	player: Player,
	mutations: { Mutation }
): (boolean, string?, { InventoryChange }?)
	local profile = getProfile(player)
	if profile == nil then
		return false, CODES.ProfileNotLoaded, nil
	end

	local inventory = profile.Inventory

	--// Phase 1: invariants against a projection //--

	local projectedItems: { [string]: number } = {}
	local projectedInstances: { [string]: boolean } = {}

	local function projectedCount(itemId: string): number
		local projected = projectedItems[itemId]
		if projected ~= nil then
			return projected
		end
		return inventory.Items[itemId] or 0
	end

	local function projectedExists(instanceId: string): boolean
		local projected = projectedInstances[instanceId]
		if projected ~= nil then
			return projected
		end
		return inventory.Instances[instanceId] ~= nil
	end

	for index, mutation in mutations do
		if mutation.Kind == "StackDelta" then
			local itemId = mutation.ItemId
			local delta = mutation.Delta

			if type(itemId) ~= "string" or itemId == "" then
				return violation(player, index, "StackDelta requires a string ItemId")
			end
			if type(delta) ~= "number" or delta % 1 ~= 0 then
				return violation(player, index, "StackDelta requires an integer Delta")
			end

			local resulting = projectedCount(itemId) + delta
			if resulting < 0 then
				return violation(
					player,
					index,
					string.format("StackDelta would take '%s' below zero (%d)", itemId, resulting)
				)
			end

			projectedItems[itemId] = resulting
		elseif mutation.Kind == "InstanceAdd" then
			if type(mutation.Instance) ~= "table" then
				return violation(player, index, "InstanceAdd requires an Instance table")
			end

			-- No InstanceId is supplied or checked here. The funnel allocates
			-- during Phase 2, so the allocator cannot advance for a mutation that
			-- never applies, and uniqueness is guaranteed by construction.
		elseif mutation.Kind == "InstanceRemove" then
			local instanceId = mutation.InstanceId

			if type(instanceId) ~= "string" or instanceId == "" then
				return violation(player, index, "InstanceRemove requires a string InstanceId")
			end
			if not projectedExists(instanceId) then
				return violation(player, index, string.format("instance '%s' does not exist", instanceId))
			end

			projectedInstances[instanceId] = false
		else
			return violation(player, index, string.format("unknown mutation Kind '%s'", tostring(mutation.Kind)))
		end
	end

	--// Phase 2: apply, collecting change descriptors //--

	local changes: { InventoryChange } = {}

	for _, mutation in mutations do
		if mutation.Kind == "StackDelta" then
			local itemId = mutation.ItemId :: string
			local resulting = projectedItems[itemId]

			-- Zero is stored as absent, so an empty stack occupies no slot and
			-- does not accumulate dead keys in the save.
			inventory.Items[itemId] = if resulting > 0 then resulting else nil

			table.insert(changes, {
				Kind = "StackChanged",
				ItemId = itemId,
				Delta = mutation.Delta,
				Count = resulting,
			})
		elseif mutation.Kind == "InstanceAdd" then
			local instance = mutation.Instance :: ItemInstance

			-- Allocation happens here, inside the no-yield apply block, so the
			-- counter advances only when the instance actually lands.
			local instanceId = allocateInstanceId(profile)

			inventory.Instances[instanceId] = instance

			table.insert(changes, {
				Kind = "InstanceAdded",
				InstanceId = instanceId,
				ItemId = instance.ItemId,
			})
		elseif mutation.Kind == "InstanceRemove" then
			local instanceId = mutation.InstanceId :: string
			local existing = inventory.Instances[instanceId]

			inventory.Instances[instanceId] = nil

			table.insert(changes, {
				Kind = "InstanceRemoved",
				InstanceId = instanceId,
				ItemId = if existing ~= nil then existing.ItemId else nil,
			})
		end
	end

	--// Phase 3: notify //--

	for _, change in changes do
		fireChanged(player, change)
	end

	-- The change list is returned, not just broadcast: createInstance reads the
	-- allocated id from it. Dropping it here made the funnel apply the mutation
	-- and then report no result.
	return true, nil, changes
end

--// Stackables //-------------------------------------------------------------

function Service:addItem(player: Player, itemId: string, count: number): (boolean, string?)
	local profile = getProfile(player)
	if profile == nil then
		return false, CODES.ProfileNotLoaded
	end

	if type(count) ~= "number" or count <= 0 or count % 1 ~= 0 then
		return false, CODES.InvalidCount
	end

	local definition = ItemRegistry.get(itemId)
	if definition == nil then
		return false, CODES.UnknownItem
	end
	if not definition.Stackable then
		return false, CODES.NotStackable
	end

	-- A full inventory blocks the pickup rather than silently destroying it (R-5).
	if not Capacity.canFitStack(profile.Inventory, itemId, count) then
		return false, CODES.InventoryFull
	end

	local ok, reason = applyMutations(player, { { Kind = "StackDelta", ItemId = itemId, Delta = count } })
	return ok, reason
end

function Service:removeItem(player: Player, itemId: string, count: number): (boolean, string?)
	local profile = getProfile(player)
	if profile == nil then
		return false, CODES.ProfileNotLoaded
	end

	if type(count) ~= "number" or count <= 0 or count % 1 ~= 0 then
		return false, CODES.InvalidCount
	end

	-- Deliberately does NOT require the item to exist in Config: a player holding
	-- an item that was removed from the game must still be able to shed it.
	if (profile.Inventory.Items[itemId] or 0) < count then
		return false, CODES.NotEnough
	end

	local ok, reason = applyMutations(player, { { Kind = "StackDelta", ItemId = itemId, Delta = -count } })
	return ok, reason
end

function Service:getCount(player: Player, itemId: string): number
	local profile = getProfile(player)
	if profile == nil then
		return 0
	end
	return profile.Inventory.Items[itemId] or 0
end

--// Instances //--------------------------------------------------------------

--[[
	Validates caller-supplied creation options.

	Affix Ids are not checked against a registry - AffixRegistry arrives in
	Phase III. Only shape and roll range are enforced here.
]]
local function validateOptions(options: CreateOptions?): (boolean, string?)
	if options == nil then
		return true, nil
	end

	if options.Origin ~= nil and type(options.Origin) ~= "string" then
		return false, "Origin must be a string"
	end
	if options.Stage ~= nil and (type(options.Stage) ~= "number" or options.Stage < 1) then
		return false, "Stage must be a number of at least 1"
	end
	if options.Experience ~= nil and (type(options.Experience) ~= "number" or options.Experience < 0) then
		return false, "Experience must be a non-negative number"
	end

	if options.Affixes ~= nil then
		if type(options.Affixes) ~= "table" then
			return false, "Affixes must be an array"
		end
		for index, affix in options.Affixes do
			if type(affix) ~= "table" then
				return false, string.format("Affixes[%d] must be a table", index)
			end
			if type(affix.Id) ~= "string" or affix.Id == "" then
				return false, string.format("Affixes[%d].Id must be a non-empty string", index)
			end
			if type(affix.Roll) ~= "number" or affix.Roll < 0 or affix.Roll > 1 then
				return false, string.format("Affixes[%d].Roll must be within [0, 1]", index)
			end
		end
	end

	return true, nil
end

--[[
	Constructs and stores a new instance, returning its id.

	Callers pass an ItemId and options; they never hand over an instance table.
	One construction site means every instance in the game has a guaranteed shape
	(IB-1). Content - which affixes, which origin - remains the caller's decision,
	so loot generation stays out of this service.
]]
function Service:createInstance(player: Player, itemId: string, options: CreateOptions?): (string?, string?)
	local profile = getProfile(player)
	if profile == nil then
		return nil, CODES.ProfileNotLoaded
	end

	local definition = ItemRegistry.get(itemId)
	if definition == nil then
		return nil, CODES.UnknownItem
	end
	if definition.Stackable then
		return nil, CODES.Stackable
	end

	local validOptions, optionProblem = validateOptions(options)
	if not validOptions then
		log.Warning("Rejected createInstance('%s') for %s: %s", itemId, player.Name, tostring(optionProblem))
		return nil, CODES.InvalidOptions
	end

	if not Capacity.canFitInstances(profile.Inventory, 1) then
		return nil, CODES.InventoryFull
	end

	local instance: ItemInstance = {
		ItemId = itemId,
		Affixes = if options ~= nil and options.Affixes ~= nil
			then TableUtil.deepCopy(options.Affixes) :: any
			else {},
		Stage = if options ~= nil and options.Stage ~= nil then options.Stage else 1,
		Experience = if options ~= nil and options.Experience ~= nil then options.Experience else 0,
		Locked = false,
		Favorite = false,
		CreatedAt = os.time(),
	}

	-- Origin is optional and absent means unknown, never invalid (4.2).
	-- Metadata is deliberately never written: sparse by contract (R-13).
	if options ~= nil and options.Origin ~= nil then
		instance.Origin = options.Origin
	end

	-- The funnel allocates the id and returns it on the change descriptor, so a
	-- rejected mutation leaves the allocator untouched.
	local ok, reason, changes = applyMutations(player, {
		{ Kind = "InstanceAdd", Instance = instance },
	})

	if not ok or changes == nil or changes[1] == nil then
		return nil, reason
	end

	return changes[1].InstanceId, nil
end

function Service:destroyInstance(player: Player, instanceId: string): (boolean, string?)
	local profile = getProfile(player)
	if profile == nil then
		return false, CODES.ProfileNotLoaded
	end

	local instance = profile.Inventory.Instances[instanceId]
	if instance == nil then
		return false, CODES.UnknownInstance
	end

	if instance.Locked == true then
		return false, CODES.Locked
	end

	-- Prevention rather than reactive cleanup: an equipped slot must never point
	-- at a destroyed instance, even briefly (IB-5 / R-18).
	local slot = equippedSlotFor(profile, instanceId)
	if slot ~= nil then
		return false, CODES.Equipped
	end

	local ok, reason = applyMutations(player, { { Kind = "InstanceRemove", InstanceId = instanceId } })
	return ok, reason
end

--[[
	Returns a frozen deep copy.

	Never the live table: that would hand out a mutable reference into the
	profile and reduce ownership to a convention (IB-4).
]]
function Service:getInstance(player: Player, instanceId: string): ItemInstance?
	local profile = getProfile(player)
	if profile == nil then
		return nil
	end

	local instance = profile.Inventory.Instances[instanceId]
	if instance == nil then
		return nil
	end

	return TableUtil.frozenCopy(instance) :: any
end

--[[
	Returns instance IDs, not instances, so a bulk query stays cheap and the
	"IDs, never instances" rule holds at the boundary (IB-5).
]]
function Service:listInstances(player: Player): { string }
	local profile = getProfile(player)
	if profile == nil then
		return {}
	end

	local ids: { string } = {}
	for instanceId in profile.Inventory.Instances do
		table.insert(ids, instanceId)
	end

	table.sort(ids)
	return ids
end

--// Capacity //---------------------------------------------------------------

function Service:getUsage(player: Player): Usage?
	local profile = getProfile(player)
	if profile == nil then
		return nil
	end
	return table.freeze(Capacity.getUsage(profile.Inventory)) :: any
end

function Service:hasRoomFor(player: Player, itemId: string, count: number): (boolean, string?)
	local profile = getProfile(player)
	if profile == nil then
		return false, CODES.ProfileNotLoaded
	end

	if type(count) ~= "number" or count <= 0 or count % 1 ~= 0 then
		return false, CODES.InvalidCount
	end

	local definition = ItemRegistry.get(itemId)
	if definition == nil then
		return false, CODES.UnknownItem
	end

	local fits = if definition.Stackable
		then Capacity.canFitStack(profile.Inventory, itemId, count)
		else Capacity.canFitInstances(profile.Inventory, count)

	if not fits then
		return false, CODES.InventoryFull
	end

	return true, nil
end

--// Notification //-----------------------------------------------------------

--[[
	Registers a callback fired after every applied mutation.

	Returns a function that unregisters it. Plain callback tables, consistent
	with PlayerDataService per A.2.3 - no Signal dependency.
]]
function Service:onInventoryChanged(callback: (Player, InventoryChange) -> ()): () -> ()
	table.insert(changeCallbacks, callback)

	return function()
		local index = table.find(changeCallbacks, callback)
		if index ~= nil then
			table.remove(changeCallbacks, index)
		end
	end
end

--// Load-time domain validation //--------------------------------------------

--[[
	Guarantees the allocator can never hand out an id that is already in use.

	Without this, a NextInstanceId lower than an existing key would silently
	overwrite an item on the next allocation - the worst failure mode an
	inventory can have (IB-2).
]]
local function repairAllocator(player: Player, profile: any)
	local highest = 0

	for instanceId in profile.Inventory.Instances do
		local numeric = tonumber(instanceId)
		if numeric == nil then
			log.Warning(
				"%s owns instance '%s' with a non-numeric id; the allocator cannot account for it.",
				player.Name,
				tostring(instanceId)
			)
		elseif numeric > highest then
			highest = numeric
		end
	end

	local meta = profile.Profile
	if type(meta.NextInstanceId) ~= "number" or meta.NextInstanceId <= highest then
		log.Warning(
			"Repaired NextInstanceId for %s: %s -> %d",
			player.Name,
			tostring(meta.NextInstanceId),
			highest + 1
		)
		meta.NextInstanceId = highest + 1
	end
end

--[[
	Reports items this build does not recognise.

	Deliberately does NOT prune (IB-7). Pruning is irreversible, and an item
	removed from Config may return - the same non-destructive stance the v1 to v2
	migration takes with unknown equipment.
]]
local function auditUnknownItems(player: Player, profile: any)
	for itemId in profile.Inventory.Items do
		if not ItemRegistry.exists(itemId) then
			log.Warning("%s holds unknown stackable '%s'. Left in place, not pruned.", player.Name, itemId)
		end
	end

	for instanceId, instance in profile.Inventory.Instances do
		local itemId = if type(instance) == "table" then instance.ItemId else nil
		if type(itemId) ~= "string" or not ItemRegistry.exists(itemId) then
			log.Warning(
				"%s owns instance '%s' with unknown ItemId '%s'. Left in place, not pruned.",
				player.Name,
				instanceId,
				tostring(itemId)
			)
		end
	end
end

--// Lifecycle //--------------------------------------------------------------

function Service:Initialize()
	playerData = CrystalEngine:GetService("PlayerDataService")
	log.Debug("Initialized.")
end

function Service:Start()
	-- Fires immediately for players already loaded, so a late start cannot miss
	-- one (PlayerDataService 5.3). The returned disconnect function is discarded:
	-- this subscription lasts for the server's lifetime.
	playerData:onProfileLoaded(function(player: Player, profile: any)
		repairAllocator(player, profile)
		auditUnknownItems(player, profile)

		local usage = Capacity.getUsage(profile.Inventory)
		log.Info(
			"%s inventory ready: %d/%d stack slots, %d/%d instance slots.",
			player.Name,
			usage.StackSlots,
			usage.StackCapacity,
			usage.InstanceSlots,
			usage.InstanceCapacity
		)
	end)

	log.Info("Started.")
end

return Service
