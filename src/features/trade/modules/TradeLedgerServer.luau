--!strict

--[=[
	The commit point of every trade.

	Two profiles can't be saved atomically, so neither profile decides how a
	trade ends. Each trade id gets one key in its own DataStore, written once
	through UpdateAsync: the first server to write "committed" or "aborted"
	wins, and every later call (from any server, for either player) reads that
	same outcome back. Both sides of a trade therefore always settle the same
	way, even across crashes, rejoins and session steals.

	When ProfileStore has no DataStore access (Studio without API access), its
	profiles live in memory, so the ledger does too.
]=]

local DataStoreService = game:GetService("DataStoreService")

local Log = require("@Core/Log")
local ProfileStore = require("@ServerPackages/profile-store")
local TradeEscrow = require("@Features/trade/modules/TradeEscrow")

type Outcome = TradeEscrow.Outcome

local STORE_NAME = "TradeLedger"
local ATTEMPTS = 5

local store: DataStore? = nil
local mockLedger: { [string]: Outcome } = {}

local TradeLedger = {}

local function usesMock(): boolean
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

-- Records `proposed` as the outcome of `tradeId` unless one is already
-- recorded, and returns the recorded outcome. Yields. Returns nil if the
-- DataStore stayed unreachable: the trade is then still undecided.
function TradeLedger.decideAsync(tradeId: string, proposed: Outcome): Outcome?
	if usesMock() then
		local outcome: Outcome = mockLedger[tradeId] or proposed
		mockLedger[tradeId] = outcome
		return outcome
	end

	for attempt = 1, ATTEMPTS do
		local decided: Outcome? = nil
		local ok, err = pcall(function()
			getStore():UpdateAsync(`Trade_{tradeId}`, function(current: any): any
				if current == "committed" or current == "aborted" then
					decided = current :: Outcome
					return nil -- already decided: leave it
				end
				decided = proposed
				return proposed
			end)
		end)

		if ok and decided then
			return decided
		end

		Log.warn(`Trade ledger write for {tradeId} failed (attempt {attempt}/{ATTEMPTS}): {err}`)
		if attempt < ATTEMPTS then
			task.wait(2 ^ attempt)
		end
	end

	return nil
end

return TradeLedger
