--!strict

--[=[
	Enemies, server side: tells the clients what the enemies in the simulation
	are doing (see EnemySim). Enemies are plain data there, not Instances: no
	Humanoids, no physics, no parts. The clients get a compact snapshot of
	where everyone is every tick and draw pooled models.

	Every attack has a telegraph (the enemy stands still for a short wind-up
	and the client shows it); the snapshot's flags carry it.
]=]

local ActSpace = require("@Features/world/modules/ActSpace")
local CombatSim = require("@Features/combat/modules/CombatSim")
local EnemyDefs = require("@Features/enemies/modules/EnemyDefs")
local EnemySim = require("@Features/enemies/modules/EnemySim")
local EnemySnapshot = require("@Features/enemies/modules/EnemySnapshot")
local Network = require("@Core/Network")
local RateLimit = require("@Core/RateLimit")
local Sim = require("@Features/sim/modules/Sim")
local SimContext = require("@Features/sim/modules/SimContext")
local SimService = require("@Features/sim/SimServiceServer")

local Packet = Network.Packet

local EnemyService = {}

local network: Network.ServerNetwork

local requestLimit = RateLimit.new({ burst = 2, perSecond = 0.5 })

local function groundPoint(x: number, z: number): Vector3
	return Vector3.new(x, ActSpace.GROUND_Y, z)
end

local function sendSnapshot(state: Sim.State)
	local entries = EnemySim.snapshot(state.enemies, state.ctx)
	if #entries > 0 then
		network:fireAllClientsUnreliable("onSnapshot", EnemySnapshot.encode(entries))
	end
end

function EnemyService.init()
	network = Network.server("Enemy", EnemyService, {
		requestEnemies = {}, -- client -> server
		onSpawn = { Packet.NumberU16, Packet.NumberU8 }, -- id, def index
		onDespawn = { Packet.NumberU16 },
		onSnapshot = { Packet.BufferLong },
		-- start, velocity, seconds it lives
		onProjectile = { Packet.Vector3F32, Packet.Vector3F32, Packet.NumberF32 },
		onBossHealth = { Packet.NumberU16, Packet.NumberU16 }, -- hp, max hp
	})

	SimService.observe("spawn", function(event: SimContext.Event)
		network:fireAllClients("onSpawn", event.id, event.def)
	end)

	SimService.observe("despawn", function(event: SimContext.Event)
		network:fireAllClients("onDespawn", event.id)
	end)

	SimService.observe("projectile", function(event: SimContext.Event)
		network:fireAllClients(
			"onProjectile",
			groundPoint(event.x, event.z),
			Vector3.new(event.vx, 0, event.vz),
			event.life
		)
	end)

	SimService.observe("bossHealth", function(event: SimContext.Event)
		network:fireAllClients("onBossHealth", event.hp, event.maxHp)
	end)

	SimService.afterStep(sendSnapshot)
end

-- Network (client -> server): a client that joined late asks who is alive.
function EnemyService.requestEnemies(player: Player)
	if not RateLimit.take(requestLimit, player) then
		return
	end

	local state = SimService.state()
	for _, enemy in state.enemies.enemies do
		network:fireClient(player, "onSpawn", enemy.body.id, EnemyDefs.indexOf(enemy.def.id) :: number)
	end

	local bossId = state.enemies.bossId
	local boss = if bossId then CombatSim.get(state.combat, bossId) else nil
	if boss then
		network:fireClient(
			player,
			"onBossHealth",
			math.clamp(math.floor(boss.hp), 0, 65535),
			math.clamp(math.floor(boss.maxHp), 0, 65535)
		)
	end
end

return EnemyService
