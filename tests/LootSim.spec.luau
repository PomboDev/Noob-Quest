local Expect = require("./Expect")
local LootSim = require("../src/features/loot/modules/LootSim")
local LootTables = require("../src/features/loot/modules/LootTables")
local Rng = require("../src/core/Rng")
local SimClock = require("../src/features/sim/modules/SimClock")
local SimContext = require("../src/features/sim/modules/SimContext")

local function setup()
	return LootSim.new(), SimContext.new()
end

-- What lies on the ground for a slot, as "kind amount" strings in drop order.
local function ground(state: LootSim.State, slot: number): { string }
	local list = {}
	for _, drop in state.drops do
		if drop.slot == slot then
			table.insert(list, `{drop.kind} {drop.amount}`)
		end
	end
	return list
end

local function sorted(list: { string }): { string }
	table.sort(list)
	return list
end

local function eventsOf(ctx: SimContext.Ctx, kind: string): { SimContext.Event }
	local found = {}
	for _, event in ctx.events do
		if event.kind == kind then
			table.insert(found, event)
		end
	end
	return found
end

return {
	["a kill drops a copy for every slot, rolled from the enemy's seed"] = function()
		local state, ctx = setup()
		LootSim.dropFromKill(state, ctx, 12345, "golem", 100, 50, { 1, 2 })
		Expect.equal(#ground(state, 1) > 5, true, "the golem showers coins and orbs")
		Expect.equal(#ground(state, 2) > 5, true)
		Expect.equal(#eventsOf(ctx, "drop"), #state.drops)

		-- Every drop lands near the fall, within the scatter range.
		for _, drop in state.drops do
			local distance = math.sqrt((drop.x - 100) ^ 2 + (drop.z - 50) ^ 2)
			Expect.equal(distance >= 1.4 and distance <= 5.1, true, `distance {distance}`)
		end
	end,

	["the same seed gives the same loot, another seed gives other loot"] = function()
		local function loot(seed: number, slots: { number }): { string }
			local state, ctx = setup()
			LootSim.dropFromKill(state, ctx, seed, "golem", 0, 0, slots)
			local list = {}
			for _, drop in state.drops do
				table.insert(
					list,
					`{drop.slot} {drop.kind} {drop.amount} {string.format("%.17g %.17g", drop.x, drop.z)}`
				)
			end
			return list
		end

		Expect.deepEqual(loot(7, { 1, 2 }), loot(7, { 1, 2 }))
		Expect.equal(table.concat(loot(7, { 1, 2 }), ",") ~= table.concat(loot(8, { 1, 2 }), ","), true)
	end,

	["each slot rolls on its own, and not because of who else is in the party"] = function()
		local alone, ctxA = setup()
		LootSim.dropFromKill(alone, ctxA, 99, "golem", 0, 0, { 2 })
		local together, ctxB = setup()
		LootSim.dropFromKill(together, ctxB, 99, "golem", 0, 0, { 1, 2, 3 })

		Expect.deepEqual(ground(alone, 2), ground(together, 2), "slot 2's loot doesn't depend on slots 1 and 3")
		Expect.equal(
			table.concat(ground(together, 1), ",") ~= table.concat(ground(together, 2), ","),
			true,
			"slots don't share a roll"
		)
	end,

	["loot doesn't depend on the order enemies die in"] = function()
		local seeds = { 11, 22, 33, 44 }
		local function kill(order: { number }): { string }
			local state, ctx = setup()
			for _, index in order do
				LootSim.dropFromKill(state, ctx, seeds[index], "grunt", index * 10, 0, { 1 })
			end
			return sorted(ground(state, 1))
		end
		Expect.deepEqual(kill({ 1, 2, 3, 4 }), kill({ 4, 2, 1, 3 }))
	end,

	["an enemy without a table drops nothing"] = function()
		local state, ctx = setup()
		LootSim.dropFromKill(state, ctx, 1, "nobody", 0, 0, { 1 })
		Expect.equal(#state.drops, 0)
		Expect.equal(#ctx.events, 0)
	end,

	["dropFor places a pile from the rng it is given"] = function()
		local state, ctx = setup()
		LootSim.dropFor(state, ctx, Rng.new(5), 3, "coin", 20.9, 10, 10)
		LootSim.dropFor(state, ctx, Rng.new(5), 3, "xp", 0, 10, 10)
		Expect.deepEqual(ground(state, 3), { "coin 20" }, "whole amounts only, and nothing for zero")

		local other = LootSim.new()
		LootSim.dropFor(other, SimContext.new(), Rng.new(5), 3, "coin", 20, 10, 10)
		Expect.equal(other.drops[1].x, state.drops[1].x)
		Expect.equal(other.drops[1].z, state.drops[1].z)
	end,

	["a hero standing close picks a drop up, and only its owner"] = function()
		local state, ctx = setup()
		LootSim.dropFor(state, ctx, Rng.new(1), 1, "coin", 7, 0, 0)
		local drop = state.drops[1]
		table.clear(ctx.events)

		local picked: { string } = {}
		local function onPickup(slot: number, kind: LootTables.Kind, amount: number)
			table.insert(picked, `{slot} {kind} {amount}`)
		end

		LootSim.step(state, ctx, { [2] = { x = drop.x, z = drop.z } }, onPickup)
		Expect.equal(#state.drops, 1, "slot 2 can't take slot 1's drop")

		LootSim.step(state, ctx, { [1] = { x = drop.x + 20, z = drop.z } }, onPickup)
		Expect.equal(#state.drops, 1, "too far")

		LootSim.step(state, ctx, { [1] = { x = drop.x + 6, z = drop.z } }, onPickup)
		Expect.equal(#state.drops, 0, "the edge counts")
		Expect.deepEqual(picked, { "1 coin 7" })
		local events = eventsOf(ctx, "pickup")
		Expect.equal(#events, 1)
		Expect.equal(events[1].collected, true)
		Expect.equal(events[1].id, drop.id)
	end,

	["a drop expires after its lifetime"] = function()
		local state, ctx = setup()
		LootSim.dropFor(state, ctx, Rng.new(1), 1, "coin", 7, 0, 0)
		local lifetime = SimClock.ticks(90)

		ctx.tick = lifetime - 1
		LootSim.step(state, ctx, {}, nil)
		Expect.equal(#state.drops, 1)

		ctx.tick = lifetime
		table.clear(ctx.events)
		LootSim.step(state, ctx, {}, nil)
		Expect.equal(#state.drops, 0)
		Expect.equal(eventsOf(ctx, "pickup")[1].collected, false)
	end,

	["a full ground makes the oldest drop of that slot go"] = function()
		local state, ctx = setup()
		for index = 1, LootSim.MAX_PER_SLOT do
			LootSim.dropFor(state, ctx, Rng.new(index), 1, "coin", index, 0, 0)
		end
		LootSim.dropFor(state, ctx, Rng.new(1), 2, "coin", 1, 0, 0)
		Expect.equal(#state.drops, LootSim.MAX_PER_SLOT + 1)

		table.clear(ctx.events)
		LootSim.dropFor(state, ctx, Rng.new(9), 1, "coin", 999, 0, 0)
		Expect.equal(#ground(state, 1), LootSim.MAX_PER_SLOT)
		Expect.equal(ground(state, 1)[1], "coin 2", "coin 1 was the oldest")
		Expect.equal(#ground(state, 2), 1, "slot 2 is untouched")
		Expect.equal(eventsOf(ctx, "pickup")[1].collected, false)
	end,

	["despawnAll and removeSlot clear drops"] = function()
		local state, ctx = setup()
		LootSim.dropFor(state, ctx, Rng.new(1), 1, "coin", 7, 0, 0)
		LootSim.dropFor(state, ctx, Rng.new(2), 2, "coin", 8, 0, 0)
		LootSim.removeSlot(state, 1)
		Expect.deepEqual(ground(state, 2), { "coin 8" })
		Expect.equal(state.counts[1], nil)

		LootSim.despawnAll(state, ctx)
		Expect.equal(#state.drops, 0)
		Expect.equal(#eventsOf(ctx, "lootClear"), 1)
	end,

	["ids wrap and skip drops still on the ground"] = function()
		local state, ctx = setup()
		state.lastId = 65534
		LootSim.dropFor(state, ctx, Rng.new(1), 1, "coin", 1, 0, 0)
		LootSim.dropFor(state, ctx, Rng.new(2), 1, "coin", 1, 0, 0)
		LootSim.dropFor(state, ctx, Rng.new(3), 1, "coin", 1, 0, 0)
		Expect.deepEqual({ state.drops[1].id, state.drops[2].id, state.drops[3].id }, { 65535, 1, 2 })
	end,
}
