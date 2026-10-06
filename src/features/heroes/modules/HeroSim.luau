--!strict

--[=[
	One hero's simulation, advanced one input at a time. The server runs it
	from the inputs a player sends and the client runs the same code to
	predict, so both reach the same state after the same inputs.

	The hero's clock is the number of inputs it has used (`tick`), not the
	wall clock: a hero whose inputs arrive late simply waits, and a hero can't
	be made faster by sending more. Cooldowns count in these ticks too, so a
	client and the server never disagree about whether an ability is ready.

	Only position, dash and cooldowns are simulated here. What a swing or a
	slam hits is up to the server, which acts on the events `step` returns.
]=]

local Angle = require("@Core/Angle")
local AttackInput = require("@Features/heroes/modules/AttackInput")
local HeroDefs = require("@Features/heroes/modules/HeroDefs")
local HeroInput = require("@Features/heroes/modules/HeroInput")
local HeroMotion = require("@Features/heroes/modules/HeroMotion")
local NavGrid = require("@Features/enemies/modules/NavGrid")
local SimClock = require("@Features/sim/modules/SimClock")

local HeroSim = {}

-- Mutated in place by `step`.
export type Sim = {
	def: HeroDefs.HeroDef,
	motion: HeroMotion.State,
	-- Inputs used so far.
	tick: number,
	-- Per ability index: the tick it can be used again.
	readyAt: { [number]: number },
	-- What the hero is doing with its basic attack (the server swings from this).
	attack: AttackInput.State,
	-- The way the hero faces, in core/Angle units. Cosmetic: nothing reads it.
	facing: number,
}

export type Result = {
	-- The ability used on this tick, if it was ready.
	used: number?,
	-- The ability asked for while it wasn't ready, with the ticks left.
	rejected: number?,
	rejectedTicks: number,
}

-- How far apart a predicted and a reported position may be before they
-- count as different (the wire carries doubles, so this is only a safety margin).
HeroSim.TOLERANCE = 0.05

function HeroSim.new(def: HeroDefs.HeroDef, x: number, z: number): Sim
	return {
		def = def,
		motion = HeroMotion.new(x, z),
		tick = 0,
		readyAt = {},
		attack = AttackInput.new(),
		facing = 0,
	}
end

function HeroSim.copy(sim: Sim): Sim
	return {
		def = sim.def,
		motion = HeroMotion.copy(sim.motion),
		tick = sim.tick,
		readyAt = table.clone(sim.readyAt),
		attack = table.clone(sim.attack),
		facing = sim.facing,
	}
end

-- Ticks until an ability can be used again (0 when ready).
function HeroSim.remaining(sim: Sim, index: number): number
	return math.max(0, (sim.readyAt[index] or 0) - sim.tick)
end

-- Puts the hero somewhere else (a spawn, a teleport): it stops dashing.
function HeroSim.place(sim: Sim, x: number, z: number)
	sim.motion = HeroMotion.new(x, z)
end

-- Uses one input. `canAct` is false while the hero is down: it can still
-- walk but can't attack or use abilities. A hero that is frozen (while the
-- map loads) is given the idle input by the caller.
function HeroSim.step(sim: Sim, input: HeroInput.Input, grid: NavGrid.Grid, canAct: boolean): Result
	sim.tick += 1
	local result: Result = { used = nil, rejected = nil, rejectedTicks = 0 }

	if canAct then
		AttackInput.setAttack(sim.attack, input.attack, input.aim, input.auto)
	else
		AttackInput.stop(sim.attack)
	end

	if canAct and input.ability > 0 then
		local ability = HeroDefs.ability(sim.def, input.ability)
		if ability then
			local left = HeroSim.remaining(sim, input.ability)
			if left == 0 then
				sim.readyAt[input.ability] = sim.tick + SimClock.ticks(ability.cooldown)
				result.used = input.ability
				if ability.kind == "dash" then
					HeroMotion.startDash(sim.motion, input.aim, ability.distance, SimClock.ticks(ability.duration))
				end
			else
				result.rejected = input.ability
				result.rejectedTicks = left
			end
		end
	end

	-- Which way the hero faces: its dash, else what it attacks, else where it walks.
	if HeroMotion.isDashing(sim.motion) then
		sim.facing = Angle.atan2(sim.motion.dashX, sim.motion.dashZ)
	elseif canAct and input.attack then
		sim.facing = input.aim
	elseif input.moving then
		sim.facing = HeroInput.moveDirection(input)
	end

	HeroMotion.step(sim.motion, input, grid, sim.def.walkSpeed)
	return result
end

-- Whether two motion states are the same, within TOLERANCE.
function HeroSim.sameMotion(a: HeroMotion.State, b: HeroMotion.State): boolean
	return math.abs(a.x - b.x) <= HeroSim.TOLERANCE
		and math.abs(a.z - b.z) <= HeroSim.TOLERANCE
		and a.dashLeft == b.dashLeft
end

return HeroSim
