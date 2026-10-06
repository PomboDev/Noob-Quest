--[=[
	A scripted player for specs: drives heroes through the simulation by
	reading its state, the way a person would. It walks to the lobby portal,
	starts a run, fights its way to the teleporter, charges it, kills the boss
	and takes the exit. It uses no randomness and no clock, so the same options
	always give the same frames.
]=]

local Angle = require("../src/core/Angle")
local Checksum = require("../src/features/sim/modules/Checksum")
local EnemySim = require("../src/features/enemies/modules/EnemySim")
local FlowField = require("../src/features/enemies/modules/FlowField")
local HeroInput = require("../src/features/heroes/modules/HeroInput")
local HeroSim = require("../src/features/heroes/modules/HeroSim")
local LobbySpace = require("../src/features/world/modules/LobbySpace")
local NavGrid = require("../src/features/enemies/modules/NavGrid")
local Sim = require("../src/features/sim/modules/Sim")
local SimContext = require("../src/features/sim/modules/SimContext")
local WorldSim = require("../src/features/world/modules/WorldSim")

export type Tamper = { tick: number, slot: number, apply: (input: HeroInput.Input) -> () }

export type Options = {
	heroes: number,
	mapSeed: number,
	lootSeed: number,
	maxTicks: number,
	-- Heroes that can't die, so the run reaches its end.
	durable: boolean,
	-- Called after every tick with the sim and the tick that just ran.
	onTick: ((sim: Sim.State, tick: number) -> ())?,
	-- Changes a hero's input on one tick before it is used.
	tamper: Tamper?,
	-- Stop at the first tick this returns true for.
	stopWhen: ((sim: Sim.State, tick: number) -> boolean)?,
}

export type Result = {
	ticks: number,
	-- Sim.checksum every CHECK_EVERY ticks, by tick.
	checksums: { [number]: number },
	-- A hash of every event of the run, in order.
	eventsHash: number,
	-- How often each kind of event happened.
	counts: { [string]: number },
	-- "tick phase" each time the phase changed.
	phases: { string },
	sim: Sim.State,
}

local SimBot = {}

SimBot.CHECK_EVERY = 20

-- How close the bot stands to what it walks to.
local ARRIVE = 4

type Fields = { [string]: FlowField.Field }

local function steer(
	sim: Sim.State,
	fields: Fields,
	hero: any,
	input: HeroInput.Input,
	targetX: number,
	targetZ: number
)
	local x, z = hero.sim.motion.x, hero.sim.motion.z
	local dx, dz = targetX - x, targetZ - z
	if dx * dx + dz * dz <= ARRIVE * ARRIVE then
		return
	end

	local grid = WorldSim.gridAt(sim.world, x, z)
	local stepX, stepZ = 0, 0
	local cx, cy = NavGrid.cellOf(grid, targetX, targetZ)
	if cx and cy then
		local key = `{grid.cols}x{grid.rows}@{grid.originX},{cx},{cy}`
		local field = fields[key]
		if field == nil then
			field = FlowField.build(grid, cx, cy)
			fields[key] = field
		end
		stepX, stepZ = FlowField.direction(grid, field, x, z)
	end
	if stepX == 0 and stepZ == 0 then
		stepX, stepZ = dx, dz
	end

	input.moving = true
	input.moveAngle = (Angle.atan2(stepX, stepZ) + 128) // 256 % 256
end

local function objectOf(sim: Sim.State, kind: string): WorldSim.Object?
	for _, object in sim.world.objects do
		if object.kind == kind then
			return object
		end
	end
	return nil
end

local function near(hero: any, x: number, z: number, distance: number): boolean
	local dx, dz = hero.sim.motion.x - x, hero.sim.motion.z - z
	return dx * dx + dz * dz <= distance * distance
end

-- What the bot's heroes do this tick, by slot.
local function decide(sim: Sim.State, fields: Fields, tick: number): { [number]: HeroInput.Input }
	local inputs: { [number]: HeroInput.Input } = {}
	local phase = sim.run.run.currentState

	local target: WorldSim.Object? = nil
	if phase == "Waiting" then
		target = objectOf(sim, "lobbyPortal")
	elseif phase == "Exploring" then
		target = objectOf(sim, "teleporter")
	elseif phase == "ExitOpen" then
		target = objectOf(sim, "portal")
	elseif phase == "Charging" or phase == "Boss" then
		target = objectOf(sim, "teleporter")
	end

	for index, hero in sim.heroes do
		local input = HeroInput.idle()
		if target then
			-- Stay close to it while charging, so the teleporter fills.
			steer(sim, fields, hero, input, target.x, target.z)
		end

		-- Fight whatever is near, always.
		if phase ~= "Waiting" then
			input.attack = true
			input.auto = true
			if
				HeroSim.remaining(hero.sim, 2) == 0
				and #EnemySim.near(sim.enemies, hero.sim.motion.x, hero.sim.motion.z, 10) > 2
			then
				input.ability = 2
			end
		end

		-- One hero uses the object when it is in reach.
		if
			index == 1
			and target
			and near(hero, target.x, target.z, 10)
			and (phase == "Waiting" or phase == "Exploring" or phase == "ExitOpen")
		then
			input.interact = target.objectId
		end
		inputs[hero.slot] = input
	end
	return inputs
end

local function hashEvent(hash: Checksum.Hash, event: SimContext.Event)
	Checksum.string(hash, event.kind)
	local keys: { string } = {}
	for key in event :: any do
		if key ~= "kind" then
			table.insert(keys, key)
		end
	end
	table.sort(keys)
	for _, key in keys do
		Checksum.string(hash, key)
		local value = (event :: any)[key]
		if type(value) == "number" then
			Checksum.number(hash, value)
		elseif type(value) == "boolean" then
			Checksum.bool(hash, value)
		elseif type(value) == "string" then
			Checksum.string(hash, value)
		end
	end
end

function SimBot.run(options: Options): Result
	local sim = Sim.new()
	local fields: Fields = {}
	local commands: { Sim.Command } = {}
	for slot = 1, options.heroes do
		table.insert(commands, { kind = "join", slot = slot, userId = 1000 + slot, defId = "warrior" })
	end

	local result: Result = {
		ticks = 0,
		checksums = {},
		eventsHash = 0,
		counts = {},
		phases = {},
		sim = sim,
	}
	local eventsHash = Checksum.new()
	local lastPhase = ""

	for tick = 0, options.maxTicks - 1 do
		local frame: Sim.Frame = { inputs = decide(sim, fields, tick), commands = commands }
		commands = {}

		local tamper = options.tamper
		if tamper and tamper.tick == tick and frame.inputs[tamper.slot] then
			tamper.apply(frame.inputs[tamper.slot])
		end

		local events = Sim.step(sim, frame)
		for _, event in events do
			hashEvent(eventsHash, event)
			result.counts[event.kind] = (result.counts[event.kind] or 0) + 1
			if event.kind == "runRequested" then
				table.insert(commands, { kind = "startRun", mapSeed = options.mapSeed, lootSeed = options.lootSeed })
			elseif event.kind == "victory" then
				table.insert(commands, { kind = "toLobby" })
			end
		end

		if options.durable then
			for _, hero in sim.heroes do
				hero.entity.maxHp = 100000
				hero.entity.hp = math.max(hero.entity.hp, 50000)
			end
		end

		local phase = sim.run.run.currentState
		if phase ~= lastPhase then
			lastPhase = phase
			table.insert(result.phases, `{tick} {phase}`)
		end
		if tick % SimBot.CHECK_EVERY == 0 then
			result.checksums[tick] = Sim.checksum(sim)
		end
		result.ticks = tick + 1

		if options.onTick then
			options.onTick(sim, tick)
		end
		if options.stopWhen and options.stopWhen(sim, tick) then
			break
		end
	end

	result.eventsHash = Checksum.result(eventsHash)
	return result
end

return SimBot
