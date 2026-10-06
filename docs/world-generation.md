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

## The four steps

1. **`PoiLayout`**: places the spawn near a random edge, then every other point of interest (teleporter, statues, chests, structures) by seeded rejection sampling. Each request sets a footprint size, a distance range from the spawn, and a minimum distance between points. Footprints never touch (one tile of gap). `layout` returns `nil` if a request can't be satisfied, and `GenerateAct` retries with a derived seed.
2. **`PathCarver`**: connects the spawn to every point with a cheapest path over seeded noise costs (Dijkstra with a binary heap). Each point joins the nearest part of the network built so far, so the paths form a wobbly tree. Everything in the network is fixed to the `path` tile and every footprint to the `plaza` tile, so every point is reachable before WFC runs.
3. **`Wfc`**: fills the remaining cells from the `TileSet`. A variant is a tile in one rotation with a socket per side, and neighbours must have equal sockets on touching sides. Cells collapse by fewest remaining options, with seeded noise to break ties and a weighted seeded choice, then constraints propagate. On a contradiction `GenerateAct` retries with a derived seed. After `maxWfcAttempts` failures it fills the free cells with plain ground and sets `relaxed = true`.

`Decorate` then scatters props (trees, rocks, bushes) over plain ground tiles. Props don't affect navigation.

4. **`Populate`**: places the **camps**, the packs of enemies that stand on the map from the start (`Act.camps`). It runs last, on the solved tiles, with its own derived seed, so it is as deterministic as the rest and part of `GenerateAct.hash`.
   - Guards first: the teleporter and the structures always get a camp a few cells away, the chests and statues by chance (`ActDef.camps.guards`). Then `count` more camps are scattered wherever there is room.
   - Camps stay `minFromSpawn` cells from the spawn and `minApart` cells from each other. Camps and their enemies only stand on tiles reachable on foot from the spawn (a flood fill, so an island in a pond stays empty), never on a plaza.
   - The farther a camp is from the spawn the bigger it is and the nastier its kinds (`CampTier`): grunts near the spawn, runners in the middle, spitters far out. Guard camps get `guardBonus` extra enemies.
   - A camp is data only: a centre in tile units and its members' offsets in studs. The run feature (`RunServiceServer.updateCamps`) spawns a camp's enemies when a hero comes within about 90 studs, and the enemies stand idle until a hero comes within about 30 studs or something hurts one of them (groups in `EnemyServiceServer`).

## Tile and prefab contract

- A tile is 12×12 studs and anchored. Its pivot is at the centre of the footprint, on the walking surface (`ActSpace.GROUND_Y`): the top of the tile is at pivot height, so a model's pivot is not its centre of mass.
- `Variant.prefab` names a model under `ReplicatedStorage.Assets.Tiles`; `rotation` is quarter turns clockwise seen from above. If the model is missing, `MapBuilder` builds a greybox block (water is a solid raised pond, so nobody walks through it).
- Props come from `Assets.Props` by kind (`tree`, `rock`, `bush`), with a greybox fallback. Props never collide. Structures with gameplay (teleporter, statues, chest, portal) come from `Assets.Structures` and are built by the server.
- Weight-0 tiles (`path`, `plaza`) are never chosen by WFC, only fixed by the carver.
- Water is the only unwalkable tile for now. Everything else is walkable.

## Who holds what

The server keeps the logical grid and the nav grid (`ActSpace.navGrid`), and builds only gameplay Instances (teleporter, statues, chests, portal). Clients get `(seed, act index, version)` through `WorldServiceServer`'s `onAct` and build the visuals and collision from the same grid with `MapBuilder`, a few tiles per frame, nearest to the spawn first. `GenerateAct.hash` fingerprints a grid: every client reports its hash and the server logs a warning when it differs from its own.

The server holds the hero still at the spawn until the client says the ground under it is built (`mapReady`), so nobody falls through a map that is still streaming in. A hero who falls off the map goes back to the spawn.

Between runs there is no act: the server builds a small lobby platform far along +X (`LOBBY_X`), heroes spawn there, and `returnToLobby` forgets the act, tells clients to drop their map (`onLobby`) and moves everyone back. The lobby portal starts the next run.

Space (`ActSpace`): the act is centred on the world origin, tile column x runs along +X and row y along +Z, and the walking surface is at height 0.

## Authoring prefabs

Tile, structure, enemy and VFX models are built in a separate asset place through the Studio MCP and pulled into git with `rojo syncback`. See [roadmap.md](roadmap.md) for the design.

1. In the asset place, put prefabs under `ReplicatedStorage.Assets` (`Tiles`, `Structures`, `Enemies`, …). The MCP tools are `execute_luau`, `insert_asset`, `generate_procedural_model` and `screen_capture`.
2. Right-click the `Assets` folder in the Explorer, choose Save to File, and save it by hand as `assets/places/Assets.rbxm`, which stays in git as the source of the prefabs (Rojo maps only `assets/shared/`). The MCP can't save files, and saving the whole place is refused.
3. Run `pesde run syncback -- --dry-run --list` to preview, then `pesde run syncback`. A different model goes after the `--`: `pesde run syncback -- path/to/Other.rbxm`. Rojo asks before writing, and `-y` skips that.
4. `assets/shared/` is tracked in git. Both generated projects map it to `ReplicatedStorage.Assets`, so `pesde run dev` serves it.

Rules: prefabs hold no scripts (code lives in `src/`). `syncback` refuses a file that isn't a single `Assets` folder, or that has scripts under it. Syncback (Rojo 7.7) writes a Model with children as a binary `.rbxm`, e.g. `assets/shared/Tiles/Ground.rbxm`, and only Folders become directories. So prefab diffs are opaque in git: review them in Studio. Still to confirm with a real prefab: how MeshParts, unions and SurfaceAppearances come out. `assets/shared/` is empty (and untracked by git) until the first syncback, and `generate` creates it.

Never edit `assets/shared/` by hand: the next syncback overwrites it. `assets.project.json` is generated.
