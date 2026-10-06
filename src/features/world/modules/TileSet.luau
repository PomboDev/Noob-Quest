--!strict

--[=[
	The tiles the generator can use. A base tile expands into one variant per
	rotation (see `build`), and `DEFAULT` is the set acts use.

	Sockets: "g" is ground and "w" is water. A shore tile has water on one side
	and ground on the others, so water can only meet ground through shore tiles.
]=]

local ActTypes = require("@Features/world/modules/ActTypes")

type Variant = ActTypes.Variant
type TileSet = ActTypes.TileSet

export type BaseTile = {
	name: string,
	prefab: string,
	-- Sockets for rotation 0 (N, E, S, W).
	sockets: { string },
	weight: number,
	walkable: boolean,
	-- 1 for tiles that look the same turned, 4 otherwise.
	rotations: number,
}

local TileSet = {}

-- One quarter turn clockwise: what faced N now faces E, and so on.
local function rotate(sockets: { string }): { string }
	return { sockets[4], sockets[1], sockets[2], sockets[3] }
end

-- `roles` names the base tiles the generator places itself.
function TileSet.build(bases: { BaseTile }, roles: { ground: string, path: string, plaza: string }): TileSet
	local variants: { Variant } = {}
	local byName: { [string]: number } = {}

	for _, base in bases do
		local sockets = table.clone(base.sockets)
		for rotation = 0, base.rotations - 1 do
			local id = #variants + 1
			if rotation == 0 then
				byName[base.name] = id
			end
			table.insert(variants, {
				id = id,
				name = base.name,
				prefab = base.prefab,
				rotation = rotation,
				sockets = sockets,
				weight = base.weight,
				walkable = base.walkable,
			})
			sockets = rotate(sockets)
		end
	end

	return table.freeze({
		variants = variants,
		ground = assert(byName[roles.ground], "no ground tile"),
		path = assert(byName[roles.path], "no path tile"),
		plaza = assert(byName[roles.plaza], "no plaza tile"),
	})
end

local DEFAULT = TileSet.build({
	{
		name = "ground",
		prefab = "Ground",
		sockets = { "g", "g", "g", "g" },
		weight = 20,
		walkable = true,
		rotations = 1,
	},
	{ name = "path", prefab = "Path", sockets = { "g", "g", "g", "g" }, weight = 0, walkable = true, rotations = 1 },
	{ name = "plaza", prefab = "Plaza", sockets = { "g", "g", "g", "g" }, weight = 0, walkable = true, rotations = 1 },
	{
		name = "water",
		prefab = "Water",
		sockets = { "w", "w", "w", "w" },
		weight = 1.5,
		walkable = false,
		rotations = 1,
	},
	{
		name = "shore",
		prefab = "Shore",
		sockets = { "w", "g", "g", "g" },
		weight = 0.4,
		walkable = true,
		rotations = 4,
	},
	{
		name = "shoreCorner",
		prefab = "ShoreCorner",
		sockets = { "w", "w", "g", "g" },
		weight = 0.3,
		walkable = true,
		rotations = 4,
	},
}, { ground = "ground", path = "path", plaza = "plaza" })

TileSet.DEFAULT = DEFAULT

return TileSet
