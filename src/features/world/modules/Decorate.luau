--!strict

--[=[
	Last step of act generation: scatters props over plain ground tiles. Props
	are only for looks and never block movement.
]=]

local ActTypes = require("@Features/world/modules/ActTypes")
local Rng = require("@Core/Rng")

type ActDef = ActTypes.ActDef
type Prop = ActTypes.Prop

local Decorate = {}

function Decorate.scatter(def: ActDef, tileSet: ActTypes.TileSet, tiles: { number }, rng: Rng.Rng): { Prop }
	local props: { Prop } = {}
	if #def.props == 0 then
		return props
	end

	local weights: { number } = {}
	for index, prop in def.props do
		weights[index] = prop.weight
	end

	for y = 0, def.height - 1 do
		for x = 0, def.width - 1 do
			if tiles[y * def.width + x + 1] == tileSet.ground and Rng.next(rng) < def.propDensity then
				table.insert(props, {
					kind = def.props[Rng.weighted(rng, weights)].kind,
					x = x,
					y = y,
					ox = Rng.next(rng),
					oy = Rng.next(rng),
					rotation = Rng.int(rng, 0, 3),
				})
			end
		end
	end
	return props
end

return Decorate
