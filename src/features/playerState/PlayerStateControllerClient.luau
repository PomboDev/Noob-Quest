--!strict

--[=[
	Client mirror of the local player's activity state (see
	PlayerStateServiceServer). Read-only: UI uses it to show what's available
	(no trade button while the auction house is open, say), and the server
	decides every change.
]=]

local Charm = require("@Packages/charm")
local Network = require("@Core/Network")
local PlayerStateMachine = require("@Features/playerState/modules/PlayerStateMachine")

type State = PlayerStateMachine.State

local current = Charm.atom("Loading" :: State)

local PlayerStateController = {}

PlayerStateController.state = {
	current = current,
	idle = Charm.computed(function()
		return current() == "Idle"
	end),
	inAuction = Charm.computed(function()
		local state = current()
		return state == "Browsing" or state == "Transacting"
	end),
}

-- Network: the server changed our state.
function PlayerStateController.onStateChanged(state: string)
	current(state :: State)
end

function PlayerStateController.start()
	local network = Network.client("PlayerState", PlayerStateController)
	network:fire("requestState")
end

return PlayerStateController
