# World generation

Each act's map is generated from a seed. The generator is pure Luau (no Instances), so the server and every client produce the same grid from the same `(def, seed)`, and the specs in `tests/` cover it.

Code: `src/features/world/modules/`, with the PRNG in `src/core/Rng.luau`.

## Determinism rules

- Randomness comes only from `Rng` (xorshift32 over `bit32`), never `math.random` or `Random`, so results don't depend on the platform.
- No `pairs` iteration over dictionaries whose order could reach the output. Iterate arrays, or loop over indices.
- No transcendental functions (`math.log`, `math.sin`, ...) in anything that affects the grid: their last digit may differ between platforms. Basic arithmetic is exact. Distances are compared squared.
- Changing any generator rule changes every map: bump `GenerateAct.VERSION` and keep client and server on the same build (the run sends `(seed, version)`).

## The grid

A flat array of tile-variant ids, `index = y * width + x + 1`, with `x`, `y` from 0. Sides are numbered 1 to 4 for N, E, S, W. A tile is 12 studs (`ActDef.tileSize`).

## The three steps

1. **`PoiLayout`**: places the spawn near a random edge, then every other point of interest (teleporter, statues, chests, structures) by seeded rejection sampling. Each request sets a footprint size, a distance range from the spawn, and a minimum distance between points. Footprints never touch (one tile of gap). `layout` returns `nil` if a request can't be satisfied, and `GenerateAct` retries with a derived seed.
2. **`PathCarver`**: connects the spawn to every point with a cheapest path over seeded noise costs (Dijkstra with a binary heap). Each point joins the nearest part of the network built so far, so the paths form a wobbly tree. Everything in the network is fixed to the `path` tile and every footprint to the `plaza` tile, so every point is reachable before WFC runs.
3. **`Wfc`**: fills the remaining cells from the `TileSet`. A variant is a tile in one rotation with a socket per side, and neighbours must have equal sockets on touching sides. Cells collapse by fewest remaining options, with seeded noise to break ties and a weighted seeded choice, then constraints propagate. On a contradiction `GenerateAct` retries with a derived seed. After `maxWfcAttempts` failures it fills the free cells with plain ground and sets `relaxed = true`.

`Decorate` then scatters props (trees, rocks, bushes) over plain ground tiles. Props don't affect navigation.

## Tile and prefab contract

- A tile is 12×12 studs, anchored, with its pivot at the centre.
- `Variant.prefab` names a model under `ReplicatedStorage.Assets.Tiles`; `rotation` is quarter turns clockwise. If the model is missing, the client builds a greybox tile.
- Weight-0 tiles (`path`, `plaza`) are never chosen by WFC, only fixed by the carver.
- Water is the only unwalkable tile for now. Everything else is walkable.

## Who holds what

The server keeps the logical grid and builds only gameplay Instances (teleporter, statues, chests, portal). Clients get `(seed, version)` and build the visuals and collision from the same grid. `GenerateAct.hash` fingerprints a grid: a dev-only check compares the client's hash with the server's.

## Authoring prefabs

Tile, structure, enemy and VFX models are built in a separate asset place through the Studio MCP, saved by hand, and pulled into `assets/` with `pesde run syncback`. See [roadmap.md](roadmap.md) for the pipeline.
