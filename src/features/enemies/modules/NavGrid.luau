--!strict

--[=[
	The walkable cells of an act, on plain numbers (Lune can test it).

	Cells are small squares (4 studs by default) laid over the map. A cell is
	walkable or not, and a tile's walkability is copied to the cells under it.
	Columns and rows count from 0, from the top-left corner, which sits at
	world (originX, originZ). Columns grow along +X and rows along +Z.
]=]

local NavGrid = {}

export type Grid = {
	cols: number,
	rows: number,
	cellSize: number,
	originX: number,
	originZ: number,
	-- Row by row: the cell at column cx, row cy is at cy * cols + cx + 1.
	walkable: { boolean },
}

function NavGrid.new(
	cols: number,
	rows: number,
	cellSize: number,
	originX: number,
	originZ: number,
	walkable: { boolean }
): Grid
	if #walkable ~= cols * rows then
		error(`NavGrid: expected {cols * rows} cells, got {#walkable}`, 2)
	end
	return { cols = cols, rows = rows, cellSize = cellSize, originX = originX, originZ = originZ, walkable = walkable }
end

-- A grid from tiles: `tileWalkable` has one entry per tile, row by row, and
-- each tile becomes `cellsPerTile` x `cellsPerTile` cells.
function NavGrid.fromTiles(
	tilesWide: number,
	tilesHigh: number,
	tileSize: number,
	tileWalkable: { boolean },
	cellsPerTile: number,
	originX: number,
	originZ: number
): Grid
	if #tileWalkable ~= tilesWide * tilesHigh then
		error(`NavGrid: expected {tilesWide * tilesHigh} tiles, got {#tileWalkable}`, 2)
	end

	local cols, rows = tilesWide * cellsPerTile, tilesHigh * cellsPerTile
	local walkable = table.create(cols * rows, false)
	for cy = 0, rows - 1 do
		local tileY = cy // cellsPerTile
		for cx = 0, cols - 1 do
			local tileX = cx // cellsPerTile
			walkable[cy * cols + cx + 1] = tileWalkable[tileY * tilesWide + tileX + 1]
		end
	end
	return NavGrid.new(cols, rows, tileSize / cellsPerTile, originX, originZ, walkable)
end

-- The column and row under a world position, or nil outside the grid.
function NavGrid.cellOf(grid: Grid, x: number, z: number): (number?, number?)
	local cx = math.floor((x - grid.originX) / grid.cellSize)
	local cy = math.floor((z - grid.originZ) / grid.cellSize)
	if cx < 0 or cy < 0 or cx >= grid.cols or cy >= grid.rows then
		return nil, nil
	end
	return cx, cy
end

-- Cells outside the grid are not walkable.
function NavGrid.isWalkable(grid: Grid, cx: number, cy: number): boolean
	if cx < 0 or cy < 0 or cx >= grid.cols or cy >= grid.rows then
		return false
	end
	return grid.walkable[cy * grid.cols + cx + 1] == true
end

function NavGrid.walkableAt(grid: Grid, x: number, z: number): boolean
	local cx, cy = NavGrid.cellOf(grid, x, z)
	return cx ~= nil and cy ~= nil and NavGrid.isWalkable(grid, cx, cy)
end

-- The world position of a cell's centre.
function NavGrid.centerOf(grid: Grid, cx: number, cy: number): (number, number)
	return grid.originX + (cx + 0.5) * grid.cellSize, grid.originZ + (cy + 0.5) * grid.cellSize
end

return NavGrid
