--!strict

--[=[
	Generates an act's map from a seed: points of interest (PoiLayout), paths
	between them (PathCarver), then wave function collapse for everything else
	(Wfc) and a scatter of props (Decorate).

	Pure and deterministic: the same (def, seed, VERSION) gives the same act on
	the server and on every client. Anything that changes the output of a
	generator step must bump VERSION.
]=]

local ActTypes = require("@Features/world/modules/ActTypes")
local Decorate = require("@Features/world/modules/Decorate")
local PathCarver = require("@Features/world/modules/PathCarver")
local PoiLayout = require("@Features/world/modules/PoiLayout")
local Rng = require("@Core/Rng")
local TileSet = require("@Features/world/modules/TileSet")
local Wfc = require("@Features/world/modules/Wfc")

type Act = ActTypes.Act
type ActDef = ActTypes.ActDef

export type Options = {
	tileSet: ActTypes.TileSet?,
	-- Layouts to try before giving up.
	maxLayoutAttempts: number?,
	-- WFC runs per layout before filling the rest with ground.
	maxWfcAttempts: number?,
}

local TWO_32 = 4294967296

local GenerateAct = {
	VERSION = 1,
}

local function cellIndex(def: ActDef, x: number, y: number): number
	return y * def.width + x + 1
end

-- Cells whose tile is already decided: the paths, then the footprints.
local function fixedCells(def: ActDef, tileSet: ActTypes.TileSet, pois: { ActTypes.Poi }, carved: { [number]: boolean })
	local fixed: { [number]: number } = {}
	for cell in carved do
		fixed[cell] = tileSet.path
	end
	for _, poi in pois do
		for y = poi.y, poi.y + poi.h - 1 do
			for x = poi.x, poi.x + poi.w - 1 do
				fixed[cellIndex(def, x, y)] = tileSet.plaza
			end
		end
	end
	return fixed
end

function GenerateAct.generate(def: ActDef, seed: number, options: Options?): Act
	local tileSet = if options and options.tileSet then options.tileSet else TileSet.DEFAULT
	local maxLayoutAttempts = if options and options.maxLayoutAttempts then options.maxLayoutAttempts else 10
	local maxWfcAttempts = if options and options.maxWfcAttempts then options.maxWfcAttempts else 8

	for layoutAttempt = 1, maxLayoutAttempts do
		local layoutSeed = Rng.derive(seed, layoutAttempt)
		local rng = Rng.new(layoutSeed)

		local pois = PoiLayout.layout(def, rng)
		if pois then
			local carved = PathCarver.carve(def, pois, rng)
			local fixed = fixedCells(def, tileSet, pois, carved)

			local tiles: { number }? = nil
			local wfcAttempts = 0
			while not tiles and wfcAttempts < maxWfcAttempts do
				wfcAttempts += 1
				tiles = Wfc.solve(
					def.width,
					def.height,
					tileSet,
					fixed,
					Rng.new(Rng.derive(layoutSeed, 1000 + wfcAttempts))
				)
			end

			local relaxed = tiles == nil
			local solved: { number } = tiles or {}
			if relaxed then
				for cell = 1, def.width * def.height do
					solved[cell] = fixed[cell] or tileSet.ground
				end
			end

			return {
				id = def.id,
				seed = seed,
				width = def.width,
				height = def.height,
				tileSize = def.tileSize,
				tiles = solved,
				pois = pois,
				props = Decorate.scatter(def, tileSet, solved, Rng.new(Rng.derive(layoutSeed, 2000))),
				layoutAttempts = layoutAttempt,
				wfcAttempts = wfcAttempts,
				relaxed = relaxed,
			}
		end
	end

	error(`could not place the points of interest for {def.id} (seed {seed})`)
end

-- A fingerprint of the generated map. Server and client compare it in dev
-- builds to catch a generator that has drifted.
function GenerateAct.hash(act: Act): number
	local hash = 17
	for _, id in act.tiles do
		hash = (hash * 31 + id) % TWO_32
	end
	for _, poi in act.pois do
		hash = (hash * 31 + poi.x * 64 + poi.y) % TWO_32
	end
	for _, prop in act.props do
		hash = (hash * 31 + prop.x * 64 + prop.y) % TWO_32
		hash = (hash * 31 + math.floor(prop.ox * 65536)) % TWO_32
		hash = (hash * 31 + math.floor(prop.oy * 65536)) % TWO_32
	end
	return hash
end

return GenerateAct
