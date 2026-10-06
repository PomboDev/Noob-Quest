# Auction house and player state

How the global auction house and the player state manager work, and why no crash, disconnect, timeout or race can duplicate or destroy items or coins.

Code:

- `src/features/auctionHouse/`: the auction house
- `src/features/playerState/`: the player state manager
- `src/features/trade/`: the existing trade feature, which now takes a lease from the state manager

## Contents

1. [Principles](#1-principles)
2. [Components](#2-components)
3. [Player state machine](#3-player-state-machine)
4. [Data model](#4-data-model)
5. [Transaction lifecycles](#5-transaction-lifecycles)
6. [Races and failures](#6-races-and-failures)
7. [Limits and capacity](#7-limits-and-capacity)
8. [Configuration](#8-configuration)
9. [Testing](#9-testing)

## 1. Principles

**One source of truth per listing.** Every listing has one DataStore key holding its record. All changes to it are `UpdateAsync` transforms (`AuctionRecord`). `UpdateAsync` is compare-and-swap: if another server wrote first, Roblox reruns the transform on the new value. Two conflicting changes therefore never both apply, whichever servers send them. The step that turns a record from `active` into `sold` is the moment of sale.

**Goods are always somewhere specific.** At every moment an item or coin is in exactly one place: an inventory, the coin balance, or an escrow entry in a profile. Escrow entries are saved with the profile, and an outcome is applied by removing the entry in the same `updateData` mutation that credits the result. Applying an outcome twice therefore finds no entry the second time and does nothing.

**Disk before commit.** Nothing outside the server can depend on an escrow until the save holding it has been confirmed (`PlayerService.saveAsync`):

- a listing is only published once the seller's escrow is saved
- a sale is only committed once the buyer's escrowed coins are saved

A crash before that point loses only unsaved changes, which nothing else has seen.

**Unknown is not failure.** A DataStore call that times out may still have been applied. The code never assumes either way. It retries the same idempotent transform, or it decides with a transform that settles the question for good (`voidUnpublished`, `resolvePurchase`).

**MemoryStore and MessagingService only add speed.** The index, purchase leases and broadcasts can be lost, stale or down without breaking correctness. Every decision is checked against the ledger.

**Activity locks are per session.** ProfileStore already guarantees a profile is live on one server at a time, so the trade/auction lock lives in server memory and dies with the player's session. It can never dangle.

## 2. Components

```
              client                                    server
┌─────────────────────────────┐      ┌──────────────────────────────────────────────┐
│ AuctionHouseController      │◀────▶│ AuctionHouseService (orchestration)          │
│ PlayerStateController       │◀─────│ PlayerStateService (activity leases)         │
│ TradeController             │◀────▶│ TradeService (takes "Trading" leases)        │
└─────────────────────────────┘      │                                              │
                                     │ AuctionEscrow ── PlayerService (ProfileStore)│
                                     │ AuctionRecord ── AuctionLedger (DataStore)   │
                                     │ AuctionIndex (MemoryStore sorted/hash maps)  │
                                     │ AuctionBroadcast (MessagingService)          │
                                     └──────────────────────────────────────────────┘
```

| Module | Side | Role |
|--------|------|------|
| `playerState/modules/PlayerStateMachine` | shared, pure | State machine and lease rules for one player, built on `@Core/StateMachine` |
| `playerState/PlayerStateServiceServer` | server | One slot per player: `acquire`, `acquireAll`, `release`, `beginTransaction`, `endTransaction`, `getState`. Replicates the state to the owner |
| `auctionHouse/modules/AuctionProtocol` | shared, pure | Limits, the fee, the `Summary`/`Page` wire types, cursors, sort keys |
| `auctionHouse/modules/AuctionRecord` | shared, pure | The ledger record and every transform: `publish`, `voidUnpublished`, `commit`, `resolvePurchase`, `cancel`, `expire`, `reprice` |
| `auctionHouse/modules/AuctionEscrow` | shared, pure | Escrow in a profile: `openListing`/`settleListing` and `openPurchase`/`settlePurchase` |
| `auctionHouse/modules/AuctionLedgerServer` | server | DataStore `AuctionLedger`: `read` (uncached) and `update` (retries, request budget, user ids for GDPR) |
| `auctionHouse/modules/AuctionIndexServer` | server | MemoryStore browsing index and purchase leases |
| `auctionHouse/modules/AuctionBroadcastServer` | server | MessagingService topic `AuctionHouse` |
| `auctionHouse/AuctionHouseServiceServer` | server | Network handlers, the transaction flows, reconciliation, background sweep |

In Studio without API access, ProfileStore uses mock profiles, and the ledger, index and broadcasts switch to in-memory stand-ins to match (`AuctionLedger.isMock`).

## 3. Player state machine

```
Loading ──Loaded──▶ Idle ⇄ Trading              BeginTrade / EndTrade
                     ⇅                          OpenAuction / CloseAuction
                  Auction
                  ├─ Browsing ⇄ Transacting     BeginTransaction / EndTransaction
                  └─ Transacting ──▶ Idle       EndTransaction, if a close was requested
```

| State | Meaning | Can trade | Can use the auction house |
|-------|---------|-----------|---------------------------|
| `Loading` | Joined, profile not loaded yet | no | no |
| `Idle` | Free | can start | can open |
| `Trading` | In a trade session, from open through settlement | yes | no |
| `Browsing` | Auction house open | no | browse, and start one action |
| `Transacting` | An auction action (list, cancel, reprice, buy) is running | no | no new action |

**Leases.** `acquire(player, activity)` succeeds only from `Idle` and returns a lease `{ player, id }`. Lease ids increase with every acquisition, and every call that changes or ends the activity must present the current one. As a result:

- **Releasing is idempotent.** A second release, or a release with an old lease, does nothing. A trade that closes twice, or an idle timeout racing a close, can't end a newer hold.
- **Pairs are atomic.** `acquireAll({a, b}, "Trading")` takes both leases with no yield in between, or takes neither.
- **Closing waits for the running action.** Releasing the auction lease during `Transacting` only sets `closeRequested`. The player stays locked until the action finishes, then moves straight to `Idle`. Mid-purchase, they can't start or accept a trade.

**Server authority.** Clients only ask (`openAuction`, `closeAuction`, trade requests). The server decides and pushes the result (`PlayerState.onStateChanged`, coalesced once per frame). A repeated `openAuction` while already open just replies `ok`.

**Recovery.**

- **Disconnect, kick or crash:** `PlayerRemoving` drops the slot, which invalidates every lease the player held. Features release from their own exit paths too, harmlessly.
- **Server crash:** the slots are gone with the server. Nothing persistent was locked.
- **A client that stops talking:** an open auction house with no requests for `IDLE_TIMEOUT` (5 min) is released by the sweep, so a client whose UI died can't hold the lock forever. A restarted client calls `requestState` to resync.
- **Trades settling when a player leaves:** the trade keeps settling through its own ledger, and the remaining player stays `Trading` until the session closes.

The locks enforce the rule that trading and the auction house never overlap. They are not what keeps goods safe: escrow does that. Both are kept so each one is simple and either is enough on its own.

## 4. Data model

### Profile (`PlayerData.auction`)

```luau
auction = {
	-- Seller escrow: the items left the inventory when listed.
	listings = { [listingId]: { itemId, amount, price, createdAt, expiresAt } },
	-- Buyer escrow: coins held for one purchase attempt.
	purchase = { id, listingId, itemId, amount, price, version }?,
}
```

`price` in a listing entry is for display only. Proceeds come from the ledger record's price at the moment of sale. Profiles with listings or a purchase in escrow settle them on load, so these entries are also the deferred claims: anything that couldn't be delivered right away arrives on the next join.

### Ledger record (DataStore `AuctionLedger`, key `Listing_{guid}`)

```luau
{
	id, status, sellerId, itemId, amount, price, version, createdAt, expiresAt,
	closedAt?, buyerId?, purchaseId?,
	voided?, -- purchase ids resolved as lost while active
}
```

```
(none) ──publish──────────▶ active ──commit──▶ sold
(none) ──voidUnpublished──▶ void      ├─cancel──▶ cancelled
                                      ├─expire──▶ expired
                                      └─reprice─▶ active (new price, version + 1)
```

Only `active` ever changes. A server that reads any other status can act on it without writing. Records are kept forever as the auction house's history, tagged with the seller's and buyer's user ids for erasure requests.

| Transform | Applies when | Outcomes |
|-----------|--------------|----------|
| `publish(record)` | no record | `published`, or `void` if voided first |
| `voidUnpublished(record)` | no record | `void`, or the status of the record that exists |
| `commit(request)` | active, unexpired, not the buyer's own, matching price, version and goods, purchase not voided | `won` (also on a retry after it already won), `sold`, `closed`, `expired`, `changed`, `own`, `voided`, `missing` |
| `resolvePurchase(id)` | always decides | `won` if sold to this id. Otherwise `lost`, fencing the id into `voided` while active |
| `cancel(sellerId)` | active, own | `cancelled`, or whatever got there first (`sold` means the seller is paid instead) |
| `expire(now)` | active and past `expiresAt` | `expired`, or the current status |
| `reprice(sellerId, price)` | active, own, unexpired | `repriced` (version + 1, idempotent at the same price) |

### Index (MemoryStore)

| Structure | Key | Sort key | Value | Used for |
|-----------|-----|----------|-------|----------|
| Sorted map `AuctionByItem` | listing id | `hex(itemId) .. ":" .. %010d price` | `Summary` | One item's listings, cheapest first |
| Sorted map `AuctionRecent` | listing id | `createdAt` | `Summary` | Every listing, newest first; lookup by id |
| Hash map `AuctionLocks` | listing id | | `{ purchaseId }` or `{ released }` | Purchase leases (60 s) |

Each entry expires when its listing does. Item ids are hex-encoded in the sort key so that the exclusive bounds `hex..":"` and `hex..";"` contain exactly one item's entries, whatever characters the id uses. Pages are cursor-based (`"{kind}{sortKey}|{listingId}"`), so listings added or removed between pages don't shift the results. The server checks every cursor a client sends back.

### Broadcast (MessagingService topic `AuctionHouse`)

`{ server, message = { kind, id, sellerId, itemId, price, version } }`, where `kind` is one of `listed | repriced | sold | cancelled | expired`. Messages are delivered on the sending server immediately, and its own echo is dropped. A receiving server reconciles the listing if the seller is online there, pushes `onListingChanged` to everyone with the auction house open, and clears its page cache.

## 5. Transaction lifecycles

Every action runs inside `transact`, which:

- checks the lease, the shutdown flag and the cooldown
- moves the player to `Transacting`
- runs the flow under `pcall`, then always ends the transaction and replies `onResult(action, listingId, result)`

The seller's own listing is also marked busy on this server for the duration, so reconciliation never races the flow that is publishing or cancelling it.

The "if the server dies here" column assumes the worst: the server dies at that point and the player rejoins elsewhere.

### List

| Step | What happens | If the server dies here |
|------|--------------|------------------------|
| 1. Escrow | `openListing`: validate (`isItemId`, amount, price, `MAX_LISTINGS`, ownership) and move the items into `auction.listings[id]` in one mutation | The unsaved escrow is lost. The items are still in the inventory, and no record exists |
| 2. Persist | `saveAsync` until the saved copy holds the entry | Same as step 1, or the save landed: an entry with no record, which reconcile voids and refunds |
| 3. Publish | `publish(record)`. If step 2 failed, `voidUnpublished(record)` instead, because that save may still land | The record is active (the listing is live and the escrow is on disk), or void, or absent. Reconcile handles all three |
| 4. Index, announce | `AuctionIndex.put`, broadcast `listed` | The listing is live but missing from the index. The next reconcile re-indexes it |

If the outcome of step 3 is unknown, the reply is `delayed` and a reconcile runs 30 s later: it voids the listing unless the publish landed.

### Buy

| Step | What happens | If the server dies here |
|------|--------------|------------------------|
| 1. Lease | `AuctionIndex.lock(listing, purchaseId)`. Fails fast with `busy` if someone else holds it, and proceeds anyway if MemoryStore is down | Nothing changed. The lease expires |
| 2. Check | Read the record (uncached) and dry-run `commit` on it | Nothing changed |
| 3. Escrow | `openPurchase`: coins into `auction.purchase` | The unsaved escrow is lost, and the coins stay |
| 4. Persist | `saveAsync`. On failure, refund at once: no commit was sent, so nothing can have been bought | The token was saved or not. On load, `resolvePurchase` voids it and refunds |
| 5. Commit | `commit(request)`: active → sold, naming `purchaseId` | Sold to this id, or not. On load, `resolvePurchase` delivers the items or refunds |
| 6. Settle | Won delivers the items, anything else refunds. Remove from the index, broadcast `sold`, unlock | The token is still saved, and the load settles it the same way |

**Seller payment.** The seller is paid when their own profile reconciles the listing:

- immediately, if they're on any server that receives the `sold` broadcast
- within `RECONCILE_INTERVAL`, if the broadcast was lost
- on their next join, if they're offline

**Unknown commit.** If step 5's outcome is unknown, the reply is `delayed` and a background loop retries `resolvePurchase` every 30 s while the buyer holds the token on this server. The buyer can't start another purchase meanwhile (`pending`).

### Cancel, reprice, expire

- **Cancel:** the `cancel` transform, then settle whatever the record now says. If a buyer won first, the seller gets the proceeds instead of the items. A listing whose publish never landed (`missing`) is voided and refunded.
- **Reprice:** the `reprice` transform (10 s cooldown per listing) bumps the version, then updates the display price, the index and the broadcast. Purchases started at the old price fail with `changed` and are refunded. No one is ever charged a price they didn't see.
- **Expire:** buyers can't commit after `expiresAt` (checked inside `commit`), and the index entries expire on their own. When the seller's escrow passes `expiresAt`, the sweep reconciles it: `expire` and return the items. An offline seller gets them back on their next join.

### Reconciliation

`reconcileListingAsync(player, listingId)` makes one escrow entry agree with the ledger:

| Ledger says | Action |
|-------------|--------|
| no record | `voidUnpublished`, then refund (or keep, if the publish landed meanwhile) |
| active, expired | `expire`, broadcast `expired`, refund |
| active | Re-index if missing or stale (version check) |
| sold | Pay proceeds (price minus fee) |
| cancelled / expired / void | Return the items |

It runs:

- on load
- on a broadcast for an online seller
- on `openAuction`, at most every 30 s
- every 5 min in the sweep
- right away in the sweep for expired entries
- 30 s after an undecided create or cancel

Pending purchases are resolved on load, after an undecided commit, and by the sweep for any token no flow is handling.

## 6. Races and failures

| Scenario | Resolution |
|----------|------------|
| Two buyers on different servers, same listing | The MemoryStore lease usually stops the second before it escrows anything. If both get through (lease expired, MemoryStore down), both commits reach the same key: compare-and-swap applies the first (`won`), and the second's transform reruns on the sold record (`sold`) and is refunded |
| Two buyers on the same server | Same as above. Each player also runs one action at a time |
| Buyer vs seller cancel | One `UpdateAsync` key: whichever lands first wins. A buyer who loses is refunded. A seller who loses is paid |
| Buyer vs expiry | `commit` refuses at or after `expiresAt`, and `expire` only applies from `expiresAt`. Exactly one applies |
| Buyer vs reprice | `commit` requires the price and version the buyer saw: `changed`, refund |
| A commit's reply is lost (timeout after the write) | Retrying the same commit finds `sold` to this `purchaseId` and reports `won`. `resolvePurchase` also reports `won` |
| A late commit after the buyer was refunded elsewhere | The old server is still retrying a commit when the player rejoins on a new server, which resolves the token. `resolvePurchase` writes the `purchaseId` into `voided`, and `commit` refuses voided ids. Exactly one of "sold to this id" and "refunded" ever happens |
| Seller crashes between saving the escrow and publishing | Escrow saved, no record. Reconcile writes `void` (which `publish` can never overwrite) and refunds. An old server's publish still in flight is serialized against the void on the same key |
| A seller's save times out but lands later | The flow voids instead of publishing, and the landed escrow is refunded by reconcile |
| Buyer disconnects mid-purchase | The flow continues without them, since everything it needs is in the ledger and the saved token. `settlePurchase` finds no profile, and the next load settles the token |
| Session stolen (old server unresponsive) | A token is only acted on after its save is confirmed, so the stolen copy has it. In-memory settlements the old server made are lost with its session and redone from the ledger on the new one |
| Server shutdown | `BindToClose` refuses new actions and waits up to 25 s for running ones. ProfileStore saves every profile. Anything still undecided is settled on the next load |
| DataStore down | Listing: `delayed`, voided or confirmed later. Purchase before commit: refunded. Purchase during commit: resolved in the background. Cancel/reprice: `failed`, nothing changed (or, if the write did land, reconcile settles it) |
| MemoryStore down | Browsing fails (`failed`) and leases are skipped. Purchases, listings and settlements still work through the ledger. Missed index updates are repaired by reconcile and by failed purchases (stale entries are removed) |
| MessagingService down or a message lost | Sellers are paid by the periodic or join-time reconcile instead of instantly. Open pages update on the next search |
| Clock skew between servers | Expiry is decided by the clock of the server running the transform. A few seconds of skew only moves the cutoff, and buy vs expire is still exclusive on one key |
| Client exploits | Every argument is validated: integer ranges, UTF-8 item ids of at most 50 bytes, GUID listing ids, cursors. Rate limits apply per player (browse 0.5 s, actions 1 s) and per listing (reprice 10 s). Ownership is checked against the profile and inside the transforms (`forbidden`, `own`). The client never names a price it isn't charged |

## 7. Limits and capacity

| Service | Limit | Effect here |
|---------|-------|-------------|
| DataStore requests | 60 + 40 × players per minute per server, per request type | Every ledger call waits for budget (up to 10 s). A listing costs one write to publish and one to close. Reconcile reads at most `MAX_LISTINGS` keys per seller every 5 min |
| DataStore key | 50 characters | `Listing_` + a 36-character GUID = 44 |
| MemoryStore memory | 64 KB + 1.2 KB × users, per experience | Each listing is stored twice (~150 bytes each). Keep `MAX_LISTINGS` × active sellers well under the quota |
| MemoryStore requests | 1000 + 120 × users per minute, per experience. `GetRangeAsync` costs one per item returned | Pages are 20 items. A 3 s per-server page cache and a 0.5 s per-player limit keep browsing cheap |
| MemoryStore sort key / expiration | 128 characters / 45 days | Item ids of at most 50 bytes become at most 111-character sort keys. Listings last 48 h |
| MessagingService | 1 KB per message, and per-server publish limits | Messages are about 200 bytes, one per listing change |
| Network | `BufferLong` up to 65535 bytes | A page is about 1.5 KB |

## 8. Configuration

In `AuctionProtocol`, shared with clients:

| Constant | Default |
|----------|---------|
| `MAX_LISTINGS` | 10 per player |
| `LISTING_DURATION` | 48 h |
| `MIN_PRICE` / `MAX_PRICE` | 1 / 1,000,000,000 |
| `MAX_AMOUNT` | 65535 (the `NumberU16` it travels as) |
| `SALE_FEE` | 5% (a coin sink, rounded down in the seller's favor) |
| `PAGE_SIZE` | 20 |
| `MAX_ITEM_ID_LENGTH` | 50 bytes |

In `AuctionHouseServiceServer`: timeouts, retry intervals, cooldowns and cache sizes (each documented where it's declared). `LOCK_TTL` is in `AuctionIndexServer`.

## 9. Testing

`pesde run test` runs the pure modules' specs:

- `tests/PlayerStateMachine.spec.luau`: activities exclude each other, leases are idempotent and stale ones are ignored, a close during a transaction is deferred
- `tests/AuctionEscrow.spec.luau`: validation (NaN, fractions, ranges, UTF-8, the listing cap), escrow and settlement, idempotency, conservation net of the fee, pages, cursors and sort-key ranges
- `tests/AuctionRecord.spec.luau`:
  - every transform against a simulated `UpdateAsync` store with lost replies and outages: the races above, retried commits, fencing, the expiry boundary, repricing, no mutation of inputs
  - a seeded randomized model of the service's flows (1000 runs): crashes at every step, saves that time out but land, unknown ledger writes, commits that land after the buyer moved servers. It checks that every escrow settles and that coins (net of fees) and items are exactly conserved. Removing the purchase fence, or publishing before the escrow is saved, makes it fail

The parts that call Roblox services can't run in Lune. To exercise them:

- **Studio, mock mode (no API access):** start a local server with two players (Test → Clients and Servers). Check list → buy → seller paid, cancel, reprice, `busy` when opening the auction while trading, and `unavailable` for trade requests to someone in the auction.
- **Published place with API access:** real DataStore and MemoryStore (Studio's are isolated from production).
- **Live, two servers:** cross-server sales and broadcasts.
