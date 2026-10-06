--!strict

--[=[
	What auction house clients and servers agree on: the limits a listing
	must respect, what a listing looks like on the wire, and the cursors that
	page through search results.

	A page of search results is sent whole (a DeltaCompress full sync, like a
	TradeProtocol view): it's at most PAGE_SIZE small summaries.
]=]

local DeltaCompress = require("@Core/DeltaCompress")

-- One active listing, as the index stores it and clients see it.
export type Summary = {
	id: string,
	sellerId: number,
	itemId: string,
	amount: number,
	price: number,
	-- Bumped whenever the price changes. buyListing must echo it.
	version: number,
	createdAt: number,
	expiresAt: number,
}

export type Page = {
	-- "" for the newest listings of every item.
	itemId: string,
	listings: { Summary },
	-- Pass back to get the next page. "" on the last one.
	cursor: string,
}

-- What onResult reports.
export type Result =
	"ok"
	| "busy" -- trading, another auction action is running, or someone else is buying this listing
	| "notOpen" -- the auction house isn't open for this player
	| "invalid" -- malformed request, or the player doesn't own what they offered
	| "limit" -- too many listings
	| "funds" -- not enough coins
	| "notFound" -- no such active listing
	| "changed" -- the price changed: refresh and try again
	| "sold" -- buying: someone was first. Settling: your listing sold
	| "returned" -- settling: your listing closed unsold and the items are back
	| "expired"
	| "own" -- can't buy your own listing
	| "pending" -- an earlier purchase is still being resolved
	| "delayed" -- the ledger couldn't be reached: it settles automatically later
	| "failed" -- nothing changed
	| "cooldown"
	| "closing" -- the server is shutting down

local AuctionProtocol = {
	MAX_LISTINGS = 10,
	-- Seconds a listing stays up (MemoryStore keeps entries 45 days at most).
	LISTING_DURATION = 48 * 60 * 60,
	MIN_PRICE = 1,
	MAX_PRICE = 1_000_000_000,
	-- Matches the NumberU16 the amount travels as.
	MAX_AMOUNT = 65535,
	-- Share of the price kept by the auction house (a coin sink).
	SALE_FEE = 0.05,
	PAGE_SIZE = 20,
	-- Hex-encoded in sort keys, which MemoryStore caps at 128 characters.
	MAX_ITEM_ID_LENGTH = 50,
}

-- What the seller receives for a sale at `price`.
function AuctionProtocol.proceeds(price: number): number
	return price - math.floor(price * AuctionProtocol.SALE_FEE)
end

-- A whole number from `min` to `max` (NaN and inf fail `% 1 == 0`).
function AuctionProtocol.isWhole(value: any, min: number, max: number): boolean
	return type(value) == "number" and value % 1 == 0 and value >= min and value <= max
end

function AuctionProtocol.isPrice(value: any): boolean
	return AuctionProtocol.isWhole(value, AuctionProtocol.MIN_PRICE, AuctionProtocol.MAX_PRICE)
end

function AuctionProtocol.isAmount(value: any): boolean
	return AuctionProtocol.isWhole(value, 1, AuctionProtocol.MAX_AMOUNT)
end

-- Valid UTF-8 (so it survives JSON) and short enough for a sort key.
function AuctionProtocol.isItemId(value: any): boolean
	return type(value) == "string"
		and #value > 0
		and #value <= AuctionProtocol.MAX_ITEM_ID_LENGTH
		and utf8.len(value) ~= nil
end

-- Listing ids are HttpService GUIDs without braces.
function AuctionProtocol.isListingId(value: any): boolean
	return type(value) == "string" and #value == 36 and string.match(value, "^[%x%-]+$") ~= nil
end

-- // Sort keys //

local function toHex(value: string): string
	return (
		string.gsub(value, ".", function(char: string): string
			return string.format("%02x", string.byte(char))
		end)
	)
end

-- Orders one item's listings by price. Hex digits never include ":" or ";",
-- so no other item's keys fall between the bounds of itemRange.
function AuctionProtocol.itemSortKey(itemId: string, price: number): string
	return `{toHex(itemId)}:{string.format("%010d", price)}`
end

-- Exclusive bounds enclosing every itemSortKey of `itemId`.
function AuctionProtocol.itemRange(itemId: string): (string, string)
	local prefix = toHex(itemId)
	return `{prefix}:`, `{prefix};`
end

-- // Cursors //
-- A cursor is the sort key and listing id of a page's last entry.

function AuctionProtocol.encodeCursor(sortKey: string | number, key: string): string
	local kind = if type(sortKey) == "number" then "n" else "s"
	return `{kind}{sortKey}|{key}`
end

-- The sort key and listing id in `cursor`, or nil if it isn't one (clients
-- send it back, so it's untrusted).
function AuctionProtocol.parseCursor(cursor: string): (string | number | nil, string?)
	local kind, sortKey, key = string.match(cursor, "^([ns])(.*)|([^|]*)$")
	if not kind or not sortKey or not AuctionProtocol.isListingId(key) then
		return nil, nil
	end

	local parsed: string | number | nil = nil
	if kind == "s" and #sortKey <= 128 then
		parsed = sortKey
	elseif kind == "n" then
		local number = tonumber(sortKey)
		parsed = if AuctionProtocol.isWhole(number, 0, math.huge) then number else nil
	end

	if parsed == nil then
		return nil, nil
	end
	return parsed, key
end

-- // Pages //

local PAGE_TEMPLATE: Page = {
	itemId = "",
	listings = {
		{
			id = "",
			sellerId = 0,
			itemId = "",
			amount = 0,
			price = 0,
			version = 0,
			createdAt = 0,
			expiresAt = 0,
		},
	},
	cursor = "",
}

local CONTEXT = DeltaCompress.createContext(PAGE_TEMPLATE)

function AuctionProtocol.encodePage(page: Page): buffer
	local delta = DeltaCompress.createDelta({} :: any, page, CONTEXT)
	return assert(delta, "a page is never empty")
end

function AuctionProtocol.decodePage(data: buffer): Page
	return DeltaCompress.applyDelta({} :: any, data, CONTEXT)
end

return AuctionProtocol
