--!strict

--[=[
	How a hero moves, one simulation tick at a time, on plain numbers. The
	server runs it from the player's inputs and the client runs the same code
	to predict, so neither takes a position from the other.

	A hero is a circle of RADIUS studs on the nav grid. It can't enter a cell
	that isn't walkable (walls, water, the edge of the map), and walking into
	one slides along it. A dash replaces walking for a few ticks: it covers its
	distance in a straight line and stops at walls the same way.

	Only + - * / and core/Angle are used, so every machine gets the same
	result bit for bit.

	Movement speed is all or nothing: the stick's partial tilt isn't sent.
]=]

local Angle = require("@Core/Angle")
local HeroInput = require("@Features/heroes/modules/HeroInput")
local NavGrid = require("@Features/enemies/modules/NavGrid")
local SimClock = require("@Features/sim/modules/SimClock")

local HeroMotion = {}

-- The hero's footprint, in studs.
HeroMotion.RADIUS = 1.5
-- Halvings used to find how far a blocked move gets.
local SEARCH_STEPS = 8

-- Mutated in place by `step` and `startDash`; `copy` it to keep an older one.
export type State = {
	x: number,
	z: number,
	-- Ticks of dash left, and how far it moves on each.
	dashLeft: number,
	dashX: number,
	dashZ: number,
}

function HeroMotion.new(x: number, z: number): State
	return { x = x, z = z, dashLeft = 0, dashX = 0, dashZ = 0 }
end

function HeroMotion.copy(state: State): State
	return { x = state.x, z = state.z, dashLeft = state.dashLeft, dashX = state.dashX, dashZ = state.dashZ }
end

function HeroMotion.isDashing(state: State): boolean
	return state.dashLeft > 0
end

-- Starts a dash of `distance` studs along `angle` over `ticks` ticks.
function HeroMotion.startDash(state: State, angle: number, distance: number, ticks: number)
	local count = math.max(1, math.floor(ticks))
	local dx, dz = Angle.direction(angle)
	local perTick = distance / count
	state.dashLeft = count
	state.dashX = dx * perTick
	state.dashZ = dz * perTick
end

-- Whether a hero standing at (x, z) would overlap a cell it can't enter.
function HeroMotion.blocked(grid: NavGrid.Grid, x: number, z: number): boolean
	local radius = HeroMotion.RADIUS
	local size = grid.cellSize
	local firstCx = math.floor((x - radius - grid.originX) / size)
	local lastCx = math.floor((x + radius - grid.originX) / size)
	local firstCy = math.floor((z - radius - grid.originZ) / size)
	local lastCy = math.floor((z + radius - grid.originZ) / size)

	for cy = firstCy, lastCy do
		for cx = firstCx, lastCx do
			if not NavGrid.isWalkable(grid, cx, cy) then
				-- The closest point of the cell to the hero.
				local minX = grid.originX + cx * size
				local minZ = grid.originZ + cy * size
				local nearX = math.clamp(x, minX, minX + size)
				local nearZ = math.clamp(z, minZ, minZ + size)
				local ox, oz = x - nearX, z - nearZ
				if ox * ox + oz * oz < radius * radius then
					return true
				end
			end
		end
	end
	return false
end

-- Moves along one axis (`dx` or `dz` is zero) as far as the grid allows and
-- returns the new position. A hero that is already inside a wall (after a
-- teleport) moves freely, so it can always walk out.
local function advance(grid: NavGrid.Grid, x: number, z: number, dx: number, dz: number): (number, number)
	if dx == 0 and dz == 0 then
		return x, z
	end
	if not HeroMotion.blocked(grid, x + dx, z + dz) or HeroMotion.blocked(grid, x, z) then
		return x + dx, z + dz
	end

	-- Blocked: bisect for the farthest free fraction of the move.
	local low, high = 0, 1
	for _ = 1, SEARCH_STEPS do
		local middle = (low + high) / 2
		if HeroMotion.blocked(grid, x + dx * middle, z + dz * middle) then
			high = middle
		else
			low = middle
		end
	end
	return x + dx * low, z + dz * low
end

-- Advances the hero by one tick of `input` at `walkSpeed` studs per second.
function HeroMotion.step(state: State, input: HeroInput.Input, grid: NavGrid.Grid, walkSpeed: number)
	local dx, dz
	if state.dashLeft > 0 then
		dx, dz = state.dashX, state.dashZ
		state.dashLeft -= 1
	elseif input.moving then
		local directionX, directionZ = Angle.direction(HeroInput.moveDirection(input))
		local distance = walkSpeed * SimClock.TICK
		dx, dz = directionX * distance, directionZ * distance
	else
		return
	end

	-- X first, then Z, so a move into a wall slides along it.
	state.x, state.z = advance(grid, state.x, state.z, dx, 0)
	state.x, state.z = advance(grid, state.x, state.z, 0, dz)
end

return HeroMotion
