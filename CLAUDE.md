# Roblox template

Feature-based Roblox game template (Luau, pesde, Rojo, darklua). See [README.md](README.md) for setup.

@.agent/rules/code-guide.md

## Game design

This is a Hero Siege–style action roguelite. [docs/roadmap.md](docs/roadmap.md) holds the feature map and build order. Maps are generated from a seed: see [docs/world-generation.md](docs/world-generation.md) before touching `features/world`. Its determinism rules matter, because the server and clients must produce identical grids.

## Commands

pesde is installed in `~/.pesde/bin`. Run scripts with `pesde run <name>`:

- `check`: format check, selene, luau-lsp types and tests. Run it before finishing a change
- `format`: apply StyLua
- `test`: unit tests in `tests/*.spec.luau`
- `generate`: regenerate the Rojo project files and sourcemap (needed after adding, removing or renaming files in `src/`)
- `dev`, `build`, `compile`: see the README

Never edit `default.project.json`, `build.project.json` or `sourcemap.json` by hand. `tools/builder.luau` generates them.
