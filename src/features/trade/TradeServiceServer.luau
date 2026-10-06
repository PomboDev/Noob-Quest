--!strict

--[=[
	Player-to-player trading between two players on the same server, safe
	against duplication.

	Negotiation is server-authoritative: clients only ask to change their own
	offer, every change is checked against their live data, and any change
	clears both "ready" flags. When both sides are ready on the same offer
	version, a short countdown runs, then the trade commits:

	1. Escrow (synchronous): both offers are validated again and moved out of
	   both inventories into each profile's `pendingTrade` (TradeEscrow.open).
	   Nothing yields between the check and the move.
	2. Persist: both profiles are saved, and the trade waits until ProfileStore
	   confirms each saved copy holds the escrow.
	3. Decide: the ledger records "committed" if both escrows are on disk,
	   "aborted" otherwise. The first recorded outcome is final (TradeLedger).
	4. Settle: each profile delivers `receive` or refunds `give`.

	A crash, leave or session steal at any point leaves at least one profile
	with its escrow saved, and a profile that loads with a pending trade asks
	the ledger how it ended (proposing "aborted", which only wins if the trade
	never committed). Goods are never in two inventories at once: either both
	escrows reached the DataStore before the commit, or the trade is aborted
	and each side gets back only what it gave.

	Both players hold a "Trading" lease from PlayerStateService for as long as
	the session is open, settling included, so neither can use the auction
	house meanwhile, and a player who is in the auction house can't be asked
	to trade.
]=]

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")

local Log = require("@Core/Log")
local Network = require("@Core/Network")
local PlayerService = require("@Features/player/PlayerServiceServer")
local PlayerStateService = require("@Features/playerState/PlayerStateServiceServer")
local RateLimit = require("@Core/RateLimit")
local TradeEscrow = require("@Features/trade/modules/TradeEscrow")
local TradeLedger = require("@Features/trade/modules/TradeLedgerServer")
local TradeProtocol = require("@Features/trade/modules/TradeProtocol")

local Packet = Network.Packet

type Offer = TradeEscrow.Offer
type Outcome = TradeEscrow.Outcome
type Phase = TradeProtocol.Phase

-- How long a profile save may take before the trade is aborted. ProfileStore
-- queues writes to one key about 6 s apart, so leave room for that.
local SAVE_TIMEOUT = 30
-- Seconds between trade requests from one player.
local REQUEST_COOLDOWN = 2
-- Seconds between ledger retries while it's unreachable.
local LEDGER_RETRY = 30

type Session = {
	id: string,
	players: { Player },
	offers: { [Player]: Offer },
	ready: { [Player]: boolean },
	version: number,
	phase: Phase,
	-- Bumped whenever a countdown starts or is interrupted.
	countdown: number,
	-- Each player's "Trading" activity, released when the session closes.
	leases: { PlayerStateService.Lease },
}

local network: Network.ServerNetwork

local sessions: { [Player]: Session } = {}
-- target -> requester -> os.clock() when the request expires
local requests: { [Player]: { [Player]: number } } = {}
local requestLimit = RateLimit.new({ burst = 1, perSecond = 1 / REQUEST_COOLDOWN })
local dirty: { [Session]: true } = {}
local flushScheduled = false

local TradeService = {}

-- // Helpers //

local function isActive(session: Session): boolean
	return sessions[session.players[1]] == session
end

local function partnerOf(session: Session, player: Player): Player
	return if session.players[1] == player then session.players[2] else session.players[1]
end

-- Loaded, idle (not trading or in the auction house) and not waiting for an
-- earlier trade to settle.
local function canTrade(player: Player): boolean
	local data = PlayerService.getData(player)
	return data ~= nil
		and data.pendingTrade == nil
		and sessions[player] == nil
		and player.Parent == Players
		and PlayerStateService.getState(player) == "Idle"
end

local function asPlayer(value: Instance?): Player?
	if typeof(value) == "Instance" and value:IsA("Player") and value.Parent == Players then
		return value :: Player
	end
	return nil
end

local function flush()
	flushScheduled = false

	for session in dirty do
		if isActive(session) then
			for _, player in session.players do
				local partner = partnerOf(session, player)
				local view: TradeProtocol.View = {
					version = session.version,
					phase = session.phase,
					mine = session.offers[player],
					theirs = session.offers[partner],
					myReady = session.ready[player] == true,
					theirReady = session.ready[partner] == true,
				}
				network:fireClient(player, "onTradeState", partner, TradeProtocol.encode(view))
			end
		end
	end

	table.clear(dirty)
end

-- Sends both clients the session's state at the end of the frame.
local function markDirty(session: Session)
	dirty[session] = true
	if not flushScheduled then
		flushScheduled = true
		task.defer(flush)
	end
end

local function close(session: Session, reason: string)
	dirty[session] = nil
	for _, player in session.players do
		if sessions[player] == session then
			sessions[player] = nil
			network:fireClient(player, "onTradeEnded", reason)
		end
	end
	-- Idempotent, and harmless for a player who already left.
	for _, lease in session.leases do
		PlayerStateService.release(lease)
	end
end

-- An offer changed: everyone has to look again before the trade can go through.
local function changed(session: Session)
	session.version += 1
	session.phase = "negotiating"
	session.countdown += 1
	table.clear(session.ready)
	markDirty(session)
end

-- Opens a session if both players can take the "Trading" activity. Returns
-- false (changing nothing) if either can't.
local function open(a: Player, b: Player): boolean
	local leases = PlayerStateService.acquireAll({ a, b }, "Trading")
	if not leases then
		return false
	end

	requests[a] = nil
	requests[b] = nil

	local session: Session = {
		id = HttpService:GenerateGUID(false),
		players = { a, b },
		offers = { [a] = TradeEscrow.emptyOffer(), [b] = TradeEscrow.emptyOffer() },
		ready = {},
		version = 0,
		phase = "negotiating",
		countdown = 0,
		leases = leases,
	}
	sessions[a] = session
	sessions[b] = session
	markDirty(session)
	Log.debug(`Trade {session.id} opened: {a.Name} <-> {b.Name}`)
	return true
end

-- // Settlement //

-- Applies the outcome to whichever of `players` still hold the escrow here.
local function settle(players: { Player }, tradeId: string, outcome: Outcome)
	for _, player in players do
		PlayerService.updateData(player, function(data)
			TradeEscrow.settle(data, tradeId, outcome)
		end)
	end
end

local function holdsEscrow(players: { Player }, tradeId: string): boolean
	for _, player in players do
		local data = PlayerService.getData(player)
		if data and TradeEscrow.isEscrowed(data, tradeId) then
			return true
		end
	end
	return false
end

-- Gets the trade's outcome from the ledger (recording `proposed` if it has
-- none) and settles it for `players`. While the ledger is unreachable the
-- escrow stays put and this retries for as long as one of `players` holds it
-- on this server; a profile that leaves settles on its next load. Returns nil
-- if it gave up.
local function resolveAsync(tradeId: string, proposed: Outcome, players: { Player }): Outcome?
	while true do
		local outcome: Outcome? = TradeLedger.decideAsync(tradeId, proposed)
		if outcome then
			settle(players, tradeId, outcome)
			Log.debug(`Trade {tradeId} {outcome}`)
			-- No need to save right away: if this server dies first, the saved
			-- escrow settles the same way on the next load.
			return outcome
		end

		if not holdsEscrow(players, tradeId) then
			return nil
		end
		task.wait(LEDGER_RETRY)
	end
end

-- Saves every player's profile and yields until each saved copy holds the
-- escrow. False if any save fails, times out or loses its session.
local function persistEscrowAsync(players: { Player }, tradeId: string): boolean
	local thread = coroutine.running()
	local remaining = #players
	local allSaved = true
	local waiting = false

	local function isSaved(saved: any): boolean
		return TradeEscrow.isEscrowed(saved, tradeId)
	end

	for _, player in players do
		task.spawn(function()
			local saved = PlayerService.saveAsync(player, isSaved, SAVE_TIMEOUT)
			allSaved = allSaved and saved
			remaining -= 1
			if remaining == 0 and waiting then
				task.spawn(thread)
			end
		end)
	end

	if remaining > 0 then
		waiting = true
		coroutine.yield()
	end
	return allSaved
end

local function commitAsync(session: Session)
	local a, b = session.players[1], session.players[2]
	local offerA, offerB = session.offers[a], session.offers[b]
	local id = session.id

	-- 1. Escrow. TradeEscrow.open checks each side against its live data and
	-- moves the goods in the same step, with no yield until both are done.
	local openedA, openedB = false, false
	PlayerService.updateData(a, function(data)
		openedA = TradeEscrow.open(data, id, offerA, offerB)
	end)
	PlayerService.updateData(b, function(data)
		openedB = TradeEscrow.open(data, id, offerB, offerA)
	end)

	if not (openedA and openedB) then
		-- Nothing has yielded, so no save can hold the escrow: undo it here.
		settle(session.players, id, "aborted")
		close(session, "invalid")
		return
	end

	session.phase = "settling"
	markDirty(session)

	-- 2. Persist. Commit only once both escrows are on disk; otherwise a
	-- crash could keep one side's goods while the other side received them.
	local persisted = persistEscrowAsync(session.players, id)

	-- 3 and 4. Decide and settle.
	local outcome = resolveAsync(id, if persisted then "committed" else "aborted", session.players)
	close(session, if outcome == "committed" then "completed" elseif outcome == "aborted" then "failed" else "delayed")
end

-- A profile that loads with a pending trade finishes it before anything else.
local function onLoaded(player: Player)
	local data = PlayerService.getData(player)
	local pending = data and data.pendingTrade
	if pending then
		Log.info(`Resolving pending trade {pending.id} for {player.Name}`)
		resolveAsync(pending.id, "aborted", { player })
	end
end

local function onPlayerRemoving(player: Player)
	requests[player] = nil
	for _, incoming in requests do
		incoming[player] = nil
	end

	local session = sessions[player]
	-- A settling trade finishes on its own: the leaving profile's final save
	-- keeps the escrow, and the ledger decides.
	if session and session.phase ~= "settling" then
		close(session, "left")
	end
end

-- // Network handlers (client input is untrusted) //

function TradeService.requestTrade(player: Player, value: Instance?)
	local target = asPlayer(value)
	if not target or target == player then
		return
	end

	if not RateLimit.take(requestLimit, player) then
		return
	end
	local now = os.clock()

	if not canTrade(player) or not canTrade(target) then
		network:fireClient(player, "onTradeEnded", "unavailable")
		return
	end

	-- They already asked us: treat this as accepting.
	local theirs = requests[player]
	if theirs and (theirs[target] or 0) > now then
		if not open(target, player) then
			network:fireClient(player, "onTradeEnded", "unavailable")
		end
		return
	end

	local incoming: { [Player]: number } = requests[target] or {}
	requests[target] = incoming
	incoming[player] = now + TradeProtocol.REQUEST_TIMEOUT
	network:fireClient(target, "onTradeRequested", player)
end

function TradeService.respondTrade(player: Player, value: Instance?, accept: boolean)
	local requester = asPlayer(value)
	local incoming = requests[player]
	local expiresAt = requester and incoming and incoming[requester]
	if not requester or not incoming or not expiresAt then
		return
	end
	incoming[requester] = nil

	if not accept then
		network:fireClient(requester, "onTradeEnded", "declined")
	elseif expiresAt < os.clock() then
		network:fireClient(player, "onTradeEnded", "expired")
	elseif not canTrade(player) or not canTrade(requester) or not open(requester, player) then
		network:fireClient(player, "onTradeEnded", "unavailable")
	end
end

-- Sets how many of `itemId` the player offers (0 removes it).
function TradeService.setItem(player: Player, itemId: string, amount: number)
	local session = sessions[player]
	local data = PlayerService.getData(player)
	if not session or session.phase == "settling" or not data then
		return
	end

	local current = session.offers[player]
	local items = table.clone(current.items)
	if amount > 0 then
		items[itemId] = amount
	else
		items[itemId] = nil
	end
	local offer: Offer = { coins = current.coins, items = items }

	local ok, reason = TradeEscrow.validateOffer(data, offer)
	if not ok then
		Log.debug(`{player.Name}'s offer rejected: {reason}`)
		markDirty(session) -- resend, so the client drops its optimistic change
		return
	end

	session.offers[player] = offer
	changed(session)
end

function TradeService.setCoins(player: Player, coins: number)
	local session = sessions[player]
	local data = PlayerService.getData(player)
	if not session or session.phase == "settling" or not data then
		return
	end

	local current = session.offers[player]
	local offer: Offer = { coins = coins, items = current.items }

	local ok, reason = TradeEscrow.validateOffer(data, offer)
	if not ok then
		Log.debug(`{player.Name}'s offer rejected: {reason}`)
		markDirty(session)
		return
	end

	session.offers[player] = offer
	changed(session)
end

-- `version` is the offer version the client saw, so nobody can be ready for
-- an offer that changed under them.
function TradeService.setReady(player: Player, ready: boolean, version: number)
	local session = sessions[player]
	if not session or session.phase == "settling" then
		return
	end

	if ready and version ~= session.version then
		markDirty(session)
		return
	end

	if ready then
		session.ready[player] = true
	else
		session.ready[player] = nil
	end
	session.countdown += 1
	session.phase = "negotiating"

	local a, b = session.players[1], session.players[2]
	local hasGoods = not TradeEscrow.isEmpty(session.offers[a]) or not TradeEscrow.isEmpty(session.offers[b])
	if session.ready[a] and session.ready[b] and hasGoods then
		session.phase = "countdown"
		local countdown = session.countdown
		task.delay(TradeProtocol.COUNTDOWN, function()
			if isActive(session) and session.phase == "countdown" and session.countdown == countdown then
				commitAsync(session)
			end
		end)
	end

	markDirty(session)
end

function TradeService.cancelTrade(player: Player)
	local session = sessions[player]
	if session and session.phase ~= "settling" then
		close(session, "cancelled")
	end
end

-- // Lifecycle //

function TradeService.init()
	-- Every key that is also a function above is callable by clients.
	network = Network.server("Trade", TradeService, {
		requestTrade = { Packet.Instance }, -- client -> server
		respondTrade = { Packet.Instance, Packet.Boolean }, -- client -> server
		setItem = { Packet.String, Packet.NumberU16 }, -- client -> server
		setCoins = { Packet.NumberU32 }, -- client -> server
		setReady = { Packet.Boolean, Packet.NumberU32 }, -- client -> server
		cancelTrade = {}, -- client -> server
		onTradeRequested = { Packet.Instance }, -- server -> client
		onTradeState = { Packet.Instance, Packet.BufferLong }, -- server -> client
		onTradeEnded = { Packet.String }, -- server -> client
	})

	Players.PlayerRemoving:Connect(onPlayerRemoving)
	PlayerService.observeLoaded(onLoaded)
end

return TradeService
