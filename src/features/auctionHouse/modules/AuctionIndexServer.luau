--!strict

--[=[
	A cross-server index of active listings in MemoryStore, for browsing. It
	caches the ledger and is never the source of truth: a stale entry at
	worst offers a listing whose purchase then fails cleanly (and removes the
	entry), and every entry expires on its own when its listing does.

	- Sorted map "AuctionByItem": each item's listings, cheapest first. The
	  sort key is AuctionProtocol.itemSortKey (hex item id + padded price),
	  so one item's listings are one contiguous range.
	- Sorted map "AuctionRecent": every listing, newest first (sort key:
	  createdAt). Also serves lookups by listing id.
	- Hash map "AuctionLocks": short purchase leases, so only one buyer at a
	  time escrows coins for a listing and a popular listing doesn't make
	  dozens of buyers save their profiles only to be refunded. Leases expire
	  on their own, and the ledger still decides if two buyers get through.

	Every call is protected: on failure the index misses an update, which
	the next reconciliation or failed purchase repairs. In Studio without API
	access, everything lives in memory instead.
]=]

local MemoryStoreService = game:GetService("MemoryStoreService")

local AuctionLedger = require("@Features/auctionHouse/modules/AuctionLedgerServer")
local AuctionProtocol = require("@Features/auctionHouse/modules/AuctionProtocol")
local Log = require("@Core/Log")

type Summary = AuctionProtocol.Summary
type SortKey = string | number

-- MemoryStore's bound format: both fields optional, both exclusive.
type Bound = { key: string?, sortKey: SortKey? }

type Entry = {
	key: string,
	value: Summary,
	sortKey: SortKey,
}

local BY_ITEM = "AuctionByItem"
local RECENT = "AuctionRecent"
local LOCKS = "AuctionLocks"
-- Seconds a purchase lease lasts: a profile save plus a ledger commit.
local LOCK_TTL = 60
-- MemoryStore's longest expiration.
local MAX_EXPIRATION = 3_888_000

local sortedMaps: { [string]: MemoryStoreSortedMap } = {}
local locks: MemoryStoreHashMap? = nil

-- In-memory stand-ins, used without API access.
local mockMaps: { [string]: { [string]: Entry } } = { [BY_ITEM] = {}, [RECENT] = {} }
local mockLocks: { [string]: { purchaseId: string, expiresAt: number } } = {}

local AuctionIndex = {}

local function getSortedMap(name: string): MemoryStoreSortedMap
	local map = sortedMaps[name]
	if not map then
		map = MemoryStoreService:GetSortedMap(name)
		sortedMaps[name] = map
	end
	return map
end

local function getLocks(): MemoryStoreHashMap
	local current = locks or MemoryStoreService:GetHashMap(LOCKS)
	locks = current
	return current
end

local function protected(label: string, fn: () -> ()): boolean
	-- `:: any`: strict mode has no type for the error of a call that returns nothing
	local ok, err = pcall(fn :: any)
	if not ok then
		Log.warn(`Auction index {label} failed: {err}`)
	end
	return ok
end

-- Seconds until the listing expires, within MemoryStore's limits.
local function expirationOf(summary: Summary): number
	return math.clamp(summary.expiresAt - os.time(), 1, MAX_EXPIRATION)
end

-- // Mock ordering, matching MemoryStore: numbers before strings, then by
-- sort key, then by key. A bound without a key sorts before its sort key's
-- entries (never equal to one in this module's ranges). //

local function compare(sortKeyA: SortKey?, keyA: string?, sortKeyB: SortKey?, keyB: string?): number
	if sortKeyA ~= sortKeyB then
		local typeA, typeB = type(sortKeyA), type(sortKeyB)
		if typeA ~= typeB then
			return if typeA == "number" then -1 else 1
		end
		return if (sortKeyA :: any) < (sortKeyB :: any) then -1 else 1
	end
	local a, b = keyA or "", keyB or ""
	return if a == b then 0 elseif a < b then -1 else 1
end

local function mockRange(name: string, ascending: boolean, count: number, lower: Bound?, upper: Bound?): { Entry }
	local now = os.time()
	local entries: { Entry } = {}
	for key, entry in mockMaps[name] do
		if entry.value.expiresAt <= now then
			mockMaps[name][key] = nil
		elseif
			(not lower or compare(entry.sortKey, entry.key, lower.sortKey, lower.key) > 0)
			and (not upper or compare(entry.sortKey, entry.key, upper.sortKey, upper.key) < 0)
		then
			table.insert(entries, entry)
		end
	end

	table.sort(entries, function(a: Entry, b: Entry): boolean
		local order = compare(a.sortKey, a.key, b.sortKey, b.key)
		return if ascending then order < 0 else order > 0
	end)

	local result = {}
	for index = 1, math.min(count, #entries) do
		result[index] = entries[index]
	end
	return result
end

local function range(name: string, ascending: boolean, count: number, lower: Bound?, upper: Bound?): { Entry }
	if AuctionLedger.isMock() then
		return mockRange(name, ascending, count, lower, upper)
	end
	local direction = if ascending then Enum.SortDirection.Ascending else Enum.SortDirection.Descending
	return getSortedMap(name):GetRangeAsync(direction, count, lower :: any, upper :: any) :: any
end

-- // Listings //

-- Adds a listing, or refreshes it after a price change. Yields.
function AuctionIndex.put(summary: Summary): boolean
	local itemSortKey = AuctionProtocol.itemSortKey(summary.itemId, summary.price)

	if AuctionLedger.isMock() then
		mockMaps[BY_ITEM][summary.id] = { key = summary.id, value = summary, sortKey = itemSortKey }
		mockMaps[RECENT][summary.id] = { key = summary.id, value = summary, sortKey = summary.createdAt }
		return true
	end

	return protected(`put {summary.id}`, function()
		local expiration = expirationOf(summary)
		getSortedMap(BY_ITEM):SetAsync(summary.id, summary, expiration, itemSortKey)
		getSortedMap(RECENT):SetAsync(summary.id, summary, expiration, summary.createdAt)
	end)
end

-- Removes a closed listing. Yields.
function AuctionIndex.remove(listingId: string): boolean
	if AuctionLedger.isMock() then
		mockMaps[BY_ITEM][listingId] = nil
		mockMaps[RECENT][listingId] = nil
		return true
	end

	return protected(`remove {listingId}`, function()
		getSortedMap(BY_ITEM):RemoveAsync(listingId)
		getSortedMap(RECENT):RemoveAsync(listingId)
	end)
end

-- The listing as indexed, or nil if it isn't. Yields. The first result is
-- false if MemoryStore couldn't be read.
function AuctionIndex.get(listingId: string): (boolean, Summary?)
	if AuctionLedger.isMock() then
		local entry = mockMaps[RECENT][listingId]
		return true, if entry then entry.value else nil
	end

	local summary: Summary? = nil
	local ok = protected(`lookup {listingId}`, function()
		summary = (getSortedMap(RECENT):GetAsync(listingId))
	end)
	return ok, summary
end

-- Up to `count` active listings after `cursor`: one item's cheapest first,
-- or every item's newest first when `itemId` is "". Yields. Returns whether
-- MemoryStore could be read, the listings, and the next page's cursor (""
-- after the last page).
function AuctionIndex.page(itemId: string, cursor: string, count: number): (boolean, { Summary }, string)
	local sortKey, key = AuctionProtocol.parseCursor(cursor)
	local entries: { Entry } = {}

	local ok = protected(`page of {if itemId == "" then "recent" else itemId}`, function()
		if itemId == "" then
			-- Newest first: the cursor bounds from above. Created times are numbers.
			local after: Bound? = if type(sortKey) == "number" then { key = key, sortKey = sortKey } else nil
			entries = range(RECENT, false, count, nil, after)
		else
			-- A cursor from another item (clients send it back) would escape
			-- this item's range, so only one inside it counts.
			local lower, upper = AuctionProtocol.itemRange(itemId)
			local inRange = type(sortKey) == "string" and sortKey > lower and sortKey < upper
			local after: Bound = if inRange then { key = key, sortKey = sortKey } else { sortKey = lower }
			entries = range(BY_ITEM, true, count, after, { sortKey = upper })
		end
	end)
	if not ok then
		return false, {}, ""
	end

	-- MemoryStore expires entries with its own clock; drop any that are due by ours.
	local now = os.time()
	local listings: { Summary } = {}
	for _, entry in entries do
		if type(entry.value) == "table" and entry.value.expiresAt > now then
			table.insert(listings, entry.value)
		end
	end

	local last = entries[#entries]
	local nextCursor = if #entries == count and last then AuctionProtocol.encodeCursor(last.sortKey, last.key) else ""
	return true, listings, nextCursor
end

-- // Purchase leases //

-- Reserves `listingId` for purchase attempt `purchaseId` for LOCK_TTL
-- seconds. Yields. True if this attempt holds it, and also if MemoryStore
-- can't be reached: the lease only saves wasted work, the ledger decides.
function AuctionIndex.lock(listingId: string, purchaseId: string): boolean
	if AuctionLedger.isMock() then
		local current = mockLocks[listingId]
		if current and current.purchaseId ~= purchaseId and current.expiresAt > os.clock() then
			return false
		end
		mockLocks[listingId] = { purchaseId = purchaseId, expiresAt = os.clock() + LOCK_TTL }
		return true
	end

	local held = false
	local reached = protected(`lock {listingId}`, function()
		getLocks():UpdateAsync(listingId, function(current: any): any
			held = current == nil or current.released == true or current.purchaseId == purchaseId
			return if held then { purchaseId = purchaseId } else nil
		end, LOCK_TTL)
	end)
	return held or not reached
end

-- Releases the lease if `purchaseId` still holds it. Yields.
function AuctionIndex.unlock(listingId: string, purchaseId: string)
	if AuctionLedger.isMock() then
		local current = mockLocks[listingId]
		if current and current.purchaseId == purchaseId then
			mockLocks[listingId] = nil
		end
		return
	end

	-- A conditional delete isn't possible, so mark it released (and let
	-- the marker expire right away) only if it's still ours.
	protected(`unlock {listingId}`, function()
		getLocks():UpdateAsync(listingId, function(current: any): any
			if current and current.purchaseId == purchaseId and not current.released then
				return { released = true }
			end
			return nil
		end, 1)
	end)
end

return AuctionIndex
