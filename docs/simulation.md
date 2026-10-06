# Simulation, owned movement and replays

## Why

Roblox characters are client-owned, so a client can walk through walls or run faster than it should. Instead of detecting that with thresholds, the server now **owns the game**: a client sends only what the player is doing (a numbered input per tick) and the server works out everything else. The same inputs and seeds always give the same result, on any machine, so a run can be recorded and replayed to check it.

Status: **steps 1 to 5 are built.** Hero movement, combat, enemies, loot, the world and the run are one pure simulation (`features/sim/modules/Sim`), and the services are thin adapters over it. A scripted run played twice gives the same state at every tick, and one fight is pinned to the same checksum in Lune and inside Roblox Studio. Steps 6 and 7 (run logs, a replay tool, `SIM_VERSION`) are still to do. See "What is left".

## The tick

`features/sim/modules/SimClock`: **20 ticks a second** (50 ms). Timers in simulation code count ticks (`SimClock.ticks(seconds)` rounds up), never `os.clock()`. Enemies, loot and the run no longer have clocks of their own: everything runs from `Sim.step`.

`SimServiceServer` steps the sim from `Heartbeat` with a fixed-step accumulator (at most 4 ticks per frame; a longer frame is not made up for later).

## One frame in, events out

```
Sim.step(state, frame) -> events
```

A `Frame` is the **only** way anything outside changes the sim, so a log of frames is a log of everything that happened:
- `inputs`: what each hero's player did this tick, by slot. A slot with no input doesn't step (its input hasn't arrived: the hero waits);
- `commands`: `join` (a hero enters, with slot, user id and hero def), `leave`, `startRun` (the run's two seeds) and `toLobby` (the results screen was left).

`Event`s are plain tables with a `kind` (`damage`, `died`, `spawn`, `drop`, `pickup`, `actGenerated`, `objectAdded`, `victory`, `teleport` ...). The sim never calls out, so replays ignore them; adapters turn them into network messages, Instances and saved data (`SimService.observe(kind, fn)`).

Order inside one step:
1. commands, in order;
2. heroes in slot order: `HeroSim` (move, cooldowns), then `HeroActions` (swing, dash, slam), then any object the input uses;
3. handle deaths (a hero going down, an enemy dropping loot);
4. `EnemySim.step` (wake groups, AI, attacks, projectiles, boss, spawns);
5. handle deaths again;
6. `LootSim.step` (expiry and pickups);
7. `RunSim.step` (the phase, camps, waves, teleporter, timers);
8. the tick counter moves on.

Deaths are queued by `CombatSim` and handled between the parts, so nothing runs inside a callback. Handling a death takes the enemy out, drops its loot and tells the run.

## The parts

| Module | Holds |
|---|---|
| `combat/modules/CombatSim` | Entities (heroes and enemies): HP, armor, i-frames (ticks), position. All damage goes through `applyDamage` |
| `heroes/modules/HeroSim`, `HeroMotion`, `HeroActions` | A hero's movement and cooldowns, and what its attacks hit |
| `enemies/modules/EnemySim` | Enemies, projectiles, camps, flow fields, crowd separation and the Siege Golem (a `StateMachine`) |
| `loot/modules/LootSim` | Drops on the ground, per hero slot |
| `world/modules/WorldSim` | The act (generated from the seed), its objects and camps |
| `run/modules/RunSim` | The phases of a run, difficulty, waves, rewards |
| `sim/modules/Sim`, `SimContext`, `Checksum` | The step, the shared tick, events and random streams, and the state hash |

Services in `features/*/…ServiceServer` only adapt: `HeroService` links players to slots and feeds inputs, `CombatService`, `EnemyService` and `LootService` send what the events say, `WorldService` builds the lobby and objects as Instances and holds heroes while the map loads, `RunService` picks the run's seeds and saves what players earn.

## Slots

Heroes in the sim belong to **slots** (1, 2, ...), never to a `Player`. `HeroService` gives a joining player the lowest free slot. Loot is owned by a slot, so co-op heroes each get their own copy.

## Hero input

`heroes/modules/HeroInput` is everything a client says about its hero for one tick: moving and a direction (1/256 turn), aim (1/65536 turn), attack, auto-target, the ability pressed (0 to 3) and an object being used. Six bytes on the wire, and any six bytes decode to a valid input (bit 2 of the first byte is unused and ignored).

The client numbers its inputs and sends the last 3 in every packet (`Hero.sendInputs`, unreliable). The server's `HeroInputQueue` uses them **in order, one per server tick**:
- sending faster doesn't move the hero faster;
- an input that is late makes the hero wait (it doesn't make one up), so its state after input N is what the client predicted whatever the latency;
- a gap that stays empty for 5 ticks is filled with "did nothing" and the client corrects itself.

## Movement and abilities

`HeroMotion` moves a hero (a 1.5 stud circle) on the nav grid one tick at a time: walking at the def's speed, sliding along walls, a dash that stops at walls. `HeroSim` wraps it with ability cooldowns, which count in the hero's own ticks (inputs used) so a client and the server never disagree on whether an ability is ready. The attack timer counts the same way, so a client can't swing faster.

The lobby has its own grid (`world/modules/LobbySpace`). Which grid a hero walks on is picked from where it stands.

## Prediction and corrections

The client runs the same `HeroSim` (see `HeroPrediction`) so the hero answers at once. Every tick the server sends `onHeroAck`: the state after input N. The client compares it with what it predicted after input N. If they match nothing happens. If not (a rejected ability, a teleport, a cheating client) it takes the server's state, replays the inputs since, and glides the drawn hero to the right place.

Other players' heroes come from `onHeroes` (positions every tick), drawn 120 ms in the past with `PoseBuffer`. Enemy snapshots go out every tick too, drawn 100 ms in the past.

The Roblox character is a puppet: anchored on the server, which never moves it, and placed every frame by each client. `HeroAnimator` plays idle and walk. Move input comes from `Humanoid.MoveDirection` (Roblox's own controls still feed it, so keyboard, thumbstick and gamepad all work; there is no `PlayerModule` to require in this place).

## Objects

Prompts only show and time the hold. When one triggers, the client puts the prompt's `InteractId` attribute in the next input. The sim (`WorldSim.use`) checks the object is enabled, not used up and within reach of the hero's **simulated** position, and `RunSim` applies what it does.

## Seeds and loot

A run has two seeds, both picked by `RunService` (the only randomness from outside the sim) and given to the sim in the `startRun` command:
- the **map seed**: act seeds derive from it, and clients are told the act seed so they build the same map;
- the **loot seed**: never leaves the server (act seeds are invertible, so they must not reveal it).

When an act is generated (`WorldSim.generate`), every camp member and object gets a `lootSeed` derived from the run's loot seed, in a fixed order. What an enemy drops is decided from its own seed when it dies: each hero slot rolls from `Rng.derive(lootSeed, slot)`. So drops don't depend on the order things die in, and heroes don't share rolls. Enemies that weren't placed at generation (waves, summons) take the next seed from the run's loot stream. A chest pays from its seed and the opening hero's slot.

Other randomness (crits, waves, where waves appear) comes from streams reseeded from the loot seed when the run starts (`SimContext`).

## Determinism rules

For anything the sim runs:
- time is a tick count, not `os.clock()`, `task.delay` or `Heartbeat`;
- random numbers come from `core/Rng` (the run's streams and seeds), never `math.random` or `Random.new()`;
- iterate arrays in a fixed order, never `pairs` over a dictionary that is used to decide something. Dictionaries are only looked up; the lists are ordered (heroes by slot, enemies by spawn, entities by registration, objects in the order they were made);
- no `math.sin`, `math.cos`, `math.atan2` or `^` with a fractional power: libm can round differently between Roblox, Lune and phones. Use `core/Angle` (whole-number angles, 65536 to a turn, sine from the literal tables in `core/TrigTables`, regenerate with `pesde run gentrig`) and loop multiplication. `Targeting`, `Populate` and the wave director use it too;
- only `+ - * /`, `math.sqrt`, `floor`, `min`, `max` and `abs`;
- the sim must not call out: no Instances, no network, no `task`. Everything it reports is an event.

`core/SpatialHash` keeps crowd separation and area attacks from checking every pair. A query visits cells in a fixed order and a cell lists points in the order they were inserted, so results come in the same order everywhere.

`Sim.checksum` hashes the whole state (heroes, entities, enemies, drops, the world, the run, the random streams) by the exact bits of every number.

Pinned values in `tests/Angle.spec.luau`, `tests/HeroMotion.spec.luau` and `tests/Sim.spec.luau` (a whole fight, checked against Roblox Studio too) match across runtimes. If a change moves them, old run logs no longer replay: bump `GenerateAct.VERSION` if the map changed.

## What is left

6. `RunLog` (seeds, roster, the input each hero used each tick, checkpoints from `Sim.checksum`), `Replay`, storage, and `pesde run replay`. The frames the adapters already build are what a log records.
7. Bump a `SIM_VERSION` whenever the simulation's outcome changes.

Known gaps in what is built: heroes of other players are drawn from snapshots and have only been tested alone in Studio (the sim itself runs several heroes in the specs); nothing adapts the client's tick rate to the server's if their clocks drift (the server skips old inputs after 13 queued, and the client corrects); the party's hold while a map loads (`HeroService.setFrozen`) is decided outside the sim, but it only turns inputs into "did nothing", which a log records.
