local Expect = require("./Expect")
local NavGrid = require("../src/features/enemies/modules/NavGrid")

return {
	["fromTiles copies each tile to its cells"] = function()
		-- 2 x 1 tiles of 12 studs: the second is blocked. Three cells of 4 studs a side.
		local grid = NavGrid.fromTiles(2, 1, 12, { true, false }, 3, 100, 50)
		Expect.equal(grid.cols, 6)
		Expect.equal(grid.rows, 3)
		Expect.equal(grid.cellSize, 4)
		for cy = 0, 2 do
			for cx = 0, 2 do
				Expect.equal(NavGrid.isWalkable(grid, cx, cy), true)
				Expect.equal(NavGrid.isWalkable(grid, cx + 3, cy), false)
			end
		end
	end,

	["cellOf and centerOf agree, relative to the origin"] = function()
		local grid = NavGrid.new(4, 4, 4, 100, 50, table.create(16, true))
		local cx, cy = NavGrid.cellOf(grid, 109, 51)
		Expect.equal(cx, 2)
		Expect.equal(cy, 0)

		local x, z = NavGrid.centerOf(grid, 2, 1)
		Expect.equal(x, 110)
		Expect.equal(z, 56)
		local back, backY = NavGrid.cellOf(grid, x, z)
		Expect.equal(back, 2)
		Expect.equal(backY, 1)
	end,

	["outside the grid is not a cell and not walkable"] = function()
		local grid = NavGrid.new(2, 2, 4, 0, 0, { true, true, true, true })
		Expect.equal((NavGrid.cellOf(grid, -0.1, 1)), nil)
		Expect.equal((NavGrid.cellOf(grid, 1, 8)), nil)
		Expect.equal(NavGrid.isWalkable(grid, -1, 0), false)
		Expect.equal(NavGrid.walkableAt(grid, 9, 1), false)
		Expect.equal(NavGrid.walkableAt(grid, 7.9, 7.9), true)
	end,

	["a wrong cell count is an error"] = function()
		Expect.errors(function()
			NavGrid.new(2, 2, 4, 0, 0, { true })
		end, "expected 4 cells")
		Expect.errors(function()
			NavGrid.fromTiles(2, 2, 12, { true }, 3, 0, 0)
		end, "expected 4 tiles")
	end,
}
