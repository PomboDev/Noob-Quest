--!strict

--[=[
	The player state manager: what every connected player is doing, for the
	features that must not overlap. Trading and the auction house each hold
	their activity through a lease (see PlayerStateMachine), so a player is
	never in both, and a player in the middle of an auction transaction can't
	start or accept a trade.

		local lease = PlayerStateService.acquire(player, "Auction")
		if lease then
			-- ...
			PlayerStateService.release(lease)
		end

	State lives in memory, per server. ProfileStore already keeps a profile
	on one server at a time, and what keeps goods safe across crashes is the
	escrow in each player's data, not these locks. A slot is created when the
	player joins (Loading), becomes Idle once their data has loaded, and is
	dropped when they leave, which ends every lease they held: a disconnect,
	crash or kick never leaves a lock behind. Releasing is idempotent and a
	stale lease is ignored, so features can release from every exit path
	without coordinating.

	Clients are told their state (onStateChanged) but never set it.
]=]

local Players = game:GetService("Players")

local Log = require("@Core/Log")
local Network = require("@Core/Network")
local PlayerService = require("@Features/player/PlayerServiceServer")
local PlayerStateMachine = require("@Features/playerState/modules/PlayerStateMachine")

export type State = PlayerStateMachine.State
export type Activity = PlayerStateMachine.Activity

-- Proof of holding an activity. Plain data: pass it back to release.
export type Lease = {
	player: Player,
	id: number,
}

local network: Network.ServerNetwork

local slots: { [Player]: PlayerStateMachine.Slot } = {}
-- The state each client was last sent.
local sent: { [Player]: State } = {}
local dirty: { [Player]: true } = {}
local flushScheduled = false

local PlayerStateService = {}

-- Sends each changed state once per frame, so a transaction that starts and
-- ends within one frame costs no messages.
local function flush()
	flushScheduled = false

	for player in dirty do
		local slot = slots[player]
		if slot then
			local state: State = PlayerStateMachine.getState(slot)
			if sent[player] ~= state then
				sent[player] = state
				network:fireClient(player, "onStateChanged", state)
			end
		end
	end

	table.clear(dirty)
end

local function markDirty(player: Player)
	dirty[player] = true
	if not flushScheduled then
		flushScheduled = true
		task.defer(flush)
	end
end

local function slotOf(lease: Lease): PlayerStateMachine.Slot?
	return slots[lease.player]
end

local function onPlayerAdded(player: Player)
	if not slots[player] then
		slots[player] = PlayerStateMachine.new()
	end
end

local function onLoaded(player: Player)
	local slot = slots[player]
	if slot and PlayerStateMachine.markLoaded(slot) then
		markDirty(player)
	end
end

local function onPlayerRemoving(player: Player)
	slots[player] = nil
	sent[player] = nil
	dirty[player] = nil
end

-- The player's state, or nil if they aren't (or are no longer) connected.
function PlayerStateService.getState(player: Player): State?
	local slot = slots[player]
	return if slot then PlayerStateMachine.getState(slot) else nil
end

-- Starts `activity` for an idle player. Nil if they are loading, busy with
-- something else or gone.
function PlayerStateService.acquire(player: Player, activity: Activity): Lease?
	local slot = slots[player]
	local id = if slot then PlayerStateMachine.acquire(slot, activity) else nil
	if not id then
		return nil
	end

	markDirty(player)
	Log.debug(`{player.Name} started {activity}`)
	return { player = player, id = id }
end

-- Starts `activity` for every player or for none: nothing yields in between,
-- so no one's state can change halfway.
function PlayerStateService.acquireAll(players: { Player }, activity: Activity): { Lease }?
	local leases: { Lease } = {}
	for _, player in players do
		local lease = PlayerStateService.acquire(player, activity)
		if not lease then
			for _, held in leases do
				PlayerStateService.release(held)
			end
			return nil
		end
		table.insert(leases, lease)
	end
	return leases
end

-- Whether `lease` still holds its player's activity.
function PlayerStateService.holds(lease: Lease): boolean
	local slot = slotOf(lease)
	return slot ~= nil and PlayerStateMachine.holds(slot, lease.id)
end

-- Ends the activity `lease` holds (an auction transaction finishes first).
-- Safe to call any number of times, and after the player left.
function PlayerStateService.release(lease: Lease)
	local slot = slotOf(lease)
	if slot and PlayerStateMachine.release(slot, lease.id) then
		markDirty(lease.player)
		-- Still Transacting if the release waits for a transaction to end.
		Log.debug(`{lease.player.Name} released their activity, now {PlayerStateMachine.getState(slot)}`)
	end
end

-- Moves an auction lease into a transaction. False if the player isn't
-- browsing (another transaction is running, or the lease is stale).
function PlayerStateService.beginTransaction(lease: Lease): boolean
	local slot = slotOf(lease)
	if slot and PlayerStateMachine.beginTransaction(slot, lease.id) then
		markDirty(lease.player)
		return true
	end
	return false
end

-- Ends the transaction `lease` is in. Safe to call after the player left.
function PlayerStateService.endTransaction(lease: Lease)
	local slot = slotOf(lease)
	if slot and PlayerStateMachine.endTransaction(slot, lease.id) then
		markDirty(lease.player)
	end
end

-- Network: the client (re)started listening; send it the current state.
function PlayerStateService.requestState(player: Player)
	if slots[player] then
		sent[player] = nil
		markDirty(player)
	end
end

function PlayerStateService.init()
	-- Only requestState is callable by clients.
	network = Network.server("PlayerState", PlayerStateService, {
		requestState = {}, -- client -> server
		onStateChanged = { Network.Packet.String }, -- server -> client
	})

	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(onPlayerRemoving)
	for _, player in Players:GetPlayers() do
		onPlayerAdded(player)
	end

	PlayerService.observeLoaded(onLoaded)
end

return PlayerStateService
