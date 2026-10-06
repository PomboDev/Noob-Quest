--!strict

--[=[
	Pure bookkeeping for the auction house in one player's data. Nothing here
	yields, so every function is safe inside PlayerService.updateData.

	Sellers: openListing moves the items out of the inventory into
	`auction.listings[id]`. Once the listing's ledger record is final,
	settleListing pays the price minus the fee for a sale and returns the
	items otherwise.

	Buyers: openPurchase moves the price out of the coins into
	`auction.purchase`. settlePurchase delivers the items if the purchase won
	and refunds the coins otherwise.

	Settling removes the escrow entry in the same step that pays out, and only
	matches that entry's id, so an outcome applied twice (a retry, a broadcast
	racing a timer, a rejoin) changes nothing the second time. A profile saved
	with an entry still in escrow settles it on its next load: escrow entries
	double as deferred claims.
]=]

local AuctionProtocol = require("@Features/auctionHouse/modules/AuctionProtocol")
local AuctionRecord = require("@Features/auctionHouse/modules/AuctionRecord")
local PlayerData = require("@Features/player/modules/PlayerData")

type Data = PlayerData.Data
type Record = AuctionRecord.Record
type Result = AuctionProtocol.Result
export type ListingEscrow = PlayerData.ListingEscrow
export type PurchaseEscrow = PlayerData.PurchaseEscrow

-- What settling a listing did: paid the seller, or gave the items back.
export type Settlement = "sold" | "returned"

local AuctionEscrow = {}

function AuctionEscrow.listingCount(data: Data): number
	local count = 0
	for _ in data.auction.listings do
		count += 1
	end
	return count
end

-- Whether `data` can list `amount` of `itemId` at `price` now, and why not.
function AuctionEscrow.validateListing(data: Data, itemId: string, amount: number, price: number): (boolean, Result?)
	if
		not AuctionProtocol.isItemId(itemId)
		or not AuctionProtocol.isAmount(amount)
		or not AuctionProtocol.isPrice(price)
	then
		return false, "invalid"
	elseif AuctionEscrow.listingCount(data) >= AuctionProtocol.MAX_LISTINGS then
		return false, "limit"
	elseif amount > (data.inventory[itemId] or 0) then
		return false, "invalid"
	end
	return true, nil
end

-- Moves the items into escrow under `listingId`, for LISTING_DURATION from
-- `now`. Returns the escrow entry, or nil and why (changing nothing).
function AuctionEscrow.openListing(
	data: Data,
	listingId: string,
	itemId: string,
	amount: number,
	price: number,
	now: number
): (ListingEscrow?, Result?)
	local ok: boolean, reason: Result? = AuctionEscrow.validateListing(data, itemId, amount, price)
	if not ok then
		return nil, reason
	elseif data.auction.listings[listingId] ~= nil then
		return nil, "invalid"
	end

	local left = (data.inventory[itemId] or 0) - amount
	if left > 0 then
		data.inventory[itemId] = left
	else
		data.inventory[itemId] = nil
	end

	local escrow: ListingEscrow = {
		itemId = itemId,
		amount = amount,
		price = price,
		createdAt = now,
		expiresAt = now + AuctionProtocol.LISTING_DURATION,
	}
	data.auction.listings[listingId] = escrow
	return escrow, nil
end

-- Applies a listing's final record to its seller's data. Returns nil
-- (changing nothing) while the listing is active, if `data` holds no escrow
-- for it, or if the record doesn't match that escrow.
function AuctionEscrow.settleListing(data: Data, sellerId: number, listingId: string, record: Record): Settlement?
	local escrow = data.auction.listings[listingId]
	if
		escrow == nil
		or record.status == "active"
		or record.id ~= listingId
		or record.sellerId ~= sellerId
		or record.itemId ~= escrow.itemId
		or record.amount ~= escrow.amount
	then
		return nil
	end

	data.auction.listings[listingId] = nil

	if record.status == "sold" then
		data.coins += AuctionProtocol.proceeds(record.price)
		return "sold"
	end

	data.inventory[escrow.itemId] = (data.inventory[escrow.itemId] or 0) + escrow.amount
	return "returned"
end

-- Updates the price shown for one of the player's listings.
function AuctionEscrow.setListingPrice(data: Data, listingId: string, price: number)
	local escrow = data.auction.listings[listingId]
	if escrow then
		escrow.price = price
	end
end

-- Moves the price into escrow for one purchase attempt. Returns false and
-- why (changing nothing) if another purchase is pending or it's unaffordable.
function AuctionEscrow.openPurchase(data: Data, purchase: PurchaseEscrow): (boolean, Result?)
	if data.auction.purchase ~= nil then
		return false, "pending"
	elseif
		not AuctionProtocol.isPrice(purchase.price)
		or not AuctionProtocol.isAmount(purchase.amount)
		or not AuctionProtocol.isItemId(purchase.itemId)
	then
		return false, "invalid"
	elseif purchase.price > data.coins then
		return false, "funds"
	end

	data.coins -= purchase.price
	data.auction.purchase = table.clone(purchase)
	return true, nil
end

-- Applies a purchase's outcome: the items if it won, the coins back if not.
-- Returns false (changing nothing) unless `purchaseId` is the one pending.
function AuctionEscrow.settlePurchase(data: Data, purchaseId: string, won: boolean): boolean
	local purchase = data.auction.purchase
	if purchase == nil or purchase.id ~= purchaseId then
		return false
	end

	data.auction.purchase = nil

	if won then
		data.inventory[purchase.itemId] = (data.inventory[purchase.itemId] or 0) + purchase.amount
	else
		data.coins += purchase.price
	end
	return true
end

-- Whether `data` (e.g. a profile's last saved copy) holds listing `listingId` in escrow.
function AuctionEscrow.holdsListing(data: Data, listingId: string): boolean
	local auction = data.auction
	return auction ~= nil and auction.listings[listingId] ~= nil
end

-- Whether `data` (e.g. a profile's last saved copy) holds purchase `purchaseId` in escrow.
function AuctionEscrow.holdsPurchase(data: Data, purchaseId: string): boolean
	local auction = data.auction
	local purchase = auction and auction.purchase
	return purchase ~= nil and purchase.id == purchaseId
end

return AuctionEscrow
