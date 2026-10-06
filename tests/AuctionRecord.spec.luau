local AuctionEscrow = require("../src/features/auctionHouse/modules/AuctionEscrow")
local AuctionProtocol = require("../src/features/auctionHouse/modules/AuctionProtocol")
local AuctionRecord = require("../src/features/auctionHouse/modules/AuctionRecord")
local Expect = require("./Expect")

local NOW = 1_000_000
local SELLER = 1
local LIFETIME = 100

local function deepCopy(value: any): any
	if type(value) ~= "table" then
		return value
	end
	local copy = {}
	for key, item in value do
		copy[key] = deepCopy(item)
	end
	return copy
end

-- One ledger key with DataStore UpdateAsync semantics: the transform sees a
-- fresh copy of what's stored and its result is written atomically.
-- `failure` "down" writes nothing and "lost" writes but loses the reply
-- (a timeout after the commit); both return nil, like AuctionLedger.update.
local function update(key: any, transform: any, failure: string?): (any, any)
	if failure == "down" then
		return nil, nil
	end
	local written, outcome = transform(deepCopy(key.value))
	if written ~= nil then
		key.value = deepCopy(written)
	end
	if failure == "lost" then
		return nil, nil
	end
	return outcome, deepCopy(key.value)
end

local function activeKey(): any
	local escrow = { itemId = "sword", amount = 2, price = 100, createdAt = NOW, expiresAt = NOW + LIFETIME }
	return { value = AuctionRecord.create("L1", SELLER, escrow) }
end

local function request(purchaseId: string, buyerId: number, price: number?, version: number?): any
	return {
		purchaseId = purchaseId,
		buyerId = buyerId,
		itemId = "sword",
		amount = 2,
		price = price or 100,
		version = version or 1,
	}
end

-- // Simulation //
-- A model of AuctionHouseServiceServer's flows (same order of escrow, save,
-- ledger write and settle) over profiles that can crash and a ledger that
-- can fail, to check that no interleaving creates or destroys goods.

-- `live` is the session's copy of the data, `saved` what's on disk. A crash
-- loses whatever wasn't saved, like a server dying.
local function newProfile(userId: number, coins: number, inventory: { [string]: number }): any
	local data = {
		schemaVersion = 1,
		coins = coins,
		level = 1,
		xp = 0,
		inventory = inventory,
		auction = { listings = {} },
	}
	return { userId = userId, live = deepCopy(data), saved = deepCopy(data) }
end

local function save(profile: any)
	profile.saved = deepCopy(profile.live)
end

local function crash(profile: any)
	profile.live = deepCopy(profile.saved)
end

local function chance(probability: number): boolean
	return math.random() < probability
end

local function pick(list: { any }): any
	return list[math.random(1, #list)]
end

local function keysOf(map: { [string]: any }): { string }
	local keys = {}
	for key in map do
		table.insert(keys, key)
	end
	table.sort(keys)
	return keys
end

local function failure(world: any): string?
	if world.reliable then
		return nil
	end
	local roll = math.random()
	return if roll < 0.15 then "down" elseif roll < 0.3 then "lost" else nil
end

local function ledgerKey(world: any, listingId: string): any
	local key = world.ledger[listingId]
	if not key then
		key = { value = nil }
		world.ledger[listingId] = key
	end
	return key
end

local function settleListing(profile: any, listingId: string, record: any)
	if record and record.status ~= "active" then
		AuctionEscrow.settleListing(profile.live, profile.userId, listingId, record)
	end
end

-- reconcileListingAsync
local function reconcileListing(world: any, profile: any, listingId: string)
	local escrow = profile.live.auction.listings[listingId]
	if not escrow or failure(world) == "down" then
		return
	end

	local key = ledgerKey(world, listingId)
	local record = deepCopy(key.value)
	local transform = nil
	if record == nil then
		transform = AuctionRecord.voidUnpublished(AuctionRecord.create(listingId, profile.userId, escrow), world.now)
	elseif record.status == "active" and world.now >= record.expiresAt then
		transform = AuctionRecord.expire(world.now)
	end
	if transform then
		local _, after = update(key, transform, failure(world))
		record = after
	end
	settleListing(profile, listingId, record)
end

-- resolvePurchaseAsync
local function resolvePurchase(world: any, profile: any)
	local purchase = profile.live.auction.purchase
	if not purchase then
		return
	end
	local outcome =
		update(ledgerKey(world, purchase.listingId), AuctionRecord.resolvePurchase(purchase.id), failure(world))
	if outcome then
		AuctionEscrow.settlePurchase(profile.live, purchase.id, outcome == "won")
	end
end

-- createListing
local function list(world: any, profile: any)
	local items = keysOf(profile.live.inventory)
	if #items == 0 then
		return
	end
	local itemId = pick(items)
	local listingId = `L{world.nextId}`
	world.nextId += 1

	local amount = math.random(1, profile.live.inventory[itemId])
	local escrow = AuctionEscrow.openListing(profile.live, listingId, itemId, amount, math.random(1, 150), world.now)
	if not escrow then
		return
	elseif chance(0.1) then
		crash(profile) -- before the save: the escrow never reached the disk
		return
	end

	-- saveAsync can time out even though the save still lands.
	local saved = chance(0.85)
	if saved or chance(0.5) then
		save(profile)
	end

	local record = AuctionRecord.create(listingId, profile.userId, escrow)
	local transform = if saved then AuctionRecord.publish(record) else AuctionRecord.voidUnpublished(record, world.now)
	local _, after = update(ledgerKey(world, listingId), transform, failure(world))
	settleListing(profile, listingId, after)
end

-- buyListing
local function buy(world: any, profile: any)
	local listingIds = keysOf(world.ledger)
	if #listingIds == 0 or profile.live.auction.purchase then
		return
	end
	local listingId = pick(listingIds)
	local key = ledgerKey(world, listingId)
	local record = deepCopy(key.value)
	if not record then
		return
	end

	local purchaseId = `P{world.nextId}`
	world.nextId += 1
	local agreed = {
		purchaseId = purchaseId,
		buyerId = profile.userId,
		itemId = record.itemId,
		amount = record.amount,
		price = record.price,
		version = record.version,
	}
	local _, predicted = AuctionRecord.commit(agreed, world.now)(record)
	if predicted ~= "won" then
		return
	end

	local token = {
		id = purchaseId,
		listingId = listingId,
		itemId = record.itemId,
		amount = record.amount,
		price = record.price,
		version = record.version,
	}
	if not AuctionEscrow.openPurchase(profile.live, token) then
		return
	elseif chance(0.1) then
		crash(profile)
		return
	elseif chance(0.1) then
		-- The save timed out (and may land anyway). No commit was sent, so refund.
		if chance(0.5) then
			save(profile)
		end
		AuctionEscrow.settlePurchase(profile.live, purchaseId, false)
		return
	end
	save(profile)

	local commit = AuctionRecord.commit(agreed, world.now)
	if chance(0.1) then
		-- This server loses the player while its commit is still in flight.
		table.insert(world.inflight, { key = key, transform = commit })
		crash(profile)
		return
	end

	local outcome = update(key, commit, failure(world))
	if outcome then
		AuctionEscrow.settlePurchase(profile.live, purchaseId, outcome == "won")
	end
end

-- cancelListing
local function cancel(world: any, profile: any)
	local listingIds = keysOf(profile.live.auction.listings)
	if #listingIds == 0 then
		return
	end
	local listingId = pick(listingIds)
	local outcome, after =
		update(ledgerKey(world, listingId), AuctionRecord.cancel(profile.userId, world.now), failure(world))
	if outcome == "missing" then
		reconcileListing(world, profile, listingId)
	else
		settleListing(profile, listingId, after)
	end
end

-- repriceListing
local function reprice(world: any, profile: any)
	local listingIds = keysOf(profile.live.auction.listings)
	if #listingIds == 0 then
		return
	end
	local listingId = pick(listingIds)
	local outcome, after = update(
		ledgerKey(world, listingId),
		AuctionRecord.reprice(profile.userId, math.random(1, 150), world.now),
		failure(world)
	)
	if outcome == "repriced" then
		AuctionEscrow.setListingPrice(profile.live, listingId, after.price)
	elseif outcome ~= nil then
		reconcileListing(world, profile, listingId)
	end
end

local function totals(world: any): (number, { [string]: number })
	local coins, items = 0, {}
	for _, profile in world.profiles do
		coins += profile.live.coins
		for itemId, amount in profile.live.inventory do
			items[itemId] = (items[itemId] or 0) + amount
		end
	end
	return coins, items
end

local function fees(world: any): number
	local total = 0
	for _, key in world.ledger do
		local record = key.value
		if record and record.status == "sold" then
			total += record.price - AuctionProtocol.proceeds(record.price)
		end
	end
	return total
end

local function simulate(seed: number, steps: number)
	math.randomseed(seed)
	local world = {
		now = NOW,
		nextId = 1,
		ledger = {},
		inflight = {},
		reliable = false,
		profiles = {
			newProfile(1, 500, { sword = 3, shield = 2 }),
			newProfile(2, 800, { gem = 5 }),
			newProfile(3, 300, { sword = 1 }),
		},
	}
	local coinsBefore, itemsBefore = totals(world)

	for _ = 1, steps do
		local profile = pick(world.profiles)
		local roll = math.random(1, 10)
		if roll == 1 then
			list(world, profile)
		elseif roll == 2 or roll == 3 then
			buy(world, profile)
		elseif roll == 4 then
			cancel(world, profile)
		elseif roll == 5 then
			reprice(world, profile)
		elseif roll == 6 then
			for _, listingId in keysOf(profile.live.auction.listings) do
				reconcileListing(world, profile, listingId)
			end
			resolvePurchase(world, profile)
		elseif roll == 7 then
			if chance(0.5) then
				save(profile) -- autosave
			else
				crash(profile)
			end
		elseif roll == 8 and #world.inflight > 0 then
			-- A commit from a server that lost its player finally lands. Its
			-- result goes nowhere: that server no longer has the profile.
			local index = math.random(1, #world.inflight)
			local late = table.remove(world.inflight, index)
			update(late.key, late.transform)
		else
			world.now += math.random(0, AuctionProtocol.LISTING_DURATION // 10)
		end
	end

	-- Everything still in flight lands, every listing expires, and with the
	-- ledger reachable again every profile settles what it holds.
	for _, late in world.inflight do
		update(late.key, late.transform)
	end
	world.reliable = true
	world.now += AuctionProtocol.LISTING_DURATION
	for _, profile in world.profiles do
		for _, listingId in keysOf(profile.live.auction.listings) do
			reconcileListing(world, profile, listingId)
		end
		resolvePurchase(world, profile)
		Expect.deepEqual(profile.live.auction, { listings = {} }, `seed {seed}: profile {profile.userId} settled`)
	end

	local coinsAfter, itemsAfter = totals(world)
	Expect.equal(coinsAfter + fees(world), coinsBefore, `seed {seed}: coins`)
	Expect.deepEqual(itemsAfter, itemsBefore, `seed {seed}: items`)
end

return {
	["publish and voidUnpublished: whichever lands first wins"] = function()
		local escrow = { itemId = "sword", amount = 1, price = 10, createdAt = NOW, expiresAt = NOW + LIFETIME }
		local record = AuctionRecord.create("L1", SELLER, escrow)

		local published = { value = nil }
		Expect.equal(update(published, AuctionRecord.publish(record)), "published")
		Expect.equal(update(published, AuctionRecord.voidUnpublished(record, NOW)), "active", "void after publish")
		Expect.equal(update(published, AuctionRecord.publish(record)), "published", "retried publish")
		Expect.deepEqual(published.value, record)

		local voided = { value = nil }
		Expect.equal(update(voided, AuctionRecord.voidUnpublished(record, NOW)), "void")
		Expect.equal(update(voided, AuctionRecord.publish(record)), "void", "publish after void")
		Expect.equal(voided.value.status, "void")
		Expect.equal(voided.value.itemId, "sword", "keeps the details")
	end,

	["of two buyers on different servers, exactly one wins"] = function()
		local key = activeKey()
		local stale = deepCopy(key.value)

		Expect.equal(update(key, AuctionRecord.commit(request("A", 2), NOW)), "won")
		-- On the record B's server last read, B would win too, which is why
		-- UpdateAsync reruns B's transform on the latest record.
		Expect.equal(select(2, AuctionRecord.commit(request("B", 3), NOW)(stale)), "won")
		Expect.equal(update(key, AuctionRecord.commit(request("B", 3), NOW)), "sold")

		Expect.equal(key.value.status, "sold")
		Expect.equal(key.value.buyerId, 2)
		Expect.equal(key.value.purchaseId, "A")
	end,

	["a commit retried after a lost reply still wins, once"] = function()
		local key = activeKey()
		Expect.equal(update(key, AuctionRecord.commit(request("A", 2), NOW), "lost"), nil)
		Expect.equal(update(key, AuctionRecord.commit(request("A", 2), NOW)), "won")
		Expect.equal(update(key, AuctionRecord.resolvePurchase("A")), "won", "resolving finds the sale")
		Expect.equal(update(key, AuctionRecord.commit(request("B", 3), NOW)), "sold")
	end,

	["resolving an unknown purchase fences off its late commit"] = function()
		local key = activeKey()
		Expect.equal(update(key, AuctionRecord.resolvePurchase("A")), "lost")
		Expect.deepEqual(key.value.voided, { "A" })
		Expect.equal(update(key, AuctionRecord.resolvePurchase("A")), "lost", "idempotent")
		Expect.deepEqual(key.value.voided, { "A" })

		Expect.equal(update(key, AuctionRecord.commit(request("A", 2), NOW)), "voided", "late commit")
		Expect.equal(key.value.status, "active")

		Expect.equal(update(key, AuctionRecord.commit(request("B", 3), NOW)), "won", "others still can")
		Expect.equal(key.value.voided, nil, "fence cleared once closed")
	end,

	["the seller cancelling and a buyer committing: the first wins"] = function()
		local cancelFirst = activeKey()
		Expect.equal(update(cancelFirst, AuctionRecord.cancel(SELLER, NOW)), "cancelled")
		Expect.equal(update(cancelFirst, AuctionRecord.commit(request("A", 2), NOW)), "closed")
		Expect.equal(update(cancelFirst, AuctionRecord.cancel(SELLER, NOW)), "cancelled", "idempotent")

		local buyFirst = activeKey()
		Expect.equal(update(buyFirst, AuctionRecord.commit(request("A", 2), NOW)), "won")
		Expect.equal(update(buyFirst, AuctionRecord.cancel(SELLER, NOW)), "sold", "too late: the seller is paid")
	end,

	["expiry and a commit around the deadline"] = function()
		local key = activeKey()
		Expect.equal(update(key, AuctionRecord.expire(NOW + LIFETIME - 1)), "active", "not yet")
		Expect.equal(update(key, AuctionRecord.commit(request("A", 2), NOW + LIFETIME)), "expired")
		Expect.equal(key.value.status, "active", "a refused commit writes nothing")
		Expect.equal(update(key, AuctionRecord.expire(NOW + LIFETIME)), "expired")
		Expect.equal(update(key, AuctionRecord.commit(request("A", 2), NOW)), "expired", "even with a slow clock")

		local early = activeKey()
		Expect.equal(update(early, AuctionRecord.commit(request("A", 2), NOW + LIFETIME - 1)), "won")
		Expect.equal(update(early, AuctionRecord.expire(NOW + LIFETIME)), "sold")
	end,

	["repricing makes purchases at the old price fail"] = function()
		local key = activeKey()
		Expect.equal(update(key, AuctionRecord.reprice(SELLER, 150, NOW)), "repriced")
		Expect.equal(key.value.version, 2)
		Expect.equal(update(key, AuctionRecord.reprice(SELLER, 150, NOW)), "repriced", "retry")
		Expect.equal(key.value.version, 2, "retry doesn't bump again")

		Expect.equal(update(key, AuctionRecord.commit(request("A", 2), NOW)), "changed", "old price")
		Expect.equal(update(key, AuctionRecord.commit(request("A", 2, 150, 1), NOW)), "changed", "old version")
		Expect.equal(update(key, AuctionRecord.commit(request("A", 2, 150, 2), NOW)), "won")
		Expect.equal(update(key, AuctionRecord.reprice(SELLER, 90, NOW)), "sold")
	end,

	["only the seller manages a listing, and can't buy it"] = function()
		local key = activeKey()
		Expect.equal(update(key, AuctionRecord.cancel(99, NOW)), "forbidden")
		Expect.equal(update(key, AuctionRecord.reprice(99, 1, NOW)), "forbidden")
		Expect.equal(update(key, AuctionRecord.commit(request("A", SELLER), NOW)), "own")
		Expect.equal(key.value.status, "active")
		Expect.equal(key.value.price, 100)

		local missing = { value = nil }
		Expect.equal(update(missing, AuctionRecord.commit(request("A", 2), NOW)), "missing")
		Expect.equal(update(missing, AuctionRecord.cancel(SELLER, NOW)), "missing")
		Expect.equal(update(missing, AuctionRecord.resolvePurchase("A")), "lost")
		Expect.equal(missing.value, nil, "nothing written")
	end,

	["transforms never mutate their input"] = function()
		local record = activeKey().value
		record.voided = { "X" }
		local transforms = {
			AuctionRecord.publish(record),
			AuctionRecord.voidUnpublished(record, NOW),
			AuctionRecord.commit(request("A", 2), NOW),
			AuctionRecord.resolvePurchase("B"),
			AuctionRecord.cancel(SELLER, NOW),
			AuctionRecord.expire(NOW + LIFETIME),
			AuctionRecord.reprice(SELLER, 5, NOW),
		}
		for index, transform in transforms do
			local input = deepCopy(record)
			transform(input)
			Expect.deepEqual(input, record, `transform {index}`)
		end
	end,

	["no interleaving of crashes, failures and races creates or destroys goods"] = function()
		for seed = 1, 1000 do
			simulate(seed, 100)
		end
	end,
}
