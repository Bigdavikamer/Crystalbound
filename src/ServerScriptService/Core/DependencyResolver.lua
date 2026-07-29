--!strict
--[[
	DependencyResolver

	Turns a set of systems into a safe initialisation order, or reports why
	no such order exists.

	Uses a three-colour depth-first search. Depth-first is chosen over Kahn's
	algorithm specifically because the traversal stack reconstructs the exact
	cycle path for the error message.

	This module touches no Roblox API and holds no state, so the future
	ClientEngine can reuse it unchanged.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local EngineTypes = require(ReplicatedStorage.Shared.Types.EngineTypes)

type SystemDescriptor = EngineTypes.SystemDescriptor

local VISITING = "visiting"
local VISITED = "visited"

local DependencyResolver = {}

--[[
	Resolves an initialisation order for one tier.

	systems  - the tier being resolved, keyed by system name
	external - names already loaded by earlier tiers. Dependencies found here
	           are satisfied and impose no ordering constraint on this tier.

	Returns an ordered list of names, or nil plus a human-readable reason.
]]
function DependencyResolver.Resolve(
	systems: { [string]: SystemDescriptor },
	external: { [string]: boolean }?
): ({ string }?, string?)
	local satisfied = external or {}

	local order: { string } = {}
	local state: { [string]: string? } = {}
	local path: { string } = {}
	local failure: string? = nil

	local function visit(name: string): boolean
		if state[name] == VISITED then
			return true
		end

		if state[name] == VISITING then
			-- Re-entering a node still on the stack closes a loop. The slice of
			-- the path starting at that node is the cycle itself.
			local startIndex = table.find(path, name) or 1
			local cycle: { string } = {}
			for index = startIndex, #path do
				table.insert(cycle, path[index])
			end
			table.insert(cycle, name)

			failure = string.format("Circular dependency detected: %s", table.concat(cycle, " -> "))
			return false
		end

		state[name] = VISITING
		table.insert(path, name)

		local descriptor = systems[name]
		for _, dependency in descriptor.Dependencies do
			if satisfied[dependency] then
				continue
			end

			if dependency == name then
				failure = string.format("'%s' declares itself as a dependency.", name)
				return false
			end

			if systems[dependency] == nil then
				failure = string.format(
					"'%s' depends on '%s', which was not found in the %s tier or in any tier loaded before it.",
					name,
					dependency,
					descriptor.TierName
				)
				return false
			end

			if not visit(dependency) then
				return false
			end
		end

		table.remove(path)
		state[name] = VISITED

		-- Post-order insertion: a node is appended only after all of its
		-- dependencies are already in the list.
		table.insert(order, name)
		return true
	end

	-- Sorted entry points keep the boot order deterministic. Without this the
	-- order would follow hash iteration and differ between sessions, which
	-- makes ordering bugs intermittent and hard to reproduce.
	local names: { string } = {}
	for name in systems do
		table.insert(names, name)
	end
	table.sort(names)

	for _, name in names do
		if not visit(name) then
			return nil, failure
		end
	end

	return order, nil
end

return DependencyResolver
