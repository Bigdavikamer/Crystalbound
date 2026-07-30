--!strict
--[[
	StorageProvider

	The ONLY module in Crystalbound permitted to contact Roblox persistence.

	Owns every DataStore call, retry and backoff policy, request-budget checks,
	and key construction. Callers pass a UserId and never see a key.

	Knows nothing about profiles. It moves opaque tables: it does not know the
	field Version exists, does not validate, does not migrate, and does not apply
	defaults. A provider that understands profiles is not an abstraction - it is
	a second data layer.

	DataStore-backed only. No switchable backend and no in-memory provider;
	mock storage and automated testing are deferred to a future sprint
	(specification 6.5).

	The most important thing this module provides is the distinction between
	Transient and NotFound. Treating a throttled read as "no data exists" and
	then writing a default profile over real progress is the classic
	total-progress-loss bug, so the result type makes that mistake hard to write.
]]

local DataStoreService = game:GetService("DataStoreService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Logger = require(ServerScriptService.Core.Logger)
local PersistenceConfig = require(ReplicatedStorage.Config.PersistenceConfig)

export type ReadResult = "Ok" | "NotFound" | "Transient" | "Corrupt"

local log = Logger.Scoped("StorageProvider")

local StorageProvider = {}

local cachedStore: DataStore? = nil

--// Internals //---------------------------------------------------------------

--[[
	Resolves the DataStore, caching it after the first success.

	GetDataStore throws when Studio API access is disabled, so it is protected.
	A nil return is reported to callers as Transient, never NotFound - the data
	may well exist and simply be unreachable.
]]
local function getStore(): DataStore?
	if cachedStore ~= nil then
		return cachedStore
	end

	local ok, result = pcall(function()
		return DataStoreService:GetDataStore(PersistenceConfig.DataStoreName)
	end)

	if not ok then
		log.Error("Could not open DataStore '%s': %s", PersistenceConfig.DataStoreName, tostring(result))
		return nil
	end

	cachedStore = result
	return cachedStore
end

-- Private to this module. No consumer builds or receives a key.
local function buildKey(userId: number): string
	return string.format("%s%d", PersistenceConfig.KeyPrefix, userId)
end

--[[
	Waits, bounded, for request budget to recover.

	Issuing a request with zero budget guarantees throttling. Waiting is bounded
	so a starved budget slows a load rather than blocking it forever.
]]
local function waitForBudget(requestType: Enum.DataStoreRequestType)
	local waited = 0

	while DataStoreService:GetRequestBudgetForRequestType(requestType) <= 0 do
		if waited >= PersistenceConfig.BudgetWaitLimit then
			log.Warning("Proceeding with no request budget after waiting %ds.", waited)
			return
		end
		task.wait(1)
		waited += 1
	end
end

--[[
	Runs an operation with bounded exponential backoff.

	Returns success, the operation's result, and the last error message.
	Callers never implement retry logic themselves.
]]
local function withRetry(label: string, maxAttempts: number, operation: () -> any): (boolean, any?, string?)
	local lastError: string? = nil
	local backoff = PersistenceConfig.RetryBaseBackoff

	for attempt = 1, maxAttempts do
		local ok, result = pcall(operation)

		if ok then
			if attempt > 1 then
				log.Info("%s succeeded on attempt %d.", label, attempt)
			end
			return true, result, nil
		end

		lastError = tostring(result)
		log.Warning("%s failed on attempt %d/%d: %s", label, attempt, maxAttempts, lastError)

		if attempt < maxAttempts then
			task.wait(backoff)
			backoff = math.min(backoff * 2, PersistenceConfig.RetryMaxBackoff)
		end
	end

	return false, nil, lastError
end

--// Public API //--------------------------------------------------------------

--[[
	Reads a player's stored data.

	Returns a result code, the data when successful, and a diagnostic otherwise.

	Ok       - a table was returned
	NotFound - the key has never been written; the caller may create defaults
	Transient- unreachable after all retries; the caller must NOT overwrite
	Corrupt  - a value was returned but is not a table; the caller must NOT overwrite
]]
function StorageProvider.read(userId: number): (ReadResult, { [any]: any }?, string?)
	local store = getStore()
	if store == nil then
		return "Transient", nil, "DataStore unavailable (Studio API access may be disabled)"
	end

	local key = buildKey(userId)
	waitForBudget(Enum.DataStoreRequestType.GetAsync)

	local ok, value, failure = withRetry("read " .. key, PersistenceConfig.RetryMaxAttempts, function()
		return store:GetAsync(key)
	end)

	if not ok then
		return "Transient", nil, failure
	end

	if value == nil then
		return "NotFound", nil, nil
	end

	if type(value) ~= "table" then
		return "Corrupt", nil, string.format("expected a table, stored value is %s", typeof(value))
	end

	return "Ok", value, nil
end

--[[
	Writes a player's data, replacing whatever is stored.

	Implemented over UpdateAsync rather than SetAsync: UpdateAsync serialises
	concurrent writes to the same key, so a stale write cannot clobber a newer
	one.

	maxAttempts defaults to the normal retry count. Final saves pass a higher
	value, since they are the last chance to persist.
]]
function StorageProvider.write(userId: number, data: { [any]: any }, maxAttempts: number?): (boolean, string?)
	local store = getStore()
	if store == nil then
		return false, "DataStore unavailable (Studio API access may be disabled)"
	end

	local key = buildKey(userId)
	waitForBudget(Enum.DataStoreRequestType.UpdateAsync)

	local ok, _, failure = withRetry(
		"write " .. key,
		maxAttempts or PersistenceConfig.RetryMaxAttempts,
		function()
			return store:UpdateAsync(key, function()
				return data
			end)
		end
	)

	return ok, failure
end

--[[
	Read-modify-write for callers needing true atomicity.

	The transform receives the currently stored value, or nil when the key has
	never been written, and returns the value to store. Returning nil aborts the
	write, per Roblox UpdateAsync semantics.
]]
function StorageProvider.update(
	userId: number,
	transform: ({ [any]: any }?) -> { [any]: any }?,
	maxAttempts: number?
): (boolean, string?)
	local store = getStore()
	if store == nil then
		return false, "DataStore unavailable (Studio API access may be disabled)"
	end

	local key = buildKey(userId)
	waitForBudget(Enum.DataStoreRequestType.UpdateAsync)

	local ok, _, failure = withRetry(
		"update " .. key,
		maxAttempts or PersistenceConfig.RetryMaxAttempts,
		function()
			return store:UpdateAsync(key, transform)
		end
	)

	return ok, failure
end

return StorageProvider
