--!strict

--[=[
	The run director, as part of the simulation: owns the phases of a run and
	ties the other parts together.

		Waiting (the lobby) ─▶ Generating ─▶ Exploring ─▶ Charging ─▶ Boss ─▶ ExitOpen ─▶ Victory
		                                  any phase of an act ─▶ Defeat
		Victory or Defeat ─▶ Waiting

	A run starts when a hero uses the lobby portal (the adapter picks the
	seeds and sends `startRun`). Exploring: packs of enemies stand around the
	map (placed when it was generated, see WorldSim) and wake up as heroes come
	close. The teleporter is far away. Using it starts Charging: it charges
	while a hero stands near it, and waves of enemies come at the hero. At 100%
	the boss appears. Killing it opens the exit portal, and the portal ends
	the run.

	Pure: time counts in ticks (the defeat and results timers too), randomness
	comes from the run's streams and the loot seeds, and nothing here reaches
	outside the sim. What the world has to do about a change (save coins, show
	results, build objects) is reported as events: `runRequested`, `runChanged`,
	`defeat`, `victory` and `lobby`.
]=]

local Angle = require("@Core/Angle")
local Checksum = require("@Features/sim/modules/Checksum")
local CombatSim = require("@Features/combat/modules/CombatSim")
local Difficulty = require("@Features/run/modules/Difficulty")
local EnemySim = require("@Features/enemies/modules/EnemySim")
local HeroActions = require("@Features/heroes/modules/HeroActions")
local LootSim = require("@Features/loot/modules/LootSim")
local LootTables = require("@Features/loot/modules/LootTables")
local Rng = require("@Core/Rng")
local RunProtocol = require("@Features/run/modules/RunProtocol")
local RunRewards = require("@Features/run/modules/RunRewards")
local RunStateMachine = require("@Features/run/modules/RunStateMachine")
local SimClock = require("@Features/sim/modules/SimClock")
local SimContext = require("@Features/sim/modules/SimContext")
local WaveDirector = require("@Features/run/modules/WaveDirector")
local WorldSim = require("@Features/world/modules/WorldSim")

type Phase = RunStateMachine.Phase

export type Camp = {
	id: string,
	x: number,
	z: number,
	enemies: { WorldSim.CampMember },
	awake: boolean,
}

export type State = {
	run: RunStateMachine.Run,
	director: WaveDirector.State,
	-- Ticks into the act, counting only while it is being played.
	elapsed: number,
	-- Ticks the teleporter has charged.
	charge: number,
	-- What was picked up this run. Already saved: this is for the HUD and the results.
	result: RunRewards.Result,
	camps: { Camp },
	-- Enemies the wave director spawned, so camps don't count against its cap. Only looked up.
	waveIds: { [number]: boolean },
	-- The tick everyone is sent back to the lobby, and the phase it only applies in.
	returnAt: number?,
	returnPhase: Phase?,
	-- A hero asked for a run and the adapter hasn't answered yet.
	requested: boolean,
	-- The seeds of the run in progress: they fix the maps and what drops.
	mapSeed: number,
	lootSeed: number,
}

-- What the run works on.
export type Deps = {
	combat: CombatSim.State,
	enemies: EnemySim.State,
	loot: LootSim.State,
	world: WorldSim.State,
	-- In slot order.
	heroes: { HeroActions.Hero },
}

-- Acts in a run. One for the vertical slice.
local TOTAL_ACTS = 1
local BOSS_ID = "golem"
-- Seconds a hero has to stand near the teleporter to fill it.
local CHARGE_SECONDS = 30
local CHARGE_RADIUS = 16
-- Camps wake (spawn their enemies, idle) when a hero comes this close.
local ACTIVATE_RADIUS = 90
-- Seconds between the party falling and everyone being back in the lobby.
local DEFEAT_DELAY = 3
-- Seconds the results stay up before everyone is sent back anyway.
local RESULTS_TIMEOUT = 60
-- Waves appear this far from a hero.
local SPAWN_MIN = 35
local SPAWN_MAX = 60
-- Between acts, heroes get this share of their health back.
local ACT_HEAL = 0.3
local CHEST_COINS = { 15, 30 }
local CHEST_XP = { 10, 20 }
local CHEST_PILES = 4
local DEVIL_COINS = 40
local DEVIL_PILES = 5
local DEVIL_COST = 0.3
local DEVIL_PACK = 5
local TICKS_PER_MINUTE = SimClock.RATE * 60

local RunSim = {}

function RunSim.new(): State
	return {
		run = RunStateMachine.create(TOTAL_ACTS),
		director = WaveDirector.new(),
		elapsed = 0,
		charge = 0,
		result = { coins = 0, xp = 0 },
		camps = {},
		waveIds = {},
		returnAt = nil,
		returnPhase = nil,
		requested = false,
		mapSeed = 0,
		lootSeed = 0,
	}
end

function RunSim.phase(state: State): Phase
	return RunStateMachine.getPhase(state.run)
end

local function changed(ctx: SimContext.Ctx)
	SimContext.emit(ctx, { kind = "runChanged" })
end

local function aliveHeroes(deps: Deps): number
	local count = 0
	for _, hero in deps.heroes do
		if not hero.entity.dead then
			count += 1
		end
	end
	return count
end

local function standingHeroes(deps: Deps): { HeroActions.Hero }
	local standing = {}
	for _, hero in deps.heroes do
		if not hero.entity.dead then
			table.insert(standing, hero)
		end
	end
	return standing
end

local function minutes(state: State): number
	return state.elapsed / TICKS_PER_MINUTE
end

local function coefficient(state: State, deps: Deps): number
	return Difficulty.coefficient(minutes(state), RunStateMachine.actIndex(state.run), math.max(1, #deps.heroes))
end

-- What every client is told about the run.
function RunSim.view(state: State, deps: Deps): RunProtocol.View
	return {
		phase = RunSim.phase(state),
		act = RunStateMachine.actIndex(state.run),
		totalActs = RunStateMachine.totalActs(state.run),
		elapsed = state.elapsed // SimClock.RATE,
		coefficient = math.floor(coefficient(state, deps) * 100 + 0.5) / 100,
		charge = math.floor(math.min(1, state.charge / SimClock.ticks(CHARGE_SECONDS)) * 100 + 0.5) / 100,
		coins = state.result.coins,
		xp = state.result.xp,
		alive = aliveHeroes(deps),
	}
end

local function placeHeroes(ctx: SimContext.Ctx, deps: Deps)
	for _, hero in deps.heroes do
		local x, z = WorldSim.spawnPoint(deps.world, hero.slot)
		HeroActions.place(ctx, hero, x, z)
	end
end

-- Everyone goes back to the lobby at full health, and the act is forgotten.
local function sendToLobby(state: State, deps: Deps, ctx: SimContext.Ctx)
	state.returnAt, state.returnPhase = nil, nil
	EnemySim.despawnAll(deps.enemies, deps.combat, ctx)
	LootSim.despawnAll(deps.loot, ctx)
	WorldSim.closePortal(deps.world, ctx)
	state.camps = {}
	state.waveIds = {}
	EnemySim.setNavGrid(deps.enemies, nil)

	for _, hero in deps.heroes do
		CombatSim.revive(deps.combat, ctx, hero.entity.id)
	end
	WorldSim.reset(deps.world, ctx)
	SimContext.emit(ctx, { kind = "lobby" })
	placeHeroes(ctx, deps)
	RunStateMachine.reset(state.run)
	changed(ctx)
end

-- Sends everyone back to the lobby after `seconds`, if the run is still in `expected`.
local function returnLater(state: State, ctx: SimContext.Ctx, seconds: number, expected: Phase)
	state.returnAt = ctx.tick + SimClock.ticks(seconds)
	state.returnPhase = expected
end

-- The party fell. The adapter charges the price at once (leaving can't dodge
-- it), then everyone is sent to the lobby.
local function defeat(state: State, deps: Deps, ctx: SimContext.Ctx)
	EnemySim.despawnAll(deps.enemies, deps.combat, ctx)
	LootSim.despawnAll(deps.loot, ctx)
	WorldSim.closePortal(deps.world, ctx)
	SimContext.emit(ctx, { kind = "defeat" })
	changed(ctx)
	returnLater(state, ctx, DEFEAT_DELAY, "Defeat")
end

-- The last exit was taken: a bonus for winning, then the results.
local function victory(state: State, deps: Deps, ctx: SimContext.Ctx)
	local bonus = RunRewards.victoryBonus()
	state.result.coins += bonus.coins
	state.result.xp += bonus.xp

	EnemySim.despawnAll(deps.enemies, deps.combat, ctx)
	WorldSim.closePortal(deps.world, ctx)
	SimContext.emit(ctx, { kind = "victory", coins = bonus.coins, xp = bonus.xp })
	changed(ctx)
	returnLater(state, ctx, RESULTS_TIMEOUT, "Victory")
end

-- Builds the current act: the map, the enemy world and the heroes.
local function beginAct(state: State, deps: Deps, ctx: SimContext.Ctx, mapSeed: number, lootSeed: number)
	local actIndex = RunStateMachine.actIndex(state.run)
	if not WorldSim.generate(deps.world, ctx, actIndex, mapSeed, lootSeed) then
		-- Nobody is to blame: back to the lobby with no penalty.
		RunStateMachine.downed(state.run)
		sendToLobby(state, deps, ctx)
		return
	end

	EnemySim.despawnAll(deps.enemies, deps.combat, ctx)
	LootSim.despawnAll(deps.loot, ctx)
	EnemySim.setNavGrid(deps.enemies, deps.world.grid)
	state.director = WaveDirector.new()
	state.charge = 0
	state.waveIds = {}
	state.camps = {}
	for _, camp in deps.world.camps do
		table.insert(state.camps, { id = camp.id, x = camp.x, z = camp.z, enemies = camp.enemies, awake = false })
	end

	for _, hero in deps.heroes do
		if actIndex == 1 or hero.entity.dead then
			CombatSim.revive(deps.combat, ctx, hero.entity.id)
		else
			CombatSim.heal(deps.combat, ctx, hero.entity.id, hero.entity.maxHp * ACT_HEAL)
		end
	end
	placeHeroes(ctx, deps)

	RunStateMachine.generated(state.run)
	changed(ctx)
end

-- A run starts (the adapter answered `runRequested`): the seeds fix the maps
-- and everything that drops. Ignored unless the party is in the lobby.
function RunSim.start(state: State, deps: Deps, ctx: SimContext.Ctx, mapSeed: number, lootSeed: number)
	state.requested = false
	state.mapSeed, state.lootSeed = mapSeed, lootSeed
	if RunSim.phase(state) ~= "Waiting" then
		return
	end

	SimContext.reseed(ctx, lootSeed)
	state.elapsed = 0
	state.result = { coins = 0, xp = 0 }
	if RunStateMachine.start(state.run) then
		beginAct(state, deps, ctx, mapSeed, lootSeed)
	end
end

-- The results screen was left: everyone goes back to the lobby.
function RunSim.toLobby(state: State, deps: Deps, ctx: SimContext.Ctx)
	if RunSim.phase(state) == "Victory" then
		sendToLobby(state, deps, ctx)
	end
end

-- A hero used an object (WorldSim.use said it could).
function RunSim.interact(state: State, deps: Deps, ctx: SimContext.Ctx, hero: HeroActions.Hero, object: WorldSim.Object)
	local current = RunSim.phase(state)
	local kind = object.kind

	if kind == "lobbyPortal" then
		if current == "Waiting" and not state.requested then
			state.requested = true
			SimContext.emit(ctx, { kind = "runRequested", slot = hero.slot })
		end
	elseif kind == "teleporter" then
		if current == "Exploring" and RunStateMachine.charge(state.run) then
			WorldSim.setEnabled(deps.world, ctx, object.id, false)
			changed(ctx)
		end
	elseif kind == "chest" then
		-- This hero's chest: what it pays is fixed by the chest's seed.
		local rng = Rng.new(Rng.derive(object.lootSeed, hero.slot))
		local coins = Rng.int(rng, CHEST_COINS[1], CHEST_COINS[2])
		for _, pile in LootTables.split(coins, CHEST_PILES) do
			LootSim.dropFor(deps.loot, ctx, rng, hero.slot, "coin", pile, object.x, object.z)
		end
		LootSim.dropFor(
			deps.loot,
			ctx,
			rng,
			hero.slot,
			"xp",
			Rng.int(rng, CHEST_XP[1], CHEST_XP[2]),
			object.x,
			object.z
		)
	elseif kind == "angelStatue" then
		-- A blessing: every hero is healed.
		for _, other in deps.heroes do
			if not other.entity.dead then
				CombatSim.heal(deps.combat, ctx, other.entity.id, other.entity.maxHp)
			end
		end
	elseif kind == "devilStatue" then
		-- A deal: some health (never the last of it) for coins, and the statue's guards wake up.
		local entity = hero.entity
		if not entity.dead then
			local cost = math.min(math.floor(entity.maxHp * DEVIL_COST), entity.hp - 1)
			if cost > 0 then
				CombatSim.applyDamage(deps.combat, ctx, nil, entity.id, cost, "true")
			end
		end

		local rng = Rng.new(Rng.derive(object.lootSeed, hero.slot))
		for _, pile in LootTables.split(DEVIL_COINS, DEVIL_PILES) do
			LootSim.dropFor(deps.loot, ctx, rng, hero.slot, "coin", pile, object.x, object.z)
		end
		for index = 1, DEVIL_PACK do
			local dx, dz = Angle.direction((index - 1) * Angle.TURN // DEVIL_PACK)
			EnemySim.spawn(deps.enemies, deps.combat, ctx, "grunt", object.x + dx * 9, object.z + dz * 9)
		end
	elseif kind == "portal" then
		if current == "ExitOpen" and RunStateMachine.advance(state.run) then
			if RunSim.phase(state) == "Victory" then
				victory(state, deps, ctx)
			else
				beginAct(state, deps, ctx, state.mapSeed, state.lootSeed)
			end
		end
	end
end

-- An enemy was killed (its loot is already on the ground).
function RunSim.onKilled(state: State, deps: Deps, ctx: SimContext.Ctx, enemy: EnemySim.Enemy)
	state.waveIds[enemy.body.id] = nil

	if enemy.def.id == BOSS_ID and RunSim.phase(state) == "Boss" and RunStateMachine.bossDefeated(state.run) then
		-- The rest of the wave goes with the boss, and the way out opens.
		EnemySim.despawnAll(deps.enemies, deps.combat, ctx)
		state.waveIds = {}
		WorldSim.openPortal(deps.world, ctx)
		changed(ctx)
	end
end

-- A hero was downed: the run is lost when none is left standing.
function RunSim.onDowned(state: State, deps: Deps, ctx: SimContext.Ctx)
	if aliveHeroes(deps) == 0 and RunStateMachine.downed(state.run) then
		defeat(state, deps, ctx)
	end
end

-- A hero picked something up: counts for the HUD and the results.
function RunSim.onPickup(state: State, kind: LootTables.Kind, amount: number)
	if kind == "coin" then
		state.result.coins += amount
	else
		state.result.xp += amount
	end
end

local function spawnBoss(deps: Deps, ctx: SimContext.Ctx)
	local teleporterX, teleporterZ = WorldSim.positionOf(deps.world, "teleporter")
	if teleporterX == nil or teleporterZ == nil then
		return
	end

	local x, z = teleporterX, teleporterZ
	local grid = deps.world.grid
	if grid then
		local pickedX, pickedZ = WaveDirector.pickSpawnPoint(grid, x, z, 12, 18, function()
			return Rng.next(ctx.rng.director)
		end)
		if pickedX and pickedZ then
			x, z = pickedX, pickedZ
		end
	end
	EnemySim.spawn(deps.enemies, deps.combat, ctx, BOSS_ID, x, z)
end

local function updateCharge(state: State, deps: Deps, ctx: SimContext.Ctx)
	local teleporterX, teleporterZ = WorldSim.positionOf(deps.world, "teleporter")
	if teleporterX == nil or teleporterZ == nil then
		return
	end

	for _, hero in standingHeroes(deps) do
		local dx, dz = hero.entity.x - teleporterX, hero.entity.z - teleporterZ
		if dx * dx + dz * dz <= CHARGE_RADIUS * CHARGE_RADIUS then
			state.charge = math.min(SimClock.ticks(CHARGE_SECONDS), state.charge + 1)
			break
		end
	end

	if state.charge >= SimClock.ticks(CHARGE_SECONDS) and RunStateMachine.charged(state.run) then
		spawnBoss(deps, ctx)
		changed(ctx)
	end
end

-- Camps near a hero stand up: their enemies appear, idle until the group wakes.
local function updateCamps(state: State, deps: Deps, ctx: SimContext.Ctx)
	local standing = standingHeroes(deps)
	if #standing == 0 then
		return
	end

	for _, camp in state.camps do
		if camp.awake then
			continue
		end

		for _, hero in standing do
			local dx, dz = hero.entity.x - camp.x, hero.entity.z - camp.z
			if dx * dx + dz * dz <= ACTIVATE_RADIUS * ACTIVATE_RADIUS then
				-- Not enough room under the enemy cap: try again once some are dead.
				if EnemySim.capacity(deps.enemies) >= #camp.enemies then
					camp.awake = true
					for _, member in camp.enemies do
						EnemySim.spawn(
							deps.enemies,
							deps.combat,
							ctx,
							member.defId,
							member.x,
							member.z,
							camp.id,
							member.lootSeed
						)
					end
				end
				break
			end
		end
	end
end

local function updateWaves(state: State, deps: Deps, ctx: SimContext.Ctx)
	local grid = deps.world.grid
	if grid == nil then
		return
	end

	local waveAlive = 0
	for _ in state.waveIds do
		waveAlive += 1
	end

	local function random(): number
		return Rng.next(ctx.rng.director)
	end
	local spawns = WaveDirector.update(
		state.director,
		SimClock.TICK,
		RunSim.phase(state),
		coefficient(state, deps),
		waveAlive,
		minutes(state),
		random
	)
	if #spawns == 0 then
		return
	end

	-- Every wave appears around a hero who is still standing.
	local standing = standingHeroes(deps)
	if #standing == 0 then
		return
	end

	for _, defId in spawns do
		local hero = standing[Rng.int(ctx.rng.director, 1, #standing)]
		local x, z = WaveDirector.pickSpawnPoint(grid, hero.entity.x, hero.entity.z, SPAWN_MIN, SPAWN_MAX, random)
		if x and z then
			local enemy = EnemySim.spawn(deps.enemies, deps.combat, ctx, defId, x, z)
			if enemy then
				state.waveIds[enemy.body.id] = true
			end
		end
	end
end

-- Advances the run by one tick.
function RunSim.step(state: State, deps: Deps, ctx: SimContext.Ctx)
	local current = RunSim.phase(state)

	if current == "Exploring" or current == "Charging" or current == "Boss" then
		state.elapsed += 1
		if current == "Charging" then
			updateCharge(state, deps, ctx)
		end
		local scale = coefficient(state, deps)
		EnemySim.setScaling(deps.enemies, Difficulty.hpScale(scale), Difficulty.damageScale(scale))
		updateCamps(state, deps, ctx)
		updateWaves(state, deps, ctx)
	end

	local returnAt = state.returnAt
	if returnAt and ctx.tick >= returnAt and RunSim.phase(state) == state.returnPhase then
		sendToLobby(state, deps, ctx)
	end
end

function RunSim.checksum(hash: Checksum.Hash, state: State)
	Checksum.section(hash, "run")
	Checksum.string(hash, RunStateMachine.getPhase(state.run))
	Checksum.number(hash, RunStateMachine.actIndex(state.run))
	Checksum.number(hash, state.elapsed)
	Checksum.number(hash, state.charge)
	Checksum.number(hash, state.result.coins)
	Checksum.number(hash, state.result.xp)
	Checksum.number(hash, state.director.credits)
	Checksum.string(hash, if state.director.next then state.director.next.defId else "")
	for _, camp in state.camps do
		Checksum.string(hash, camp.id)
		Checksum.bool(hash, camp.awake)
	end
	Checksum.number(hash, state.returnAt or -1)
	Checksum.bool(hash, state.requested)
	Checksum.number(hash, state.mapSeed)
	Checksum.number(hash, state.lootSeed)

	local waves: { number } = {}
	for id in state.waveIds do
		table.insert(waves, id)
	end
	table.sort(waves)
	for _, id in waves do
		Checksum.number(hash, id)
	end
end

return RunSim
