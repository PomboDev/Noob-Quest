--!strict

--[=[
	The ledger record of one listing, and every change to it as a pure
	transform for DataStore UpdateAsync (see AuctionLedgerServer).

	A record is the single source of truth for its listing. A transform takes
	the stored record (nil if there is none) and returns the record to write
	(nil to leave it alone) and an outcome. UpdateAsync reruns the transform
	whenever another server wrote first, so of two conflicting changes (two
	buyers, a buyer and the seller cancelling, a buyer and expiry) exactly one
	applies and the other sees its result.

		(none) ──publish──────────▶ active ──commit──▶ sold
		(none) ──voidUnpublished──▶ void      ├─cancel──▶ cancelled
		                                      ├─expire──▶ expired
		                                      └─reprice─▶ active (new price, version + 1)

	Only "active" ever changes, so a server that reads any other status can
	act on it without writing. Transforms never mutate their input, and each
	one is idempotent: retrying a change whose reply was lost reports the
	same outcome without applying it twice.

	Purchases are fenced by id. commit names the purchase attempt in the sold
	record, so a retried commit still reports "won". resolvePurchase, used
	when a purchase's outcome is unknown, records the attempt in `voided`
	while the listing is still active, so a commit still in flight from
	another server can't land after the buyer was refunded.
]=]

local AuctionProtocol = require("@Features/auctionHouse/modules/AuctionProtocol")
local PlayerData = require("@Features/player/modules/PlayerData")

export type Status = "active" | "sold" | "cancelled" | "expired" | "void"

export type Record = {
	id: string,
	status: Status,
	sellerId: number,
	itemId: string,
	amount: number,
	price: number,
	version: number,
	createdAt: number,
	expiresAt: number,
	-- When the record stopped being active.
	closedAt: number?,
	-- Set by the sale.
	buyerId: number?,
	purchaseId: string?,
	-- Purchase attempts resolved as lost while the listing was active.
	voided: { string }?,
}

-- What a buyer agreed to. commit only applies if the record still matches.
export type PurchaseRequest = {
	purchaseId: string,
	buyerId: number,
	itemId: string,
	amount: number,
	price: number,
	version: number,
}

-- The record to write (nil: leave it as is) and the outcome.
export type Transform<O> = (current: Record?) -> (Record?, O)

export type CommitOutcome =
	"won" -- sold to this purchase
	| "sold" -- sold to someone else
	| "closed" -- cancelled or never published
	| "expired"
	| "changed" -- price, version or goods differ from the request
	| "own" -- the buyer is the seller
	| "voided" -- this attempt was resolved as lost
	| "missing" -- no such listing

local AuctionRecord = {}

local function contains(list: { string }?, value: string): boolean
	if list then
		for _, item in list do
			if item == value then
				return true
			end
		end
	end
	return false
end

local function close(record: Record, status: Status, now: number): Record
	local closed = table.clone(record)
	closed.status = status
	closed.closedAt = now
	-- Nothing can commit to a closed listing, so the fence has done its job.
	closed.voided = nil
	return closed
end

-- The record a listing escrowed by `sellerId` publishes as.
function AuctionRecord.create(listingId: string, sellerId: number, escrow: PlayerData.ListingEscrow): Record
	return {
		id = listingId,
		status = "active",
		sellerId = sellerId,
		itemId = escrow.itemId,
		amount = escrow.amount,
		price = escrow.price,
		version = 1,
		createdAt = escrow.createdAt,
		expiresAt = escrow.expiresAt,
	}
end

function AuctionRecord.summary(record: Record): AuctionProtocol.Summary
	return {
		id = record.id,
		sellerId = record.sellerId,
		itemId = record.itemId,
		amount = record.amount,
		price = record.price,
		version = record.version,
		createdAt = record.createdAt,
		expiresAt = record.expiresAt,
	}
end

-- Makes `record` live, unless its listing was voided first.
function AuctionRecord.publish(record: Record): Transform<"published" | "void">
	return function(current: Record?): (Record?, "published" | "void")
		if current == nil then
			return table.clone(record), "published"
		elseif current.status == "void" then
			return nil, "void"
		end
		-- Already published: a retry whose first reply was lost.
		return nil, "published"
	end
end

-- Makes sure `record` (built with create) is never published, unless it
-- already was. Outcome: the status the record ends up with.
function AuctionRecord.voidUnpublished(record: Record, now: number): Transform<Status>
	return function(current: Record?): (Record?, Status)
		if current == nil then
			return close(record, "void", now), "void"
		end
		return nil, current.status
	end
end

-- Sells the listing to `request`'s purchase if it's still active, unexpired
-- and exactly what the buyer agreed to.
function AuctionRecord.commit(request: PurchaseRequest, now: number): Transform<CommitOutcome>
	return function(current: Record?): (Record?, CommitOutcome)
		if current == nil then
			return nil, "missing"
		elseif current.status == "sold" and current.purchaseId == request.purchaseId then
			return nil, "won" -- already ours: an earlier reply was lost
		elseif contains(current.voided, request.purchaseId) then
			return nil, "voided"
		elseif current.status == "sold" then
			return nil, "sold"
		elseif current.status == "expired" or (current.status == "active" and now >= current.expiresAt) then
			return nil, "expired"
		elseif current.status ~= "active" then
			return nil, "closed"
		elseif current.sellerId == request.buyerId then
			return nil, "own"
		elseif
			current.price ~= request.price
			or current.version ~= request.version
			or current.itemId ~= request.itemId
			or current.amount ~= request.amount
		then
			return nil, "changed"
		end

		local sold = close(current, "sold", now)
		sold.buyerId = request.buyerId
		sold.purchaseId = request.purchaseId
		return sold, "won"
	end
end

-- Settles a purchase attempt whose commit may or may not have landed:
-- "won" if it did, otherwise "lost", fencing the attempt off so it never can.
function AuctionRecord.resolvePurchase(purchaseId: string): Transform<"won" | "lost">
	return function(current: Record?): (Record?, "won" | "lost")
		if current == nil then
			-- commit never writes a missing record, and a purchase only starts
			-- after reading the listing's record, so nothing can land here.
			return nil, "lost"
		elseif current.status == "sold" and current.purchaseId == purchaseId then
			return nil, "won"
		elseif current.status ~= "active" or contains(current.voided, purchaseId) then
			return nil, "lost"
		end

		local fenced = table.clone(current)
		local voided = if current.voided then table.clone(current.voided) else {}
		table.insert(voided, purchaseId)
		fenced.voided = voided
		return fenced, "lost"
	end
end

-- The seller takes an active listing down. Outcome: "cancelled", or the
-- status that got there first ("sold" means the seller is paid instead).
function AuctionRecord.cancel(sellerId: number, now: number): Transform<Status | "missing" | "forbidden">
	return function(current: Record?): (Record?, Status | "missing" | "forbidden")
		if current == nil then
			return nil, "missing"
		elseif current.sellerId ~= sellerId then
			return nil, "forbidden"
		elseif current.status ~= "active" then
			return nil, current.status
		end
		return close(current, "cancelled", now), "cancelled"
	end
end

-- Closes an active listing whose time is up. Outcome: the resulting status.
function AuctionRecord.expire(now: number): Transform<Status | "missing">
	return function(current: Record?): (Record?, Status | "missing")
		if current == nil then
			return nil, "missing"
		elseif current.status ~= "active" or now < current.expiresAt then
			return nil, current.status
		end
		return close(current, "expired", now), "expired"
	end
end

-- Changes an active listing's price, bumping its version so purchases made
-- at the old price fail with "changed".
function AuctionRecord.reprice(
	sellerId: number,
	price: number,
	now: number
): Transform<"repriced" | Status | "missing" | "forbidden">
	return function(current: Record?): (Record?, "repriced" | Status | "missing" | "forbidden")
		if current == nil then
			return nil, "missing"
		elseif current.sellerId ~= sellerId then
			return nil, "forbidden"
		elseif current.status ~= "active" then
			return nil, current.status
		elseif now >= current.expiresAt then
			return nil, "expired"
		elseif current.price == price then
			return nil, "repriced" -- already at that price, e.g. a retry
		end

		local repriced = table.clone(current)
		repriced.price = price
		repriced.version += 1
		return repriced, "repriced"
	end
end

return AuctionRecord
