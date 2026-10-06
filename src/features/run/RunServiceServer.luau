--!strict

--[=[
	Run director, server side: owns the phases of a run and ties the other
	features together.

		Waiting ─▶ Generating ─▶ Exploring ─▶ Charging ─▶ Boss ─▶ ExitOpen ─▶ Victory
		                                  any phase of an act ─▶ Defeat

	Exploring: waves trickle in, chests and statues are there to find, and the
	teleporter is far away. Using the teleporter starts Charging: it charges
	while a hero stands near it, and the waves come much faster. At 100% the
	boss appears. Killing it opens the exit portal, and the portal ends the run.

	Rewards are paid once, when the run ends (win or lose): nothing a player
	picked up is lost. The act number, timer and difficulty are shared with
	every client as a small view (RunProtocol).

	This feature wires others together: world (the map and its objects), enemies
	(spawns, kills), heroes (downed), combat (healing, damage) and player (rewards).
]=]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local CombatService = require("@Features/combat/CombatServiceServer")
local Difficulty = require("@Features/run/modules/Difficulty")
local EnemyDefs = require("@Features/enemies/modules/EnemyDefs")
local EnemyService = require("@Features/enemies/EnemyServiceServer")
local HeroService = require("@Features/heroes/HeroServiceServer")
local Log = require("@Core/Log")
local Network = require("@Core/Network")
local PlayerService = require("@Features/player/PlayerServiceServer")
local RateLimit = require("@Core/RateLimit")
local RunProtocol = require("@Features/run/modules/RunProtocol")
local RunRewards = require("@Features/run/modules/RunRewards")
local RunStateMachine = require("@Features/run/modules/RunStateMachine")
local WaveDirector = require("@Features/run/modules/WaveDirector")
local WorldService = require("@Features/world/WorldServiceServer")

local Packet = Network.Packet

local RunFeature = {}

-- Acts in a run. One for the vertical slice.
local TOTAL_ACTS = 1
local BOSS_ID = "golem"
-- Seconds a hero has to stand near the teleporter to fill it.
local CHARGE_SECONDS = 30
local CHARGE_RADIUS = 16
-- Seconds between the first hero appearing and the run starting.
local START_DELAY = 3
-- Waves appear this far from a hero.
local SPAWN_MIN = 35
local SPAWN_MAX = 60
local TICK = 0.1
local BROADCAST_INTERVAL = 0.25
-- Between acts, heroes get this share of their health back.
local ACT_HEAL = 0.3
local CHEST_COINS = { 15, 30 }
local DEVIL_COINS = 40
local DEVIL_COST = 0.3
local DEVIL_PACK = 5

local network: Network.ServerNetwork

local run = RunStateMachine.create(TOTAL_ACTS)
local director = WaveDirector.new()
local rng = Random.new()

local elapsed = 0
local charge = 0
-- Reward points from kills, and coins picked up from chests and deals.
local points = 0
local pickedUpCoins = 0
local result: RunRewards.Result = { coins = 0, xp = 0 }
local paid = false
local waitingSince: number? = nil

local lastView: RunProtocol.View? = nil
local lastBroadcast = 0

local restartLimit = RateLimit.new({ burst = 1, perSecond = 0.5 })
local requestLimit = RateLimit.new({ burst = 2, perSecond = 0.5 })

local function phase(): RunStateMachine.Phase
	return RunStateMachine.getPhase(run)
end

local function heroIds(): { number }
	local ids = {}
	for _, player in Players:GetPlayers() do
		local id = HeroService.getEntityId(player)
		if id then
			table.insert(ids, id)
		end
	end
	return ids
end

local function aliveHeroes(): number
	local count = 0
	for _, id in heroIds() do
		if CombatService.isAlive(id) then
			count += 1
		end
	end
	return count
end

local function buildView(): RunProtocol.View
	return {
		phase = phase(),
		act = RunStateMachine.actIndex(run),
		totalActs = RunStateMachine.totalActs(run),
		elapsed = math.floor(elapsed),
		coefficient = math.floor(
			Difficulty.coefficient(elapsed / 60, RunStateMachine.actIndex(run), #Players:GetPlayers()) * 100 + 0.5
		) / 100,
		charge = math.floor(charge * 100 + 0.5) / 100,
		coins = result.coins,
		xp = result.xp,
		alive = aliveHeroes(),
	}
end

local function sameView(a: RunProtocol.View, b: RunProtocol.View): boolean
	for key, value in a :: any do
		if (b :: any)[key] ~= value then
			return false
		end
	end
	return true
end

-- Sends the view if it changed, at most a few times a second (always when `force`).
local function broadcast(force: boolean)
	local now = os.clock()
	if not force and now - lastBroadcast < BROADCAST_INTERVAL then
		return
	end

	local view = buildView()
	if not force and lastView and sameView(view, lastView) then
		return
	end

	lastView = view
	lastBroadcast = now
	network:fireAllClients("onRunState", RunProtocol.encode(view))
end

local function minutes(): number
	return elapsed / 60
end

local function coefficient(): number
	return Difficulty.coefficient(minutes(), RunStateMachine.actIndex(run), math.max(1, #Players:GetPlayers()))
end

-- Pays the run's rewards once, whether it was won or lost.
local function finish(victory: boolean)
	if paid then
		return
	end
	paid = true

	result = RunRewards.compute(points, pickedUpCoins, victory)
	for _, player in Players:GetPlayers() do
		PlayerService.updateData(player, function(data)
			data.coins += result.coins
			data.level, data.xp = RunRewards.addXp(data.level, data.xp, result.xp)
		end)
	end

	EnemyService.despawnAll()
	WorldService.closePortal()
	Log.info(`Run over: {if victory then "victory" else "defeat"}, {result.coins} coins and {result.xp} xp each`)
	broadcast(true)
end

local function spawnNear(defId: string, x: number, z: number)
	EnemyService.spawn(defId, x, z)
end

-- Builds the current act: the map, the enemy world and the heroes.
local function beginAct()
	local actIndex = RunStateMachine.actIndex(run)
	local generated = false
	for attempt = 1, 3 do
		local seed = rng:NextInteger(1, 2 ^ 31)
		local ok, err = pcall(WorldService.generate, actIndex, seed)
		if ok then
			generated = true
			break
		end
		Log.warn(`Act {actIndex} failed to generate (attempt {attempt}): {err}`)
	end
	if not generated then
		-- Leave the run waiting: a new attempt starts on the next tick.
		RunStateMachine.downed(run)
		return
	end

	EnemyService.despawnAll()
	EnemyService.setNavGrid(WorldService.getNavGrid(), WorldService.getGroundY())
	director = WaveDirector.new()
	charge = 0

	for _, id in heroIds() do
		local entity = CombatService.get(id)
		if entity then
			if actIndex == 1 or entity.dead then
				CombatService.revive(id)
			else
				CombatService.heal(id, entity.maxHp * ACT_HEAL)
			end
		end
	end

	RunStateMachine.generated(run)
	Log.debug(`Act {actIndex} ready`)
	broadcast(true)
end

local function startRun()
	elapsed = 0
	points = 0
	pickedUpCoins = 0
	result = { coins = 0, xp = 0 }
	paid = false
	if RunStateMachine.start(run) then
		beginAct()
	end
end

local function onInteract(kind: string, id: string, player: Player)
	local current = phase()
	local heroId = HeroService.getEntityId(player)

	if kind == "teleporter" then
		if current == "Exploring" and RunStateMachine.charge(run) then
			WorldService.setInteractable(id, false)
			Log.debug("Teleporter charging")
			broadcast(true)
		end
	elseif kind == "chest" then
		pickedUpCoins += rng:NextInteger(CHEST_COINS[1], CHEST_COINS[2])
	elseif kind == "angelStatue" then
		-- A blessing: every hero is healed.
		for _, entityId in heroIds() do
			local entity = CombatService.get(entityId)
			if entity and not entity.dead then
				CombatService.heal(entityId, entity.maxHp)
			end
		end
	elseif kind == "devilStatue" then
		-- A deal: some health (never the last of it) for coins, and the statue's guards wake up.
		local entity = if heroId then CombatService.get(heroId) else nil
		if entity and not entity.dead then
			local cost = math.min(math.floor(entity.maxHp * DEVIL_COST), entity.hp - 1)
			if cost > 0 then
				CombatService.applyDamage(nil, entity.id, cost, "true")
			end
		end
		pickedUpCoins += DEVIL_COINS

		local statue = WorldService.positionsOf("devilStatue")[1]
		if statue then
			for index = 1, DEVIL_PACK do
				local angle = index / DEVIL_PACK * math.pi * 2
				spawnNear("grunt", statue.X + math.sin(angle) * 9, statue.Z + math.cos(angle) * 9)
			end
		end
	elseif kind == "portal" then
		if current == "ExitOpen" and RunStateMachine.advance(run) then
			if phase() == "Victory" then
				finish(true)
			else
				beginAct()
			end
		end
	end
end

local function onKilled(_enemyId: number, defId: string)
	local def = EnemyDefs.get(defId)
	if def then
		points += def.reward
	end

	if defId == BOSS_ID and phase() == "Boss" and RunStateMachine.bossDefeated(run) then
		-- The rest of the wave goes with the boss, and the way out opens.
		EnemyService.despawnAll()
		WorldService.openPortal()
		Log.debug("Boss defeated, exit open")
		broadcast(true)
	end
end

local function onHeroDowned()
	if aliveHeroes() == 0 and RunStateMachine.downed(run) then
		finish(false)
	end
end

local function spawnBoss()
	local teleporter = WorldService.positionOf("teleporter")
	local grid = WorldService.getNavGrid()
	if teleporter == nil then
		return
	end

	local x: number, z: number = teleporter.X, teleporter.Z
	if grid then
		local pickedX, pickedZ = WaveDirector.pickSpawnPoint(grid, teleporter.X, teleporter.Z, 12, 18, function()
			return rng:NextNumber()
		end)
		if pickedX and pickedZ then
			x, z = pickedX, pickedZ
		end
	end
	spawnNear(BOSS_ID, x, z)
end

local function updateCharge(dt: number)
	local teleporter = WorldService.positionOf("teleporter")
	if teleporter == nil then
		return
	end

	for _, player in Players:GetPlayers() do
		local id = HeroService.getEntityId(player)
		local entity = if id then CombatService.get(id) else nil
		if entity and not entity.dead then
			local position = entity.position()
			local dx, dz = position.X - teleporter.X, position.Z - teleporter.Z
			if dx * dx + dz * dz <= CHARGE_RADIUS * CHARGE_RADIUS then
				charge = math.min(1, charge + dt / CHARGE_SECONDS)
				break
			end
		end
	end

	if charge >= 1 and RunStateMachine.charged(run) then
		Log.debug("Teleporter charged, boss incoming")
		spawnBoss()
		broadcast(true)
	end
end

local function updateWaves(dt: number)
	local grid = WorldService.getNavGrid()
	if grid == nil then
		return
	end

	local scale = coefficient()
	EnemyService.setScaling(Difficulty.hpScale(scale), Difficulty.damageScale(scale))

	local spawns = WaveDirector.update(director, dt, phase(), scale, EnemyService.aliveCount(), minutes(), function()
		return rng:NextNumber()
	end)
	if #spawns == 0 then
		return
	end

	-- Every wave appears around a hero who is still standing.
	local standing = {}
	for _, id in heroIds() do
		local entity = CombatService.get(id)
		if entity and not entity.dead then
			table.insert(standing, entity)
		end
	end
	if #standing == 0 then
		return
	end

	for _, defId in spawns do
		local hero = standing[rng:NextInteger(1, #standing)]
		local position = hero.position()
		local x, z = WaveDirector.pickSpawnPoint(grid, position.X, position.Z, SPAWN_MIN, SPAWN_MAX, function()
			return rng:NextNumber()
		end)
		if x and z then
			spawnNear(defId, x, z)
		end
	end
end

local function tick(dt: number)
	local current = phase()

	if current == "Waiting" then
		if #heroIds() > 0 then
			local since = waitingSince or os.clock()
			waitingSince = since
			if os.clock() - since >= START_DELAY then
				waitingSince = nil
				startRun()
			end
		else
			waitingSince = nil
		end
	elseif current == "Exploring" or current == "Charging" or current == "Boss" then
		elapsed += dt
		if current == "Charging" then
			updateCharge(dt)
		end
		updateWaves(dt)
	end

	broadcast(false)
end

function RunFeature.init()
	network = Network.server("Run", RunFeature, {
		requestRun = {}, -- client -> server
		requestRestart = {}, -- client -> server: "Play again"
		onRunState = { Packet.BufferLong },
	})

	WorldService.observeInteract(onInteract)
	EnemyService.observeKilled(onKilled)
	HeroService.observeDowned(onHeroDowned)

	local sinceTick = 0
	RunService.Heartbeat:Connect(function(dt)
		sinceTick += dt
		if sinceTick >= TICK then
			tick(sinceTick)
			sinceTick = 0
		end
	end)
end

-- Network (client -> server)
function RunFeature.requestRun(player: Player)
	if RateLimit.take(requestLimit, player) then
		network:fireClient(player, "onRunState", RunProtocol.encode(buildView()))
	end
end

function RunFeature.requestRestart(player: Player)
	if not RateLimit.take(restartLimit, player) then
		return
	end

	local current = phase()
	if current == "Victory" or current == "Defeat" then
		startRun()
	end
end

return RunFeature
