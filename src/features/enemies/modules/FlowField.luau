--!strict

--[=[
	A flow field over a NavGrid: how many steps every cell is from a target,
	so any number of enemies can find their way to it by always stepping
	downhill, with no per-enemy pathfinding. Build one per hero, and again
	when the hero moves to another cell.

	A build can stop `maxSteps` cells out: cells further than that stay
	unreachable (-1), so a rebuild costs the area around the target, not the
	whole map. Rebuilding into the field it replaces (`reuse`) only resets the
	cells the last build reached, so nothing the size of the map is allocated
	or walked again.
]=]

local NavGrid = require("@Features/enemies/modules/NavGrid")

local FlowField = {}

export type Field = {
	-- Steps to the target per cell (same layout as NavGrid.Grid.walkable), -1 where it can't be reached.
	steps: { number },
	targetCx: number,
	targetCy: number,
	-- The cells this build reached (indexes into `steps`), so the next build into it can reset them.
	reached: { number },
	reachedCount: number,
}

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

-- Breadth-first from the target, at most `maxSteps` cells out (no limit
-- without it). A target that isn't walkable gives a field where nothing can
-- be reached. `reuse` is an earlier field of the same grid to build into.
function FlowField.build(
	grid: NavGrid.Grid,
	targetCx: number,
	targetCy: number,
	maxSteps: number?,
	reuse: Field?
): Field
	local cols, rows = grid.cols, grid.rows
	local walkable = grid.walkable
	local field: Field
	if reuse and #reuse.steps == cols * rows then
		field = reuse
		local steps = field.steps
		for index = 1, field.reachedCount do
			steps[field.reached[index]] = -1
		end
		field.targetCx, field.targetCy = targetCx, targetCy
	else
		field = {
			steps = table.create(cols * rows, -1),
			targetCx = targetCx,
			targetCy = targetCy,
			reached = {},
			reachedCount = 0,
		}
	end
	field.reachedCount = 0

	if not NavGrid.isWalkable(grid, targetCx, targetCy) then
		return field
	end

	local steps = field.steps
	-- The queue is the list of reached cells: index = cy * cols + cx + 1.
	local queue = field.reached
	local limit = maxSteps or math.huge
	local start = targetCy * cols + targetCx + 1
	steps[start] = 0
	queue[1] = start
	local head, tail = 1, 1
	while head <= tail do
		local index = queue[head]
		head += 1

		local next = steps[index] + 1
		if next > limit then
			continue
		end
		local cx = (index - 1) % cols

		-- The four orthogonal neighbours, inlined: this loop is most of the cost.
		if cx + 1 < cols then
			local n = index + 1
			if walkable[n] and steps[n] == -1 then
				steps[n] = next
				tail += 1
				queue[tail] = n
			end
		end
		if cx > 0 then
			local n = index - 1
			if walkable[n] and steps[n] == -1 then
				steps[n] = next
				tail += 1
				queue[tail] = n
			end
		end
		if index + cols <= cols * rows then
			local n = index + cols
			if walkable[n] and steps[n] == -1 then
				steps[n] = next
				tail += 1
				queue[tail] = n
			end
		end
		if index > cols then
			local n = index - cols
			if walkable[n] and steps[n] == -1 then
				steps[n] = next
				tail += 1
				queue[tail] = n
			end
		end
	end
	field.reachedCount = tail
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
