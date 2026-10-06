--!strict

--[=[
	Where an act's grid sits in the world, on plain numbers (Lune can test it).

	The act is centred on the world origin. Tile column x runs along +X and
	tile row y along +Z. The walking surface is at height GROUND_Y, and a tile
	prefab's pivot sits on that surface at the centre of the tile.
]=]

local ActTypes = require("@Features/world/modules/ActTypes")
local NavGrid = require("@Features/enemies/modules/NavGrid")

type Act = ActTypes.Act
type Poi = ActTypes.Poi

local ActSpace = {}

-- Height of the walking surface.
ActSpace.GROUND_Y = 0
-- Nav cells along each side of a tile: 12-stud tiles give 4-stud cells.
ActSpace.CELLS_PER_TILE = 3

-- The world position of the act's top-left corner.
function ActSpace.origin(act: Act): (number, number)
	return -act.width * act.tileSize / 2, -act.height * act.tileSize / 2
end

-- Index into act.tiles for a column and row (both from 0).
function ActSpace.tileIndex(act: Act, x: number, y: number): number
	return y * act.width + x + 1
end

function ActSpace.tileCenter(act: Act, x: number, y: number): (number, number)
	local originX, originZ = ActSpace.origin(act)
	return originX + (x + 0.5) * act.tileSize, originZ + (y + 0.5) * act.tileSize
end

-- The column and row under a world position, or nil outside the act.
function ActSpace.tileAt(act: Act, worldX: number, worldZ: number): (number?, number?)
	local originX, originZ = ActSpace.origin(act)
	local x = math.floor((worldX - originX) / act.tileSize)
	local y = math.floor((worldZ - originZ) / act.tileSize)
	if x < 0 or y < 0 or x >= act.width or y >= act.height then
		return nil, nil
	end
	return x, y
end

-- The centre of a point of interest's footprint.
function ActSpace.poiCenter(act: Act, poi: Poi): (number, number)
	local originX, originZ = ActSpace.origin(act)
	return originX + (poi.x + poi.w / 2) * act.tileSize, originZ + (poi.y + poi.h / 2) * act.tileSize
end

function ActSpace.poisOfKind(act: Act, kind: ActTypes.PoiKind): { Poi }
	local found = {}
	for _, poi in act.pois do
		if poi.kind == kind then
			table.insert(found, poi)
		end
	end
	return found
end

-- Where a prop stands.
function ActSpace.propPosition(act: Act, prop: ActTypes.Prop): (number, number)
	local originX, originZ = ActSpace.origin(act)
	return originX + (prop.x + prop.ox) * act.tileSize, originZ + (prop.y + prop.oy) * act.tileSize
end

-- The world position of a camp's centre.
function ActSpace.campPosition(act: Act, camp: ActTypes.Camp): (number, number)
	local originX, originZ = ActSpace.origin(act)
	return originX + camp.x * act.tileSize, originZ + camp.y * act.tileSize
end

-- Rotation about the up axis for quarter turns clockwise seen from above.
-- Roblox turns counter-clockwise for a positive angle, hence the sign.
function ActSpace.rotationRadians(quarterTurns: number): number
	return -quarterTurns * math.pi / 2
end

function ActSpace.navGrid(act: Act, tileSet: ActTypes.TileSet): NavGrid.Grid
	local tileWalkable = table.create(#act.tiles, false)
	for index, variantId in act.tiles do
		local variant = tileSet.variants[variantId]
		tileWalkable[index] = variant ~= nil and variant.walkable
	end

	local originX, originZ = ActSpace.origin(act)
	return NavGrid.fromTiles(
		act.width,
		act.height,
		act.tileSize,
		tileWalkable,
		ActSpace.CELLS_PER_TILE,
		originX,
		originZ
	)
end

-- Every tile index, nearest to the point first (ties by index), so a map can
-- be built outwards from the player.
function ActSpace.streamOrder(act: Act, worldX: number, worldZ: number): { number }
	local entries = {}
	for y = 0, act.height - 1 do
		for x = 0, act.width - 1 do
			local centerX, centerZ = ActSpace.tileCenter(act, x, y)
			local dx, dz = centerX - worldX, centerZ - worldZ
			table.insert(entries, { index = ActSpace.tileIndex(act, x, y), distance = dx * dx + dz * dz })
		end
	end

	table.sort(entries, function(a, b)
		if a.distance ~= b.distance then
			return a.distance < b.distance
		end
		return a.index < b.index
	end)

	local order = {}
	for _, entry in entries do
		table.insert(order, entry.index)
	end
	return order
end

return ActSpace
