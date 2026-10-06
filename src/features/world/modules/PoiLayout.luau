--!strict

--[=[
	Step 1 of act generation: where the points of interest go.

	The spawn goes near a random edge. Every other point is placed by seeded
	rejection sampling under the distance rules of its request. Footprints keep
	at least one cell between them.
]=]

local ActTypes = require("@Features/world/modules/ActTypes")
local Rng = require("@Core/Rng")

type ActDef = ActTypes.ActDef
type Poi = ActTypes.Poi

-- Cells that must stay empty between two footprints.
local GAP = 1
local MAX_TRIES = 200

local PoiLayout = {}

local function makePoi(kind: ActTypes.PoiKind, id: string, x: number, y: number, size: number): Poi
	return { kind = kind, id = id, x = x, y = y, w = size, h = size, cx = x + size // 2, cy = y + size // 2 }
end

local function overlaps(a: Poi, b: Poi): boolean
	return a.x < b.x + b.w + GAP and b.x < a.x + a.w + GAP and a.y < b.y + b.h + GAP and b.y < a.y + a.h + GAP
end

local function distanceSquared(a: Poi, b: Poi): number
	local dx, dy = a.cx - b.cx, a.cy - b.cy
	return dx * dx + dy * dy
end

local function placeSpawn(def: ActDef, rng: Rng.Rng): Poi
	local size, margin = def.spawnSize, def.spawnMargin
	local maxX, maxY = def.width - size - margin, def.height - size - margin
	local side = Rng.int(rng, 1, 4)
	local x, y
	if side == 1 then
		x, y = Rng.int(rng, margin, maxX), margin
	elseif side == 2 then
		x, y = maxX, Rng.int(rng, margin, maxY)
	elseif side == 3 then
		x, y = Rng.int(rng, margin, maxX), maxY
	else
		x, y = margin, Rng.int(rng, margin, maxY)
	end
	return makePoi("spawn", "spawn", x, y, size)
end

local function fits(candidate: Poi, request: ActTypes.PoiRequest, placed: { Poi }): boolean
	local fromSpawn = distanceSquared(candidate, placed[1])
	if
		fromSpawn < request.minFromSpawn * request.minFromSpawn
		or fromSpawn > request.maxFromSpawn * request.maxFromSpawn
	then
		return false
	end

	for _, other in placed do
		if overlaps(candidate, other) or distanceSquared(candidate, other) < request.minApart * request.minApart then
			return false
		end
	end
	return true
end

-- The spawn followed by every requested point, or nil if a request can't be
-- satisfied (the caller tries another seed).
function PoiLayout.layout(def: ActDef, rng: Rng.Rng): { Poi }?
	local placed: { Poi } = { placeSpawn(def, rng) }

	for _, request in def.pois do
		local size = request.size
		for number = 1, request.count do
			local found: Poi? = nil
			for _ = 1, MAX_TRIES do
				-- One cell of margin keeps footprints off the map edge.
				local x = Rng.int(rng, 1, def.width - size - 1)
				local y = Rng.int(rng, 1, def.height - size - 1)
				local candidate = makePoi(request.kind, `{request.kind}_{number}`, x, y, size)
				if fits(candidate, request, placed) then
					found = candidate
					break
				end
			end

			if not found then
				return nil
			end
			table.insert(placed, found)
		end
	end

	return placed
end

return PoiLayout
