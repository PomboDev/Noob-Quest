local Checksum = require("../src/features/sim/modules/Checksum")
local CombatSim = require("../src/features/combat/modules/CombatSim")
local Expect = require("./Expect")
local SimContext = require("../src/features/sim/modules/SimContext")

local function setup()
	return CombatSim.new(), SimContext.new()
end

local function kinds(ctx: SimContext.Ctx): { string }
	local list = {}
	for _, event in ctx.events do
		table.insert(list, event.kind)
	end
	return list
end

return {
	["registering a hero reports its health, an enemy doesn't"] = function()
		local state, ctx = setup()
		local hero = CombatSim.register(state, ctx, "hero", 100, 0, 1, 2)
		Expect.deepEqual(kinds(ctx), { "heroHealth" })
		Expect.equal(ctx.events[1].id, hero.id)
		Expect.equal(ctx.events[1].hp, 100)

		CombatSim.register(state, ctx, "enemy", 40, 0, 0, 0)
		Expect.equal(#ctx.events, 1)
	end,

	["damage applies armor, crits, and is capped at the target's hit points"] = function()
		local state, ctx = setup()
		local enemy = CombatSim.register(state, ctx, "enemy", 100, 100, 5, 6)
		-- 100 armor halves a hit.
		Expect.equal(CombatSim.applyDamage(state, ctx, nil, enemy.id, 20, "physical"), 10)
		Expect.equal(CombatSim.applyDamage(state, ctx, nil, enemy.id, 20, "physical", true), 20)
		Expect.equal(CombatSim.applyDamage(state, ctx, nil, enemy.id, 20, "true"), 20)
		Expect.equal(enemy.hp, 50)
		-- The last hit only takes what is left.
		Expect.equal(CombatSim.applyDamage(state, ctx, nil, enemy.id, 9999, "true"), 50)

		local damage = ctx.events[1]
		Expect.equal(damage.kind, "damage")
		Expect.equal(damage.id, enemy.id)
		Expect.equal(damage.x, 5)
		Expect.equal(damage.z, 6)
		Expect.equal(damage.damage, 10)
		Expect.equal(damage.crit, false)
		Expect.equal(ctx.events[2].crit, true)
	end,

	["bad amounts and unknown targets do nothing"] = function()
		local state, ctx = setup()
		local enemy = CombatSim.register(state, ctx, "enemy", 100, 0, 0, 0)
		for _, amount in { 0, -5, 0 / 0, math.huge } do
			Expect.equal(CombatSim.applyDamage(state, ctx, nil, enemy.id, amount, "physical"), 0)
		end
		Expect.equal(CombatSim.applyDamage(state, ctx, nil, 999, 10, "physical"), 0)
		Expect.equal(enemy.hp, 100)
		Expect.equal(#ctx.events, 0)
	end,

	["a death is queued and announced once, and the dead take no more damage"] = function()
		local state, ctx = setup()
		local hero = CombatSim.register(state, ctx, "hero", 30, 0, 3, 4)
		local enemy = CombatSim.register(state, ctx, "enemy", 10, 0, 0, 0)
		table.clear(ctx.events)

		CombatSim.applyDamage(state, ctx, enemy.id, hero.id, 1000, "true")
		Expect.equal(hero.dead, true)
		Expect.deepEqual(kinds(ctx), { "damage", "heroHealth", "died" })
		Expect.equal(ctx.events[3].hero, true)
		Expect.equal(CombatSim.applyDamage(state, ctx, enemy.id, hero.id, 5, "true"), 0)

		local deaths = CombatSim.popDeaths(state)
		Expect.equal(#deaths, 1)
		Expect.equal(deaths[1].id, hero.id)
		Expect.equal(deaths[1].sourceId, enemy.id)
		Expect.equal(#CombatSim.popDeaths(state), 0, "popped once")
	end,

	["invulnerability lasts until its tick and never gets shorter"] = function()
		local state, ctx = setup()
		local hero = CombatSim.register(state, ctx, "hero", 100, 0, 0, 0)
		ctx.tick = 10
		CombatSim.setInvulnerable(state, ctx, hero.id, 6)
		CombatSim.setInvulnerable(state, ctx, hero.id, 2)
		ctx.tick = 15
		Expect.equal(CombatSim.applyDamage(state, ctx, nil, hero.id, 5, "true"), 0, "still protected at tick 15")
		ctx.tick = 16
		Expect.equal(CombatSim.applyDamage(state, ctx, nil, hero.id, 5, "true"), 5, "over at tick 16")
	end,

	["heal stops at the maximum and skips the dead, revive brings them back"] = function()
		local state, ctx = setup()
		local hero = CombatSim.register(state, ctx, "hero", 100, 0, 0, 0)
		CombatSim.applyDamage(state, ctx, nil, hero.id, 40, "true")
		CombatSim.heal(state, ctx, hero.id, 1000)
		Expect.equal(hero.hp, 100)

		CombatSim.applyDamage(state, ctx, nil, hero.id, 1000, "true")
		CombatSim.heal(state, ctx, hero.id, 10)
		Expect.equal(hero.hp, 0, "no healing the dead")
		CombatSim.revive(state, ctx, hero.id, 30)
		Expect.equal(hero.dead, false)
		Expect.equal(hero.hp, 30)
		CombatSim.revive(state, ctx, hero.id)
		Expect.equal(hero.hp, 100)
	end,

	["points list the living of a team in registration order"] = function()
		local state, ctx = setup()
		local a = CombatSim.register(state, ctx, "enemy", 10, 0, 1, 1)
		local b = CombatSim.register(state, ctx, "enemy", 10, 0, 2, 2)
		CombatSim.register(state, ctx, "hero", 10, 0, 3, 3)
		local c = CombatSim.register(state, ctx, "enemy", 10, 0, 4, 4)
		CombatSim.applyDamage(state, ctx, nil, b.id, 1000, "true")

		local points = CombatSim.points(state, "enemy")
		Expect.equal(#points, 2)
		Expect.equal(points[1].id, a.id)
		Expect.equal(points[2].id, c.id)
		Expect.equal(points[2].x, 4)
	end,

	["ids are reused only once free, and wrap"] = function()
		local state, ctx = setup()
		state.lastId = 65534
		local a = CombatSim.register(state, ctx, "enemy", 1, 0, 0, 0)
		local b = CombatSim.register(state, ctx, "enemy", 1, 0, 0, 0)
		Expect.equal(a.id, 65535)
		Expect.equal(b.id, 1, "wrapped")
		CombatSim.unregister(state, a.id)
		Expect.equal(CombatSim.get(state, a.id), nil)
		Expect.equal(CombatSim.register(state, ctx, "enemy", 1, 0, 0, 0).id, 2)
	end,

	["the checksum changes with the state and not otherwise"] = function()
		local function sum(state: CombatSim.State): number
			local hash = Checksum.new()
			CombatSim.checksum(hash, state)
			return Checksum.result(hash)
		end

		local a, ctxA = setup()
		local b, ctxB = setup()
		for _, pair in { { a, ctxA }, { b, ctxB } } do
			CombatSim.register(pair[1], pair[2], "enemy", 50, 0, 1.5, 2.5)
		end
		Expect.equal(sum(a), sum(b))

		CombatSim.applyDamage(a, ctxA, nil, 1, 1, "true")
		Expect.equal(sum(a) ~= sum(b), true)
		CombatSim.applyDamage(b, ctxB, nil, 1, 1, "true")
		Expect.equal(sum(a), sum(b))
		a.entities[1].x += 1e-12
		Expect.equal(sum(a) ~= sum(b), true, "even the last bit of a position counts")
	end,
}
