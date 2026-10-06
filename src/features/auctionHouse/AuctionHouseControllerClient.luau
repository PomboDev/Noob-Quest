--!strict

--[=[
	Client side of the auction house: Charm atoms for UI to bind to, and the
	actions an auction UI calls. The server decides everything; these only ask.

		AuctionHouseController.open()
		AuctionHouseController.search("sword") -- cheapest swords first
		AuctionHouseController.search() -- newest listings of every item
		AuctionHouseController.list("sword", 1, 250)
		AuctionHouseController.buy(listing) -- a Summary from state.page()

	The player's own listings, and coins held for a purchase, are in their
	replicated data under `auction` (see PlayerController).
]=]

local AuctionProtocol = require("@Features/auctionHouse/modules/AuctionProtocol")
local Charm = require("@Packages/charm")
local Log = require("@Core/Log")
local Network = require("@Core/Network")
local PlayerStateController = require("@Features/playerState/PlayerStateControllerClient")

type Page = AuctionProtocol.Page
type Summary = AuctionProtocol.Summary

export type Outcome = {
	-- "open", "browse", "list", "cancel", "reprice", "buy", or "settle" when
	-- one of the player's listings closed
	action: string,
	listingId: string,
	result: AuctionProtocol.Result,
}

local page = Charm.atom(nil :: Page?)
local lastResult = Charm.atom(nil :: Outcome?)

local network: Network.ClientNetwork? = nil
-- Only the latest search's page is shown.
local latestRequest = 0

local AuctionHouseController = {}

AuctionHouseController.state = {
	-- True while the server has the auction house open for this player.
	isOpen = PlayerStateController.state.inAuction,
	page = page,
	lastResult = lastResult,
}

local function fire(method: string, ...: any)
	if network then
		network:fire(method, ...)
	end
end

-- // Network (server -> client) //

function AuctionHouseController.onPage(requestId: number, data: buffer)
	if requestId == latestRequest then
		page(AuctionProtocol.decodePage(data))
	end
end

function AuctionHouseController.onResult(action: string, listingId: string, result: string)
	lastResult({ action = action, listingId = listingId, result = result :: AuctionProtocol.Result })
	Log.debug(`Auction {action} {listingId}: {result}`)
end

-- A listing changed on some server: patch the page on screen.
function AuctionHouseController.onListingChanged(listingId: string, kind: string, price: number, version: number)
	local current = page()
	if not current then
		return
	end

	local listings: { Summary } = {}
	local changed = false
	for _, listing in current.listings do
		if listing.id ~= listingId then
			table.insert(listings, listing)
		elseif kind == "repriced" then
			local updated = table.clone(listing)
			updated.price = price
			updated.version = version
			table.insert(listings, updated)
			changed = true
		else
			changed = true -- sold, cancelled or expired: gone
		end
	end

	if changed then
		page({ itemId = current.itemId, listings = listings, cursor = current.cursor })
	end
end

-- // Actions //

function AuctionHouseController.open()
	fire("openAuction")
end

function AuctionHouseController.close()
	fire("closeAuction")
	page(nil)
end

-- One page of listings: `itemId`'s cheapest first, or every item's newest
-- first. Pass the current page's cursor to get the next one.
function AuctionHouseController.search(itemId: string?, cursor: string?)
	latestRequest = (latestRequest + 1) % 65536
	fire("browse", latestRequest, itemId or "", cursor or "")
end

function AuctionHouseController.list(itemId: string, amount: number, price: number)
	fire("createListing", itemId, amount, price)
end

function AuctionHouseController.cancel(listingId: string)
	fire("cancelListing", listingId)
end

function AuctionHouseController.reprice(listingId: string, price: number)
	fire("repriceListing", listingId, price)
end

-- Buys at the price shown: if the seller changed it meanwhile, the result
-- is "changed" and nothing is charged.
function AuctionHouseController.buy(listing: Summary)
	fire("buyListing", listing.id, listing.price, listing.version)
end

function AuctionHouseController.start()
	network = Network.client("AuctionHouse", AuctionHouseController)
end

return AuctionHouseController
