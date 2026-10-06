--!strict

--[=[
	The durable store of auction listings: one DataStore key per listing,
	holding its AuctionRecord. Every change goes through UpdateAsync with a
	transform from AuctionRecord, so changes from different servers to one
	listing apply one at a time, and the record is the commit point of every
	sale, cancellation and expiry.

	Records stay after a listing closes, as the auction house's permanent
	history. Each write tags the record with the seller's and buyer's user
	ids for data-erasure requests.

	When ProfileStore has no DataStore access (Studio without API access),
	its profiles live in memory, so the ledger does too.
]=]

local DataStoreService = game:GetService("DataStoreService")

local AuctionRecord = require("@Features/auctionHouse/modules/AuctionRecord")
local Log = require("@Core/Log")
local ProfileStore = require("@ServerPackages/profile-store")

type Record = AuctionRecord.Record

local STORE_NAME = "AuctionLedger"
-- Longest wait for this server's request budget before trying anyway.
local BUDGET_WAIT = 10

local store: DataStore? = nil
local getOptions: DataStoreGetOptions? = nil
local mockRecords: { [string]: Record } = {}

local AuctionLedger = {}

-- Whether the auction house runs on in-memory stand-ins (no API access).
-- Yields until ProfileStore knows.
function AuctionLedger.isMock(): boolean
	while ProfileStore.DataStoreState == "NotReady" do
		task.wait()
	end
	return ProfileStore.DataStoreState ~= "Access"
end

local function getStore(): DataStore
	local current = store or DataStoreService:GetDataStore(STORE_NAME)
	store = current
	return current
end

-- Reads must see writes from other servers, so skip the 4 s read cache.
local function getReadOptions(): DataStoreGetOptions
	local existing = getOptions
	if existing then
		return existing
	end
	local options = Instance.new("DataStoreGetOptions")
	options.UseCache = false
	getOptions = options
	return options
end

local function keyOf(listingId: string): string
	return `Listing_{listingId}`
end

local function userIdsOf(record: Record): { number }
	local userIds = { record.sellerId }
	if record.buyerId then
		table.insert(userIds, record.buyerId)
	end
	return userIds
end

local function deepCopy(value: any): any
	if type(value) ~= "table" then
		return value
	end
	local copy = {}
	for key, item in value do
		copy[key] = deepCopy(item)
	end
	return copy
end

-- Waits until this server may send another request of `requestType`, so
-- auction traffic queues instead of failing when the budget runs low.
local function waitForBudget(requestType: Enum.DataStoreRequestType)
	local deadline = os.clock() + BUDGET_WAIT
	while DataStoreService:GetRequestBudgetForRequestType(requestType) < 1 and os.clock() < deadline do
		task.wait(1)
	end
end

-- The listing's record, or nil if it has none. Yields. The first result is
-- false if the DataStore couldn't be read.
function AuctionLedger.read(listingId: string): (boolean, Record?)
	if AuctionLedger.isMock() then
		return true, deepCopy(mockRecords[listingId])
	end

	waitForBudget(Enum.DataStoreRequestType.GetAsync)
	local ok, result = pcall(function(): any
		return getStore():GetAsync(keyOf(listingId), getReadOptions())
	end)
	if not ok then
		Log.warn(`Auction ledger read of {listingId} failed: {result}`)
		return false, nil
	end
	return true, result
end

-- Applies `transform` to the listing's record. Yields. Returns the outcome
-- and the record as it now stands, or nil if the DataStore stayed
-- unreachable for `attempts` tries. In that case the change may or may not
-- have been written: retry it (transforms are idempotent) or settle it
-- another way, never assume either.
function AuctionLedger.update<O>(listingId: string, transform: AuctionRecord.Transform<O>, attempts: number): (O?, Record?)
	if AuctionLedger.isMock() then
		local written, outcome = transform(deepCopy(mockRecords[listingId]))
		if written ~= nil then
			mockRecords[listingId] = deepCopy(written)
		end
		return outcome, deepCopy(mockRecords[listingId])
	end

	for attempt = 1, attempts do
		-- UpdateAsync may run the transform several times (whenever another
		-- server wrote first); the last run is the one that took effect.
		local outcome: O? = nil
		local after: Record? = nil

		waitForBudget(Enum.DataStoreRequestType.UpdateAsync)
		local ok, err = pcall(function()
			getStore():UpdateAsync(keyOf(listingId), function(current: any): (any, any)
				local written, result = transform(current)
				outcome = result
				after = if written ~= nil then written else current
				if written == nil then
					return nil, nil -- cancel: nothing to change
				end
				return written, userIdsOf(written)
			end)
		end)

		if ok and outcome ~= nil then
			return outcome, after
		end

		Log.warn(`Auction ledger write to {listingId} failed (attempt {attempt}/{attempts}): {err}`)
		if attempt < attempts then
			task.wait(2 ^ attempt)
		end
	end

	return nil, nil
end

return AuctionLedger
