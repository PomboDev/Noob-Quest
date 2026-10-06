--!strict

--[=[
	Types shared by the world-generation modules. Only types are exported;
	requiring this module at runtime returns nil.

	Grid coordinates: `x` and `y` count from 0 at the top-left, and a cell's
	index into a flat array is `y * width + x + 1`. Sides are numbered 1 to 4
	for N, E, S, W.
]=]

export type PoiKind = "spawn" | "teleporter" | "angelStatue" | "devilStatue" | "chest" | "structure" | "dungeon"

-- A point of interest: a square footprint of cells (top-left `x`, `y`, side
-- `w` = `h`) and its centre cell.
export type Poi = {
	kind: PoiKind,
	id: string,
	x: number,
	y: number,
	w: number,
	h: number,
	cx: number,
	cy: number,
}

-- `count` points of `kind`, each a `size` x `size` footprint. Distances are in
-- cells, between centres. `minApart` applies to every other point.
export type PoiRequest = {
	kind: PoiKind,
	count: number,
	size: number,
	minFromSpawn: number,
	maxFromSpawn: number,
	minApart: number,
}

export type PropDef = {
	kind: string,
	weight: number,
}

export type ActDef = {
	id: string,
	width: number,
	height: number,
	-- Studs per tile.
	tileSize: number,
	spawnSize: number,
	-- Cells between the spawn footprint and the map edge.
	spawnMargin: number,
	pois: { PoiRequest },
	props: { PropDef },
	-- Chance that a plain ground tile gets a prop.
	propDensity: number,
	-- Largest random extra cost per cell when carving paths: higher bends them more.
	wobble: number,
}

-- A decoration on a tile. `ox`, `oy` place it inside the tile as a fraction
-- (0 to 1), `rotation` is quarter turns.
export type Prop = {
	kind: string,
	x: number,
	y: number,
	ox: number,
	oy: number,
	rotation: number,
}

-- A tile in one rotation. `sockets` has one entry per side (N, E, S, W) and
-- neighbours must have equal sockets on the sides that touch.
export type Variant = {
	id: number,
	name: string,
	prefab: string,
	rotation: number,
	sockets: { string },
	-- 0 keeps WFC from choosing it; the carver places those tiles itself.
	weight: number,
	walkable: boolean,
}

export type TileSet = {
	variants: { Variant },
	-- Variant ids the generator places itself, and the filler used when WFC fails.
	ground: number,
	path: number,
	plaza: number,
}

export type Act = {
	id: string,
	seed: number,
	width: number,
	height: number,
	tileSize: number,
	-- Variant id per cell.
	tiles: { number },
	-- The spawn first, then everything else.
	pois: { Poi },
	props: { Prop },
	layoutAttempts: number,
	wfcAttempts: number,
	-- WFC kept failing and the free cells were filled with plain ground.
	relaxed: boolean,
}

return nil
