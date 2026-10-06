--!strict

--[=[
	Loot, as part of the simulation: the coins and XP that enemies and chests
	drop.

	Every drop belongs to one hero slot: a kill drops a copy for every hero, so
	in co-op nobody steals a drop and nobody waits for one. The owner picks a
	drop up by walking close to it.

	What an enemy drops is fixed by its `lootSeed` (picked when the act was
	generated, see WorldSim): each slot rolls from its own stream
	`Rng.derive(lootSeed, slot)`, so the loot doesn't depend on the order
	things die in, and heroes don't share rolls.

	Pure: time counts in ticks, randomness comes from the seed, and the owner
	of a drop is a slot number, never a Player. Reports with events.
]=]

local Angle = require("@Core/Angle")
local Checksum = require("@Features/sim/modules/Checksum")
local LootTables = require("@Features/loot/modules/LootTables")
local Rng = require("@Core/Rng")
local SimClock = require("@Features/sim/modules/SimClock")
local SimContext = require("@Features/sim/modules/SimContext")

type Kind = LootTables.Kind

export type Drop = {
	id: number,
	kind: Kind,
	amount: number,
	x: number,
	z: number,
	slot: number,
	-- The tick it disappears.
	expiresAt: number,
}

export type State = {
	-- In the order they were dropped.
	drops: { Drop },
	byId: { [number]: Drop },
	-- Drops on the ground per slot.
	counts: { [number]: number },
	lastId: number,
}

export type PickupCallback = (slot: number, kind: Kind, amount: number) -> ()

-- A hero this close picks a drop up.
local PICKUP_RADIUS = 6
-- How long a drop waits (seconds).
local LIFETIME = 90
-- Drops per slot on the ground at once. The oldest go first.
local MAX_PER_SLOT = 150
-- Drops land this far from where the enemy fell.
local SCATTER_MIN, SCATTER_MAX = 1.5, 5
-- Ids travel as NumberU16.
local MAX_ID = 65535

local LootSim = {}

LootSim.PICKUP_RADIUS = PICKUP_RADIUS
LootSim.MAX_PER_SLOT = MAX_PER_SLOT

function LootSim.new(): State
	return { drops = {}, byId = {}, counts = {}, lastId = 0 }
end

local function kindIndex(kind: Kind): number
	return table.find(LootTables.KINDS, kind) :: number
end

local function nextId(state: State): number?
	for _ = 1, MAX_ID do
		state.lastId = if state.lastId >= MAX_ID then 1 else state.lastId + 1
		if state.byId[state.lastId] == nil then
			return state.lastId
		end
	end
	return nil
end

local function describe(drop: Drop): SimContext.Event
	return {
		kind = "drop",
		slot = drop.slot,
		id = drop.id,
		item = kindIndex(drop.kind),
		amount = math.clamp(drop.amount, 0, 65535),
		x = drop.x,
		z = drop.z,
	}
end

-- Takes a drop off the ground. `collected` tells the owner whether they got it.
local function remove(state: State, ctx: SimContext.Ctx, drop: Drop, collected: boolean)
	if state.byId[drop.id] == nil then
		return
	end
	state.byId[drop.id] = nil
	local index = table.find(state.drops, drop)
	if index then
		table.remove(state.drops, index)
	end
	state.counts[drop.slot] = math.max(0, (state.counts[drop.slot] or 1) - 1)
	SimContext.emit(ctx, {
		kind = "pickup",
		slot = drop.slot,
		id = drop.id,
		collected = collected,
		item = kindIndex(drop.kind),
		amount = drop.amount,
	})
end

local function oldestOf(state: State, slot: number): Drop?
	for _, drop in state.drops do
		if drop.slot == slot then
			return drop
		end
	end
	return nil
end

-- Puts one pile or orb on the ground for a slot, near (x, z). Where it lands
-- comes from `rng`, always two numbers, so a full ground doesn't shift the rest.
local function add(
	state: State,
	ctx: SimContext.Ctx,
	rng: Rng.Rng,
	slot: number,
	kind: Kind,
	amount: number,
	x: number,
	z: number
)
	local angle = math.floor(Rng.next(rng) * Angle.TURN)
	local distance = SCATTER_MIN + Rng.next(rng) * (SCATTER_MAX - SCATTER_MIN)
	if amount <= 0 then
		return
	end

	if (state.counts[slot] or 0) >= MAX_PER_SLOT then
		local oldest = oldestOf(state, slot)
		if oldest then
			remove(state, ctx, oldest, false)
		end
	end

	local id = nextId(state)
	if id == nil then
		return
	end

	local sine, cosine = Angle.direction(angle)
	local drop: Drop = {
		id = id,
		kind = kind,
		amount = amount,
		x = x + sine * distance,
		z = z + cosine * distance,
		slot = slot,
		expiresAt = ctx.tick + SimClock.ticks(LIFETIME),
	}
	state.byId[id] = drop
	table.insert(state.drops, drop)
	state.counts[slot] = (state.counts[slot] or 0) + 1
	SimContext.emit(ctx, describe(drop))
end

-- One pile or orb for one slot, near (x, z). `rng` places it.
function LootSim.dropFor(
	state: State,
	ctx: SimContext.Ctx,
	rng: Rng.Rng,
	slot: number,
	kind: Kind,
	amount: number,
	x: number,
	z: number
)
	add(state, ctx, rng, slot, kind, math.floor(amount), x, z)
end

-- What a dead enemy leaves: a copy for every slot in `slots` (in that order),
-- each rolled from the enemy's `lootSeed` and the slot.
function LootSim.dropFromKill(
	state: State,
	ctx: SimContext.Ctx,
	lootSeed: number,
	defId: string,
	x: number,
	z: number,
	slots: { number }
)
	for _, slot in slots do
		local rng = Rng.new(Rng.derive(lootSeed, slot))
		local rolled = LootTables.roll(defId, function()
			return Rng.next(rng)
		end)
		for _, drop in rolled do
			add(state, ctx, rng, slot, drop.kind, drop.amount, x, z)
		end
	end
end

-- Forgets every drop of a slot that left, without telling anyone.
function LootSim.removeSlot(state: State, slot: number)
	local kept: { Drop } = {}
	for _, drop in state.drops do
		if drop.slot == slot then
			state.byId[drop.id] = nil
		else
			table.insert(kept, drop)
		end
	end
	state.drops = kept
	state.counts[slot] = nil
end

-- Clears every drop (the act or the run ended).
function LootSim.despawnAll(state: State, ctx: SimContext.Ctx)
	table.clear(state.drops)
	table.clear(state.byId)
	table.clear(state.counts)
	SimContext.emit(ctx, { kind = "lootClear" })
end

-- Expires old drops and lets heroes pick up what they stand near.
-- `positions` has the standing heroes by slot.
function LootSim.step(
	state: State,
	ctx: SimContext.Ctx,
	positions: { [number]: { x: number, z: number } },
	onPickup: PickupCallback?
)
	local limit = PICKUP_RADIUS * PICKUP_RADIUS
	-- Remove after the loop: `remove` edits the list being walked.
	local gone: { Drop } = {}
	local collected: { boolean } = {}
	for _, drop in state.drops do
		if ctx.tick >= drop.expiresAt then
			table.insert(gone, drop)
			table.insert(collected, false)
			continue
		end

		local position = positions[drop.slot]
		if position then
			local dx, dz = position.x - drop.x, position.z - drop.z
			if dx * dx + dz * dz <= limit then
				table.insert(gone, drop)
				table.insert(collected, true)
			end
		end
	end

	for index, drop in gone do
		remove(state, ctx, drop, collected[index])
		if collected[index] and onPickup then
			onPickup(drop.slot, drop.kind, drop.amount)
		end
	end
end

function LootSim.checksum(hash: Checksum.Hash, state: State)
	Checksum.section(hash, "loot")
	Checksum.number(hash, state.lastId)
	for _, drop in state.drops do
		Checksum.number(hash, drop.id)
		Checksum.number(hash, kindIndex(drop.kind))
		Checksum.number(hash, drop.amount)
		Checksum.number(hash, drop.x)
		Checksum.number(hash, drop.z)
		Checksum.number(hash, drop.slot)
		Checksum.number(hash, drop.expiresAt)
	end
end

return LootSim
