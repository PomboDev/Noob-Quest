--!strict

--[=[
	The whole simulation of the game server: heroes, combat, enemies, loot, the
	world and the run, advanced one tick at a time by `step`.

	A step takes a `Frame`, the only way anything outside changes the sim:
	- `inputs`: what each hero's player did this tick, by slot. A slot with no
	  input doesn't step (its input hasn't arrived: the hero waits);
	- `commands`: heroes joining and leaving, and the run starting with its
	  seeds. A log of frames is a log of everything that happened.

	It returns the events of the tick (damage, spawns, drops, a run changing),
	for adapters to turn into network messages, Instances and saved data. The
	sim never calls out, so a replay can ignore them.

	Pure and deterministic: same frames in, same state and same events out, on
	any machine (see docs/simulation.md for the rules). `checksum` hashes the
	state, to tell whether two runs really did the same.
]=]

local Checksum = require("@Features/sim/modules/Checksum")
local CombatSim = require("@Features/combat/modules/CombatSim")
local EnemySim = require("@Features/enemies/modules/EnemySim")
local HeroActions = require("@Features/heroes/modules/HeroActions")
local HeroInput = require("@Features/heroes/modules/HeroInput")
local LootSim = require("@Features/loot/modules/LootSim")
local RunProtocol = require("@Features/run/modules/RunProtocol")
local RunSim = require("@Features/run/modules/RunSim")
local SimContext = require("@Features/sim/modules/SimContext")
local WorldSim = require("@Features/world/modules/WorldSim")

export type Command =
	{ kind: "join", slot: number, userId: number, defId: string }
	| { kind: "leave", slot: number }
	| { kind: "startRun", mapSeed: number, lootSeed: number }
	| { kind: "toLobby" }

export type Frame = {
	inputs: { [number]: HeroInput.Input },
	commands: { Command },
}

export type State = {
	ctx: SimContext.Ctx,
	combat: CombatSim.State,
	enemies: EnemySim.State,
	loot: LootSim.State,
	world: WorldSim.State,
	run: RunSim.State,
	-- In slot order.
	heroes: { HeroActions.Hero },
	-- What the parts work on: the same tables as above.
	deps: RunSim.Deps,
}

-- A death can cause more deaths (rarely): handled in rounds, up to this many.
local MAX_DRAIN_ROUNDS = 8

local Sim = {}

function Sim.new(): State
	local combat, enemies, loot, world = CombatSim.new(), EnemySim.new(), LootSim.new(), WorldSim.new()
	local heroes: { HeroActions.Hero } = {}
	return {
		ctx = SimContext.new(),
		combat = combat,
		enemies = enemies,
		loot = loot,
		world = world,
		run = RunSim.new(),
		heroes = heroes,
		deps = { combat = combat, enemies = enemies, loot = loot, world = world, heroes = heroes },
	}
end

function Sim.hero(state: State, slot: number): HeroActions.Hero?
	for _, hero in state.heroes do
		if hero.slot == slot then
			return hero
		end
	end
	return nil
end

local function heroByEntity(state: State, entityId: number): HeroActions.Hero?
	for _, hero in state.heroes do
		if hero.entity.id == entityId then
			return hero
		end
	end
	return nil
end

local function slots(state: State): { number }
	local list = {}
	for _, hero in state.heroes do
		table.insert(list, hero.slot)
	end
	return list
end

local function join(state: State, command: { kind: "join", slot: number, userId: number, defId: string })
	if Sim.hero(state, command.slot) then
		return
	end

	local x, z = WorldSim.spawnPoint(state.world, command.slot)
	local hero = HeroActions.new(state.combat, state.ctx, command.slot, command.userId, command.defId, x, z)
	if hero == nil then
		return
	end

	local index = #state.heroes + 1
	for position, other in state.heroes do
		if other.slot > command.slot then
			index = position
			break
		end
	end
	table.insert(state.heroes, index, hero)
	SimContext.emit(state.ctx, {
		kind = "heroJoined",
		slot = hero.slot,
		userId = hero.userId,
		entityId = hero.entity.id,
		x = x,
		z = z,
		inAct = state.world.act ~= nil,
	})
end

local function leave(state: State, command: { kind: "leave", slot: number })
	local hero = Sim.hero(state, command.slot)
	if hero == nil then
		return
	end

	table.remove(state.heroes, table.find(state.heroes, hero))
	CombatSim.unregister(state.combat, hero.entity.id)
	LootSim.removeSlot(state.loot, hero.slot)
	SimContext.emit(state.ctx, { kind = "heroLeft", slot = hero.slot })
end

-- Handles what died since the last call: heroes go down, enemies drop loot.
local function drain(state: State)
	local ctx = state.ctx
	for _ = 1, MAX_DRAIN_ROUNDS do
		local deaths = CombatSim.popDeaths(state.combat)
		if #deaths == 0 then
			return
		end

		for _, death in deaths do
			local hero = heroByEntity(state, death.id)
			if hero then
				HeroActions.onDowned(hero)
				RunSim.onDowned(state.run, state.deps, ctx)
				continue
			end

			local enemy = EnemySim.onDeath(state.enemies, state.combat, ctx, death.id)
			if enemy then
				LootSim.dropFromKill(
					state.loot,
					ctx,
					enemy.lootSeed,
					enemy.def.id,
					enemy.body.x,
					enemy.body.z,
					slots(state)
				)
				RunSim.onKilled(state.run, state.deps, ctx, enemy)
			end
		end
	end
end

local function apply(state: State, command: Command)
	if command.kind == "join" then
		join(state, command)
	elseif command.kind == "leave" then
		leave(state, command)
	elseif command.kind == "startRun" then
		RunSim.start(state.run, state.deps, state.ctx, command.mapSeed, command.lootSeed)
	elseif command.kind == "toLobby" then
		RunSim.toLobby(state.run, state.deps, state.ctx)
	end
end

-- Advances the simulation by one tick and returns what happened.
function Sim.step(state: State, frame: Frame): { SimContext.Event }
	local ctx = state.ctx
	ctx.events = {}

	for _, command in frame.commands do
		apply(state, command)
	end

	-- Heroes in slot order: move, act, use objects.
	for _, hero in state.heroes do
		local input = frame.inputs[hero.slot]
		if input == nil then
			continue
		end

		local objectId = HeroActions.step(state.deps, ctx, hero, input)
		if objectId then
			local object = WorldSim.use(state.world, ctx, hero.sim.motion.x, hero.sim.motion.z, objectId)
			if object then
				RunSim.interact(state.run, state.deps, ctx, hero, object)
			end
		end
	end
	drain(state)

	EnemySim.step(state.enemies, state.combat, ctx)
	drain(state)

	local positions: { [number]: { x: number, z: number } } = {}
	for _, hero in state.heroes do
		if not hero.entity.dead then
			positions[hero.slot] = { x = hero.entity.x, z = hero.entity.z }
		end
	end
	LootSim.step(state.loot, ctx, positions, function(_, kind, amount)
		RunSim.onPickup(state.run, kind, amount)
	end)

	RunSim.step(state.run, state.deps, ctx)

	ctx.tick += 1
	return ctx.events
end

-- What every client is told about the run.
function Sim.view(state: State): RunProtocol.View
	return RunSim.view(state.run, state.deps)
end

-- A number that is the same for two states that are the same in every way the
-- simulation can tell.
function Sim.checksum(state: State): number
	local hash = Checksum.new()
	Checksum.number(hash, state.ctx.tick)
	Checksum.number(hash, state.ctx.rng.combat.state)
	Checksum.number(hash, state.ctx.rng.director.state)
	Checksum.number(hash, state.ctx.rng.loot.state)

	Checksum.section(hash, "heroes")
	for _, hero in state.heroes do
		HeroActions.checksum(hash, hero)
	end
	CombatSim.checksum(hash, state.combat)
	EnemySim.checksum(hash, state.enemies)
	LootSim.checksum(hash, state.loot)
	WorldSim.checksum(hash, state.world)
	RunSim.checksum(hash, state.run)
	return Checksum.result(hash)
end

return Sim
