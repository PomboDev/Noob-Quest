--!strict

--[=[
	A flow field over a NavGrid: how many steps every cell is from a target,
	so any number of enemies can find their way to it by always stepping
	downhill, with no per-enemy pathfinding. Build one per hero, and again
	when the hero moves to another cell.
]=]

local NavGrid = require("@Features/enemies/modules/NavGrid")

local FlowField = {}

export type Field = {
	-- Steps to the target per cell (same layout as NavGrid.Grid.walkable), -1 where it can't be reached.
	steps: { number },
	targetCx: number,
	targetCy: number,
}

local ORTHOGONAL = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }
-- Every neighbour, with the two orthogonal cells a diagonal step squeezes between.
local NEIGHBOURS = {
	{ 1, 0 },
	{ -1, 0 },
	{ 0, 1 },
	{ 0, -1 },
	{ 1, 1 },
	{ 1, -1 },
	{ -1, 1 },
	{ -1, -1 },
}

-- Breadth-first from the target. A target that isn't walkable gives a field
-- where nothing can be reached.
function FlowField.build(grid: NavGrid.Grid, targetCx: number, targetCy: number): Field
	local steps = table.create(grid.cols * grid.rows, -1)
	local field: Field = { steps = steps, targetCx = targetCx, targetCy = targetCy }

	if not NavGrid.isWalkable(grid, targetCx, targetCy) then
		return field
	end

	steps[targetCy * grid.cols + targetCx + 1] = 0
	local queue = { targetCx, targetCy }
	local head = 1
	while head <= #queue do
		local cx, cy = queue[head], queue[head + 1]
		head += 2

		local next = steps[cy * grid.cols + cx + 1] + 1
		for _, offset in ORTHOGONAL do
			local nx, ny = cx + offset[1], cy + offset[2]
			if NavGrid.isWalkable(grid, nx, ny) and steps[ny * grid.cols + nx + 1] == -1 then
				steps[ny * grid.cols + nx + 1] = next
				table.insert(queue, nx)
				table.insert(queue, ny)
			end
		end
	end
	return field
end

-- The way to go from a world position: a unit step (dx, dz) towards the
-- neighbouring cell closest to the target, or 0, 0 when already at the target
-- or when the position can't reach it (outside the grid, walled in).
function FlowField.direction(grid: NavGrid.Grid, field: Field, x: number, z: number): (number, number)
	local cx, cy = NavGrid.cellOf(grid, x, z)
	if cx == nil or cy == nil then
		return 0, 0
	end

	local here = field.steps[cy * grid.cols + cx + 1]
	if here == nil or here <= 0 then
		return 0, 0
	end

	local bestX, bestY, best = cx, cy, here
	for _, offset in NEIGHBOURS do
		local ox, oy = offset[1], offset[2]
		local nx, ny = cx + ox, cy + oy
		if not NavGrid.isWalkable(grid, nx, ny) then
			continue
		end
		-- No cutting corners through a wall.
		if
			ox ~= 0
			and oy ~= 0
			and not (NavGrid.isWalkable(grid, cx + ox, cy) and NavGrid.isWalkable(grid, cx, cy + oy))
		then
			continue
		end

		local value = field.steps[ny * grid.cols + nx + 1]
		if value ~= nil and value >= 0 and value < best then
			bestX, bestY, best = nx, ny, value
		end
	end

	if best == here then
		return 0, 0
	end

	local tx, tz = NavGrid.centerOf(grid, bestX, bestY)
	local dx, dz = tx - x, tz - z
	local length = math.sqrt(dx * dx + dz * dz)
	if length < 1e-6 then
		return 0, 0
	end
	return dx / length, dz / length
end

return FlowField
