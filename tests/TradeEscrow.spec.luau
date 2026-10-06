local Expect = require("./Expect")
local TradeEscrow = require("../src/features/trade/modules/TradeEscrow")
local TradeProtocol = require("../src/features/trade/modules/TradeProtocol")

local function newData(coins: number, inventory: { [string]: number }): any
	return { schemaVersion = 1, coins = coins, level = 1, xp = 0, inventory = inventory }
end

local function offer(coins: number, items: { [string]: number }): any
	return { coins = coins, items = items }
end

-- Total coins and items across both players, which no outcome may change.
local function totals(a: any, b: any): any
	local result = { coins = a.coins + b.coins, items = {} }
	for _, data in { a, b } do
		for itemId, amount in data.inventory do
			result.items[itemId] = (result.items[itemId] or 0) + amount
		end
		local pending = data.pendingTrade
		if pending then
			result.coins += pending.give.coins
			for itemId, amount in pending.give.items do
				result.items[itemId] = (result.items[itemId] or 0) + amount
			end
		end
	end
	return result
end

return {
	["validateOffer accepts what the player owns"] = function()
		local data = newData(100, { sword = 3 })
		Expect.equal(TradeEscrow.validateOffer(data, offer(100, { sword = 3 })), true)
		Expect.equal(TradeEscrow.validateOffer(data, offer(0, {})), true)
	end,

	["validateOffer rejects what the player doesn't own"] = function()
		local data = newData(100, { sword = 3 })
		Expect.equal(TradeEscrow.validateOffer(data, offer(101, {})), false, "coins")
		Expect.equal(TradeEscrow.validateOffer(data, offer(0, { sword = 4 })), false, "too many swords")
		Expect.equal(TradeEscrow.validateOffer(data, offer(0, { bow = 1 })), false, "unowned item")
	end,

	["validateOffer rejects malformed amounts"] = function()
		local data = newData(100, { sword = 3 })
		for _, bad in { -1, 0.5, 0 / 0, math.huge, "1" } do
			Expect.equal(TradeEscrow.validateOffer(data, offer(bad :: any, {})), false, `coins {bad}`)
		end
		for _, bad in { -1, 0, 0.5, 0 / 0 } do
			Expect.equal(TradeEscrow.validateOffer(data, offer(0, { sword = bad })), false, `amount {bad}`)
		end
	end,

	["validateOffer caps distinct items"] = function()
		local inventory, items = {}, {}
		for i = 1, TradeEscrow.MAX_ITEM_TYPES + 1 do
			inventory[`item{i}`] = 1
			items[`item{i}`] = 1
		end
		Expect.equal(TradeEscrow.validateOffer(newData(0, inventory), offer(0, items)), false)
	end,

	["open moves the offer into escrow"] = function()
		local data = newData(100, { sword = 3, shield = 1 })
		local ok = TradeEscrow.open(data, "t1", offer(40, { sword = 3 }), offer(5, { gem = 1 }))

		Expect.equal(ok, true)
		Expect.deepEqual(data.inventory, { shield = 1 })
		Expect.equal(data.coins, 60)
		Expect.deepEqual(
			data.pendingTrade,
			{ id = "t1", give = offer(40, { sword = 3 }), receive = offer(5, { gem = 1 }) }
		)
		Expect.equal(TradeEscrow.isEscrowed(data, "t1"), true)
		Expect.equal(TradeEscrow.isEscrowed(data, "t2"), false)
	end,

	["open copies the offers"] = function()
		local data = newData(0, { sword = 3 })
		local give = offer(0, { sword = 1 })
		TradeEscrow.open(data, "t1", give, offer(0, {}))
		give.items.sword = 3
		Expect.equal(data.pendingTrade.give.items.sword, 1)
	end,

	["open refuses a second pending trade or an unaffordable offer"] = function()
		local data = newData(100, { sword = 3 })
		Expect.equal(TradeEscrow.open(data, "t1", offer(0, { sword = 4 }), offer(0, {})), false, "unaffordable")
		Expect.deepEqual(data, newData(100, { sword = 3 }), "unchanged")

		TradeEscrow.open(data, "t1", offer(10, {}), offer(0, {}))
		Expect.equal(TradeEscrow.open(data, "t2", offer(10, {}), offer(0, {})), false, "already pending")
		Expect.equal(data.coins, 90)
	end,

	["committed delivers, aborted refunds, both conserve goods"] = function()
		for _, outcome in { "committed", "aborted" } do
			local a = newData(100, { sword = 2 })
			local b = newData(0, { gem = 1 })
			local before = totals(a, b)

			TradeEscrow.open(a, "t1", offer(50, { sword = 2 }), offer(0, { gem = 1 }))
			TradeEscrow.open(b, "t1", offer(0, { gem = 1 }), offer(50, { sword = 2 }))
			Expect.deepEqual(totals(a, b), before, `{outcome}: while escrowed`)

			TradeEscrow.settle(a, "t1", outcome :: any)
			TradeEscrow.settle(b, "t1", outcome :: any)
			Expect.deepEqual(totals(a, b), before, `{outcome}: after settling`)
			Expect.equal(a.pendingTrade, nil)

			if outcome == "committed" then
				Expect.deepEqual(a, newData(50, { gem = 1 }))
				Expect.deepEqual(b, newData(50, { sword = 2 }))
			else
				Expect.deepEqual(a, newData(100, { sword = 2 }))
				Expect.deepEqual(b, newData(0, { gem = 1 }))
			end
		end
	end,

	["settle is idempotent and ignores other trades"] = function()
		local data = newData(0, {})
		TradeEscrow.open(data, "t1", offer(0, {}), offer(10, {}))

		Expect.equal(TradeEscrow.settle(data, "t2", "committed"), false, "other trade")
		Expect.equal(TradeEscrow.settle(data, "t1", "committed"), true)
		Expect.equal(TradeEscrow.settle(data, "t1", "committed"), false, "second time")
		Expect.equal(data.coins, 10)
	end,

	["protocol views round-trip, including empty offers"] = function()
		local view = {
			version = 7,
			phase = "countdown",
			mine = offer(0, {}),
			theirs = offer(25, { sword = 2, ["health potion"] = 1 }),
			myReady = true,
			theirReady = false,
		}
		Expect.deepEqual(TradeProtocol.decode(TradeProtocol.encode(view :: any)), view)
	end,
}
