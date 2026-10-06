local Expect = require("./Expect")
local Rng = require("../src/core/Rng")
local SpatialHash = require("../src/core/SpatialHash")

type Point = { id: number, x: number, z: number }

local function randomPoints(seed: number, count: number, spread: number): { Point }
	local rng = Rng.new(seed)
	local points: { Point } = {}
	for id = 1, count do
		table.insert(points, {
			id = id,
			x = (Rng.next(rng) - 0.5) * spread,
			z = (Rng.next(rng) - 0.5) * spread,
		})
	end
	return points
end

local function build(points: { Point }, cellSize: number): SpatialHash.Hash
	local hash = SpatialHash.new(cellSize)
	for _, point in points do
		SpatialHash.insert(hash, point.id, point.x, point.z)
	end
	return hash
end

local function brute(points: { Point }, x: number, z: number, radius: number): { number }
	local found = {}
	for _, point in points do
		local dx, dz = point.x - x, point.z - z
		if dx * dx + dz * dz <= radius * radius then
			table.insert(found, point.id)
		end
	end
	table.sort(found)
	return found
end

local function sortedQuery(hash: SpatialHash.Hash, x: number, z: number, radius: number): { number }
	local found = SpatialHash.query(hash, x, z, radius, {})
	table.sort(found)
	return found
end

return {
	["finds exactly what a scan of every point finds"] = function()
		-- Points on both sides of the origin, so negative cells are covered.
		local points = randomPoints(7, 300, 200)
		local hash = build(points, 8)
		local rng = Rng.new(99)
		for _ = 1, 200 do
			local x, z = (Rng.next(rng) - 0.5) * 220, (Rng.next(rng) - 0.5) * 220
			local radius = Rng.next(rng) * 30
			Expect.deepEqual(sortedQuery(hash, x, z, radius), brute(points, x, z, radius))
		end
	end,

	["a radius bigger than a cell still finds everything in range"] = function()
		local points = randomPoints(3, 200, 100)
		local hash = build(points, 4)
		Expect.deepEqual(sortedQuery(hash, 0, 0, 80), brute(points, 0, 0, 80))
	end,

	["a point on the edge of the radius or of a cell is found"] = function()
		local hash = SpatialHash.new(8)
		SpatialHash.insert(hash, 1, 8, 0)
		SpatialHash.insert(hash, 2, -8, 0)
		SpatialHash.insert(hash, 3, 0, 16)
		Expect.deepEqual(sortedQuery(hash, 0, 0, 8), { 1, 2 })
		Expect.deepEqual(sortedQuery(hash, 8, 0, 0), { 1 })
		Expect.deepEqual(sortedQuery(hash, 0, 8, 8), { 3 })
	end,

	["results come in the same order from the same inserts"] = function()
		local points = randomPoints(11, 150, 60)
		local a, b = build(points, 8), build(points, 8)
		local first = SpatialHash.query(a, 5, -3, 20, {})
		Expect.equal(#first > 5, true)
		Expect.deepEqual(first, SpatialHash.query(b, 5, -3, 20, {}))
	end,

	["points in one cell come out in the order they were inserted"] = function()
		local hash = SpatialHash.new(100)
		for _, id in { 9, 2, 7, 4 } do
			SpatialHash.insert(hash, id, id, id)
		end
		Expect.deepEqual(SpatialHash.query(hash, 5, 5, 50, {}), { 9, 2, 7, 4 })
	end,

	["clear forgets every point and the hash can be rebuilt"] = function()
		local points = randomPoints(5, 100, 80)
		local hash = build(points, 8)
		SpatialHash.clear(hash)
		Expect.deepEqual(SpatialHash.query(hash, 0, 0, 1000, {}), {})

		local moved: { Point } = {}
		for _, point in points do
			table.insert(moved, { id = point.id, x = point.x + 13, z = point.z - 7 })
		end
		for _, point in moved do
			SpatialHash.insert(hash, point.id, point.x, point.z)
		end
		Expect.deepEqual(sortedQuery(hash, 10, -10, 25), brute(moved, 10, -10, 25))
	end,

	["query appends to the list it is given"] = function()
		local hash = SpatialHash.new(8)
		SpatialHash.insert(hash, 5, 1, 1)
		local out = { 99 }
		Expect.equal(SpatialHash.query(hash, 0, 0, 5, out), out)
		Expect.deepEqual(out, { 99, 5 })
	end,

	["points far outside the map don't break it"] = function()
		local hash = SpatialHash.new(8)
		SpatialHash.insert(hash, 1, 1e9, -1e9)
		SpatialHash.insert(hash, 2, 0, 0)
		Expect.deepEqual(sortedQuery(hash, 0, 0, 5), { 2 })
	end,
}
