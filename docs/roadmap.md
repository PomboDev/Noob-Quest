# Hero Siege clone: roadmap

## Context

The repo is a fresh copy of the feature-based Roblox template: core framework, player data, monetization, trade, auction house and playerState leases. The goal is a Hero Siege–style action roguelite with Risk of Rain run structure. It should be kid-friendly and play equally well on phone, tablet and PC.

This plan defines every feature folder, how the major systems work, and the build order. Phase 1 (the solo vertical slice) is detailed enough to implement. Phases 2–4 are scoped at the feature level and get their own detailed plan when we reach them.

Decisions taken:
- **Maps** are generated procedurally per act from a seed. First, points of interest are placed relative to the player spawn: teleporter, dungeon, angel and devil statues, other structures. Next, paths connect them. Last, Wave Function Collapse fills the remaining space. Only the tile and structure *prefabs* are authored in Studio, through the Studio MCP, and pulled into git with `rojo syncback` (Rojo 7.7 is installed and supports it).
- **Loot**: random-affix gear with base tiers and sockets, plus runes and runewords in the style of Diablo 2. Augment items (relics) go in a rotatable grid backpack instead of Hero Siege's lose-them-all-on-death relics.
- **First hero**: Warrior (melee).
- **Enemies**: the server simulates them as plain data, and clients render pooled models from snapshots.

---

## Feature map

| Feature (`src/features/…`) | Status | Phase | Owns |
|---|---|---|---|
| `player` | existing | 1→ | Profile and replication. Grows hero, gear, backpack and stash fields |
| `app` | existing | 1→ | Root ScreenGui. Mounts HUD components exported by other features |
| `monetization` | existing | 4 | Cosmetics, stash tabs, XP boost |
| `playerState` | existing | 3 | Leases. Adds lobby activities |
| `trade`, `auctionHouse` | existing | 4 | Rework for unique gear, plus safety gates |
| `camera` | new | 1 | Fixed top-down camera (client only) |
| `combat` | new | 1 | Entity registry (heroes and enemies), HP, damage, targeting, hit events |
| `heroes` | new | 1 (Warrior), 2 (Archer, Mage) | Class defs, auto-attack, abilities (dash + 1–2 skills), input and ability buttons |
| `enemies` | new | 1 | Server sim, AI, navigation, snapshots, client renderer and pool, boss patterns |
| `world` | new | 1 | Procedural act generation (POIs → paths → WFC), shared server/client map builder, nav grid, interactables (teleporter, chests, angel/devil statues, exit portal; dungeons in phase 2) |
| `run` | new | 1 | Run director: state machine, difficulty, wave director, teleporter charge, boss, results and rewards |
| `items` | new | 2 | Bases and tiers, affixes, item generation, sockets, runes, runewords, relics, backpack grid, stat aggregation |
| `loot` | new | 2 | Drop tables, per-player instanced drops, pickup |
| `inventory` | new | 2 | Bag, equipment and backpack UI (drag, rotate, socket), server-validated moves |
| `party` | new | 3 | Lobby, party, reserved-server teleport, scaling, downed and revive |
| `stash` | new | 4 | Account-wide storage, tabs |

Game data lives in the owning feature's `modules/` (e.g. `heroes/modules/HeroDefs.luau`). Pure logic goes in `modules/` with a spec in `tests/`.

---

## System design

### Camera and controls (`camera`, `heroes` client)
- The camera is Scriptable and bound with `BindToRenderStep` after the default camera. It sits at a fixed 57° pitch and fixed yaw, about 50 studs from `HumanoidRootPart`, with light smoothing and no zoom or rotate.
- Default `PlayerModule` movement (thumbstick, WASD, gamepad) stays. Move direction already follows the camera's fixed yaw.
- Mouse lock is disabled (`DevEnableMouseLock = false`) and zoom is clamped.
- **Two aiming modes**, picked from the last input device (`UserInputService.LastInputTypeChanged`), so a player on a touch laptop or with a controller plugged in switches seamlessly:
  - **Aimed (mouse and keyboard)**, modelled on Diablo 4's PC controls. WASD moves and the mouse aims, like a twin-stick shooter.
    - Hold **left mouse** to attack towards the cursor. The attack repeats at the swing speed and doesn't need a target.
    - Hold **Shift** to stand still while attacking (Diablo 4's "force stand still"), so the hero can hold a position without drifting towards enemies.
    - **Right mouse**, **Q** and **E** fire the skills. **Space** dashes towards the cursor.
    - A ring on the ground shows the aim point. The enemy under the cursor gets a `Highlight` outline.
  - **Auto-target (touch, and gamepad when the right stick is idle)**: the hero hits the nearest enemy in range and the player only moves. 2–3 large buttons (dash and one or two skills) have cooldowns. Twin-stick aiming doesn't work on a touchscreen, which is why touch keeps auto-target.
  - Gamepad: right stick aims, with the same auto-target as touch while it is idle.
- **Aim point:** the cursor ray is intersected with the horizontal plane at the hero's feet (pure maths, no raycast, which is accurate because the camera is fixed). The aim direction is hero → aim point on the XZ plane. A small snap radius (about 3 studs) pulls the aim onto the closest enemy near the cursor, like Diablo 4's soft targeting, so a click near an enemy doesn't miss because of perspective.
- Inputs are bound through `ContextActionService`. Vide draws the touch buttons, with radial cooldowns, and these replace the CAS touch buttons for size control. The same ability icons show the keybind on PC.

### Combat (`combat`)
- **Entity registry (server):** `{id, team, hp, maxHp, armor, position()}` for every hero and enemy. All damage goes through `CombatService.applyDamage(source, target, amount, kind)`.
- **Hero HP is ours, not the Humanoid's.** The Humanoid is never damaged, which keeps death, downed states and armor under our control. A hero at 0 HP is *downed*. In solo, downed means defeat.
- **Pure modules:** `CombatMath` (armor mitigation, crit, scaling) and `Targeting` (`nearest`, `inCone`, `inRadius` over position lists, plus `nearestToPoint` for the aim snap).
- **Client events:** `onDamage` is unreliable and batched (entity id, amount, crit) and drives damage numbers and hit flashes. `onHeroHealth` is reliable. Kills show a cartoon "poof" with no gore.

### Heroes (`heroes`)
- `HeroDefs` holds base stats, attack profile and ability ids. The first hero is the **Warrior**:
  - Basic attack is a melee cleave: a 100° cone, about 8 studs, centred on the aim direction (the nearest enemy's direction in auto-target mode).
  - **Dash** ("Charge"): about 20 studs, 4 s cooldown, damages along its path, towards the aim point (or the move direction when there isn't one).
  - **Ground Slam**: an AoE around the hero, about 14 studs, with a brief stun and an 8 s cooldown.
- **Attacking is a held state, not one request per swing.** The client sends `setAttack(active, angle, auto)` when the button goes down or up, and `setAim(angle)` (unreliable, at most 20 Hz) while the angle changes.
- The server runs the attack loop per hero: while the hero is attacking and the swing timer is up, it uses the aim direction (in auto mode it picks the nearest enemy instead and ignores the angle), applies cone damage, then fires `onHeroAttack(heroId, angle)` so clients play the swing and turn the hero that way. A swing with nobody in the cone still plays, as in Diablo.
- The server checks everything the client says: the angle is a finite number, requests are rate-limited, and the hero must be alive. The mode flag costs nothing to trust, since auto-target is the weaker mode.
- Facing: while attacking the hero turns to the aim direction, otherwise towards its move direction.
- **Abilities:** the client runs the dash movement immediately on its own character, since the player owns their character physics, using a short `LinearVelocity`. It then fires `useAbility(id, angle)`. The server validates the request (alive, cooldown, rate limit), applies damage and i-frames, and is the authority on cooldowns. Later ranged heroes (Archer, Mage) shoot projectiles along the aim direction and place AoEs at the aim point, clamped to the skill's range.

### Enemies (`enemies`)
- **Simulation:** the server holds each enemy as data (`id, defId, pos, vel, hp, state`) and ticks it at 20 Hz. No Humanoids or physics. The cap is about 40 alive enemies.
- **Navigation:** `world` derives the `NavGrid` straight from the generated tile grid, with no raycasting. Each tile declares a walkable sub-cell mask and a floor height, at 4-stud cells. A `FlowField` per hero is recomputed when the hero changes cell. Enemies follow the field toward the nearest hero, with separation steering. Both modules are pure and tested.
- **AI:** `EnemyDefs` sets behaviour per enemy: melee chaser, fast runner, or ranged spitter firing server-simulated projectiles. Every attack has a short *telegraph* (wind-up) to keep it fair and readable for kids. The boss runs a small `StateMachine` (core) with slam and summon patterns.
- **Replication:** `onSpawn(id, defId)` and `onDespawn(id)` are reliable. `onSnapshot` is unreliable at 15 Hz and packs u16 id plus `Vector3S16` position, about 40 × 8 bytes, well under the ~900-byte unreliable limit. `EnemySnapshot` is the pure codec and has a spec.
- **Client:** models are pooled from `ReplicatedStorage.Assets.Enemies`, with a greybox fallback. A 100 ms interpolation buffer smooths movement. The client handles hit flash, the death poof and the boss HP bar.
- Enemies don't physically block players. That's intended, and it keeps everything cheap.

### World generation (`world`)
Generation is a **pure, seeded** module set in `world/modules/`. It uses only `Random.new(seed)` and arrays, never iterating `pairs` over dictionaries, so the server and clients produce identical output from the same `(seed, actIndex, generatorVersion)`. Lune specs cover all of it.

The act is a tile grid: about 24×24 tiles of 12 studs, so roughly 288 studs across, sized per `ActDefs`. Generation has three steps, each its own module:

1. **`PoiLayout`**
   - The player spawn goes near an edge.
   - The rest are placed with seeded rejection sampling under constraints from `ActDefs`. Those constraints are minimum and maximum distance from spawn and from each other: the teleporter is far from spawn, statues sit mid-distance, and structures don't overlap.
     - teleporter(s)
     - dungeon entrance (phase 2)
     - angel statue(s) and devil statue(s)
     - chests
     - other structures
   - Each POI stamps a multi-tile **footprint** with fixed tiles into the grid.
2. **`PathCarver`**: connects spawn to every POI with seeded, wobbly paths (A* over the grid with noise costs). It pre-collapses those cells to path-compatible tiles, which guarantees the act is fully connected and walkable before WFC runs.
3. **`Wfc`**: fills every remaining cell from the `TileSet`.
   - Each tile has edge sockets per side, rotations, a weight, a walkable mask, a floor height and a prefab name.
   - Cells collapse by lowest entropy with seeded weighted choice and constraint propagation.
   - On a contradiction it restarts with a derived seed, up to N times, then falls back to filler tiles in the region that failed.
   - Afterwards, a decoration pass scatters props (trees, rocks) on non-path cells.

**Who holds what (memory):**
- The server keeps only the *logical* grid: tile ids, the walkable/nav data and the POI list.
- The server creates only gameplay Instances: teleporter, statues, chests, portal and their `ProximityPrompt`s.
- Clients receive `(seed, actIndex, version)` through `RunProtocol` and build the visual and collision geometry locally with the shared `MapBuilder`. It streams tiles in over several frames, nearest to the player first, from prefabs in `ReplicatedStorage.Assets.Tiles`/`Structures`.
- So the server never holds or replicates thousands of map parts, and switching acts means freeing the grid and regenerating.
- This works because Roblox characters are client-simulated, and enemies, projectiles and line of sight on the server use the nav grid rather than parts.
- Fallback: if a client-built map ever causes trouble, the server can run the same `MapBuilder`, which is a single switch.

**Prefabs and asset pipeline:**
- Tile and structure prefabs, plus enemy and VFX models, are authored through the Studio MCP in an asset place (`places/Assets.rbxl`, gitignored, not Rojo-connected). The MCP tools are `execute_luau`, `insert_asset`, `generate_procedural_model`, and `screen_capture` for review.
- The asset place is saved by hand in Studio (the MCP can't save files), then `pesde run syncback` pulls `ReplicatedStorage.Assets` into `assets/shared/`.
- Prefabs follow a contract: a fixed 12×12 footprint per tile, the pivot at the tile centre, and anchored. Structures declare their footprint size as an attribute. `TileSet` validates that every referenced prefab exists.
- Missing prefabs fall back to code-built greybox, so generation work never waits on art.
- **Builder changes** (`tools/builder.luau`):
  - map `ReplicatedStorage.Assets ← assets/shared` in both projects
  - generate `assets.project.json`, which contains only that folder, so syncback never touches code
- New `tools/syncback.luau` and a `syncback` script in `pesde.toml`. Add `!assets/**` to `.gitignore`, which currently ignores every `*.rbxm`. Avoid Terrain: there's one per place and it can't be scoped.

**Interactables** use `ProximityPrompt`, which is touch-friendly with large targets:
- teleporter
- chest: coins in phase 1, loot in phase 2
- **angel statue**: a blessing, a free run buff or a heal
- **devil statue**: a risk/reward deal, such as paying HP or summoning an elite pack for better rewards
- exit portal
- dungeon entrance: phase 2, an optional sub-area with an elite or mini-boss and loot

A kill plane returns fallen heroes to spawn.

### Run director (`run`)
- **`RunStateMachine`** (pure, tested): `Waiting → Generating → Exploring → Charging → Boss → ExitOpen → (next act | Victory)`, and any phase can go to `Defeat`. Each act gets a new seed on the same server. The next act's logical grid is generated while the exit portal is open, so the swap has no hitch.
- **`Difficulty`** (pure): a coefficient computed from elapsed minutes, act index and party size, in the style of Risk of Rain: `(1 + k·minutes·partyFactor) · 1.15^act`. It scales enemy HP and damage and the director's credit rate.
- **`WaveDirector`** (pure): a credit-based director. It earns credits per second, scaled by the difficulty coefficient, with a boost while charging. It spends them on enemy "cards" by cost and weight, never past the alive cap. The output is a list of spawn decisions, which the service places on walkable cells off-screen from the heroes.
- **Teleporter:** a prompt starts the charge. The charge fills (about 90 s at base) only while every alive hero is inside the ring, which is visible on the ground. At 100% the boss spawns at the teleporter. Killing the boss opens the exit portal.
- **Run state replication:** `RunProtocol` sends a full view on change (phase, map seed/act/version, charge %, timer, difficulty label, boss entity id, results), the same pattern as `TradeProtocol`.
- **Results:** coins and XP go through `PlayerService.updateData` at victory or defeat. Nothing a player picked up is ever lost. Phase 1 offers "Play again" on the same server.

### Items, gear, runewords and backpack (`items`, `loot`, `inventory`). Phase 2
- **Gear** is unique: `{uid, base, tier, rarity, ilvl, affixes: {[statId]: value}, sockets: {runeId | false}, runeword?}`.
  - Bases come in families (sword, axe, helm and so on) with **tiers** T1/T2/T3. Higher tiers unlock with act depth and, later, with difficulty levels in the style of Diablo 2's Normal, Nightmare and Hell.
  - Rarity is Normal, Magic (1–2 affixes), Rare (3–5) or Unique (fixed).
  - Affix pools are per slot. Each affix has value tiers gated by ilvl.
  - Values are rolled by seeded, pure `ItemGen` and stored explicitly, so later balance changes don't mutate existing items.
- **Runes** are stackable and live in the existing `inventory {[runeId]: count}`, so they trade and auction today without changes. Socketing is permanent, as in Diablo 2.
- **Runewords:** an exact ordered rune sequence in a *Normal* base with exactly that many sockets and an allowed slot type turns the item into a runeword with fixed bonuses. `Runewords` is pure and tested.
- **Relics** (augments) are unique `{uid, relicId, level}` items, each with a polyomino shape. They only work while placed in the **backpack**: a dedicated grid of about 4×3 that grows with account level, where relics are dragged and rotated in. Power is capped by grid space, not by hoarding, and nothing is lost on death. A later option is adjacency synergies (relics that buff neighbours). `BackpackGrid` (`canPlace`/`place`/`rotate`/`remove`) is pure and tested.
  - The backpack is a separate relic grid next to a normal slot-based gear bag. If the whole inventory should be a grid, the same `BackpackGrid` module covers it.
- **`HeroStats.compute`**(heroDef, equipped, placedRelics, blessings) is pure. It's the single place where stats are aggregated, and the server applies it to the hero's combat entity.
- **Loot** is per-player instanced: each player sees and gets their own drops, so co-op has no loot stealing. Coins and runes are picked up automatically. Gear is picked up with a tap and shows a rarity beam.
- **Inventory UI** works on touch through tap-to-select, then tap a cell, plus a rotate button. Every move is validated on the server.

### Co-op (`party`). Phase 3
- A lobby place handles party forming among friends. The leader starts the run with `TeleportService:ReserveServer` + `TeleportAsync`, passing the party list in TeleportData. The run server waits for the expected members, with a timeout.
- Phase 3 needs **multi-place tooling**: one project per place sharing `src/`, with place-specific features.
- Enemy HP and director credits scale with party size. Solo is a party of one, so the code path is the same.
- **Downed and revive:** a teammate holds a `ProximityPrompt` to revive, there's a bleed-out timer, and a downed player gets a spectate camera. If every hero is down, the run ends in defeat.
- Trade and auction are lobby-only, guarded by `playerState` leases.

### Meta, safety and monetization. Phase 4
- **Stash:** an account-wide stash in the lobby. Extra stash tabs are a monetized convenience.
- **Replication:** the player data full sync must stay under 64 KB. The stash should replicate on demand (when opened) rather than inside the player-data delta, and gear records should stay compact.
- **Trade and auction for unique gear:** offers and escrow carry gear uids with their full records, auction ledger records hold item data, and the index filters by base, rarity and affix. The escrow and ledger dupe-safety model is unchanged.
- **Safety:**
  - Trade is limited to friends, or to accounts at least N days old.
  - The auction house requires an account age and a minimum level.
  - The trade confirm screen shows full tooltips. Both sides must be ready, and the existing countdown applies.
  - Paid cosmetics can't be traded.
  - There's no custom text input. Auction search uses filters.
  - Roblox chat filtering is unchanged.
- **Monetization:** hero skins, stash tabs and XP boost, all through the existing `MonetizationService.registerProduct`/`registerPass`. Nothing grants power: no paid backpack space, runes or gear.

---

## Phase 1: vertical slice (solo, Warrior, one act)

Order matters. Each step ends with `pesde run check` green.

1. **Docs:** write `docs/roadmap.md` (this design) and `docs/world-generation.md` (the three generation steps, the tile and prefab contract, the MCP asset workflow). Add a short "World and assets" pointer to `CLAUDE.md`.
2. **World generation core:**
   - pure `world/modules/`: `ActDefs`, `TileSet` (greybox tiles first: ground, path, cliff edge and corner, water, plus POI footprints), `PoiLayout`, `PathCarver`, `Wfc`, `Decorate`, `GenerateAct` (runs all three steps)
   - specs for: determinism (same seed gives an identical grid), POI distance constraints honoured, every POI reachable from spawn, no socket mismatches, and contradiction fallback
   - This step has no Roblox dependency, so it's built and tested first.
3. **Asset pipeline:**
   - extend `tools/builder.luau` (the Assets root and `assets.project.json`)
   - add `tools/syncback.luau` and the `syncback` script
   - add the `.gitignore` exception
   - update `tests/Builder.spec.luau`
   - **Verify early:** author one tile prefab through the MCP, save it, syncback, and check that `pesde run dev` shows it. This checks how syncback represents MeshParts and unions; any instance it can't express becomes an `.rbxm`.
4. **`camera`:** `CameraControllerClient.luau`, with mouse lock and zoom locked. Its ray-to-ground maths lives in the heroes aim module below.
5. **`combat`:**
   - `CombatServiceServer`, `CombatControllerClient`, which handles damage numbers via pooled BillboardGuis, hit flash and poof
   - `modules/CombatMath`, `modules/Targeting`, plus specs
6. **`heroes`:**
   - `HeroServiceServer`, which registers the hero entity on spawn and runs the attack loop and abilities
   - `HeroControllerClient`, which picks the aim mode from the last input device, handles input, local dash and swing visuals, the aim ring and the enemy highlight
   - `modules/HeroDefs`, with the Warrior only
   - `modules/Aim`: pure maths on plain numbers (so Lune can test it): `groundPoint` intersects a ray with a horizontal plane and `angleTo` turns a point into an aim angle. The soft target uses `Targeting.nearestToPoint`
   - `modules/AbilityButtons` (Vide)
   - specs for `Aim`, and for the server's attack input handling (rejects NaN angles, repeats while held, stops on release, auto mode ignores the angle)
7. **`enemies`:**
   - `EnemyServiceServer`, which handles sim, AI, telegraphs and the boss
   - `EnemyControllerClient`, which handles the pool and interpolation
   - `modules/EnemyDefs`: grunt, runner, spitter and the "Siege Golem" boss
   - `modules/NavGrid`, `modules/FlowField`, `modules/EnemySnapshot`, plus specs
8. **`world` runtime:**
   - `WorldServiceServer` holds the logical grid and nav grid, spawns the gameplay Instances (teleporter, chests, angel and devil statues, portal) and the kill plane
   - `WorldControllerClient` builds the map locally from the seed via `modules/MapBuilder`: it streams nearest tiles first and uses the greybox fallback
   - Then build Act 1's first real tile and statue prefabs through the MCP.
9. **`run`:**
   - `RunServiceServer`, `RunControllerClient`
   - `modules/RunStateMachine`, `modules/Difficulty`, `modules/WaveDirector`, `modules/RunProtocol`, plus specs
   - rewards via `PlayerService.updateData`
10. **HUD**, mounted in `app/AppControllerClient.luau`:
   - hero HP bar, ability buttons, timer and difficulty
   - teleporter charge, boss bar
   - the victory/defeat results screen with "Play again"
   - The existing coins label stays.

Reuse:
- `core/StateMachine` for the run and boss
- `core/Network` (`fireAllClientsUnreliable` for snapshots, `Packet.Vector3S16`/`NumberU16`)
- `core/RateLimit` for `useAbility` and interact requests
- `core/DeltaCompress` for `RunProtocol`, following the `trade/modules/TradeProtocol.luau` pattern
- `PlayerService.updateData`/`observeLoaded` for rewards and spawning

No player-data reshape in phase 1. Rewards use the existing `coins`/`level`/`xp`, so no migration is needed.

## Phases 2–4 (detailed plans later)
2. **Classes and loot:** Archer and Mage (projectile path), a hero select screen with per-hero level and XP, then `items`, `loot` and `inventory` as designed above, plus dungeon entrances (a generated sub-area using the same three-step generator with a dungeon `TileSet`). New data fields only (`gear`, `bag`, `equipped`, `backpack`, `relics`, `heroes`, `selectedHero`), which need no migration.
3. **Co-op:** multi-place tooling, the lobby, `party`, reserved servers, scaling, downed and revive, spectate.
4. **Meta:** stash and on-demand replication, the trade and auction rework for gear with safety gates, monetization.

---

## Verification
- `pesde run check` after each step: format, selene, luau-lsp and the specs for every pure module listed above.
- **Play-test through the Studio MCP:**
  - run `pesde run dev` and connect Rojo
  - `start_stop_play`
  - drive the character with `character_navigation`/`user_keyboard_input`
  - read `get_console_output` and check visuals with `screen_capture`
- **Slice acceptance:** spawn into a generated Act 1 (different each run, always connected). The angel and devil statues work. Auto-attack kills grunts, dash and slam work with cooldowns, find and activate the teleporter, waves intensify while charging, the boss spawns at 100%, killing it opens the portal, the victory screen grants coins and XP (they persist after a rejoin), dying shows the defeat screen, and "Play again" resets.
- Check mobile in Studio's device emulator: touch buttons are large and the camera and thumbstick feel right.
- Performance:
  - Act generation time is logged in dev, with a target under 200 ms on the server, spread across frames if needed.
  - The client map build doesn't hitch.
  - Server memory doesn't grow across several act swaps.
  - 40 enemies alive, unreliable snapshots stay under 900 bytes (log the size in dev), and server heartbeat stays stable.

## Risks / to confirm during implementation
- **Syncback fidelity** (MeshPart, SurfaceAppearance, unions) is checked in step 2 before any real map work.
- **Generation determinism across server and client** is the core assumption of client-built maps. It's covered by specs and a dev-only check: the client hashes its grid and the server compares that hash with its own. If they differ, it logs a warning and the server builds the map itself.
- **Client-only collision geometry:** exploiters could already noclip with client-owned characters, and server sanity checks (below) cover both.
- The asset place must be saved by hand in Studio. The MCP can't save files.
- Character movement is client-authoritative, as everywhere in Roblox. Add server speed and teleport sanity checks before co-op.
