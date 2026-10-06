local Expect = require("./Expect")
local GreedyMesh = require("../src/features/minimap/modules/GreedyMesh")

-- Paints the rectangles back onto a grid, erroring if two overlap.
local function paint(width: number, height: number, rects: { GreedyMesh.Rect }): { number }
	local grid = table.create(width * height, 0)
	for _, rect in rects do
		Expect.equal(rect.w >= 1 and rect.h >= 1, true, "rect has a size")
		for y = rect.y, rect.y + rect.h - 1 do
			for x = rect.x, rect.x + rect.w - 1 do
				Expect.equal(x >= 0 and x < width and y >= 0 and y < height, true, "rect is inside the grid")
				local index = y * width + x + 1
				Expect.equal(grid[index], 0, `cell {x},{y} is in one rect only`)
				grid[index] = rect.value
			end
		end
	end
	return grid
end

local function randomGrid(width: number, height: number, seed: number, values: number): { number }
	local state = seed
	local cells = {}
	for index = 1, width * height do
		state = (state * 1103515245 + 12345) % 2147483648
		cells[index] = state // 65536 % (values + 1)
	end
	return cells
end

return {
	["a uniform grid is one rectangle"] = function()
		local cells = table.create(48 * 48, 3)
		local rects = GreedyMesh.merge(48, 48, cells)
		Expect.equal(#rects, 1)
		Expect.deepEqual(rects[1], { x = 0, y = 0, w = 48, h = 48, value = 3 })
	end,

	["an empty grid has no rectangles"] = function()
		Expect.deepEqual(GreedyMesh.merge(10, 10, table.create(100, 0)), {})
	end,

	["the rectangles cover the filled cells exactly"] = function()
		for seed = 1, 30 do
			local cells = randomGrid(20, 15, seed, 4)
			Expect.deepEqual(paint(20, 15, GreedyMesh.merge(20, 15, cells)), cells, `seed {seed}`)
		end
	end,

	["it never uses more rectangles than there are cells"] = function()
		for seed = 1, 10 do
			local cells = randomGrid(24, 24, seed, 5)
			local filled = 0
			for _, value in cells do
				if value ~= 0 then
					filled += 1
				end
			end
			Expect.equal(#GreedyMesh.merge(24, 24, cells) <= filled, true, `seed {seed}`)
		end
	end,

	["it merges far fewer rectangles than cells on a map-like grid"] = function()
		-- Big patches of two values with a stripe through them.
		local cells = {}
		for y = 0, 47 do
			for x = 0, 47 do
				cells[y * 48 + x + 1] = if x == 24 then 2 elseif (x // 12 + y // 12) % 2 == 0 then 1 else 3
			end
		end
		local rects = GreedyMesh.merge(48, 48, cells)
		Expect.deepEqual(paint(48, 48, rects), cells)
		Expect.equal(#rects < 48 * 48 / 20, true, `{#rects} rectangles`)
	end,

	["different values never merge"] = function()
		-- A checkerboard: no two neighbours match.
		local cells = { 1, 2, 2, 1 }
		Expect.equal(#GreedyMesh.merge(2, 2, cells), 4)

		-- Matching columns do merge, downwards.
		Expect.equal(#GreedyMesh.merge(2, 2, { 1, 2, 1, 2 }), 2)
	end,

	["a rectangle grows right, then down"] = function()
		local cells = {
			1,
			1,
			1,
			0,
			1,
			1,
			1,
			0,
			1,
			1,
			2,
			0,
		}
		local rects = GreedyMesh.merge(4, 3, cells)
		Expect.deepEqual(rects[1], { x = 0, y = 0, w = 3, h = 2, value = 1 })
		Expect.equal(#rects, 3, "the leftover row of 1s and the lone 2")
		Expect.deepEqual(paint(4, 3, rects), cells)
	end,

	["empty cells split rectangles and are never covered"] = function()
		local cells = { 1, 0, 1, 1, 0, 1 }
		local rects = GreedyMesh.merge(3, 2, cells)
		Expect.deepEqual(paint(3, 2, rects), cells)
	end,

	["the same grid always gives the same rectangles"] = function()
		local cells = randomGrid(30, 30, 7, 4)
		Expect.deepEqual(GreedyMesh.merge(30, 30, cells), GreedyMesh.merge(30, 30, cells))
	end,
}
