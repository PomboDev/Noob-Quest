--!strict

--[=[
	What every part of the simulation shares for one step: the tick number, the
	events it has produced so far, and the random number streams.

	An event is a plain table with a `kind` and whatever else the adapters
	need to turn it into a network message, an Instance or a profile write.
	The sim never calls out: it only appends events, so a replay can ignore
	them. Randomness comes from these streams and from seeds kept in the
	state, never from `math.random` or `Random`.
]=]

local Rng = require("@Core/Rng")

export type Event = { kind: string, [string]: any }

-- One stream per purpose, so a change in one doesn't shift the others.
export type Rngs = {
	-- Crits.
	combat: Rng.Rng,
	-- The wave director and where waves appear.
	director: Rng.Rng,
	-- Loot seeds of enemies that weren't placed at generation (waves, summons).
	loot: Rng.Rng,
}

export type Ctx = {
	-- The number of the step being run (0 for the first).
	tick: number,
	events: { Event },
	rng: Rngs,
}

local SimContext = {}

-- The salts that turn a run's loot seed into the streams.
local SALT_COMBAT, SALT_DIRECTOR, SALT_LOOT = 1, 2, 3

local function streams(seed: number): Rngs
	return {
		combat = Rng.new(Rng.derive(seed, SALT_COMBAT)),
		director = Rng.new(Rng.derive(seed, SALT_DIRECTOR)),
		loot = Rng.new(Rng.derive(seed, SALT_LOOT)),
	}
end

function SimContext.new(): Ctx
	return { tick = 0, events = {}, rng = streams(0) }
end

-- Starts the streams again from a run's seed.
function SimContext.reseed(ctx: Ctx, seed: number)
	ctx.rng = streams(seed)
end

function SimContext.emit(ctx: Ctx, event: Event)
	table.insert(ctx.events, event)
end

-- A seed for something spawned without one: the next number of the loot stream.
function SimContext.nextSeed(ctx: Ctx): number
	return math.floor(Rng.next(ctx.rng.loot) * 4294967296)
end

return SimContext
