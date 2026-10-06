--!strict

--[=[
	Run director, client side: a replica of the run's view for the HUD, and the
	"Play again" request.
]=]

local Charm = require("@Packages/charm")
local Network = require("@Core/Network")
local RunProtocol = require("@Features/run/modules/RunProtocol")

local RunController = {}

local view = Charm.atom(RunProtocol.TEMPLATE)

local network: Network.ClientNetwork? = nil

RunController.state = {
	view = view,
	phase = Charm.computed(function()
		return view().phase
	end),
	charge = Charm.computed(function()
		return view().charge
	end),
	-- The run is over and the results are on screen.
	finished = Charm.computed(function()
		local phase = view().phase
		return phase == "Victory" or phase == "Defeat"
	end),
}

-- Network (server -> client)
function RunController.onRunState(data: buffer)
	view(RunProtocol.decode(data))
end

-- "Play again": only does anything once the run is over.
function RunController.playAgain()
	if network then
		network:fire("requestRestart")
	end
end

function RunController.start()
	-- Yields until the server has registered the service.
	local connected = Network.client("Run", RunController)
	network = connected
	connected:fire("requestRun")
end

return RunController
