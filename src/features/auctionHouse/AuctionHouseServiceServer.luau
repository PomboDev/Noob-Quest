--!strict

--[=[
	The global auction house: players list items for coins, and anyone on any
	server can buy them. Items and coins are never duplicated or lost,
	whatever crashes, disconnects or timeouts happen along the way. The full
	design, with every failure case, is in docs/auction-house.md.

	- AuctionLedger (DataStore): one record per listing, the source of truth.
	  Every change is an UpdateAsync transform from AuctionRecord, so of two
	  conflicting changes from any servers exactly one applies
	- AuctionEscrow: what a player has put up, held in their own profile data
	  until the ledger decides
	- AuctionIndex (MemoryStore): browsing across servers, and short purchase
	  leases
	- AuctionBroadcast (MessagingService): quick notice of changes to every
	  server
	- PlayerStateService: a player is in the auction house or trading, never
	  both, and runs one auction action at a time

	Listing:
	1. Escrow: the items move from the inventory into `auction.listings[id]`.
	2. Persist: the profile is saved, and this waits until the saved copy
	   holds the escrow. Until then nothing outside this server knows about
	   the listing, so a crash only loses the unsaved escrow and the items
	   stay put.
	3. Publish: the ledger record is created, and from then on the listing
	   exists everywhere. If the save failed (it may still land later), the
	   listing is voided instead: a void record can never be published, and
	   it tells reconciliation to return the items.
	4. Index and announce, so buyers can find it.

	Buying:
	1. Lease: a MemoryStore lock, so one buyer at a time goes ahead.
	2. Check: the record must be active, at the price and version the buyer
	   saw, unexpired and not theirs. This is a dry run of the commit.
	3. Escrow: the price moves from the coins into `auction.purchase`.
	4. Persist: as above. If it fails, no sale was attempted, so the coins
	   come straight back.
	5. Commit: the record goes from active to sold, naming this purchase.
	   This is the moment of sale: a competing buyer, cancellation or expiry
	   on any server either got there first (and this fails) or fails itself.
	6. Settle: a won purchase delivers the items, anything else refunds. The
	   seller is paid when their own profile settles the listing: right away
	   if they're online (broadcast), else on a timer or when they next join.

	If a commit can't be confirmed (the DataStore is down, or its reply was
	lost), the purchase is resolved later with resolvePurchase. That finds a
	sale that did land, and otherwise fences the attempt off so a commit
	still in flight can't land after the refund.

	Escrow lives in saved data and every outcome is applied by removing the
	escrow entry in the same step that pays out, so settling twice does
	nothing, and a profile that loads with entries in escrow just settles
	them (reconciliation).
]=]

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")

local AuctionBroadcast = require("@Features/auctionHouse/modules/AuctionBroadcastServer")
local AuctionEscrow = require("@Features/auctionHouse/modules/AuctionEscrow")
local AuctionIndex = require("@Features/auctionHouse/modules/AuctionIndexServer")
local AuctionLedger = require("@Features/auctionHouse/modules/AuctionLedgerServer")
local AuctionProtocol = require("@Features/auctionHouse/modules/AuctionProtocol")
local AuctionRecord = require("@Features/auctionHouse/modules/AuctionRecord")
local Log = require("@Core/Log")
local Network = require("@Core/Network")
local PlayerService = require("@Features/player/PlayerServiceServer")
local PlayerStateService = require("@Features/playerState/PlayerStateServiceServer")
local RateLimit = require("@Core/RateLimit")

local Packet = Network.Packet

type Kind = AuctionBroadcast.Kind
type Lease = PlayerStateService.Lease
type Record = AuctionRecord.Record
type Result = AuctionProtocol.Result

-- How long a profile save may take before an action gives up on it.
-- ProfileStore queues writes to one key about 6 s apart, so leave room.
local SAVE_TIMEOUT = 30
-- Ledger tries while the player waits for an answer.
local LIVE_ATTEMPTS = 3
-- Seconds between ledger retries for outcomes settled in the background.
local LEDGER_RETRY = 30
-- Seconds without auction requests before the auction house closes for a player.
local IDLE_TIMEOUT = 5 * 60
-- Seconds between background passes (idle players, expiries, stuck purchases).
local SWEEP_INTERVAL = 30
-- Seconds between full checks of a seller's listings against the ledger:
-- at most this often when they open the auction house, and in the background.
local OPEN_RECONCILE_INTERVAL = 30
local RECONCILE_INTERVAL = 5 * 60
-- Seconds between requests from one player.
local BROWSE_COOLDOWN = 0.5
local ACTION_COOLDOWN = 1
-- Seconds between price changes of one listing.
local REPRICE_COOLDOWN = 10
-- Seconds a search result is reused for identical requests on this server.
local PAGE_CACHE_TTL = 3
local PAGE_CACHE_SIZE = 200
-- Longest a closing server waits for running actions.
local SHUTDOWN_WAIT = 25

local COMMIT_RESULTS: { [AuctionRecord.CommitOutcome]: Result } = {
	won = "ok",
	sold = "sold",
	closed = "notFound",
	expired = "expired",
	changed = "changed",
	own = "own",
	voided = "failed",
	missing = "notFound",
}

type CachedPage = {
	at: number,
	page: buffer,
}

local network: Network.ServerNetwork

-- Players with the auction house open.
local leases: { [Player]: Lease } = {}
local lastRequest: { [Player]: number } = {}
local lastReconcile: { [Player]: number } = {}
local browseLimit = RateLimit.new({ burst = 1, perSecond = 1 / BROWSE_COOLDOWN })
local actionLimit = RateLimit.new({ burst = 1, perSecond = 1 / ACTION_COOLDOWN })
-- Keyed by listing id.
local repriceLimit = RateLimit.new({ burst = 1, perSecond = 1 / REPRICE_COOLDOWN })
-- Listings with an action or reconciliation running on this server.
local busyListings: { [string]: true } = {}
-- Purchase attempts being bought, and being resolved in the background.
local purchasing: { [string]: true } = {}
local resolving: { [string]: true } = {}
local pageCache: { [string]: CachedPage } = {}
local pageCacheSize = 0
local running = 0
local closing = false

local AuctionHouseService = {}

-- // Helpers //

local function reply(player: Player, action: string, listingId: string, result: Result)
	network:fireClient(player, "onResult", action, listingId, result)
end

-- The player's auction lease, if they have the auction house open.
local function leaseOf(player: Player): Lease?
	local lease = leases[player]
	if lease and PlayerStateService.holds(lease) then
		return lease
	end
	leases[player] = nil
	return nil
end

local function ownsListing(player: Player, listingId: string): boolean
	local data = PlayerService.getData(player)
	return data ~= nil and data.auction.listings[listingId] ~= nil
end

local function clearPageCache()
	table.clear(pageCache)
	pageCacheSize = 0
end

local function announce(kind: Kind, record: Record)
	AuctionBroadcast.publish({
		kind = kind,
		id = record.id,
		sellerId = record.sellerId,
		itemId = record.itemId,
		price = record.price,
		version = record.version,
	})
end

-- Runs `fn` with one of the player's listings marked busy, so other actions
-- and reconciliation on this server leave it alone until `fn` returns or
-- errors.
local function withListing(listingId: string, fn: () -> Result): Result
	if busyListings[listingId] then
		return "busy"
	end

	busyListings[listingId] = true
	local ok, result = pcall(fn)
	busyListings[listingId] = nil

	if not ok then
		error(result, 0)
	end
	return result :: Result
end

-- // Settlement //

-- Applies a listing's final record to its seller (if their data is loaded
-- here) and takes the listing out of the index.
local function settleListing(player: Player, listingId: string, record: Record)
	local settled: AuctionEscrow.Settlement? = nil
	PlayerService.updateData(player, function(data)
		settled = AuctionEscrow.settleListing(data, player.UserId, listingId, record)
	end)

	if settled then
		Log.info(`{player.Name}'s listing {listingId} ({record.amount}x {record.itemId}) closed: {settled}`)
		reply(player, "settle", listingId, settled)
		if record.status ~= "void" then
			AuctionIndex.remove(listingId)
		end
	elseif ownsListing(player, listingId) then
		Log.warn(`Listing {listingId}'s record doesn't match {player.Name}'s escrow; leaving it in escrow`)
	end
end

-- Applies a purchase's outcome to the buyer, if their data is loaded here.
local function settlePurchase(player: Player, purchaseId: string, won: boolean): boolean
	local settled = false
	PlayerService.updateData(player, function(data)
		settled = AuctionEscrow.settlePurchase(data, purchaseId, won)
	end)
	return settled
end

-- // Reconciliation //

-- Brings one of the player's listings in line with the ledger: settles it
-- if it closed, closes it if its time is up or it was never published, and
-- repairs its index entry if it's live. Yields. False if the ledger couldn't
-- be reached: the escrow then stays put for a later try.
local function reconcileListingAsync(player: Player, listingId: string): boolean
	local data = PlayerService.getData(player)
	local escrow = if data then data.auction.listings[listingId] else nil
	if not escrow then
		return true
	end

	local ok, record = AuctionLedger.read(listingId)
	if not ok then
		return false
	end

	local now = os.time()
	if record == nil then
		-- Escrow without a record: the publish never landed (a failed save, a
		-- crash, an unreachable ledger). Void it so it never can.
		local stub = AuctionRecord.create(listingId, player.UserId, escrow)
		local _, voided = AuctionLedger.update(listingId, AuctionRecord.voidUnpublished(stub, now), LIVE_ATTEMPTS)
		record = voided
	elseif record.status == "active" and now >= record.expiresAt then
		local outcome, expired = AuctionLedger.update(listingId, AuctionRecord.expire(now), LIVE_ATTEMPTS)
		if outcome == "expired" and expired then
			announce("expired", expired)
		end
		record = expired
	end

	if record == nil then
		return false
	elseif record.status == "active" then
		-- Live: make sure buyers see it as it is (an index write may have failed).
		local reached, indexed = AuctionIndex.get(listingId)
		if reached and (indexed == nil or indexed.version ~= record.version) then
			AuctionIndex.put(AuctionRecord.summary(record))
		end
		return true
	end

	settleListing(player, listingId, record)
	return true
end

-- Reconciles one listing unless something else on this server is busy with it.
local function reconcileListing(player: Player, listingId: string)
	local ok, err = pcall(withListing, listingId, function(): Result
		return if reconcileListingAsync(player, listingId) then "ok" else "delayed"
	end)
	if not ok then
		Log.warn(`Reconciling {player.Name}'s listing {listingId} failed: {err}`)
	end
end

-- Reconciles every listing the player has in escrow. Yields.
local function reconcileSeller(player: Player)
	lastReconcile[player] = os.clock()

	local data = PlayerService.getData(player)
	if not data then
		return
	end

	local listingIds = {}
	for listingId in data.auction.listings do
		table.insert(listingIds, listingId)
	end
	for _, listingId in listingIds do
		if player.Parent ~= Players then
			return
		end
		reconcileListing(player, listingId)
	end
end

local function resolveLoop(player: Player, purchaseId: string, listingId: string)
	while true do
		local outcome, record =
			AuctionLedger.update(listingId, AuctionRecord.resolvePurchase(purchaseId), LIVE_ATTEMPTS)
		if outcome ~= nil then
			local won = outcome == "won"
			if settlePurchase(player, purchaseId, won) then
				Log.info(`{player.Name}'s pending purchase of {listingId} resolved: {outcome}`)
				reply(player, "buy", listingId, if won then "ok" else "failed")
			end
			if won and record then
				-- The server that committed may have died before telling anyone.
				AuctionIndex.remove(listingId)
				announce("sold", record)
			end
			return
		end

		local data = PlayerService.getData(player)
		if not data or not AuctionEscrow.holdsPurchase(data, purchaseId) then
			return -- settles on their next load
		end
		task.wait(LEDGER_RETRY)
	end
end

-- Settles a purchase whose commit may or may not have landed, retrying
-- while the ledger is unreachable for as long as the buyer holds it here.
local function resolvePurchaseAsync(player: Player, purchaseId: string, listingId: string)
	if resolving[purchaseId] then
		return
	end

	resolving[purchaseId] = true
	-- `:: any`: strict mode has no type for the error of a call that returns nothing
	local ok, err = pcall(resolveLoop :: any, player, purchaseId, listingId)
	resolving[purchaseId] = nil

	if not ok then
		Log.warn(`Resolving {player.Name}'s purchase of {listingId} failed: {err}`)
	end
end

-- // Actions //

local function createListingAsync(
	player: Player,
	listingId: string,
	itemId: string,
	amount: number,
	price: number
): Result
	-- 1. Escrow: validated against the live data and moved in the same step.
	local escrow: AuctionEscrow.ListingEscrow? = nil
	local reason: Result? = nil
	PlayerService.updateData(player, function(data)
		escrow, reason = AuctionEscrow.openListing(data, listingId, itemId, amount, price, os.time())
	end)
	if not escrow then
		return reason or "failed"
	end
	local record = AuctionRecord.create(listingId, player.UserId, escrow)

	-- 2. Persist.
	local saved = PlayerService.saveAsync(player, function(savedData)
		return AuctionEscrow.holdsListing(savedData, listingId)
	end, SAVE_TIMEOUT)

	-- 3. Publish, or void it if the save failed: a void record is how a save
	-- that still lands later gets its items back.
	local after: Record? = nil
	if saved then
		local _, published = AuctionLedger.update(listingId, AuctionRecord.publish(record), LIVE_ATTEMPTS)
		after = published
	else
		local _, voided =
			AuctionLedger.update(listingId, AuctionRecord.voidUnpublished(record, os.time()), LIVE_ATTEMPTS)
		after = voided
	end

	if not after then
		-- Unknown whether it landed. Reconciliation voids it unless it did.
		Log.warn(`Listing {listingId} by {player.Name} is undecided; reconciling later`)
		task.delay(LEDGER_RETRY, reconcileListing, player, listingId)
		return "delayed"
	elseif after.status ~= "active" then
		settleListing(player, listingId, after)
		return "failed"
	end

	-- 4. Index and announce.
	AuctionIndex.put(AuctionRecord.summary(after))
	announce("listed", after)
	Log.info(`{player.Name} listed {amount}x {itemId} for {price} ({listingId})`)
	return "ok"
end

local function cancelListingAsync(player: Player, listingId: string): Result
	local outcome, record =
		AuctionLedger.update(listingId, AuctionRecord.cancel(player.UserId, os.time()), LIVE_ATTEMPTS)
	if outcome == nil then
		-- The cancel may still have landed; if so, this returns the items.
		task.delay(LEDGER_RETRY, reconcileListing, player, listingId)
		return "failed"
	elseif outcome == "missing" then
		-- Never published: voiding it returns the items.
		return if reconcileListingAsync(player, listingId) then "ok" else "failed"
	elseif outcome == "forbidden" or not record then
		Log.warn(`{player.Name} holds listing {listingId} in escrow but the ledger names another seller`)
		return "invalid"
	end

	if outcome == "cancelled" then
		announce("cancelled", record)
		Log.info(`{player.Name} cancelled listing {listingId}`)
	end
	-- Whatever closed it first decides: if it sold, the seller is paid instead.
	settleListing(player, listingId, record)
	return if record.status == "sold" then "sold" else "ok"
end

local function repriceListingAsync(player: Player, listingId: string, price: number): Result
	if not AuctionProtocol.isPrice(price) then
		return "invalid"
	elseif not RateLimit.take(repriceLimit, listingId) then
		return "cooldown"
	end

	local outcome, record =
		AuctionLedger.update(listingId, AuctionRecord.reprice(player.UserId, price, os.time()), LIVE_ATTEMPTS)
	if outcome == nil then
		return "failed"
	elseif outcome == "repriced" and record then
		local newPrice = record.price
		PlayerService.updateData(player, function(data)
			AuctionEscrow.setListingPrice(data, listingId, newPrice)
		end)
		AuctionIndex.put(AuctionRecord.summary(record))
		announce("repriced", record)
		return "ok"
	end

	-- It sold, closed, expired or was never published: settle it now.
	reconcileListingAsync(player, listingId)
	return if outcome == "sold" then "sold" elseif outcome == "expired" then "expired" else "notFound"
end

local function purchaseAsync(
	player: Player,
	listingId: string,
	purchaseId: string,
	price: number,
	version: number
): Result
	-- 2. Check, with the same transform the commit will use, so a stale index
	-- entry costs the buyer nothing.
	local readOk, record = AuctionLedger.read(listingId)
	if not readOk then
		return "failed"
	elseif not record then
		return "notFound"
	end

	local request: AuctionRecord.PurchaseRequest = {
		purchaseId = purchaseId,
		buyerId = player.UserId,
		itemId = record.itemId,
		amount = record.amount,
		price = price,
		version = version,
	}
	local _: Record?, predicted: AuctionRecord.CommitOutcome = AuctionRecord.commit(request, os.time())(record)
	if predicted ~= "won" then
		if record.status ~= "active" then
			AuctionIndex.remove(listingId) -- a stale entry
		end
		return COMMIT_RESULTS[predicted]
	end

	-- 3. Escrow the price.
	local opened = false
	local reason: Result? = nil
	PlayerService.updateData(player, function(data)
		opened, reason = AuctionEscrow.openPurchase(data, {
			id = purchaseId,
			listingId = listingId,
			itemId = request.itemId,
			amount = request.amount,
			price = price,
			version = version,
		})
	end)
	if not opened then
		return reason or "failed"
	end

	-- 4. Persist: the payment is on disk before the sale can exist.
	local saved = PlayerService.saveAsync(player, function(savedData)
		return AuctionEscrow.holdsPurchase(savedData, purchaseId)
	end, SAVE_TIMEOUT)
	if not saved then
		-- No commit was sent, so this attempt bought nothing: refund. If the
		-- profile already left this server, its next load does that.
		settlePurchase(player, purchaseId, false)
		return "failed"
	end

	-- 5. Commit.
	local outcome, after = AuctionLedger.update(listingId, AuctionRecord.commit(request, os.time()), LIVE_ATTEMPTS)
	if outcome == nil then
		Log.warn(`{player.Name}'s purchase of {listingId} is undecided; resolving in the background`)
		task.spawn(resolvePurchaseAsync, player, purchaseId, listingId)
		return "delayed"
	end

	-- 6. Settle.
	local won = outcome == "won"
	settlePurchase(player, purchaseId, won)
	if after and after.status ~= "active" then
		AuctionIndex.remove(listingId)
	end
	if won and after then
		announce("sold", after)
		Log.info(`{player.Name} bought {after.amount}x {after.itemId} for {after.price} ({listingId})`)
	end
	-- The cast: update's generic outcome loses its string literals.
	return COMMIT_RESULTS[outcome :: AuctionRecord.CommitOutcome]
end

local function buyListingAsync(player: Player, listingId: string, price: number, version: number): Result
	local data = PlayerService.getData(player)
	if not data then
		return "failed"
	elseif data.auction.purchase then
		return "pending"
	elseif not AuctionProtocol.isPrice(price) then
		return "invalid"
	elseif price > data.coins then
		return "funds"
	end

	-- 1. Lease.
	local purchaseId = HttpService:GenerateGUID(false)
	if not AuctionIndex.lock(listingId, purchaseId) then
		return "busy"
	end

	purchasing[purchaseId] = true
	local ok, result = pcall(purchaseAsync, player, listingId, purchaseId, price, version)
	purchasing[purchaseId] = nil
	AuctionIndex.unlock(listingId, purchaseId)

	if not ok then
		error(result, 0) -- a purchase left in escrow is resolved by the sweep
	end
	return result :: Result
end

-- Runs one auction action: holds the player in Transacting (one action at a
-- time, no trading) while `run` runs, always ends it (even if `run` errors),
-- and replies with the result.
local function transact(player: Player, action: string, listingId: string, run: () -> Result)
	local lease = leaseOf(player)
	local result: Result

	if not lease then
		result = "notOpen"
	elseif closing then
		result = "closing"
	elseif not RateLimit.take(actionLimit, player) then
		result = "cooldown"
	elseif not PlayerStateService.beginTransaction(lease) then
		result = "busy"
	else
		lastRequest[player] = os.clock()
		running += 1
		local ok, value = pcall(run)
		running -= 1
		PlayerStateService.endTransaction(lease)

		if ok then
			result = value :: Result
		else
			Log.warn(`Auction {action} by {player.Name} errored: {value}`)
			result = "failed"
		end
	end

	reply(player, action, listingId, result)
end

-- // Background //

-- Closes forgotten auction houses, settles expired listings and stuck
-- purchases, and reconciles sellers now and then in case a broadcast was
-- missed.
local function sweep()
	local clock = os.clock()
	for player, lease in leases do
		if clock - (lastRequest[player] or 0) >= IDLE_TIMEOUT then
			Log.debug(`Closing the auction house for idle {player.Name}`)
			leases[player] = nil
			PlayerStateService.release(lease)
		end
	end

	local now = os.time()
	for _, player in Players:GetPlayers() do
		local data = PlayerService.getData(player)
		if not data then
			continue
		end

		local purchase = data.auction.purchase
		if purchase and not purchasing[purchase.id] and not resolving[purchase.id] then
			task.spawn(resolvePurchaseAsync, player, purchase.id, purchase.listingId)
		end

		if next(data.auction.listings) == nil then
			continue
		elseif clock - (lastReconcile[player] or -math.huge) >= RECONCILE_INTERVAL then
			task.spawn(reconcileSeller, player)
		else
			local expired = {}
			for listingId, escrow in data.auction.listings do
				if escrow.expiresAt <= now then
					table.insert(expired, listingId)
				end
			end
			for _, listingId in expired do
				task.spawn(reconcileListing, player, listingId)
			end
		end
	end
end

local function onBroadcast(message: AuctionBroadcast.Message)
	clearPageCache()

	-- A seller on this server is paid or refunded right away.
	if message.kind == "sold" or message.kind == "cancelled" or message.kind == "expired" then
		local seller = Players:GetPlayerByUserId(message.sellerId)
		if seller then
			reconcileListing(seller, message.id)
		end
	end

	-- Open auction screens stay current.
	for player in leases do
		network:fireClient(player, "onListingChanged", message.id, message.kind, message.price, message.version)
	end
end

-- A profile that loads with auction escrow settles it before anything else.
local function onLoaded(player: Player)
	local data = PlayerService.getData(player)
	if not data then
		return
	end

	local purchase = data.auction.purchase
	if purchase then
		Log.info(`Resolving {player.Name}'s pending purchase of {purchase.listingId}`)
		task.spawn(resolvePurchaseAsync, player, purchase.id, purchase.listingId)
	end
	reconcileSeller(player)
end

local function onPlayerRemoving(player: Player)
	-- PlayerStateService drops their state, which ends the lease. Actions
	-- still running finish on their own: everything they escrowed is in the
	-- profile's final save and settles on the next load.
	leases[player] = nil
	lastRequest[player] = nil
	lastReconcile[player] = nil
end

local function onClose()
	closing = true
	local deadline = os.clock() + SHUTDOWN_WAIT
	while running > 0 and os.clock() < deadline do
		task.wait(0.5)
	end
end

-- // Network handlers (client input is untrusted) //

function AuctionHouseService.openAuction(player: Player)
	lastRequest[player] = os.clock()
	if leaseOf(player) then
		reply(player, "open", "", "ok")
		return
	end

	local lease = PlayerStateService.acquire(player, "Auction")
	if not lease then
		reply(player, "open", "", "busy")
		return
	end
	leases[player] = lease
	reply(player, "open", "", "ok")

	-- Catch up on sales and expiries no broadcast told us about.
	if os.clock() - (lastReconcile[player] or -math.huge) >= OPEN_RECONCILE_INTERVAL then
		reconcileSeller(player)
	end
end

function AuctionHouseService.closeAuction(player: Player)
	local lease = leases[player]
	leases[player] = nil
	if lease then
		-- If an action is running, the player is free once it ends.
		PlayerStateService.release(lease)
	end
end

-- `itemId` "" pages through the newest listings of every item.
function AuctionHouseService.browse(player: Player, requestId: number, itemId: string, cursor: string)
	if not leaseOf(player) then
		reply(player, "browse", "", "notOpen")
		return
	end
	lastRequest[player] = os.clock()

	if itemId ~= "" and not AuctionProtocol.isItemId(itemId) then
		reply(player, "browse", "", "invalid")
		return
	elseif not RateLimit.take(browseLimit, player) then
		reply(player, "browse", "", "cooldown")
		return
	end

	local cacheKey = `{itemId}|{cursor}`
	local cached = pageCache[cacheKey]
	if cached and os.clock() - cached.at < PAGE_CACHE_TTL then
		network:fireClient(player, "onPage", requestId, cached.page)
		return
	end

	local ok, listings, nextCursor = AuctionIndex.page(itemId, cursor, AuctionProtocol.PAGE_SIZE)
	if not ok then
		reply(player, "browse", "", "failed")
		return
	end

	local page = AuctionProtocol.encodePage({ itemId = itemId, listings = listings, cursor = nextCursor })
	if pageCacheSize >= PAGE_CACHE_SIZE then
		clearPageCache()
	end
	if not pageCache[cacheKey] then
		pageCacheSize += 1
	end
	pageCache[cacheKey] = { at = os.clock(), page = page }
	network:fireClient(player, "onPage", requestId, page)
end

function AuctionHouseService.createListing(player: Player, itemId: string, amount: number, price: number)
	local listingId = HttpService:GenerateGUID(false)
	transact(player, "list", listingId, function(): Result
		-- Busy from the start, so reconciliation can't void it mid-publish.
		return withListing(listingId, function(): Result
			return createListingAsync(player, listingId, itemId, amount, price)
		end)
	end)
end

function AuctionHouseService.cancelListing(player: Player, listingId: string)
	if not AuctionProtocol.isListingId(listingId) then
		reply(player, "cancel", "", "invalid")
		return
	end
	transact(player, "cancel", listingId, function(): Result
		if not ownsListing(player, listingId) then
			return "notFound"
		end
		return withListing(listingId, function(): Result
			return cancelListingAsync(player, listingId)
		end)
	end)
end

function AuctionHouseService.repriceListing(player: Player, listingId: string, price: number)
	if not AuctionProtocol.isListingId(listingId) then
		reply(player, "reprice", "", "invalid")
		return
	end
	transact(player, "reprice", listingId, function(): Result
		if not ownsListing(player, listingId) then
			return "notFound"
		end
		return withListing(listingId, function(): Result
			return repriceListingAsync(player, listingId, price)
		end)
	end)
end

-- `price` and `version` are what the buyer saw: the purchase fails with
-- "changed" rather than charge anything else.
function AuctionHouseService.buyListing(player: Player, listingId: string, price: number, version: number)
	if not AuctionProtocol.isListingId(listingId) then
		reply(player, "buy", "", "invalid")
		return
	end
	transact(player, "buy", listingId, function(): Result
		return buyListingAsync(player, listingId, price, version)
	end)
end

-- // Lifecycle //

function AuctionHouseService.init()
	-- Every key that is also a function above is callable by clients.
	network = Network.server("AuctionHouse", AuctionHouseService, {
		openAuction = {}, -- client -> server
		closeAuction = {}, -- client -> server
		browse = { Packet.NumberU16, Packet.String, Packet.String }, -- client -> server: request id, item id, cursor
		createListing = { Packet.String, Packet.NumberU16, Packet.NumberU32 }, -- client -> server: item id, amount, price
		cancelListing = { Packet.String }, -- client -> server: listing id
		repriceListing = { Packet.String, Packet.NumberU32 }, -- client -> server: listing id, price
		buyListing = { Packet.String, Packet.NumberU32, Packet.NumberU32 }, -- client -> server: listing id, price, version
		onPage = { Packet.NumberU16, Packet.BufferLong }, -- server -> client: request id, AuctionProtocol page
		onResult = { Packet.String, Packet.String, Packet.String }, -- server -> client: action, listing id, result
		onListingChanged = { Packet.String, Packet.String, Packet.NumberU32, Packet.NumberU32 }, -- server -> client: listing id, kind, price, version
	})

	Players.PlayerRemoving:Connect(onPlayerRemoving)
	PlayerService.observeLoaded(onLoaded)
	AuctionBroadcast.observe(onBroadcast)
	game:BindToClose(onClose)
end

function AuctionHouseService.start()
	task.spawn(function()
		while true do
			task.wait(SWEEP_INTERVAL)
			-- `:: any`: strict mode has no type for the error of a call that returns nothing
			local ok, err = pcall(sweep :: any)
			if not ok then
				Log.warn(`Auction sweep failed: {err}`)
			end
		end
	end)

	AuctionBroadcast.start()
end

return AuctionHouseService
