# Roblox template

Feature-based Roblox game template (Luau, pesde, Rojo, darklua). See [README.md](README.md) for setup.

@.agent/rules/code-guide.md

## Game design

This is a Hero Siege–style action roguelite. [docs/roadmap.md](docs/roadmap.md) holds the feature map and build order. Maps are generated from a seed: see [docs/world-generation.md](docs/world-generation.md) before touching `features/world`. Its determinism rules matter, because the server and clients must produce identical grids. Gameplay is one deterministic simulation (`features/sim/modules/Sim`, 20 Hz) over heroes, combat, enemies, loot, the world and the run, and the `*ServiceServer` files are adapters that turn its events into messages and Instances. Hero movement is owned by the server from numbered inputs. Read [docs/simulation.md](docs/simulation.md) before touching `features/heroes`, `combat`, `enemies`, `loot`, `run` or `world`, and keep sim code deterministic (no `os.clock`, `task`, `math.random`, `Random`, libm trig, or `pairs` over a dictionary that decides something). Bump nothing silently: a change that moves the pinned values in `tests/Sim.spec.luau` changes what a replay would compute.

## Commands

pesde is installed in `~/.pesde/bin`. Run scripts with `pesde run <name>`:

- `check`: format check, selene, luau-lsp types and tests. Run it before finishing a change
- `format`: apply StyLua
- `test`: unit tests in `tests/*.spec.luau`
- `generate`: regenerate the Rojo project files and sourcemap (needed after adding, removing or renaming files in `src/`)
- `syncback`: pull `ReplicatedStorage.Assets` from the saved Assets folder (`assets/places/Assets.rbxm`) into `assets/shared/`. Pass `-- --dry-run` to preview
- `dev`, `build`, `compile`: see the README

Never edit `default.project.json`, `build.project.json`, `assets.project.json` or `sourcemap.json` by hand. `tools/builder.luau` generates them.
