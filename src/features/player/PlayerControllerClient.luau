--!strict

--[=[
	Client replica of the local player's data.

	Requests a full sync on start, then applies the binary deltas the server
	pushes whenever the data changes. Exposed as Charm atoms so UI can react
	without polling.
]=]

local Charm = require("@Packages/charm")
local DeltaCompress = require("@Core/DeltaCompress")
local Log = require("@Core/Log")
local Network = require("@Core/Network")
local PlayerData = require("@Features/player/modules/PlayerData")

type Data = PlayerData.Data

local data = Charm.atom(PlayerData.TEMPLATE)
local loaded = Charm.atom(false)

local PlayerController = {}

PlayerController.state = {
	data = data,
	-- false until the first sync arrives; data() holds the template until then
	loaded = loaded,
	coins = Charm.computed(function()
		return data().coins
	end),
	level = Charm.computed(function()
		return data().level
	end),
}

-- Network: the first delta after requestData is a full sync, so it applies
-- to an empty table; later ones apply to the current replica.
function PlayerController.onDataDelta(delta: buffer)
	local isLoaded = loaded()
	local base: any = if isLoaded then data() else {}
	data(DeltaCompress.applyDelta(base, delta, PlayerData.CONTEXT))

	if not isLoaded then
		loaded(true)
		Log.debug("Player data loaded")
	end
end

function PlayerController.start()
	local network = Network.client("Player", PlayerController)
	network:fire("requestData")
end

return PlayerController
