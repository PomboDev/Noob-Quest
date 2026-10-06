--!strict

--[=[
	Client side of trading: Charm atoms for UI to bind to, and the actions a
	trade UI calls. The server decides everything; these only ask.

		TradeController.request(otherPlayer)
		TradeController.offerItem("sword", 2)
		TradeController.markReady(true)

	Goods held in escrow while a trade settles show up in the player's
	replicated data as `pendingTrade` (see PlayerController).
]=]

local Players = game:GetService("Players")

local Charm = require("@Packages/charm")
local Log = require("@Core/Log")
local Network = require("@Core/Network")
local TradeProtocol = require("@Features/trade/modules/TradeProtocol")

export type Trade = {
	partner: Player,
	view: TradeProtocol.View,
}

local trade = Charm.atom(nil :: Trade?)
-- requester -> os.clock() when the request expires
local requests = Charm.atom({} :: { [Player]: number })
-- Why the last trade ended ("completed", "declined", "left", ...)
local lastResult = Charm.atom(nil :: string?)

local network: Network.ClientNetwork? = nil

local TradeController = {}

TradeController.state = {
	trade = trade,
	requests = requests,
	lastResult = lastResult,
}

local function fire(method: string, ...: any)
	if network then
		network:fire(method, ...)
	end
end

local function removeRequest(requester: Player)
	local current = requests()
	if current[requester] then
		local nextRequests = table.clone(current)
		nextRequests[requester] = nil
		requests(nextRequests)
	end
end

-- // Network (server -> client) //

function TradeController.onTradeRequested(requester: Instance?)
	if typeof(requester) ~= "Instance" or not requester:IsA("Player") then
		return
	end
	local player = requester :: Player

	local nextRequests = table.clone(requests())
	nextRequests[player] = os.clock() + TradeProtocol.REQUEST_TIMEOUT
	requests(nextRequests)

	task.delay(TradeProtocol.REQUEST_TIMEOUT, function()
		if (requests()[player] or math.huge) <= os.clock() then
			removeRequest(player)
		end
	end)
end

function TradeController.onTradeState(partner: Instance?, state: buffer)
	if typeof(partner) ~= "Instance" or not partner:IsA("Player") then
		return
	end
	trade({ partner = partner :: Player, view = TradeProtocol.decode(state) })
end

function TradeController.onTradeEnded(reason: string)
	trade(nil)
	lastResult(reason)
	Log.debug(`Trade ended: {reason}`)
end

-- // Actions //

function TradeController.request(target: Player)
	fire("requestTrade", target)
end

function TradeController.respond(requester: Player, accept: boolean)
	removeRequest(requester)
	fire("respondTrade", requester, accept)
end

-- Offers `amount` of `itemId` (0 takes it back out).
function TradeController.offerItem(itemId: string, amount: number)
	fire("setItem", itemId, amount)
end

function TradeController.offerCoins(coins: number)
	fire("setCoins", coins)
end

-- Ready means "I accept the offers as I see them now".
function TradeController.markReady(ready: boolean)
	local current = trade()
	if current then
		fire("setReady", ready, current.view.version)
	end
end

function TradeController.cancel()
	fire("cancelTrade")
end

function TradeController.start()
	Players.PlayerRemoving:Connect(removeRequest)
	network = Network.client("Trade", TradeController)
end

return TradeController
