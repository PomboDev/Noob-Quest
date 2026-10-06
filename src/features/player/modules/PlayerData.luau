--!strict

--[=[
	Shape of a player's saved data, shared by server and client.

	TEMPLATE seeds new profiles (ProfileStore fills missing keys on Reconcile),
	and CONTEXT interns its keys so replication deltas stay small. Add new
	fields here; both sides pick them up automatically. Renaming or reshaping
	a field that has shipped also needs a migration (see PlayerMigrations).
]=]

local DeltaCompress = require("@Core/DeltaCompress")

-- Coins and items (itemId -> amount) one side of a trade puts up.
export type Offer = {
	coins: number,
	items: { [string]: number },
}

-- A trade this profile is part of whose outcome hasn't been applied yet
-- (see features/trade). `give` has already left the inventory and `receive`
-- hasn't arrived.
export type PendingTrade = {
	id: string,
	give: Offer,
	receive: Offer,
}

-- Items a seller put up on the auction house (see features/auctionHouse).
-- They left the inventory when the listing was created; the listing's
-- ledger record decides whether they come back or turn into coins.
export type ListingEscrow = {
	itemId: string,
	amount: number,
	-- The price when listed or last repriced, for display. Settlement uses
	-- the price in the ledger record.
	price: number,
	createdAt: number,
	expiresAt: number,
}

-- Coins a buyer put up for one purchase attempt whose outcome hasn't been
-- applied yet. `id` is the attempt's id, recorded in the listing on a sale.
export type PurchaseEscrow = {
	id: string,
	listingId: string,
	itemId: string,
	amount: number,
	price: number,
	version: number,
}

export type AuctionData = {
	listings: { [string]: ListingEscrow },
	purchase: PurchaseEscrow?,
}

export type Data = {
	schemaVersion: number,
	coins: number,
	level: number,
	xp: number,
	inventory: { [string]: number },
	pendingTrade: PendingTrade?,
	auction: AuctionData,
	-- Developer product purchases already granted: PurchaseId -> os.time()
	-- of the grant (see features/monetization). Only the newest are kept.
	receipts: { [string]: number },
}

local TEMPLATE = table.freeze({
	schemaVersion = 1,
	coins = 0,
	level = 1,
	xp = 0,
	inventory = table.freeze({}),
	auction = table.freeze({
		listings = table.freeze({}),
	}),
	receipts = table.freeze({}),
}) :: Data

return {
	TEMPLATE = TEMPLATE,
	CONTEXT = DeltaCompress.createContext(TEMPLATE),
}
