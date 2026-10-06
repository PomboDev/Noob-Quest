local Expect = require("./Expect")
local PlayerStateMachine = require("../src/features/playerState/modules/PlayerStateMachine")

local function loaded(): any
	local slot = PlayerStateMachine.new()
	PlayerStateMachine.markLoaded(slot)
	return slot
end

return {
	["slots start loading and refuse every activity"] = function()
		local slot = PlayerStateMachine.new()
		Expect.equal(PlayerStateMachine.getState(slot), "Loading")
		Expect.equal(PlayerStateMachine.acquire(slot, "Trading"), nil, "trade")
		Expect.equal(PlayerStateMachine.acquire(slot, "Auction"), nil, "auction")

		Expect.equal(PlayerStateMachine.markLoaded(slot), true)
		Expect.equal(PlayerStateMachine.markLoaded(slot), false, "second time")
		Expect.equal(PlayerStateMachine.getState(slot), "Idle")
	end,

	["trading and the auction house exclude each other"] = function()
		local slot = loaded()
		local trade = PlayerStateMachine.acquire(slot, "Trading")
		Expect.equal(PlayerStateMachine.getState(slot), "Trading")
		Expect.equal(PlayerStateMachine.acquire(slot, "Auction"), nil, "auction while trading")
		Expect.equal(PlayerStateMachine.acquire(slot, "Trading"), nil, "second trade")
		PlayerStateMachine.release(slot, trade)

		local auction = PlayerStateMachine.acquire(slot, "Auction")
		Expect.equal(PlayerStateMachine.getState(slot), "Browsing")
		Expect.equal(PlayerStateMachine.acquire(slot, "Trading"), nil, "trade while browsing")
		PlayerStateMachine.beginTransaction(slot, auction)
		Expect.equal(PlayerStateMachine.acquire(slot, "Trading"), nil, "trade while transacting")
	end,

	["a stale or repeated release changes nothing"] = function()
		local slot = loaded()
		local first = PlayerStateMachine.acquire(slot, "Trading")
		Expect.equal(PlayerStateMachine.release(slot, first), true)
		Expect.equal(PlayerStateMachine.release(slot, first), false, "second release")

		local second = PlayerStateMachine.acquire(slot, "Auction")
		Expect.equal(second > first, true, "new lease id")
		Expect.equal(PlayerStateMachine.release(slot, first), false, "stale lease")
		Expect.equal(PlayerStateMachine.holds(slot, first), false, "stale holds")
		Expect.equal(PlayerStateMachine.holds(slot, second), true, "current holds")
		Expect.equal(PlayerStateMachine.getState(slot), "Browsing")
	end,

	["one transaction at a time, only while browsing"] = function()
		local slot = loaded()
		local trade = PlayerStateMachine.acquire(slot, "Trading")
		Expect.equal(PlayerStateMachine.beginTransaction(slot, trade), false, "while trading")
		PlayerStateMachine.release(slot, trade)

		local lease = PlayerStateMachine.acquire(slot, "Auction")
		Expect.equal(PlayerStateMachine.beginTransaction(slot, lease), true)
		Expect.equal(PlayerStateMachine.getState(slot), "Transacting")
		Expect.equal(PlayerStateMachine.beginTransaction(slot, lease), false, "second transaction")

		Expect.equal(PlayerStateMachine.endTransaction(slot, lease), true)
		Expect.equal(PlayerStateMachine.getState(slot), "Browsing")
		Expect.equal(PlayerStateMachine.endTransaction(slot, lease), false, "no transaction running")
	end,

	["closing during a transaction waits for it to end"] = function()
		local slot = loaded()
		local lease = PlayerStateMachine.acquire(slot, "Auction")
		PlayerStateMachine.beginTransaction(slot, lease)

		Expect.equal(PlayerStateMachine.release(slot, lease), true)
		Expect.equal(PlayerStateMachine.getState(slot), "Transacting", "still transacting")
		Expect.equal(PlayerStateMachine.acquire(slot, "Trading"), nil, "no trade yet")

		PlayerStateMachine.endTransaction(slot, lease)
		Expect.equal(PlayerStateMachine.getState(slot), "Idle")
		Expect.equal(PlayerStateMachine.holds(slot, lease), false)

		-- The close request doesn't carry over to the next visit.
		local again = PlayerStateMachine.acquire(slot, "Auction")
		PlayerStateMachine.beginTransaction(slot, again)
		PlayerStateMachine.endTransaction(slot, again)
		Expect.equal(PlayerStateMachine.getState(slot), "Browsing")
	end,

	["a stale lease can't drive a newer hold"] = function()
		local slot = loaded()
		local old = PlayerStateMachine.acquire(slot, "Auction")
		PlayerStateMachine.release(slot, old)

		local current = PlayerStateMachine.acquire(slot, "Auction")
		Expect.equal(PlayerStateMachine.beginTransaction(slot, old), false, "begin")
		PlayerStateMachine.beginTransaction(slot, current)
		Expect.equal(PlayerStateMachine.endTransaction(slot, old), false, "end")
		Expect.equal(PlayerStateMachine.release(slot, old), false, "release")
		Expect.equal(PlayerStateMachine.getState(slot), "Transacting")
	end,
}
