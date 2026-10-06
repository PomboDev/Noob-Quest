---
trigger: always_on
---

# Roblox Feature-Based Architecture Guide

This project uses a **functional and procedural pattern** organized by **feature**. Follow these rules for all code generation.

---

## 1. Directory Architecture

```
src/
├── core/                  # Game-agnostic framework layer
│   ├── Log.luau           # Leveled logging
│   ├── Loader.luau        # Feature discovery + init/start lifecycle
│   ├── Network/           # Schema-driven, batched networking (init.luau + helpers)
│   ├── DeltaCompress.luau # Binary table deltas (state replication)
│   ├── RateLimit.luau     # Per-key token buckets for client requests
│   └── StateMachine.luau  # Hierarchical state machine
├── features/              # Game logic, one folder per feature
│   └── [featureName]/     # camelCase
│       ├── FeatureNameControllerClient.luau
│       ├── FeatureNameServiceServer.luau
│       └── modules/       # Internal modules (never auto-loaded)
└── startup/               # Entry scripts (call Loader)
assets/shared/             # Prefabs for ReplicatedStorage.Assets, written by `pesde run syncback`, never edited by hand
    ├── Client.client.luau
    └── Server.server.luau
tests/                     # Lune unit tests (*.spec.luau), never shipped
tools/                     # pesde scripts: dev, build, compile, generate, syncback, check, format, test
```

| Directory | Purpose |
|-----------|---------|
| `src/core` | Reusable framework code with no game-specific knowledge |
| `src/features/[featureName]` | Everything one feature needs: client, server and shared modules |
| `src/startup` | Entry points; they only hand the `Features` folder to `Loader` |
| `tests` | Specs for the pure modules (`core/`, the build tools). Run with `pesde run test` |

Game data and types belong to the feature that owns them (e.g. `features/player/modules/PlayerData.luau`). Other features import them through `@Features/...`.

---

## 2. Naming & Routing Rules

The Rojo project files are **generated** from `src/` by `tools/builder.luau`. The file name decides where a module goes.

### File Naming (PascalCase)
- **Name ends with `Server`** → `ServerScriptService` (never replicated to clients)
- **Anything else** (including `*Client`) → `ReplicatedStorage.Source`

Routing matches the **suffix** only. `ObserverUtils` is shared and `NetworkServer` is server-only.

Files named `Server`, `Client`, `Utils` or `Types` take their folder's name as a prefix, so `combat/Server.luau` becomes `CombatServer` (server-only) and `combat/modules/Utils.luau` becomes `ModulesUtils` (the *immediate* folder, so prefer explicit names inside `modules/`). Two files that end up with the same instance name make `generate` fail, naming both.

### Folder Naming (camelCase)
- Feature folders: `combat`, `inventory`, `playerData`
- Internal folders: `modules`
- Folders become PascalCase instances (`playerData` → `PlayerData`; `ui` → `UI`)
- A folder containing `init.luau` becomes that module and Rojo maps its other files as children, keeping their file names (no prefixes). Files ending in `Server` inside it are carved out into `ServerScriptService` at the same path, so they never reach clients (`core/Network/NetworkServer.luau` is the example)
- Never put `Foo.luau` next to a `foo/` folder: luau-lsp resolves `require("Foo")` to the folder, and `generate` fails. Use `foo/init.luau`

### Examples
| File | Location |
|------|----------|
| `features/combat/CombatServiceServer.luau` | ServerScriptService.Features.Combat |
| `features/combat/CombatControllerClient.luau` | ReplicatedStorage.Source.Features.Combat |
| `features/combat/modules/CombatUtils.luau` | ReplicatedStorage.Source.Features.Combat.Modules |
| `features/combat/modules/DamageServer.luau` | ServerScriptService.Features.Combat.Modules |

---

## 3. Functional Pattern Requirements

### Core Principles
- **Favor statelessness**: modules export functions, not objects with state
- **No OOP patterns**: avoid `self` and colon-notation (`:`) in your own modules
- **Dot-notation only**: use `Module.function()`, not `Module:method()`
- **Pure functions when possible**: same input → same output

Exceptions: Roblox APIs, third-party packages (e.g. ProfileStore) and `Network` handles (`network:fire(...)`) use colon calls.

### Module Export Patterns

**Pattern A: Single Function (for utilities)**
```luau
--!strict

local function clamp(value: number, min: number, max: number): number
	return math.max(min, math.min(max, value))
end

return clamp
```

**Pattern B: Function Table (for utility modules)**
```luau
--!strict

local CombatUtils = {}

function CombatUtils.calculateDamage(baseDamage: number, multiplier: number): number
	return baseDamage * multiplier
end

return CombatUtils
```

**Pattern C: Feature Controller/Service (lifecycle)**
```luau
--!strict

local FeatureService = {}

-- Wire up networks, state and connections. Must not yield.
function FeatureService.init() end

-- Runs after every feature's init(). May yield and use other features.
function FeatureService.start() end

return FeatureService
```

---

## 4. Feature Lifecycle

`startup/*.luau` calls `Loader.load(Features, "Client" | "Server")` (the client waits for `game.Loaded` first, so every replicated module is there). The loader:

1. Requires every **direct child** of each feature folder whose name ends with the suffix (`modules/` is never auto-loaded)
2. Sorts the modules by name
3. Calls every `init()` synchronously. If one errors, it's logged and that feature's `start()` is skipped
4. Spawns every `start()`

Put anything that yields (`WaitForChild`, `Network.client`, DataStore calls) in `start()`, or in a spawned thread.

---

## 5. Feature Structure

```
src/features/inventory/
├── InventoryControllerClient.luau  # Client logic
├── InventoryServiceServer.luau     # Server logic
└── modules/
    ├── InventoryUtils.luau         # Shared utilities
    └── InventoryTypes.luau         # Shared types
```

### Server Module (`InventoryServiceServer.luau`)
```luau
--!strict

local Players = game:GetService("Players")

local Log = require("@Core/Log")
local Network = require("@Core/Network")
local Packet = Network.Packet

local InventoryService = {}

local network: Network.ServerNetwork

function InventoryService.init()
	-- Only methods listed here exist on the wire. A key that is also a function
	-- on InventoryService is callable by clients (the Player is passed first).
	network = Network.server("Inventory", InventoryService, {
		openInventory = {}, -- client -> server
		addItem = { Packet.String, Packet.NumberU16 }, -- client -> server
		onInventoryOpened = {}, -- server -> client
	})
end

function InventoryService.openInventory(player: Player)
	Log.debug(`{player.Name} opened inventory`)
	network:fireClient(player, "onInventoryOpened")
end

function InventoryService.addItem(player: Player, itemId: string, amount: number)
	-- Validate everything: client input is untrusted
end

return InventoryService
```

### Client Module (`InventoryControllerClient.luau`)
```luau
--!strict

local Log = require("@Core/Log")
local Network = require("@Core/Network")

local InventoryController = {}

local network: Network.ClientNetwork

-- Bound automatically: a function named like a schema method receives it.
function InventoryController.onInventoryOpened()
	Log.debug("Server confirmed inventory opened")
end

-- Not named after a schema method, so it is never bound as a receiver.
function InventoryController.open()
	network:fire("openInventory")
end

function InventoryController.start()
	-- Yields until the server registers "Inventory"
	network = Network.client("Inventory", InventoryController)
end

return InventoryController
```

### Networking Notes
- Service names are explicit and must match on both sides (`"Inventory"`)
- **Name server → client methods `on*`** (`onInventoryOpened`). `Network.client` binds every controller function named like a schema method, so a controller function that shares a name with a client → server method would also receive server messages
- On the server, `Network.server` runs in `init()`. On the client, `Network.client` yields until the server has registered the service, so it belongs in `start()`: the controller's `network` handle doesn't exist before that
- `fire`/`fireClient` batch per frame, the `*Unreliable` variants use an UnreliableRemoteEvent (may be dropped or reordered, and anything over ~900 bytes is dropped), and `*Immediate` sends at once, so it can **overtake** messages still waiting in the frame's batch
- A message for a service or method the client hasn't bound yet is **dropped**. Have the client ask for initial state once connected (`requestData` in `features/player`)
- `network:invoke` yields until the server handler returns, with no timeout. Return values use plain Roblox serialization, and a handler error is re-raised on the client
- Length limits: `String`/`Buffer` hold at most 255 bytes, `StringLong`/`BufferLong` at most 65535
- **Client input is untrusted.** Validate every argument and rate-limit anything expensive (see Rate Limiting below). An `Instance` argument may arrive as `nil` (not replicated, streamed out, destroyed), numbers may be NaN or infinite, and anything that isn't an Instance in the received list is turned into `nil`

Data types (`Network.Packet.*`):

| Type | Holds |
|------|-------|
| `NumberU8/U16/U32`, `NumberS8/S16/S32` | Integers; fractions truncate and out-of-range values wrap |
| `NumberF32`, `NumberF64` | Floats (F32 keeps ~7 digits) |
| `Boolean`, `String`, `StringLong`, `Buffer`, `BufferLong` | As named, with the limits above |
| `Vector2F32`, `Vector3F32`, `Vector3S16`, `CFrameF32`, `Color3` | Compact Roblox types (`Color3` is 8 bits per channel, `CFrameF32` has 16-bit angles) |
| `Instance` | Travels beside the buffer |
| `Any` | nil, boolean, number, string (≤255 bytes), Vector3 or Instance, tagged with its type: bigger on the wire than a fixed type |

### Replicating State
Follow `features/player`. The server owns the data and diffs it against a snapshot with `DeltaCompress.createDelta`, then pushes the delta as `Packet.BufferLong`. The client applies it with `DeltaCompress.applyDelta` into a Charm atom. Both sides build the `DeltaCompress` context from the same template.

- The first delta after `requestData` is a full sync. It must fit in one `BufferLong` (under 64 KB), so keep replicated data small
- The server only sends the snapshot's difference: always diff against a snapshot, never against the live table. `createDelta` returns the next snapshot as its second value, copied only where the data changed
- `PlayerService.updateData(player, mutate)`: `mutate` must not yield, since the change is sent once it returns
- Replicated values must be booleans, numbers, strings, tables, `Vector3`, `Color3` or `CFrame`

### Data Migrations
`PlayerData.TEMPLATE.schemaVersion` is the current data version. Adding a field needs nothing more: `Reconcile` fills it in on load. To rename, move or reshape a field that has shipped, append a function to `MIGRATIONS` in `features/player/modules/PlayerMigrations.luau` and bump `schemaVersion` in the same change. `MIGRATIONS[n]` turns version n data into version n + 1 in place.

- Migrations run when a profile loads, before `Reconcile`, on a copy: if one errors, the player is kicked and the saved data is left as it was
- Data saved by a newer version than the server knows (during a rollout) is never loaded
- Never edit or remove a migration that has shipped, and carry pending trades and auction escrows over

### Rate Limiting
`core/RateLimit` keeps one token bucket per key. Create a limiter per action at module level and check it first thing in the handler:

```luau
local requestLimit = RateLimit.new({ burst = 3, perSecond = 0.5 })

function TradeService.requestTrade(player: Player, ...)
	if not RateLimit.take(requestLimit, player) then
		return
	end
end
```

`{ burst = 1, perSecond = 1 / N }` is one request every N seconds. `RateLimit.take(limiter, key, cost)` charges more for heavier requests. Keys need no cleanup: buckets that have refilled are dropped.

### Purchases
`features/monetization` owns `MarketplaceService.ProcessReceipt`. Never set it anywhere else. Register in your feature's `init()`:

- `MonetizationService.registerProduct(productId, function(player, data, receipt) ... end)`: changes `data` to grant the product, must not yield. It runs once per purchase. If it errors, its changes are undone and Roblox retries later
- `MonetizationService.registerPass(passId, onOwned?)`: `onOwned(player)` runs once a player is known to own the pass (on join or after buying it). `MonetizationService.ownsPass(player, passId)` reads the cache
- Client: `MonetizationController.promptProduct` / `promptPass`, and `state.passes` (a Charm atom)

A purchase is reported granted only after a save holding its `PurchaseId` (in `data.receipts`) reaches the DataStore.

### StateMachine Notes
- Moving to the current state or one of its ancestors is *local*: states that stay active are not exited or re-entered
- `StateMachine.send` from an `enter`/`exit` callback is queued and runs right after the current transition (it returns `false` meanwhile). Guards must be pure
- `StateMachine.update` stops as soon as an `update` callback changes the state

### Exclusive Activities
Features a player must not use at the same time (trading, the auction house) each hold an activity lease from `features/playerState`:

- Take it with `PlayerStateService.acquire(player, activity)` (or `acquireAll` for several players at once, all or nothing). It returns `nil` unless the player is `Idle`
- Release it from every exit path with `PlayerStateService.release(lease)`. Releasing is idempotent and stale leases are ignored, and a player who leaves drops all their leases
- Wrap actions that must finish before the player is free in `beginTransaction` / `endTransaction`

Leases are a per-session rule, not what keeps goods safe. Anything that moves items or coins across profiles or servers escrows them in the player's data and commits through a DataStore `UpdateAsync` record, as `features/trade` and `features/auctionHouse` do (see `docs/auction-house.md`).

---

## 6. Luau Standards & Tooling

### Strict Mode
Start every file with `--!strict`.

### String Requires & Aliases
**ALWAYS** use string requires with aliases. **NEVER** use `require(script.X)`, relative paths or `game.ReplicatedStorage...` inside `src`. darklua rewrites aliases into instance paths at build time.

Aliases are defined in `src/.luaurc` and mirrored in `.darklua.json`:

| Alias | Path |
|-------|------|
| `@Core` | `src/core` |
| `@Features` | `src/features` |
| `@Packages` | `roblox_packages` (shared) |
| `@ServerPackages` | `roblox_server_packages` (server only) |

```luau
local Network = require("@Core/Network")
local PlayerData = require("@Features/player/modules/PlayerData")
local Vide = require("@Packages/vide")
local ProfileStore = require("@ServerPackages/profile-store")
```

### Logging
**ALWAYS** use `Log`, never `print()`/`warn()` directly.

| Function | Prints |
|----------|--------|
| `Log.debug` | Dev builds only (`pesde run dev`) |
| `Log.info` | Always |
| `Log.warn` | Always |

### Packages
UI: `vide`, `vide-ripple` (animation). State: `charm`, with `vide-charm` to bind atoms into Vide. Animation: `ripple`. Persistence: `profile-store` (server).

### Scripts (`pesde run <name>`)
| Script | Does |
|--------|------|
| `dev` | Dev build, darklua watch, `rojo serve`. Regenerates project files when files are added, removed or renamed |
| `build` | Release compile + `rojo build` → `game.rbxl` |
| `compile` | Release compile of `src/` → `out/` |
| `generate` | Regenerate `default.project.json`, `build.project.json`, `assets.project.json` and `sourcemap.json` |
| `syncback` | Pull `ReplicatedStorage.Assets` from the saved Assets folder (`assets/places/Assets.rbxm`) into `assets/shared/` |
| `check` | Everything CI runs: `generate`, StyLua `--check`, selene, luau-lsp type check, `test` |
| `format` | StyLua over `src`, `tools` and `tests` |
| `test` | Lune unit tests in `tests/*.spec.luau` |

Never edit the generated `*.project.json` files by hand. Run `pesde run check` before finishing a change; if you touch `src/core`, `tools/builder.luau` or the build pipeline, add or update a spec in `tests/`.

Strict-mode gotchas the checker enforces:
- `pcall`/`xpcall` of a function that returns nothing has no type for the error, so cast the callee: `pcall(fn :: any)`
- iterate a typed local, not `for _, v in list or {} do`

### Formatting Standards
- **Line endings**: Unix (LF)
- **Indentation**: Tabs (width: 4)
- **File names**: PascalCase
- **Folder names**: camelCase
- **Function names**: camelCase
- **Type names**: PascalCase

---

## 7. Anti-Patterns to Avoid

### ❌ OOP/Colon Notation in Your Modules
```luau
-- BAD
function Module:doSomething()
	self.value = 10
end

-- GOOD
function Module.doSomething(value: number): number
	return value
end
```

### ❌ Mutable State Exposed on the Module Table
```luau
-- BAD
Module.cachedData = {}

-- GOOD: keep state local; expose functions (or Charm atoms for reactive state)
local cachedData = {}
function Module.get(key: string)
	return cachedData[key]
end
```

### ❌ Yielding in `init()`
```luau
-- BAD
function Feature.init()
	local gui = Players.LocalPlayer:WaitForChild("PlayerGui")
end

-- GOOD
function Feature.start()
	local gui = Players.LocalPlayer:WaitForChild("PlayerGui")
end
```

### ❌ Direct `print`
```luau
-- BAD
print("Hello")

-- GOOD
Log.info("Hello")
```

---

## Quick Reference

| Concept | Convention |
|---------|------------|
| Server-only module | Name ends with `Server` |
| Client module | Name ends with `Client` |
| Feature folders | `camelCase` |
| File names | `PascalCase` |
| Lifecycle | `init()` (sync), then `start()` (may yield) |
| Function calls | Dot notation (`Module.func()`) |
| Strict mode | Required (`--!strict`) |
| Path aliases | `@Core/`, `@Features/`, `@Packages/`, `@ServerPackages/` |
| Logging | `require("@Core/Log")` |
| Indentation | Tabs (4 width) in Luau, 2 spaces in JSON/TOML/YAML/Markdown |
| Before finishing | `pesde run check` (format, lint, types, tests) |
