--!strict
--[[
	TableUtil

	Small table helpers shared by both server and client.

	Pure functions only - no state, no Roblox API, no gameplay logic.

	Registry and ProfileValidator each carry a private copy of deepCopy or
	deepFreeze from before this module existed. Those should migrate here in a
	separate cleanup commit; refactoring verified code mid-phase buys nothing and
	adds risk. New code uses this module.
]]

local TableUtil = {}

--[[
	Recursively copies a table.

	Used wherever a caller must receive data it cannot mutate in place - handing
	out a live reference into a player's profile would break the ownership rules
	in Sprint03Specification 6.1.
]]
function TableUtil.deepCopy(source: { [any]: any }): { [any]: any }
	local result = {}
	for key, value in source do
		if type(value) == "table" then
			result[key] = TableUtil.deepCopy(value)
		else
			result[key] = value
		end
	end
	return result
end

--[[
	Recursively freezes a table and everything it contains.

	The isfrozen guard makes this safe for tables reachable by more than one
	path, which would otherwise be visited twice.
]]
function TableUtil.deepFreeze(value: { [any]: any }): { [any]: any }
	for _, child in value do
		if type(child) == "table" then
			TableUtil.deepFreeze(child)
		end
	end

	if not table.isfrozen(value) then
		table.freeze(value)
	end

	return value
end

--[[
	Copies a table and freezes the copy.

	The standard way to expose owned data to a caller: they can read all of it
	and mutate none of it.
]]
function TableUtil.frozenCopy(source: { [any]: any }): { [any]: any }
	return TableUtil.deepFreeze(TableUtil.deepCopy(source))
end

return TableUtil
