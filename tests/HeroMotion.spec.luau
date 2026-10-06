local Angle = require("../src/core/Angle")
local Expect = require("./Expect")
local HeroInput = require("../src/features/heroes/modules/HeroInput")
local HeroMotion = require("../src/features/heroes/modules/HeroMotion")
local NavGrid = require("../src/features/enemies/modules/NavGrid")
local Rng = require("../src/core/Rng")
local SimClock = require("../src/features/sim/modules/SimClock")

-- "#" is a wall and anything else is floor. 4-stud cells, the top-left corner at (0, 0).
local function gridOf(rows: { string }): NavGrid.Grid
	local walkable = {}
	for _, row in rows do
		for column = 1, #row do
			table.insert(walkable, string.sub(row, column, column) ~= "#")
		end
	end
	return NavGrid.new(#rows[1], #rows, 4, 0, 0, walkable)
end

local ROOM = gridOf({
	"##########",
	"#........#",
	"#........#",
	"#...##...#",
	"#...##...#",
	"#........#",
	"#........#",
	"##########",
})

local SPEED = 18

local function moving(angle: number): HeroInput.Input
	local input = HeroInput.idle()
	input.moving = true
	input.moveAngle = HeroInput.quantizeMove(angle)
	return input
end

local function walk(state: HeroMotion.State, input: HeroInput.Input, ticks: number, grid: NavGrid.Grid?)
	for _ = 1, ticks do
		HeroMotion.step(state, input, grid or ROOM, SPEED)
	end
end

local function near(actual: number, expected: number, tolerance: number, label: string?)
	if math.abs(actual - expected) > tolerance then
		error(`{label or "value"}: expected {expected} ± {tolerance}, got {actual}`, 2)
	end
end

return {
	["walks at the walk speed"] = function()
		local state = HeroMotion.new(8, 8)
		walk(state, moving(Angle.QUARTER), SimClock.RATE)
		-- One second at 18 studs a second along +X.
		near(state.x, 8 + SPEED, 1e-6)
		near(state.z, 8, 1e-6)

		state = HeroMotion.new(8, 8)
		walk(state, moving(0), SimClock.RATE // 2)
		near(state.z, 8 + SPEED / 2, 1e-6)
	end,

	["standing still doesn't move, and attacking doesn't stop a walk"] = function()
		local state = HeroMotion.new(8, 12)
		walk(state, HeroInput.idle(), 10)
		Expect.equal(state.x, 8)

		local input = moving(Angle.QUARTER)
		input.attack = true
		walk(state, input, 10)
		Expect.equal(state.x > 8, true)
	end,

	["diagonals are no faster than straight lines"] = function()
		local state = HeroMotion.new(8, 8)
		walk(state, moving(Angle.QUARTER // 2), 10)
		local travelled = math.sqrt((state.x - 8) ^ 2 + (state.z - 8) ^ 2)
		near(travelled, SPEED * 10 * SimClock.TICK, 1e-4)
	end,

	["walls stop the hero at its radius"] = function()
		local state = HeroMotion.new(8, 12)
		walk(state, moving(Angle.HALF + Angle.QUARTER), 60)
		-- The left wall's inner face is at x = 4.
		near(state.x, 4 + HeroMotion.RADIUS, 0.01)
		Expect.equal(HeroMotion.blocked(ROOM, state.x, state.z), false)
	end,

	["walking into a wall at an angle slides along it"] = function()
		local state = HeroMotion.new(8, 8)
		-- Diagonally into the left wall (towards -X and +Z): x is stopped, z keeps going.
		walk(state, moving(Angle.HALF + Angle.QUARTER + Angle.QUARTER // 2), 20)
		near(state.x, 4 + HeroMotion.RADIUS, 0.01)
		Expect.equal(state.z > 12, true)
		Expect.equal(HeroMotion.blocked(ROOM, state.x, state.z), false)
	end,

	["the hero can't slip through a corner gap smaller than itself"] = function()
		-- Two diagonal wall cells with no gap for a 3-stud wide hero.
		local grid = gridOf({
			"######",
			"#..###",
			"#..###",
			"###..#",
			"###..#",
			"######",
		})
		local state = HeroMotion.new(6, 6)
		walk(state, moving(Angle.QUARTER // 2), 120, grid)
		Expect.equal(HeroMotion.blocked(grid, state.x, state.z), false)
		Expect.equal(state.x < 12 and state.z < 12, true, "still in the first room")
	end,

	["a dash covers its distance in its ticks"] = function()
		local state = HeroMotion.new(8, 8)
		HeroMotion.startDash(state, Angle.QUARTER, 20, SimClock.ticks(0.2))
		Expect.equal(HeroMotion.isDashing(state), true)
		walk(state, HeroInput.idle(), 6)
		Expect.equal(HeroMotion.isDashing(state), false)
		near(state.x, 28, 1e-6)
		near(state.z, 8, 1e-6)
		walk(state, HeroInput.idle(), 5)
		near(state.x, 28, 1e-6, "no drift afterwards")
	end,

	["walking input can't steer a dash"] = function()
		local state = HeroMotion.new(8, 8)
		HeroMotion.startDash(state, Angle.QUARTER, 20, 6)
		walk(state, moving(0), 6)
		near(state.z, 8, 1e-6)
		near(state.x, 28, 1e-6)
	end,

	["a dash stops at a wall and never ends inside one"] = function()
		local state = HeroMotion.new(8, 12)
		HeroMotion.startDash(state, Angle.HALF + Angle.QUARTER, 60, 6)
		walk(state, HeroInput.idle(), 6)
		near(state.x, 4 + HeroMotion.RADIUS, 0.01)
		Expect.equal(HeroMotion.blocked(ROOM, state.x, state.z), false)
	end,

	["a hero inside a wall can walk out"] = function()
		local state = HeroMotion.new(2, 6)
		Expect.equal(HeroMotion.blocked(ROOM, 2, 6), true)
		walk(state, moving(Angle.QUARTER), 30)
		Expect.equal(HeroMotion.blocked(ROOM, state.x, state.z), false)
	end,

	["no input sequence gets the hero into a wall"] = function()
		local rng = Rng.new(2024)
		local state = HeroMotion.new(8, 12)
		for tick = 1, 3000 do
			local input = HeroInput.idle()
			input.moving = Rng.next(rng) < 0.9
			input.moveAngle = if input.moving then Rng.int(rng, 0, 255) else 0
			if tick % 90 == 0 then
				HeroMotion.startDash(state, Rng.int(rng, 0, 65535), 20, 6)
			end
			HeroMotion.step(state, input, ROOM, SPEED)
			if HeroMotion.blocked(ROOM, state.x, state.z) then
				error(`inside a wall at tick {tick}: ({state.x}, {state.z})`)
			end
		end
	end,

	["the same inputs give the same positions"] = function()
		local function run(): { number }
			local rng = Rng.new(77)
			local state = HeroMotion.new(8, 12)
			local trace = {}
			for tick = 1, 600 do
				local input = HeroInput.idle()
				input.moving = true
				input.moveAngle = Rng.int(rng, 0, 255)
				if tick % 50 == 0 then
					HeroMotion.startDash(state, input.moveAngle * 256, 20, 6)
				end
				HeroMotion.step(state, input, ROOM, SPEED)
				table.insert(trace, state.x)
				table.insert(trace, state.z)
			end
			return trace
		end
		Expect.deepEqual(run(), run())
	end,

	-- Pinned: a change here means old run logs no longer replay.
	["gives the same positions on every platform"] = function()
		local rng = Rng.new(31)
		local state = HeroMotion.new(8, 12)
		for tick = 1, 400 do
			local input = HeroInput.idle()
			input.moving = true
			input.moveAngle = Rng.int(rng, 0, 255)
			if tick % 70 == 0 then
				HeroMotion.startDash(state, input.moveAngle * 256, 20, 6)
			end
			HeroMotion.step(state, input, ROOM, SPEED)
		end
		Expect.equal(string.format("%.17g %.17g", state.x, state.z), "10.086155860264364 14.335347374017296")
	end,

	["copy is independent of the original"] = function()
		local state = HeroMotion.new(8, 12)
		local saved = HeroMotion.copy(state)
		walk(state, moving(Angle.QUARTER), 5)
		Expect.equal(saved.x, 8)
	end,
}
