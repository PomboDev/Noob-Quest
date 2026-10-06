local Angle = require("../src/core/Angle")
local Expect = require("./Expect")
local HeroDefs = require("../src/features/heroes/modules/HeroDefs")
local HeroInput = require("../src/features/heroes/modules/HeroInput")
local HeroMotion = require("../src/features/heroes/modules/HeroMotion")
local HeroSim = require("../src/features/heroes/modules/HeroSim")
local NavGrid = require("../src/features/enemies/modules/NavGrid")
local SimClock = require("../src/features/sim/modules/SimClock")

local def = HeroDefs.get(HeroDefs.DEFAULT) :: HeroDefs.HeroDef
local OPEN = NavGrid.new(20, 20, 4, 0, 0, table.create(400, true))

local function press(index: number, aim: number): HeroInput.Input
	local input = HeroInput.idle()
	input.ability = index
	input.aim = aim
	return input
end

local function idleFor(sim: HeroSim.Sim, ticks: number)
	for _ = 1, ticks do
		HeroSim.step(sim, HeroInput.idle(), OPEN, true)
	end
end

return {
	["every step counts one tick"] = function()
		local sim = HeroSim.new(def, 40, 40)
		idleFor(sim, 7)
		Expect.equal(sim.tick, 7)
	end,

	["the dash ability starts a dash along the aim"] = function()
		local sim = HeroSim.new(def, 20, 40)
		local result = HeroSim.step(sim, press(1, Angle.QUARTER), OPEN, true)
		Expect.equal(result.used, 1)
		Expect.equal(HeroMotion.isDashing(sim.motion) or sim.motion.x > 20, true)
		idleFor(sim, 10)
		-- 20 studs along +X, whatever the dash ticks were.
		Expect.equal(math.abs(sim.motion.x - 40) < 1e-6, true, `x was {sim.motion.x}`)
		Expect.equal(math.abs(sim.motion.z - 40) < 1e-6, true)
	end,

	["an ability can't be used again until its cooldown has passed, counted in ticks"] = function()
		local sim = HeroSim.new(def, 8, 40)
		local dash = def.abilities[1] :: HeroDefs.Dash
		local cooldown = SimClock.ticks(dash.cooldown)

		Expect.equal(HeroSim.step(sim, press(1, 0), OPEN, true).used, 1)
		Expect.equal(HeroSim.remaining(sim, 1), cooldown)

		local result = HeroSim.step(sim, press(1, 0), OPEN, true)
		Expect.equal(result.used, nil)
		Expect.equal(result.rejected, 1)
		Expect.equal(result.rejectedTicks, cooldown - 1)

		-- It is ready exactly `cooldown` ticks after the first use.
		idleFor(sim, cooldown - 3)
		Expect.equal(HeroSim.step(sim, press(1, 0), OPEN, true).rejected, 1)
		Expect.equal(HeroSim.step(sim, press(1, 0), OPEN, true).used, 1)
	end,

	["abilities are independent"] = function()
		local sim = HeroSim.new(def, 8, 40)
		Expect.equal(HeroSim.step(sim, press(1, 0), OPEN, true).used, 1)
		Expect.equal(HeroSim.step(sim, press(2, 0), OPEN, true).used, 2)
	end,

	["a hero that can't act uses no abilities and doesn't attack"] = function()
		local sim = HeroSim.new(def, 8, 40)
		local input = press(1, 0)
		input.attack = true
		local result = HeroSim.step(sim, input, OPEN, false)
		Expect.equal(result.used, nil)
		Expect.equal(result.rejected, nil)
		Expect.equal(sim.attack.active, false)
		Expect.equal(HeroSim.remaining(sim, 1), 0)
	end,

	["an unknown ability does nothing"] = function()
		local sim = HeroSim.new(def, 8, 40)
		local result = HeroSim.step(sim, press(3, 0), OPEN, true)
		Expect.equal(result.used, nil)
		Expect.equal(result.rejected, nil)
	end,

	["holding attack passes the aim to the attack state"] = function()
		local sim = HeroSim.new(def, 8, 40)
		local input = HeroInput.idle()
		input.attack = true
		input.auto = true
		input.aim = Angle.QUARTER
		HeroSim.step(sim, input, OPEN, true)
		Expect.equal(sim.attack.active, true)
		Expect.equal(sim.attack.auto, true)
		Expect.equal(sim.attack.angle, Angle.QUARTER)
		HeroSim.step(sim, HeroInput.idle(), OPEN, true)
		Expect.equal(sim.attack.active, false)
	end,

	["the hero faces what it attacks, else where it walks"] = function()
		local sim = HeroSim.new(def, 40, 40)
		local walking = HeroInput.idle()
		walking.moving = true
		walking.moveAngle = 64
		HeroSim.step(sim, walking, OPEN, true)
		Expect.equal(sim.facing, Angle.QUARTER)

		walking.attack = true
		walking.aim = Angle.HALF
		HeroSim.step(sim, walking, OPEN, true)
		Expect.equal(sim.facing, Angle.HALF)

		-- Standing still keeps the last facing.
		HeroSim.step(sim, HeroInput.idle(), OPEN, true)
		Expect.equal(sim.facing, Angle.HALF)
	end,

	["copy is independent of the original"] = function()
		local sim = HeroSim.new(def, 8, 40)
		local saved = HeroSim.copy(sim)
		HeroSim.step(sim, press(1, 0), OPEN, true)
		Expect.equal(saved.tick, 0)
		Expect.equal(HeroSim.remaining(saved, 1), 0)
		Expect.equal(saved.readyAt[1], nil)
	end,
}
