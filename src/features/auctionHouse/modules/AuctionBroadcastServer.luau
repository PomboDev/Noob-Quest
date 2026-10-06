--!strict

--[=[
	Tells every server about listing changes through MessagingService, so a
	seller who is online elsewhere is paid right away and open auction
	screens stay current.

	Best effort: MessagingService can drop or delay messages, so nothing
	depends on them for correctness. Sellers are also reconciled on a timer
	and when they join, and purchases always check the ledger.

	A message is delivered on this server immediately, and this server's own
	copy coming back through MessagingService is ignored.
]=]

local HttpService = game:GetService("HttpService")
local MessagingService = game:GetService("MessagingService")

local AuctionLedger = require("@Features/auctionHouse/modules/AuctionLedgerServer")
local Log = require("@Core/Log")

export type Kind = "listed" | "repriced" | "sold" | "cancelled" | "expired"

-- Well under MessagingService's 1 KB limit: item ids are at most 50 bytes.
export type Message = {
	kind: Kind,
	id: string,
	sellerId: number,
	itemId: string,
	price: number,
	version: number,
}

local TOPIC = "AuctionHouse"
local PUBLISH_ATTEMPTS = 2
local SUBSCRIBE_RETRY = 30

-- Tells this server's own messages apart (JobId is "" in Studio).
local SERVER_ID = HttpService:GenerateGUID(false)

local KINDS: { [string]: true } = {
	listed = true,
	repriced = true,
	sold = true,
	cancelled = true,
	expired = true,
}

local callbacks: { (message: Message) -> () } = {}

local AuctionBroadcast = {}

local function deliver(message: Message)
	for _, callback in callbacks do
		task.spawn(callback, message)
	end
end

local function isMessage(value: any): boolean
	return type(value) == "table"
		and KINDS[value.kind] == true
		and type(value.id) == "string"
		and type(value.sellerId) == "number"
		and type(value.itemId) == "string"
		and type(value.price) == "number"
		and type(value.version) == "number"
end

local function onPacket(packet: any)
	local ok, envelope = pcall(function(): any
		return HttpService:JSONDecode(packet.Data)
	end)
	if not ok or type(envelope) ~= "table" or envelope.server == SERVER_ID then
		return
	end
	if isMessage(envelope.message) then
		deliver(envelope.message :: Message)
	else
		Log.debug(`Ignored a malformed auction broadcast`)
	end
end

-- Calls `callback` (in its own thread) for every message, from this server
-- or any other.
function AuctionBroadcast.observe(callback: (message: Message) -> ())
	table.insert(callbacks, callback)
end

-- Delivers `message` here and publishes it to every other server. Doesn't
-- yield.
function AuctionBroadcast.publish(message: Message)
	deliver(message)

	task.spawn(function()
		if AuctionLedger.isMock() then
			return
		end

		local payload = HttpService:JSONEncode({ server = SERVER_ID, message = message })
		for attempt = 1, PUBLISH_ATTEMPTS do
			local ok, err = pcall(function()
				MessagingService:PublishAsync(TOPIC, payload)
			end)
			if ok then
				return
			end
			Log.warn(`Auction broadcast of {message.kind} {message.id} failed (attempt {attempt}): {err}`)
			task.wait(1)
		end
	end)
end

-- Starts receiving other servers' messages. Yields, retrying until
-- subscribed.
function AuctionBroadcast.start()
	if AuctionLedger.isMock() then
		return
	end

	while true do
		local ok, err = pcall(function()
			MessagingService:SubscribeAsync(TOPIC, onPacket)
		end)
		if ok then
			Log.debug("Subscribed to auction broadcasts")
			return
		end
		Log.warn(`Subscribing to auction broadcasts failed, retrying in {SUBSCRIBE_RETRY}s: {err}`)
		task.wait(SUBSCRIBE_RETRY)
	end
end

return AuctionBroadcast
