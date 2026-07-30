--!strict
--[[
	Capacity

	Slot accounting for the two independent inventory pools.

	Pure functions over an inventory table plus ItemRegistry. No player state, no
	yielding, no mutation - which makes every rule here testable in isolation and
	keeps the arithmetic out of InventoryService's control flow.

	THE TWO POOLS (Sprint03Specification 6.3)

		Stack slots     one per distinct stackable ItemId, plus one more for each
		                MaxStack the count exceeds
		Instance slots  one per ItemInstance

	Stacks are stored as a flat [itemId] = count map; slot counts are COMPUTED,
	never stored. A count of 1500 at MaxStack 999 occupies two slots without the
	save holding two entries.

	Capacity and InstanceCapacity in the profile are the player's OWNED counts.
	Equipment and upgrade contributions to StackCapacity / InstanceCapacity are
	deliberately not applied yet: no item in Config grants either, and resolving
	them would require equipment data that InventoryService cannot reach without
	inverting its dependency on EquipmentService. Revisit when a capacity-granting
	item actually exists (decision IB-3).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ItemRegistry = require(ReplicatedStorage.Modules.ItemRegistry)

export type Usage = {
	StackSlots: number,
	StackCapacity: number,
	InstanceSlots: number,
	InstanceCapacity: number,
}

local Capacity = {}

--[[
	Slots consumed by holding `count` of one item.

	Zero is zero slots - an item at count zero must not occupy a slot, which is
	why InventoryService removes the key rather than storing 0.
]]
function Capacity.slotsForStack(itemId: string, count: number): number
	if count <= 0 then
		return 0
	end

	local definition = ItemRegistry.get(itemId)
	local maxStack = if definition ~= nil then definition.MaxStack else 1

	if maxStack < 1 then
		maxStack = 1
	end

	return math.ceil(count / maxStack)
end

function Capacity.usedStackSlots(inventory: any): number
	local total = 0
	for itemId, count in inventory.Items do
		total += Capacity.slotsForStack(itemId, count)
	end
	return total
end

function Capacity.usedInstanceSlots(inventory: any): number
	local total = 0
	for _ in inventory.Instances do
		total += 1
	end
	return total
end

--[[
	How many stack slots change if `delta` of an item is added or removed.

	Adding to a partially filled stack often costs nothing, and removing may free
	a slot, so the delta cannot be inferred from the count alone.
]]
function Capacity.stackSlotDelta(inventory: any, itemId: string, delta: number): number
	local current = inventory.Items[itemId] or 0
	local resulting = math.max(0, current + delta)

	return Capacity.slotsForStack(itemId, resulting) - Capacity.slotsForStack(itemId, current)
end

function Capacity.getUsage(inventory: any): Usage
	return {
		StackSlots = Capacity.usedStackSlots(inventory),
		StackCapacity = inventory.Capacity,
		InstanceSlots = Capacity.usedInstanceSlots(inventory),
		InstanceCapacity = inventory.InstanceCapacity,
	}
end

--[[
	Whether `delta` of a stackable item fits.

	Removals always fit.
]]
function Capacity.canFitStack(inventory: any, itemId: string, delta: number): boolean
	if delta <= 0 then
		return true
	end

	local slotDelta = Capacity.stackSlotDelta(inventory, itemId, delta)
	if slotDelta <= 0 then
		return true
	end

	return Capacity.usedStackSlots(inventory) + slotDelta <= inventory.Capacity
end

function Capacity.canFitInstances(inventory: any, additional: number): boolean
	if additional <= 0 then
		return true
	end

	return Capacity.usedInstanceSlots(inventory) + additional <= inventory.InstanceCapacity
end

return Capacity
