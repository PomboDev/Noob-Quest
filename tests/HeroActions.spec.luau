local Angle = require("../src/core/Angle")
local CombatSim = require("../src/features/combat/modules/CombatSim")
local EnemySim = require("../src/features/enemies/modules/EnemySim")
local Expect = require("./Expect")
local HeroActions = require("../src/features/heroes/modules/HeroActions")
local HeroInput = require("../src/features/heroes/modules/HeroInput")
local LobbySpace = require("../src/features/world/modules/LobbySpace")
local SimClock = require("../src/features/sim/modules/SimClock")
local SimContext = require("../src/features/sim/modules/SimContext")
local WorldSim = require("../src/features/world/modules/WorldSim")

-- The middle of the lobby: open floor all round.
local X, Z = LobbySpace.X, LobbySpace.Z

local function setup()
	local ctx = SimContext.new()
	local deps: HeroActions.Deps = { combat = CombatSim.new(), enemies = EnemySim.new(), world = WorldSim.new() }
	local hero = HeroActions.new(deps.combat, ctx, 1, 100, "warrior", X, Z) :: HeroActions.Hero
	return ctx, deps, hero
end

local function enemyAt(ctx: SimContext.Ctx, deps: HeroActions.Deps, dx: number, dz: number): EnemySim.Enemy
	return EnemySim.spawn(deps.enemies, deps.combat, ctx, "grunt", X + dx, Z + dz, nil, 1) :: EnemySim.Enemy
end

local function attacking(aim: number, auto: boolean?): HeroInput.Input
	local input = HeroInput.idle()
	input.attack = true
	input.auto = auto == true
	input.aim = aim
	return input
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

-- Runs one tick the way Sim.step does.
local function step(
	ctx: SimContext.Ctx,
	deps: HeroActions.Deps,
	hero: HeroActions.Hero,
	input: HeroInput.Input
): number?
	local used = HeroActions.step(deps, ctx, hero, input)
	ctx.tick += 1
	return used
end

return {
	["a swing hits what is in the cone and in range, and nothing else"] = function()
		local ctx, deps, hero = setup()
		local ahead = enemyAt(ctx, deps, 5, 0)
		local angled = enemyAt(ctx, deps, 4, 4)
		local behind = enemyAt(ctx, deps, -5, 0)
		local far = enemyAt(ctx, deps, 20, 0)
		local aside = enemyAt(ctx, deps, 0, 6)

		step(ctx, deps, hero, attacking(Angle.QUARTER))
		Expect.equal(ahead.body.hp < ahead.body.maxHp, true)
		Expect.equal(angled.body.hp < angled.body.maxHp, true, "45 degrees off is inside a 100 degree cone")
		Expect.equal(behind.body.hp, behind.body.maxHp)
		Expect.equal(far.body.hp, far.body.maxHp)
		Expect.equal(aside.body.hp, aside.body.maxHp, "90 degrees off is outside it")

		local attacks = eventsOf(ctx, "heroAttack")
		Expect.equal(#attacks, 1)
		Expect.equal(attacks[1].userId, 100)
		Expect.equal(attacks[1].angle, Angle.QUARTER)
		Expect.equal(hero.sim.facing, Angle.QUARTER)
	end,

	["a held attack swings on the hero's own clock"] = function()
		local ctx, deps, hero = setup()
		local input = attacking(Angle.QUARTER)
		local swings = {}
		for tick = 1, 40 do
			step(ctx, deps, hero, input)
			if #eventsOf(ctx, "heroAttack") > #swings then
				table.insert(swings, tick)
			end
		end
		-- 0.55 s is 11 ticks: the first swing at once, then every 11th input after the last swing.
		Expect.deepEqual(swings, { 1, 11, 22, 33 })
	end,

	["crits come from the run's combat stream, so they repeat"] = function()
		local function crits(): { boolean }
			local ctx, deps, hero = setup()
			SimContext.reseed(ctx, 4242)
			for index = 1, 30 do
				enemyAt(ctx, deps, 2 + index % 3, 0)
			end
			local list = {}
			for _ = 1, 40 do
				table.clear(ctx.events)
				step(ctx, deps, hero, attacking(Angle.QUARTER))
				for _, event in eventsOf(ctx, "damage") do
					table.insert(list, event.crit)
				end
			end
			return list
		end

		local first = crits()
		Expect.equal(#first > 20, true)
		Expect.deepEqual(first, crits())
		local seen = { [true] = false, [false] = false }
		for _, crit in first do
			seen[crit] = true
		end
		Expect.equal(seen[true] and seen[false], true, "about one in twelve is a crit")
	end,

	["auto-target swings at the nearest enemy in range, whatever the aim says"] = function()
		local ctx, deps, hero = setup()
		-- Auto range is 12, but a swing only reaches 8.
		local near = enemyAt(ctx, deps, 0, 7)
		enemyAt(ctx, deps, 11, 0)

		step(ctx, deps, hero, attacking(Angle.HALF, true))
		Expect.equal(eventsOf(ctx, "heroAttack")[1].angle, 0, "towards +Z")
		Expect.equal(near.body.hp < near.body.maxHp, true)
	end,

	["auto-target with nothing in range doesn't swing or start the timer"] = function()
		local ctx, deps, hero = setup()
		enemyAt(ctx, deps, 0, 30)
		step(ctx, deps, hero, attacking(0, true))
		Expect.equal(#eventsOf(ctx, "heroAttack"), 0)

		local close = enemyAt(ctx, deps, 0, 6)
		step(ctx, deps, hero, attacking(0, true))
		Expect.equal(#eventsOf(ctx, "heroAttack"), 1, "swings the moment something comes close")
		Expect.equal(close.body.hp < close.body.maxHp, true)
	end,

	["a downed hero can't attack or use abilities, but can walk"] = function()
		local ctx, deps, hero = setup()
		local target = enemyAt(ctx, deps, 0, 4)
		CombatSim.applyDamage(deps.combat, ctx, nil, hero.entity.id, 1e9, "true")
		table.clear(ctx.events)

		local input = attacking(0)
		input.ability = 2
		input.moving = true
		input.moveAngle = 64
		step(ctx, deps, hero, input)
		Expect.equal(#eventsOf(ctx, "heroAttack"), 0)
		Expect.equal(#eventsOf(ctx, "abilityUsed"), 0)
		Expect.equal(target.body.hp, target.body.maxHp)
		Expect.equal(hero.sim.motion.x > X, true)
		Expect.equal(hero.entity.x, hero.sim.motion.x, "the body follows")
	end,

	["the dash hits what is on its path, and protects the hero while it lasts"] = function()
		local ctx, deps, hero = setup()
		local onPath = enemyAt(ctx, deps, 10, 0)
		local beside = enemyAt(ctx, deps, 10, 8)
		local beyond = enemyAt(ctx, deps, 26, 0)

		local input = HeroInput.idle()
		input.ability = 1
		input.aim = Angle.QUARTER
		step(ctx, deps, hero, input)

		Expect.equal(onPath.body.hp, onPath.body.maxHp - 30)
		Expect.equal(beside.body.hp, beside.body.maxHp)
		Expect.equal(beyond.body.hp, beyond.body.maxHp)
		Expect.equal(hero.entity.invulnerableUntil, SimClock.ticks(0.3), "0.3 s of i-frames from this tick")

		local used = eventsOf(ctx, "abilityUsed")
		Expect.equal(#used, 1)
		Expect.equal(used[1].index, 1)
		Expect.equal(used[1].angle, Angle.QUARTER)

		-- Nothing hurts the hero until they run out.
		Expect.equal(CombatSim.applyDamage(deps.combat, ctx, nil, hero.entity.id, 10, "true"), 0)
		ctx.tick = SimClock.ticks(0.3)
		Expect.equal(CombatSim.applyDamage(deps.combat, ctx, nil, hero.entity.id, 10, "true"), 10)
	end,

	["the slam hits and stuns everything round the hero"] = function()
		local ctx, deps, hero = setup()
		-- Tougher than the 45 damage of a slam, so they live to be stunned.
		EnemySim.setScaling(deps.enemies, 4, 1)
		local close = enemyAt(ctx, deps, 6, 6)
		local behind = enemyAt(ctx, deps, -12, 0)
		local out = enemyAt(ctx, deps, 15, 0)

		local input = HeroInput.idle()
		input.ability = 2
		step(ctx, deps, hero, input)

		Expect.equal(close.body.hp, close.body.maxHp - 45)
		Expect.equal(behind.body.hp, behind.body.maxHp - 45)
		Expect.equal(out.body.hp, out.body.maxHp)
		Expect.equal(close.stunUntil, 0 + SimClock.ticks(1.2))
		Expect.equal(out.stunUntil, 0)
	end,

	["an ability on cooldown is rejected with the ticks left"] = function()
		local ctx, deps, hero = setup()
		local input = HeroInput.idle()
		input.ability = 1
		step(ctx, deps, hero, input)
		table.clear(ctx.events)

		step(ctx, deps, hero, input)
		Expect.equal(#eventsOf(ctx, "abilityUsed"), 0)
		local rejected = eventsOf(ctx, "abilityRejected")
		Expect.equal(#rejected, 1)
		Expect.equal(rejected[1].slot, 1)
		Expect.equal(rejected[1].index, 1)
		Expect.equal(rejected[1].ticks, SimClock.ticks(4) - 1)
	end,

	["using an object is returned for the world to check"] = function()
		local ctx, deps, hero = setup()
		local input = HeroInput.idle()
		Expect.equal(step(ctx, deps, hero, input), nil)
		input.interact = 7
		Expect.equal(step(ctx, deps, hero, input), 7)
	end,

	["place stops a dash and tells the adapter"] = function()
		local ctx, deps, hero = setup()
		local input = HeroInput.idle()
		input.ability = 1
		step(ctx, deps, hero, input)
		Expect.equal(hero.sim.motion.dashLeft > 0, true)

		table.clear(ctx.events)
		HeroActions.place(ctx, hero, X + 3, Z + 4)
		Expect.equal(hero.sim.motion.dashLeft, 0)
		Expect.equal(hero.entity.x, X + 3)
		Expect.equal(hero.entity.z, Z + 4)
		local events = eventsOf(ctx, "teleport")
		Expect.equal(#events, 1)
		Expect.equal(events[1].slot, 1)
		Expect.equal(events[1].x, X + 3)
	end,

	["an unknown hero can't be added"] = function()
		local ctx = SimContext.new()
		Expect.equal(HeroActions.new(CombatSim.new(), ctx, 1, 1, "nobody", 0, 0), nil)
	end,
}
