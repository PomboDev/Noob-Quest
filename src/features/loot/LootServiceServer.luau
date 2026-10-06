--!strict

--[=[
	Loot, server side: tells each player about the coins and XP on the ground
	for them (see LootSim).

	Drops are plain data in the simulation. Each one belongs to one hero slot:
	a kill drops a copy for every hero, so in co-op nobody steals a drop and
	nobody waits for one. The owner picks a drop up by walking close to it, and
	the client only draws it (see LootControllerClient).

	This feature knows nothing about player data. A pickup is an event the run
	feature watches, and it saves what was collected.
]=]

local ActSpace = require("@Features/world/modules/ActSpace")
local HeroService = require("@Features/heroes/HeroServiceServer")
local LootTables = require("@Features/loot/modules/LootTables")
local Network = require("@Core/Network")
local RateLimit = require("@Core/RateLimit")
local SimContext = require("@Features/sim/modules/SimContext")
local SimService = require("@Features/sim/SimServiceServer")

local Packet = Network.Packet

local LootService = {}

local network: Network.ServerNetwork

local requestLimit = RateLimit.new({ burst = 2, perSecond = 0.5 })

local function groundPoint(x: number, z: number): Vector3
	return Vector3.new(x, ActSpace.GROUND_Y, z)
end

function LootService.init()
	network = Network.server("Loot", LootService, {
		requestDrops = {}, -- client -> server
		-- id, kind index, amount, position
		onDrop = { Packet.NumberU16, Packet.NumberU8, Packet.NumberU16, Packet.Vector3F32 },
		-- id, whether the player collected it (false: it expired or was cleared)
		onPickup = { Packet.NumberU16, Packet.Boolean },
		onClear = {},
	})

	SimService.observe("drop", function(event: SimContext.Event)
		local player = HeroService.playerOfSlot(event.slot)
		if player then
			network:fireClient(player, "onDrop", event.id, event.item, event.amount, groundPoint(event.x, event.z))
		end
	end)

	SimService.observe("pickup", function(event: SimContext.Event)
		local player = HeroService.playerOfSlot(event.slot)
		if player then
			network:fireClient(player, "onPickup", event.id, event.collected)
		end
	end)

	SimService.observe("lootClear", function()
		network:fireAllClients("onClear")
	end)
end

-- Network (client -> server): a client that joined late asks for what is on the ground.
function LootService.requestDrops(player: Player)
	if not RateLimit.take(requestLimit, player) then
		return
	end

	local slot = HeroService.slotOf(player)
	if slot == nil then
		return
	end

	for _, drop in SimService.state().loot.drops do
		if drop.slot == slot then
			network:fireClient(
				player,
				"onDrop",
				drop.id,
				table.find(LootTables.KINDS, drop.kind) :: number,
				math.clamp(drop.amount, 0, 65535),
				groundPoint(drop.x, drop.z)
			)
		end
	end
end

return LootService
