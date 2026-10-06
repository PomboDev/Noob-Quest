--!strict

--[=[
	A uniform grid over the XZ plane for finding what is near a point without
	checking everything. Pure and deterministic: a query visits cells in a fixed
	order and a cell lists its points in the order they were inserted, so the
	same inserts give the same results in the same order on every machine.

	Pick a cell size at least as big as the usual query radius: a query then
	only looks at a few cells around the point.

	Rebuild it with `clear` and `insert` when points move. Buckets are kept
	between rebuilds, so a steady crowd allocates nothing.
]=]

-- Cell coordinates are shifted by this much so they are never negative, and
-- packed into one number as `x * STRIDE + z`.
local OFFSET = 32768
local STRIDE = 65536
local MAX_CELL = STRIDE - 1

export type Hash = {
	cellSize: number,
	-- Cell key -> ids inserted into it.
	cells: { [number]: { number } },
	-- Keys of the cells that hold something, so `clear` only touches those.
	used: { number },
	-- Id -> where it was inserted. Looked up by id, never iterated.
	xs: { [number]: number },
	zs: { [number]: number },
}

local SpatialHash = {}

function SpatialHash.new(cellSize: number): Hash
	assert(cellSize > 0, "SpatialHash needs a positive cell size")
	return { cellSize = cellSize, cells = {}, used = {}, xs = {}, zs = {} }
end

local function cellOf(hash: Hash, value: number): number
	return math.clamp(math.floor(value / hash.cellSize) + OFFSET, 0, MAX_CELL)
end

-- Forgets every point. Keeps the buckets for the next build.
function SpatialHash.clear(hash: Hash)
	for _, key in hash.used do
		table.clear(hash.cells[key])
	end
	table.clear(hash.used)
	table.clear(hash.xs)
	table.clear(hash.zs)
end

-- Adds a point. An id is inserted once per build.
function SpatialHash.insert(hash: Hash, id: number, x: number, z: number)
	local key = cellOf(hash, x) * STRIDE + cellOf(hash, z)
	local bucket = hash.cells[key]
	if bucket == nil then
		bucket = {}
		hash.cells[key] = bucket
	end
	if #bucket == 0 then
		table.insert(hash.used, key)
	end
	table.insert(bucket, id)
	hash.xs[id] = x
	hash.zs[id] = z
end

-- Appends to `out` the id of every point within `radius` of (x, z), edge
-- included. Returns `out`.
function SpatialHash.query(hash: Hash, x: number, z: number, radius: number, out: { number }): { number }
	local limit = radius * radius
	local xs, zs = hash.xs, hash.zs
	for cellX = cellOf(hash, x - radius), cellOf(hash, x + radius) do
		for cellZ = cellOf(hash, z - radius), cellOf(hash, z + radius) do
			local bucket = hash.cells[cellX * STRIDE + cellZ]
			if bucket then
				for _, id in bucket do
					local dx, dz = xs[id] - x, zs[id] - z
					if dx * dx + dz * dz <= limit then
						table.insert(out, id)
					end
				end
			end
		end
	end
	return out
end

return SpatialHash
