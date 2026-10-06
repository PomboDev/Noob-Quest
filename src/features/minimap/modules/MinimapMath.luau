--!strict

--[=[
	Maths for the minimap, on plain numbers so Lune can test it.

	The map is drawn on a content frame inside a view (the circle or square the
	player sees). The content is `pxPerStud` times the size of the act, and it
	slides so the point in focus (the hero, or the middle of the act when the
	map is open) sits in the middle of the view.
]=]

local MinimapMath = {}

-- Side of the minimap in the corner, and of the open map, in pixels.
MinimapMath.SIZE_NORMAL = 190
MinimapMath.SIZE_EXPANDED = 460
-- How much of the world one pixel of the small map covers.
MinimapMath.NORMAL_PX_PER_STUD = 0.8
-- How far the hero sees: tiles inside this radius are explored and shown bright.
MinimapMath.VISION_RADIUS = 55
-- The open map leaves this share of the view around the act.
local FIT_MARGIN = 0.96

-- Indices (row by row, from 1) of the tiles whose centre is within `radius`
-- studs of (x, z). The grid starts at (originX, originZ).
function MinimapMath.tilesWithin(
	width: number,
	height: number,
	tileSize: number,
	originX: number,
	originZ: number,
	x: number,
	z: number,
	radius: number
): { number }
	local reach = radius + tileSize / 2
	local minX = math.max(0, math.floor((x - reach - originX) / tileSize))
	local maxX = math.min(width - 1, math.floor((x + reach - originX) / tileSize))
	local minY = math.max(0, math.floor((z - reach - originZ) / tileSize))
	local maxY = math.min(height - 1, math.floor((z + reach - originZ) / tileSize))

	local found: { number } = {}
	for ty = minY, maxY do
		local dz = originZ + (ty + 0.5) * tileSize - z
		for tx = minX, maxX do
			local dx = originX + (tx + 0.5) * tileSize - x
			if dx * dx + dz * dz <= radius * radius then
				table.insert(found, ty * width + tx + 1)
			end
		end
	end
	return found
end

-- Where `value` sits along an axis that starts at `origin` and is `size` long, from 0 to 1.
function MinimapMath.fraction(origin: number, size: number, value: number): number
	return (value - origin) / size
end

-- Pixels per stud that fit a whole act of `mapWidth` x `mapHeight` studs in a square view.
function MinimapMath.fitScale(viewSize: number, mapWidth: number, mapHeight: number): number
	return viewSize * FIT_MARGIN / math.max(mapWidth, mapHeight, 1)
end

-- Where the top-left corner of the content goes, in pixels from the view's top-left
-- corner, so that the world point (focusX, focusZ) is in the middle of the view.
function MinimapMath.contentOffset(
	viewSize: number,
	pxPerStud: number,
	originX: number,
	originZ: number,
	focusX: number,
	focusZ: number
): (number, number)
	return viewSize / 2 - (focusX - originX) * pxPerStud, viewSize / 2 - (focusZ - originZ) * pxPerStud
end

return MinimapMath
