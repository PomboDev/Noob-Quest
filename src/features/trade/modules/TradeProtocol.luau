--!strict

--[=[
	What the server tells each client about its open trade, shared by both
	sides. The view is sent whole (a DeltaCompress full sync) whenever it
	changes: it's a few dozen bytes, so diffing isn't worth the bookkeeping.
]=]

local DeltaCompress = require("@Core/DeltaCompress")
local TradeEscrow = require("@Features/trade/modules/TradeEscrow")

type Offer = TradeEscrow.Offer

-- negotiating: offers can change. countdown: both sides are ready and the
-- trade goes through when it ends, unless something changes. settling: the
-- goods are in escrow and the outcome is being decided.
export type Phase = "negotiating" | "countdown" | "settling"

export type View = {
	-- Bumped whenever an offer changes. setReady must echo it.
	version: number,
	phase: Phase,
	mine: Offer,
	theirs: Offer,
	myReady: boolean,
	theirReady: boolean,
}

local TEMPLATE: View = {
	version = 0,
	phase = "negotiating",
	mine = TradeEscrow.emptyOffer(),
	theirs = TradeEscrow.emptyOffer(),
	myReady = false,
	theirReady = false,
}

local CONTEXT = DeltaCompress.createContext(TEMPLATE)
DeltaCompress.registerStrings(CONTEXT, { "countdown", "settling" })

local TradeProtocol = {
	-- Seconds between both sides being ready and the trade going through.
	COUNTDOWN = 3,
	-- Seconds a trade request stays open.
	REQUEST_TIMEOUT = 30,
}

function TradeProtocol.encode(view: View): buffer
	local delta = DeltaCompress.createDelta({} :: any, view, CONTEXT)
	return assert(delta, "a view is never empty")
end

function TradeProtocol.decode(data: buffer): View
	return DeltaCompress.applyDelta({} :: any, data, CONTEXT)
end

return TradeProtocol
