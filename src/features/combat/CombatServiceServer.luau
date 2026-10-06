--!strict

--[=[
	Combat, server side: tells the clients what combat did in the simulation
	(see CombatSim): damage numbers, hero health and deaths.

	All damage is dealt inside the sim, by whoever acts (a hero's swing, an
	enemy's attack). This only turns its events into messages. Hero HP lives in
	the sim, not on the Humanoid, which is never damaged: a hero at 0 HP is
	downed, and the run decides what that means.
]=]

local ActSpace = require("@Features/world/modules/ActSpace")
local Network = require("@Core/Network")
local RateLimit = require("@Core/RateLimit")
local SimContext = require("@Features/sim/modules/SimContext")
local SimService = require("@Features/sim/SimServiceServer")

local Packet = Network.Packet

local CombatService = {}

-- Packets carry HP as NumberU16.
local MAX_VALUE = 65535

local network: Network.ServerNetwork

local requestLimit = RateLimit.new({ burst = 2, perSecond = 0.5 })

local function clampValue(value: number): number
	return math.clamp(math.floor(value + 0.5), 0, MAX_VALUE)
end

local function groundPoint(x: number, z: number): Vector3
	return Vector3.new(x, ActSpace.GROUND_Y, z)
end

function CombatService.init()
	-- All server -> client.
	network = Network.server("Combat", CombatService, {
		requestHealth = {}, -- client -> server
		-- entity id, position, damage dealt, crit
		onDamage = { Packet.NumberU16, Packet.Vector3S16, Packet.NumberU16, Packet.Boolean },
		-- hero entity id, hp, max hp
		onHeroHealth = { Packet.NumberU16, Packet.NumberU16, Packet.NumberU16 },
		-- entity id, position, whether it was a hero
		onEntityDied = { Packet.NumberU16, Packet.Vector3S16, Packet.Boolean },
	})

	SimService.observe("damage", function(event: SimContext.Event)
		network:fireAllClientsUnreliable("onDamage", event.id, groundPoint(event.x, event.z), event.damage, event.crit)
	end)

	SimService.observe("heroHealth", function(event: SimContext.Event)
		network:fireAllClients("onHeroHealth", event.id, event.hp, event.maxHp)
	end)

	SimService.observe("died", function(event: SimContext.Event)
		network:fireAllClients("onEntityDied", event.id, groundPoint(event.x, event.z), event.hero)
	end)
end

-- Network (client -> server): a client that joined late asks for every hero's health.
function CombatService.requestHealth(player: Player)
	if not RateLimit.take(requestLimit, player) then
		return
	end

	for _, entity in SimService.state().combat.entities do
		if entity.team == "hero" then
			network:fireClient(player, "onHeroHealth", entity.id, clampValue(entity.hp), clampValue(entity.maxHp))
		end
	end
end

return CombatService
