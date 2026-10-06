local Expect = require("./Expect")
local PurchaseReceipts = require("../src/features/monetization/modules/PurchaseReceipts")

local function newData(): any
	return { schemaVersion = 1, coins = 10, level = 1, xp = 0, inventory = { sword = 1 }, receipts = {} }
end

local function addCoins(data: any)
	data.coins += 100
end

local function count(receipts: { [string]: number }): number
	local total = 0
	for _ in receipts do
		total += 1
	end
	return total
end

return {
	["grants and records a purchase"] = function()
		local data = newData()
		local status = PurchaseReceipts.grant(data, "p1", 1000, addCoins)

		Expect.equal(status, "granted")
		Expect.equal(data.coins, 110)
		Expect.deepEqual(data.receipts, { p1 = 1000 })
		Expect.equal(PurchaseReceipts.isRecorded(data, "p1"), true)
		Expect.equal(PurchaseReceipts.isRecorded(data, "p2"), false)
	end,

	["grants each purchase id once"] = function()
		local data = newData()
		PurchaseReceipts.grant(data, "p1", 1000, addCoins)
		local status = PurchaseReceipts.grant(data, "p1", 1001, addCoins)

		Expect.equal(status, "duplicate")
		Expect.equal(data.coins, 110)
		Expect.deepEqual(data.receipts, { p1 = 1000 })

		Expect.equal(PurchaseReceipts.grant(data, "p2", 1002, addCoins), "granted", "another purchase")
		Expect.equal(data.coins, 210)
	end,

	["a grant that errors changes nothing"] = function()
		local data = newData()
		local inventory = data.inventory
		local status, reason = PurchaseReceipts.grant(data, "p1", 1000, function(granting)
			granting.coins += 100
			granting.inventory.sword = 5
			granting.title = "Supporter"
			error("out of stock")
		end)

		Expect.equal(status, "failed")
		Expect.equal(string.find(reason or "", "out of stock", 1, true) ~= nil, true, "reason")
		Expect.deepEqual(data, newData())
		Expect.equal(PurchaseReceipts.isRecorded(data, "p1"), false)

		-- The retry grants it in full.
		Expect.equal(PurchaseReceipts.grant(data, "p1", 1001, addCoins), "granted")
		Expect.equal(data.coins, 110)
		Expect.equal(data.inventory, inventory, "tables keep their identity")
	end,

	["a grant that yields is undone"] = function()
		local data = newData()
		local status, reason = PurchaseReceipts.grant(data, "p1", 1000, function(granting)
			granting.coins += 100
			coroutine.yield()
			granting.coins += 100
		end)

		Expect.equal(status, "failed")
		Expect.equal(reason, "the grant yielded")
		Expect.deepEqual(data, newData())
	end,

	["keeps only the newest receipts"] = function()
		local data = newData()
		for i = 1, PurchaseReceipts.MAX_RECEIPTS + 5 do
			PurchaseReceipts.grant(data, `p{i}`, 1000 + i, addCoins)
		end

		Expect.equal(count(data.receipts), PurchaseReceipts.MAX_RECEIPTS)
		for i = 1, 5 do
			Expect.equal(PurchaseReceipts.isRecorded(data, `p{i}`), false, `p{i} dropped`)
		end
		Expect.equal(PurchaseReceipts.isRecorded(data, "p6"), true)
		Expect.equal(PurchaseReceipts.isRecorded(data, `p{PurchaseReceipts.MAX_RECEIPTS + 5}`), true)
	end,

	["never drops the purchase it just recorded"] = function()
		local data = newData()
		for i = 1, PurchaseReceipts.MAX_RECEIPTS do
			PurchaseReceipts.grant(data, `p{i}`, 2000 + i, addCoins)
		end

		-- Granted on a server whose clock is behind the others.
		PurchaseReceipts.grant(data, "late", 1000, addCoins)
		Expect.equal(count(data.receipts), PurchaseReceipts.MAX_RECEIPTS)
		Expect.equal(PurchaseReceipts.isRecorded(data, "late"), true)
		Expect.equal(PurchaseReceipts.isRecorded(data, "p1"), false, "the oldest other one goes")
	end,
}
