local Expect = require("./Expect")
local FlowField = require("../src/features/enemies/modules/FlowField")
local NavGrid = require("../src/features/enemies/modules/NavGrid")

-- Rows of "." (walkable) and "#" (wall), cells of 1 stud from (0, 0).
local function grid(rows: { string }): NavGrid.Grid
	local walkable = {}
	for _, row in rows do
		for index = 1, #row do
			table.insert(walkable, string.sub(row, index, index) == ".")
		end
	end
	return NavGrid.new(#rows[1], #rows, 1, 0, 0, walkable)
end

local function near(a: number, b: number): boolean
	return math.abs(a - b) < 1e-6
end

return {
	["steps count cells from the target around walls"] = function()
		local g = grid({
			"...",
			".#.",
			"...",
		})
		local field = FlowField.build(g, 0, 0)
		Expect.equal(field.steps[1], 0)
		Expect.equal(field.steps[3], 2, "top right")
		Expect.equal(field.steps[5], -1, "the wall can't be reached")
		Expect.equal(field.steps[9], 4, "far corner, around the wall")
	end,

	["a target in a wall reaches nothing"] = function()
		local g = grid({ ".#." })
		local field = FlowField.build(g, 1, 0)
		Expect.deepEqual(field.steps, { -1, -1, -1 })
	end,

	["walled-in cells stay unreachable"] = function()
		local g = grid({
			".#.",
			".#.",
		})
		local field = FlowField.build(g, 0, 0)
		Expect.equal(field.steps[3], -1)
		local dx, dz = FlowField.direction(g, field, 2.5, 0.5)
		Expect.equal(dx, 0)
		Expect.equal(dz, 0)
	end,

	["direction heads for the target"] = function()
		local g = grid({
			".....",
			".....",
			".....",
		})
		local field = FlowField.build(g, 0, 1)
		local dx, dz = FlowField.direction(g, field, 4.5, 1.5)
		Expect.equal(dx < 0, true)
		Expect.equal(near(dx * dx + dz * dz, 1), true, "a unit step")
		local sx, sz = FlowField.direction(g, field, 0.5, 1.5)
		Expect.equal(sx, 0, "already there")
		Expect.equal(sz, 0)
	end,

	["direction goes round a wall, not into it"] = function()
		local g = grid({
			"..#..",
			"..#..",
			"..#..",
			".....",
		})
		-- From the top right, the way to the top left goes down first.
		local field = FlowField.build(g, 0, 0)
		local dx, dz = FlowField.direction(g, field, 3.5, 0.5)
		Expect.equal(dz > 0, true, "heads down, not at the wall")

		-- Following the field arrives.
		local x, z = 3.5, 0.5
		for _ = 1, 40 do
			local sx, sz = FlowField.direction(g, field, x, z)
			x += sx * 0.5
			z += sz * 0.5
			Expect.equal(NavGrid.walkableAt(g, x, z), true, "never inside the wall")
		end
		local cx, cy = NavGrid.cellOf(g, x, z)
		Expect.equal(cx, 0)
		Expect.equal(cy, 0)
	end,

	["diagonal steps don't cut wall corners"] = function()
		local g = grid({
			".#",
			"#.",
		})
		-- (1, 1) and (0, 0) touch only at a corner between two walls: not connected.
		local field = FlowField.build(g, 0, 0)
		Expect.equal(field.steps[4], -1)
		local dx, dz = FlowField.direction(g, field, 1.5, 1.5)
		Expect.equal(dx, 0)
		Expect.equal(dz, 0)
	end,

	["positions outside the grid have no direction"] = function()
		local g = grid({ "..." })
		local field = FlowField.build(g, 0, 0)
		local dx, dz = FlowField.direction(g, field, -5, 0.5)
		Expect.equal(dx, 0)
		Expect.equal(dz, 0)
	end,
}
