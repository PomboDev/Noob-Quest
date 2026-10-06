local ActDefs = require("../src/features/world/modules/ActDefs")
local ActSpace = require("../src/features/world/modules/ActSpace")
local Expect = require("./Expect")
local GenerateAct = require("../src/features/world/modules/GenerateAct")
local NavGrid = require("../src/features/enemies/modules/NavGrid")
local TileSet = require("../src/features/world/modules/TileSet")

local function act(seed: number)
	return GenerateAct.generate(ActDefs.forAct(1), seed)
end

return {
	["the act is centred on the origin"] = function()
		local a = act(1)
		local originX, originZ = ActSpace.origin(a)
		Expect.equal(originX, -a.width * a.tileSize / 2)
		Expect.equal(originZ, -a.height * a.tileSize / 2)

		-- The first and last tile centres are mirror images.
		local firstX, firstZ = ActSpace.tileCenter(a, 0, 0)
		local lastX, lastZ = ActSpace.tileCenter(a, a.width - 1, a.height - 1)
		Expect.equal(firstX, -lastX)
		Expect.equal(firstZ, -lastZ)
	end,

	["tileAt and tileCenter agree, and outside is nil"] = function()
		local a = act(2)
		for _, spot in { { 0, 0 }, { 5, 7 }, { a.width - 1, a.height - 1 } } do
			local x, z = ActSpace.tileCenter(a, spot[1], spot[2])
			local tx, ty = ActSpace.tileAt(a, x, z)
			Expect.equal(tx, spot[1])
			Expect.equal(ty, spot[2])
		end

		local originX, originZ = ActSpace.origin(a)
		Expect.equal((ActSpace.tileAt(a, originX - 0.1, 0)), nil)
		Expect.equal((ActSpace.tileAt(a, 0, -originZ + 0.1)), nil)
		Expect.equal(ActSpace.tileIndex(a, 3, 2), 2 * a.width + 3 + 1)
	end,

	["a point of interest is centred on its footprint, inside the map"] = function()
		local a = act(3)
		for _, poi in a.pois do
			local x, z = ActSpace.poiCenter(a, poi)
			local tx, ty = ActSpace.tileAt(a, x, z)
			Expect.equal(tx ~= nil and ty ~= nil, true, poi.id)
			-- The footprint's centre falls within the footprint.
			local column, row = tx :: number, ty :: number
			Expect.equal(column >= poi.x and column < poi.x + poi.w, true, poi.id)
			Expect.equal(row >= poi.y and row < poi.y + poi.h, true, poi.id)
		end
	end,

	["there is exactly one spawn and one teleporter in act 1"] = function()
		local a = act(4)
		Expect.equal(#ActSpace.poisOfKind(a, "spawn"), 1)
		Expect.equal(#ActSpace.poisOfKind(a, "teleporter"), 1)
		Expect.equal(#ActSpace.poisOfKind(a, "dungeon"), 0)
	end,

	["quarter turns are clockwise seen from above"] = function()
		Expect.equal(ActSpace.rotationRadians(0), 0)
		Expect.equal(ActSpace.rotationRadians(1), -math.pi / 2)
		Expect.equal(ActSpace.rotationRadians(4), -2 * math.pi)
	end,

	["propPosition stays inside the prop's tile"] = function()
		local a = act(5)
		Expect.equal(#a.props > 0, true)
		for _, prop in a.props do
			local x, z = ActSpace.propPosition(a, prop)
			local tx, ty = ActSpace.tileAt(a, x, z)
			Expect.equal(tx, prop.x)
			Expect.equal(ty, prop.y)
		end
	end,

	["the nav grid blocks exactly the unwalkable tiles"] = function()
		local a = act(6)
		local grid = ActSpace.navGrid(a, TileSet.DEFAULT)
		Expect.equal(grid.cols, a.width * ActSpace.CELLS_PER_TILE)
		Expect.equal(grid.rows, a.height * ActSpace.CELLS_PER_TILE)

		for y = 0, a.height - 1 do
			for x = 0, a.width - 1 do
				local variant = TileSet.DEFAULT.variants[a.tiles[ActSpace.tileIndex(a, x, y)]]
				local cx, cz = ActSpace.tileCenter(a, x, y)
				Expect.equal(NavGrid.walkableAt(grid, cx, cz), variant.walkable, `tile {x},{y}`)
				-- A corner of the tile is the same tile's cell.
				Expect.equal(NavGrid.walkableAt(grid, cx - a.tileSize * 0.45, cz + a.tileSize * 0.45), variant.walkable)
			end
		end
	end,

	["the spawn, and every point of interest, are walkable"] = function()
		for seed = 1, 10 do
			local a = act(seed)
			local grid = ActSpace.navGrid(a, TileSet.DEFAULT)
			for _, poi in a.pois do
				local x, z = ActSpace.poiCenter(a, poi)
				Expect.equal(NavGrid.walkableAt(grid, x, z), true, `{poi.id} of seed {seed}`)
			end
		end
	end,

	["streamOrder lists every tile once, nearest first"] = function()
		local a = act(7)
		local order = ActSpace.streamOrder(a, 20, -30)
		Expect.equal(#order, a.width * a.height)

		local seen: { [number]: boolean } = {}
		local previous = -1
		for _, index in order do
			Expect.equal(seen[index], nil, "a tile twice")
			seen[index] = true

			local x, y = (index - 1) % a.width, (index - 1) // a.width
			local cx, cz = ActSpace.tileCenter(a, x, y)
			local distance = (cx - 20) ^ 2 + (cz + 30) ^ 2
			Expect.equal(distance >= previous, true, "out of order")
			previous = distance
		end
	end,
}
