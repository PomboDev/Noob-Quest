--!strict

--[=[
	Schema-driven networking over one shared set of remotes.

	Server:
		local network = Network.server("MyService", MyService, {
			doThing = { Network.Packet.String }, -- client -> server (handler: MyService.doThing)
			onThingDone = {}, -- server -> client
		})
		network:fireClient(player, "onThingDone")

	Client:
		local network = Network.client("MyService", MyController) -- binds MyController.onThingDone
		network:fire("doThing", "hello")

	Outgoing messages are batched once per frame. Schemas live on the server
	and are sent to clients, so both sides always agree on the wire format.

	- `*Immediate` sends at once, so it can overtake messages still waiting
	  in the frame's batch
	- `*Unreliable` messages may be dropped or reordered, and any over ~900
	  bytes are dropped
	- a message for a service or method the client hasn't bound yet is
	  dropped: have the client ask for initial state once it has connected
	- `invoke` yields until the server handler returns (no timeout). Return
	  values use plain Roblox serialization and handler errors are re-raised
	  on the client
]=]

local RunService = game:GetService("RunService")

local Packet = require("@Core/Network/Packet")
local Types = require("@Core/Network/Types")

export type ServerNetwork = Types.ServerNetwork
export type ClientNetwork = Types.ClientNetwork
export type MethodHandler = Types.MethodHandler
export type MethodSchema = Types.MethodSchema
export type Schemas = Types.Schemas

local Network = {
	Packet = Packet,
}

if RunService:IsServer() then
	local NetworkServer = require("@Core/Network/NetworkServer")

	function Network.server(name: string, service: { [string]: any }, schemas: Schemas): ServerNetwork
		return NetworkServer.new(name, service, schemas)
	end
else
	local NetworkClient = require("@Core/Network/NetworkClient")

	function Network.client(name: string, controller: { [string]: any }?): ClientNetwork
		return NetworkClient.new(name, controller)
	end
end

return Network
