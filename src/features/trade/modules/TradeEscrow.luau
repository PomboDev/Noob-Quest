--!strict

--[=[
	Pure bookkeeping for one side of a trade, applied to that player's data.

	A trade moves through each profile in two steps:

	1. open: the offered coins and items leave the inventory and are parked in
	   `data.pendingTrade` along with what the other side will send
	2. settle: once the ledger has decided, "committed" delivers `receive` and
	   "aborted" refunds `give`. Settling only matches the pending trade's id,
	   so applying an outcome twice does nothing

	Escrowed goods are in no inventory, so nothing else can spend them, and a
	profile holds at most one pending trade.
]=]

local PlayerData = require("@Features/player/modules/PlayerData")

type Data = PlayerData.Data
export type Offer = PlayerData.Offer
export type PendingTrade = PlayerData.PendingTrade
export type Outcome = "committed" | "aborted"

-- Distinct item ids one side may offer.
local MAX_ITEM_TYPES = 8

local TradeEscrow = {
	MAX_ITEM_TYPES = MAX_ITEM_TYPES,
}

-- A whole, non-negative, finite amount (NaN and inf fail `% 1 == 0`).
local function isAmount(value: any): boolean
	return type(value) == "number" and value % 1 == 0 and value >= 0
end

local function copyOffer(offer: Offer): Offer
	return { coins = offer.coins, items = table.clone(offer.items) }
end

function TradeEscrow.emptyOffer(): Offer
	return { coins = 0, items = {} }
end

function TradeEscrow.isEmpty(offer: Offer): boolean
	return offer.coins == 0 and next(offer.items) == nil
end

-- Whether `data` owns everything in `offer` right now, and why not.
function TradeEscrow.validateOffer(data: Data, offer: Offer): (boolean, string?)
	if not isAmount(offer.coins) or offer.coins > data.coins then
		return false, "not enough coins"
	end

	local itemTypes = 0
	for itemId, amount in offer.items do
		itemTypes += 1
		if itemTypes > MAX_ITEM_TYPES then
			return false, "too many items"
		end
		if type(itemId) ~= "string" or not isAmount(amount) or amount == 0 then
			return false, "invalid item"
		end
		if amount > (data.inventory[itemId] or 0) then
			return false, `not enough {itemId}`
		end
	end

	return true, nil
end

-- Moves `give` out of `data` into escrow under `tradeId`. Changes nothing and
-- returns false if a trade is already pending or `data` can't afford `give`.
function TradeEscrow.open(data: Data, tradeId: string, give: Offer, receive: Offer): boolean
	if data.pendingTrade ~= nil or not TradeEscrow.validateOffer(data, give) then
		return false
	end

	data.coins -= give.coins
	for itemId, amount in give.items do
		local left = data.inventory[itemId] - amount
		if left > 0 then
			data.inventory[itemId] = left
		else
			data.inventory[itemId] = nil
		end
	end

	data.pendingTrade = {
		id = tradeId,
		give = copyOffer(give),
		receive = copyOffer(receive),
	}
	return true
end

-- Applies the ledger's decision for `tradeId`. Returns false (changing
-- nothing) if that trade isn't the one pending in `data`.
function TradeEscrow.settle(data: Data, tradeId: string, outcome: Outcome): boolean
	local pending = data.pendingTrade
	if pending == nil or pending.id ~= tradeId then
		return false
	end

	local delivered = if outcome == "committed" then pending.receive else pending.give
	data.coins += delivered.coins
	for itemId, amount in delivered.items do
		data.inventory[itemId] = (data.inventory[itemId] or 0) + amount
	end

	data.pendingTrade = nil
	return true
end

-- Whether `data` (e.g. a profile's last saved data) holds `tradeId` in escrow.
function TradeEscrow.isEscrowed(data: Data, tradeId: string): boolean
	local pending = data.pendingTrade
	return pending ~= nil and pending.id == tradeId
end

return TradeEscrow
