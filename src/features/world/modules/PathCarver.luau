--!strict

--[=[
	Step 2 of act generation: paths from the spawn to every point of interest.

	Points are connected nearest-first. Each one runs a cheapest-path search
	from its centre until it reaches the network built so far, over a cost
	that adds seeded noise to every cell, so the paths bend instead of running
	straight. That makes the network a tree, and every point reachable.
]=]

local ActTypes = require("@Features/world/modules/ActTypes")
local Rng = require("@Core/Rng")

type ActDef = ActTypes.ActDef
type Poi = ActTypes.Poi

local DX = { 0, 1, 0, -1 }
local DY = { -1, 0, 1, 0 }

local PathCarver = {}

-- Binary min-heap of (cost, cell). Equal costs order by cell, so the search
-- never depends on insertion order.
type Heap = { costs: { number }, cells: { number } }

local function lower(heap: Heap, a: number, b: number): boolean
	local costs = heap.costs
	return costs[a] < costs[b] or (costs[a] == costs[b] and heap.cells[a] < heap.cells[b])
end

local function swap(heap: Heap, a: number, b: number)
	heap.costs[a], heap.costs[b] = heap.costs[b], heap.costs[a]
	heap.cells[a], heap.cells[b] = heap.cells[b], heap.cells[a]
end

local function push(heap: Heap, cost: number, cell: number)
	table.insert(heap.costs, cost)
	table.insert(heap.cells, cell)
	local index = #heap.costs
	while index > 1 do
		local parent = index // 2
		if not lower(heap, index, parent) then
			break
		end
		swap(heap, index, parent)
		index = parent
	end
end

local function pop(heap: Heap): (number, number)
	local size = #heap.costs
	local cost, cell = heap.costs[1], heap.cells[1]
	swap(heap, 1, size)
	heap.costs[size] = nil :: any
	heap.cells[size] = nil :: any
	size -= 1

	local index = 1
	while true do
		local smallest = index
		local left, right = index * 2, index * 2 + 1
		if left <= size and lower(heap, left, smallest) then
			smallest = left
		end
		if right <= size and lower(heap, right, smallest) then
			smallest = right
		end
		if smallest == index then
			break
		end
		swap(heap, index, smallest)
		index = smallest
	end
	return cost, cell
end

-- The cells of the cheapest path from `start` to any cell in `goals`.
local function shortestPath(def: ActDef, noise: { number }, start: number, goals: { [number]: boolean }): { number }
	local width, height = def.width, def.height
	local dist: { [number]: number } = { [start] = 0 }
	local previous: { [number]: number } = {}
	local heap: Heap = { costs = {}, cells = {} }
	push(heap, 0, start)

	while #heap.costs > 0 do
		local cost, cell = pop(heap)
		if cost <= (dist[cell] or math.huge) then
			if goals[cell] then
				local path = { cell }
				while previous[cell] do
					cell = previous[cell]
					table.insert(path, cell)
				end
				return path
			end

			local x, y = (cell - 1) % width, (cell - 1) // width
			for d = 1, 4 do
				local nx, ny = x + DX[d], y + DY[d]
				if nx >= 0 and nx < width and ny >= 0 and ny < height then
					local neighbor = ny * width + nx + 1
					local next = cost + 1 + noise[neighbor]
					if next < (dist[neighbor] or math.huge) then
						dist[neighbor] = next
						previous[neighbor] = cell
						push(heap, next, neighbor)
					end
				end
			end
		end
	end
	return {}
end

local function footprintCells(def: ActDef, poi: Poi): { number }
	local cells = {}
	for y = poi.y, poi.y + poi.h - 1 do
		for x = poi.x, poi.x + poi.w - 1 do
			table.insert(cells, y * def.width + x + 1)
		end
	end
	return cells
end

-- The cells that make up the path network, including those inside
-- footprints. `pois[1]` is the spawn.
function PathCarver.carve(def: ActDef, pois: { Poi }, rng: Rng.Rng): { [number]: boolean }
	local noise: { number } = {}
	for cell = 1, def.width * def.height do
		noise[cell] = Rng.next(rng) * def.wobble
	end

	local network: { [number]: boolean } = {}
	for _, cell in footprintCells(def, pois[1]) do
		network[cell] = true
	end

	local spawn = pois[1]
	local order: { Poi } = {}
	for index = 2, #pois do
		table.insert(order, pois[index])
	end
	local function distance(poi: Poi): number
		local dx, dy = poi.cx - spawn.cx, poi.cy - spawn.cy
		return dx * dx + dy * dy
	end
	table.sort(order, function(a, b)
		local da, db = distance(a), distance(b)
		if da ~= db then
			return da < db
		end
		return a.id < b.id
	end)

	local carved: { [number]: boolean } = {}
	for _, poi in order do
		for _, cell in shortestPath(def, noise, poi.cy * def.width + poi.cx + 1, network) do
			carved[cell] = true
			network[cell] = true
		end
		for _, cell in footprintCells(def, poi) do
			network[cell] = true
		end
	end
	return carved
end

return PathCarver
