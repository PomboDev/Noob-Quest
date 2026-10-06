local AuctionEscrow = require("../src/features/auctionHouse/modules/AuctionEscrow")
local AuctionProtocol = require("../src/features/auctionHouse/modules/AuctionProtocol")
local AuctionRecord = require("../src/features/auctionHouse/modules/AuctionRecord")
local Expect = require("./Expect")

local NOW = 1_000_000
local SELLER = 1
local BUYER = 2

local function newData(coins: number, inventory: { [string]: number }): any
	return {
		schemaVersion = 1,
		coins = coins,
		level = 1,
		xp = 0,
		inventory = inventory,
		auction = { listings = {} },
	}
end

-- `record` as it stands once closed with `status`.
local function closed(record: any, status: string): any
	local copy = table.clone(record)
	copy.status = status
	return copy
end

local function purchase(id: string, price: number): any
	return { id = id, listingId = "L1", itemId = "sword", amount = 2, price = price, version = 1 }
end

return {
	["validateListing accepts what the player owns"] = function()
		local data = newData(0, { sword = 3 })
		Expect.equal(AuctionEscrow.validateListing(data, "sword", 3, AuctionProtocol.MAX_PRICE), true)
		Expect.equal(AuctionEscrow.validateListing(data, "sword", 1, AuctionProtocol.MIN_PRICE), true)
	end,

	["validateListing rejects malformed or unowned offers"] = function()
		local data = newData(0, { sword = 3 })
		for _, bad in { 0, -1, 0.5, 0 / 0, math.huge, AuctionProtocol.MAX_AMOUNT + 1, "1" } do
			Expect.equal(AuctionEscrow.validateListing(data, "sword", bad :: any, 10), false, `amount {bad}`)
		end
		for _, bad in { 0, -1, 0.5, 0 / 0, math.huge, AuctionProtocol.MAX_PRICE + 1 } do
			Expect.equal(AuctionEscrow.validateListing(data, "sword", 1, bad), false, `price {bad}`)
		end
		for _, bad in { "", string.rep("x", AuctionProtocol.MAX_ITEM_ID_LENGTH + 1), "\255", 7 } do
			Expect.equal(AuctionEscrow.validateListing(data, bad :: any, 1, 10), false, `item id {bad}`)
		end
		Expect.equal(AuctionEscrow.validateListing(data, "sword", 4, 10), false, "more than owned")
		Expect.equal(AuctionEscrow.validateListing(data, "bow", 1, 10), false, "unowned")
	end,

	["listings are capped"] = function()
		local data = newData(0, { sword = 100 })
		for i = 1, AuctionProtocol.MAX_LISTINGS do
			Expect.equal(AuctionEscrow.openListing(data, `L{i}`, "sword", 1, 10, NOW) ~= nil, true, `listing {i}`)
		end
		local escrow, reason = AuctionEscrow.openListing(data, "extra", "sword", 1, 10, NOW)
		Expect.equal(escrow, nil)
		Expect.equal(reason, "limit")
	end,

	["openListing moves the items into escrow"] = function()
		local data = newData(5, { sword = 3, shield = 1 })
		local escrow = AuctionEscrow.openListing(data, "L1", "sword", 3, 250, NOW)

		Expect.deepEqual(escrow, {
			itemId = "sword",
			amount = 3,
			price = 250,
			createdAt = NOW,
			expiresAt = NOW + AuctionProtocol.LISTING_DURATION,
		})
		Expect.deepEqual(data.inventory, { shield = 1 })
		Expect.equal(data.coins, 5)
		Expect.equal(data.auction.listings.L1, escrow)
		Expect.equal(AuctionEscrow.holdsListing(data, "L1"), true)
		Expect.equal(AuctionEscrow.listingCount(data), 1)
	end,

	["openListing refuses a reused id and changes nothing"] = function()
		local data = newData(0, { sword = 3 })
		AuctionEscrow.openListing(data, "L1", "sword", 1, 10, NOW)
		local before = AuctionEscrow.listingCount(data)

		Expect.equal(AuctionEscrow.openListing(data, "L1", "sword", 1, 10, NOW), nil)
		Expect.equal(AuctionEscrow.listingCount(data), before)
		Expect.equal(data.inventory.sword, 2)
	end,

	["proceeds keep the fee, rounded in the seller's favor"] = function()
		Expect.equal(AuctionProtocol.proceeds(100), 100 - math.floor(100 * AuctionProtocol.SALE_FEE))
		Expect.equal(AuctionProtocol.proceeds(1), 1)
		for _, price in { 1, 7, 19, 20, 999, AuctionProtocol.MAX_PRICE } do
			local proceeds = AuctionProtocol.proceeds(price)
			Expect.equal(proceeds % 1, 0, `whole at {price}`)
			Expect.equal(
				proceeds <= price and proceeds >= price * (1 - AuctionProtocol.SALE_FEE),
				true,
				`range at {price}`
			)
		end
	end,

	["a sold listing pays the seller once"] = function()
		local data = newData(0, { sword = 2 })
		local escrow = AuctionEscrow.openListing(data, "L1", "sword", 2, 100, NOW)
		local record = AuctionRecord.create("L1", SELLER, escrow)

		Expect.equal(AuctionEscrow.settleListing(data, SELLER, "L1", record), nil, "still active")
		Expect.equal(AuctionEscrow.holdsListing(data, "L1"), true)

		local sold = closed(record, "sold")
		Expect.equal(AuctionEscrow.settleListing(data, SELLER, "L1", sold), "sold")
		Expect.equal(AuctionEscrow.settleListing(data, SELLER, "L1", sold), nil, "second time")
		Expect.equal(data.coins, AuctionProtocol.proceeds(100))
		Expect.deepEqual(data.inventory, {})
		Expect.equal(AuctionEscrow.holdsListing(data, "L1"), false)
	end,

	["a listing that closes unsold returns the items"] = function()
		for _, status in { "cancelled", "expired", "void" } do
			local data = newData(0, { sword = 2 })
			local escrow = AuctionEscrow.openListing(data, "L1", "sword", 2, 100, NOW)
			local record = closed(AuctionRecord.create("L1", SELLER, escrow), status)

			Expect.equal(AuctionEscrow.settleListing(data, SELLER, "L1", record), "returned", status)
			Expect.deepEqual(data, newData(0, { sword = 2 }), status)
		end
	end,

	["settleListing ignores records that don't match the escrow"] = function()
		local data = newData(0, { sword = 2 })
		local escrow = AuctionEscrow.openListing(data, "L1", "sword", 2, 100, NOW)
		local sold = closed(AuctionRecord.create("L1", SELLER, escrow), "sold")

		local mismatches = {
			{ sellerId = 99 },
			{ id = "L2" },
			{ itemId = "shield" },
			{ amount = 1 },
		}
		for _, fields in mismatches do
			local record = table.clone(sold)
			for key, value in fields do
				record[key] = value
			end
			Expect.equal(AuctionEscrow.settleListing(data, SELLER, "L1", record), nil)
		end
		Expect.equal(AuctionEscrow.settleListing(data, 99, "L1", sold), nil, "other seller")
		Expect.equal(AuctionEscrow.holdsListing(data, "L1"), true)
	end,

	["openPurchase escrows the price once"] = function()
		local data = newData(100, {})
		local ok, reason = AuctionEscrow.openPurchase(data, purchase("P1", 101))
		Expect.equal(ok, false)
		Expect.equal(reason, "funds")

		Expect.equal(AuctionEscrow.openPurchase(data, purchase("P1", 60)), true)
		Expect.equal(data.coins, 40)
		Expect.equal(AuctionEscrow.holdsPurchase(data, "P1"), true)

		ok, reason = AuctionEscrow.openPurchase(data, purchase("P2", 10))
		Expect.equal(ok, false)
		Expect.equal(reason, "pending")
		Expect.equal(data.coins, 40)
	end,

	["openPurchase rejects malformed prices"] = function()
		for _, bad in { 0, -5, 0.5, 0 / 0, math.huge } do
			local data = newData(100, {})
			Expect.equal(AuctionEscrow.openPurchase(data, purchase("P1", bad)), false, `price {bad}`)
			Expect.equal(data.coins, 100)
		end
	end,

	["a won purchase delivers, a lost one refunds, each once"] = function()
		local won = newData(100, {})
		AuctionEscrow.openPurchase(won, purchase("P1", 60))
		Expect.equal(AuctionEscrow.settlePurchase(won, "P2", true), false, "other purchase")
		Expect.equal(AuctionEscrow.settlePurchase(won, "P1", true), true)
		Expect.equal(AuctionEscrow.settlePurchase(won, "P1", true), false, "second time")
		Expect.deepEqual(won, newData(40, { sword = 2 }))

		local lost = newData(100, {})
		AuctionEscrow.openPurchase(lost, purchase("P1", 60))
		Expect.equal(AuctionEscrow.settlePurchase(lost, "P1", false), true)
		Expect.deepEqual(lost, newData(100, {}))
	end,

	["a sale conserves goods net of the fee"] = function()
		local seller = newData(0, { sword = 2 })
		local buyer = newData(500, {})
		local escrow = AuctionEscrow.openListing(seller, "L1", "sword", 2, 300, NOW)
		AuctionEscrow.openPurchase(buyer, purchase("P1", 300))

		local sold = closed(AuctionRecord.create("L1", SELLER, escrow), "sold")
		sold.buyerId = BUYER
		AuctionEscrow.settleListing(seller, SELLER, "L1", sold)
		AuctionEscrow.settlePurchase(buyer, "P1", true)

		local fee = 300 - AuctionProtocol.proceeds(300)
		Expect.equal(seller.coins + buyer.coins + fee, 500)
		Expect.deepEqual(buyer.inventory, { sword = 2 })
		Expect.deepEqual(seller.inventory, {})
	end,

	["pages round-trip, including empty ones"] = function()
		local page = {
			itemId = "sword",
			cursor = AuctionProtocol.encodeCursor("abc:0000000010", "00000000-0000-0000-0000-000000000001"),
			listings = {
				{
					id = "00000000-0000-0000-0000-000000000001",
					sellerId = 42,
					itemId = "sword",
					amount = 2,
					price = 10,
					version = 3,
					createdAt = NOW,
					expiresAt = NOW + 60,
				},
			},
		}
		Expect.deepEqual(AuctionProtocol.decodePage(AuctionProtocol.encodePage(page :: any)), page)

		local empty = { itemId = "", cursor = "", listings = {} }
		Expect.deepEqual(AuctionProtocol.decodePage(AuctionProtocol.encodePage(empty :: any)), empty)
	end,

	["cursors round-trip and reject junk"] = function()
		local id = "0A1B2C3D-0000-0000-0000-000000000001"
		for _, sortKey in { 1700000000, "73776f7264:0000000100" } do
			local parsedKey, parsedId = AuctionProtocol.parseCursor(AuctionProtocol.encodeCursor(sortKey :: any, id))
			Expect.equal(parsedKey, sortKey)
			Expect.equal(parsedId, id)
		end

		for _, junk in
			{ "", "|", "n5|nope", "x5|" .. id, "n-1|" .. id, "nnan|" .. id, "s" .. string.rep("a", 129) .. "|" .. id }
		do
			Expect.equal(AuctionProtocol.parseCursor(junk), nil, junk)
		end
	end,

	["item sort keys stay within their own item's range, ordered by price"] = function()
		local items = { "a", "ab", "abc", "ab:c", "ab;", "Ab", "b", "health potion" }
		for _, itemId in items do
			local lower, upper = AuctionProtocol.itemRange(itemId)
			for _, other in items do
				for _, price in { AuctionProtocol.MIN_PRICE, 999, AuctionProtocol.MAX_PRICE } do
					local key = AuctionProtocol.itemSortKey(other, price)
					Expect.equal(key > lower and key < upper, other == itemId, `{other} at {price} in {itemId}'s range`)
				end
			end
		end

		Expect.equal(AuctionProtocol.itemSortKey("sword", 9) < AuctionProtocol.itemSortKey("sword", 10), true)
		local longest =
			AuctionProtocol.itemSortKey(string.rep("x", AuctionProtocol.MAX_ITEM_ID_LENGTH), AuctionProtocol.MAX_PRICE)
		Expect.equal(#longest <= 128, true, "fits MemoryStore's sort key limit")
	end,
}
