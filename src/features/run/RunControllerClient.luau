--!strict

--[=[
	Run director, client side: a replica of the run's view for the HUD, what the
	last death cost, and the request to leave the results screen.
]=]

local Charm = require("@Packages/charm")
local Network = require("@Core/Network")
local RunProtocol = require("@Features/run/modules/RunProtocol")

local RunController = {}

export type Penalty = { coins: number, xp: number }

-- How long the death notice stays up.
local PENALTY_SECONDS = 7

local view = Charm.atom(RunProtocol.TEMPLATE)
-- What the last death cost: nil when there is nothing to show.
local penalty = Charm.atom(nil :: Penalty?)
local penaltyToken = 0

local network: Network.ClientNetwork? = nil

RunController.state = {
	view = view,
	phase = Charm.computed(function()
		return view().phase
	end),
	charge = Charm.computed(function()
		return view().charge
	end),
	-- The run was won and the results are on screen.
	showResults = Charm.computed(function()
		return view().phase == "Victory"
	end),
	-- In the lobby, between runs.
	inLobby = Charm.computed(function()
		return view().phase == "Waiting"
	end),
	penalty = penalty,
}

-- Network (server -> client)
function RunController.onRunState(data: buffer)
	view(RunProtocol.decode(data))
end

-- A death cost this much. Nothing is shown when it cost nothing.
function RunController.onDeathPenalty(coins: number, xp: number)
	penaltyToken += 1
	local token = penaltyToken
	if coins <= 0 and xp <= 0 then
		penalty(nil)
		return
	end

	penalty({ coins = coins, xp = xp })
	task.delay(PENALTY_SECONDS, function()
		if penaltyToken == token then
			penalty(nil)
		end
	end)
end

-- Leaves the results: only does anything once the run was won.
function RunController.returnToLobby()
	if network then
		network:fire("requestLobby")
	end
end

function RunController.start()
	-- Yields until the server has registered the service.
	local connected = Network.client("Run", RunController)
	network = connected
	connected:fire("requestRun")
end

return RunController
