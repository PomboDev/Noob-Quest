--!strict

--[=[
	What one player is doing, as far as activities that must not overlap go,
	and the leases that hold it. Pure: PlayerStateServiceServer keeps one slot
	per connected player, and the specs drive slots directly.

		Loading ──Loaded──▶ Idle ⇄ Trading              BeginTrade / EndTrade
		                     ⇅                          OpenAuction / CloseAuction
		                  Auction
		                  ├─ Browsing ⇄ Transacting     BeginTransaction / EndTransaction
		                  └─ Transacting ──▶ Idle       EndTransaction, if a close was requested

	An activity is held through a lease: acquire() returns a lease id, and the
	calls that change or end the activity must present it. Ids grow with every
	acquisition, so a release that arrives late (a trade closing twice, a
	timeout racing a close) can't end a hold that started after it.

	Releasing the auction while a transaction runs only requests the close:
	the player stays in Transacting (so still out of trades) until the
	transaction ends, then goes straight to Idle.
]=]

local StateMachine = require("@Core/StateMachine")

export type State = "Loading" | "Idle" | "Trading" | "Browsing" | "Transacting"
export type Activity = "Trading" | "Auction"

type Context = {
	-- The auction was released while a transaction ran.
	closeRequested: boolean,
}

export type Slot = {
	machine: StateMachine.Machine<Context>,
	-- The latest lease handed out; no other id is honored.
	lease: number,
}

local Loading: StateMachine.State<Context> = StateMachine.state({ name = "Loading" } :: StateMachine.State<Context>)
local Idle: StateMachine.State<Context> = StateMachine.state({ name = "Idle" } :: StateMachine.State<Context>)
local Trading: StateMachine.State<Context> = StateMachine.state({ name = "Trading" } :: StateMachine.State<Context>)
local Auction: StateMachine.State<Context> = StateMachine.state({
	name = "Auction",
	exit = function(context: Context)
		context.closeRequested = false
	end,
})
local Browsing: StateMachine.State<Context> = StateMachine.state({ name = "Browsing", parent = Auction })
local Transacting: StateMachine.State<Context> = StateMachine.state({ name = "Transacting", parent = Auction })

local STATES = { Loading, Idle, Trading, Auction, Browsing, Transacting }

local TRANSITIONS: { StateMachine.TransitionConfig<Context> } = {
	{ from = Loading, to = Idle, event = "Loaded" },
	{ from = Idle, to = Trading, event = "BeginTrade" },
	{ from = Trading, to = Idle, event = "EndTrade" },
	{ from = Idle, to = Browsing, event = "OpenAuction" },
	{ from = Browsing, to = Idle, event = "CloseAuction" },
	{ from = Browsing, to = Transacting, event = "BeginTransaction" },
	{
		from = Transacting,
		to = Idle,
		event = "EndTransaction",
		guard = function(context: Context): boolean
			return context.closeRequested
		end,
	},
	{ from = Transacting, to = Browsing, event = "EndTransaction" },
}

local PlayerStateMachine = {}

-- A slot for a player who just joined: Loading until markLoaded.
function PlayerStateMachine.new(): Slot
	return {
		machine = StateMachine.create({
			initial = Loading,
			states = STATES,
			transitions = TRANSITIONS,
			context = { closeRequested = false },
		}),
		lease = 0,
	}
end

function PlayerStateMachine.getState(slot: Slot): State
	return StateMachine.getState(slot.machine) :: State
end

-- Loading -> Idle. False if the slot was already loaded.
function PlayerStateMachine.markLoaded(slot: Slot): boolean
	return StateMachine.send(slot.machine, "Loaded")
end

-- Starts `activity` if the player is idle, and returns the id of the lease
-- that holds it. Nil (changing nothing) otherwise.
function PlayerStateMachine.acquire(slot: Slot, activity: Activity): number?
	local event = if activity == "Trading" then "BeginTrade" else "OpenAuction"
	if not StateMachine.send(slot.machine, event) then
		return nil
	end

	slot.lease += 1
	return slot.lease
end

-- Whether `lease` still holds the slot's current activity.
function PlayerStateMachine.holds(slot: Slot, lease: number): boolean
	local state = PlayerStateMachine.getState(slot)
	return lease == slot.lease and state ~= "Idle" and state ~= "Loading"
end

-- Ends the activity `lease` holds; during a transaction, only once it ends.
-- Returns false (changing nothing) if the lease no longer holds anything, so
-- releasing twice or with a stale lease is harmless.
function PlayerStateMachine.release(slot: Slot, lease: number): boolean
	if not PlayerStateMachine.holds(slot, lease) then
		return false
	end

	local machine = slot.machine
	if StateMachine.isState(machine, "Transacting") then
		machine.context.closeRequested = true
		return true
	end
	return StateMachine.send(machine, if StateMachine.isState(machine, "Trading") then "EndTrade" else "CloseAuction")
end

-- Browsing -> Transacting: one auction transaction at a time.
function PlayerStateMachine.beginTransaction(slot: Slot, lease: number): boolean
	return PlayerStateMachine.holds(slot, lease)
		and StateMachine.isState(slot.machine, "Browsing")
		and StateMachine.send(slot.machine, "BeginTransaction")
end

-- Transacting -> Browsing, or Idle if the auction was released meanwhile.
function PlayerStateMachine.endTransaction(slot: Slot, lease: number): boolean
	return PlayerStateMachine.holds(slot, lease)
		and StateMachine.isState(slot.machine, "Transacting")
		and StateMachine.send(slot.machine, "EndTransaction")
end

return PlayerStateMachine
