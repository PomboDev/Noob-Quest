# Roblox template

A feature-based Roblox game template: a small game-agnostic framework in `src/core`, one folder per feature in `src/features`, and a build pipeline that generates the Rojo projects from the layout of `src/`.

- **Language:** Luau, strict mode, formatted with StyLua and linted with selene
- **Packages:** managed by [pesde](https://pesde.dev) (Vide, Charm, Ripple, ProfileStore)
- **Build:** [darklua](https://darklua.com) turns `require("@Core/...")` aliases into instance paths, [Rojo](https://rojo.space) syncs and builds
- **Included:** feature loader (`init`/`start` lifecycle), schema-driven batched networking, binary delta replication, a hierarchical state machine, a token-bucket rate limiter, and a player-data feature (ProfileStore persistence with versioned migrations, replicated to a Charm atom, with a Vide UI example)
- **Monetization:** developer products granted exactly once (the purchase is recorded in the profile and acknowledged only after it saves) and cached game pass ownership
- **Example economy features:** dupe-safe player-to-player trading, a cross-server auction house (DataStore ledger, MemoryStore index, MessagingService broadcasts), and a player state manager that keeps the two from overlapping. The design and its failure handling are in [docs/auction-house.md](docs/auction-house.md)

## Requirements

- [pesde](https://pesde.dev/docs/installation) 0.7+: download the release for your system, run `pesde self-install` and add `~/.pesde/bin` to your `PATH`
- Roblox Studio with the [Rojo plugin](https://rojo.space/docs/v7/getting-started/installation/), matching the Rojo version pinned in `pesde.lock`
- Optional: VS Code with the [Luau Language Server](https://marketplace.visualstudio.com/items?itemName=JohnnyMorganz.luau-lsp) extension

```sh
export PATH="$PATH:$HOME/.pesde/bin" # in your shell profile
```

## Getting started

```sh
pesde install      # packages, plus the Lune engine and the dev tools (installed on first use)
lune setup         # Lune type definitions, for editing tools/ and tests/
pesde run dev      # dev build + watcher + Rojo server
```

Then open a place in Studio and connect from the Rojo plugin (default `localhost:34872`).

If the very first `pesde install` on a machine stalls or fails with "Waiting for existing installation process", stop it, run `rojo --version` once (that installs Rojo on its own) and run `pesde install` again. Several package scripts try to install Rojo at the same time otherwise.

## Scripts

Run with `pesde run <name>`.

| Script | Does |
|--------|------|
| `dev` | Dev build into `out/`, darklua watch, `rojo serve`. Regenerates the project files when files are added, removed or renamed |
| `build` | Release build → `game.rbxl` |
| `compile` | Release compile of `src/` → `out/` |
| `generate` | Regenerate `default.project.json`, `build.project.json`, `assets.project.json` and `sourcemap.json` |
| `syncback` | Pull `ReplicatedStorage.Assets` from the saved Assets folder (`assets/places/Assets.rbxm`) into `assets/shared/`. Optional arguments go after `--`: a model path, then flags such as `--dry-run`, which go to `rojo syncback` |
| `check` | What CI should run: `generate`, StyLua `--check`, selene, luau-lsp type check, `test` |
| `format` | StyLua over `src`, `tools` and `tests` |
| `test` | Lune unit tests in `tests/*.spec.luau` |

`check` downloads the Roblox type definitions once (`globalTypes.d.luau`) and generates selene's Roblox standard library (`roblox.yml`). Both are git-ignored.

## How it fits together

```
src/ ──darklua──▶ out/ ──Rojo──▶ Studio / game.rbxl
  │
  └─ generate ──▶ default.project.json + sourcemap.json (luau-lsp, darklua)
               └▶ build.project.json (Rojo)
```

1. You write modules in `src/` and require them by alias: `@Core`, `@Features`, `@Packages` and `@ServerPackages` (see `src/.luaurc`)
2. `generate` maps the layout of `src/` to a Rojo project, so there is no project file to edit by hand
3. darklua rewrites the aliases into instance paths (using the sourcemap) and injects `__DEV__`, which makes `Log.debug` print only in dev builds
4. Rojo serves or builds the result in `out/`

`assets/shared/` holds prefabs authored in a separate asset place. Both projects map it to `ReplicatedStorage.Assets`, and `assets.project.json` (tracked) lets `syncback` write only that folder.

`default.project.json` is tracked because tools that read the sourcemap need it right after cloning. `build.project.json`, `sourcemap.json` and `out/` are generated and ignored.

## Project layout

```
src/
├── core/        # game-agnostic framework: Log, Loader, Network, DeltaCompress, RateLimit, StateMachine
├── features/    # one folder per feature: *ControllerClient, *ServiceServer, modules/
└── startup/     # the two entry scripts, which hand features/ to Loader
tests/           # Lune specs for the pure modules and the build tools
tools/           # the pesde scripts
```

Routing is decided by file name: a file ending in `Server` goes to `ServerScriptService` (never replicated to clients), everything else to `ReplicatedStorage.Source`. See [the code guide](.agent/rules/code-guide.md#2-naming--routing-rules) for the details, including `init.luau` folders.

## Adding a feature

1. Create `src/features/inventory/` with `InventoryServiceServer.luau` and/or `InventoryControllerClient.luau`
2. Export a table with optional `init()` (sync, must not yield) and `start()` (may yield). `Loader` finds the module by its suffix and runs them: every `init()` first, then every `start()`
3. Talk across the network with `Network.server` / `Network.client` and a schema. To replicate state, follow `features/player`
4. Keep helpers in `features/inventory/modules/`: they are never loaded automatically
5. Run `pesde run check`

The full conventions are in [`.agent/rules/code-guide.md`](.agent/rules/code-guide.md). `CLAUDE.md` points Claude Code at the same file.

## Using it for a new game

Rename the package in `pesde.toml`, then replace `features/player/modules/PlayerData.luau` (the saved data shape), the example UI in `features/app/` and the `STORE_NAME` in `PlayerServiceServer.luau`. Everything in `src/core` is meant to stay as it is.
