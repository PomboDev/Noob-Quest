local Checksum = require("../src/features/sim/modules/Checksum")
local CombatSim = require("../src/features/combat/modules/CombatSim")
local EnemyDefs = require("../src/features/enemies/modules/EnemyDefs")
local EnemySim = require("../src/features/enemies/modules/EnemySim")
local EnemySnapshot = require("../src/features/enemies/modules/EnemySnapshot")
local Expect = require("./Expect")
local NavGrid = require("../src/features/enemies/modules/NavGrid")
local SimClock = require("../src/features/sim/modules/SimClock")
local SimContext = require("../src/features/sim/modules/SimContext")

local function world()
	return CombatSim.new(), SimContext.new(), EnemySim.new()
end

local function hero(combat: CombatSim.State, ctx: SimContext.Ctx, x: number, z: number, hp: number?)
	return CombatSim.register(combat, ctx, "hero", hp or 100, 0, x, z)
end

local function spawn(
	combat: CombatSim.State,
	ctx: SimContext.Ctx,
	sim: EnemySim.State,
	defId: string,
	x: number,
	z: number,
	group: string?
)
	return EnemySim.spawn(sim, combat, ctx, defId, x, z, group, 1) :: EnemySim.Enemy
end

-- Runs `count` ticks the way Sim.step does: step, then the clock moves on.
local function run(combat: CombatSim.State, ctx: SimContext.Ctx, sim: EnemySim.State, count: number)
	for _ = 1, count do
		EnemySim.step(sim, combat, ctx)
		ctx.tick += 1
	end
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

local function near(actual: number, expected: number, tolerance: number, label: string?)
	if math.abs(actual - expected) > tolerance then
		error(`{label or "value"}: expected {expected} ± {tolerance}, got {actual}`, 2)
	end
end

-- A walkable room with a wall across the middle, gap at the bottom.
local function room(): NavGrid.Grid
	local walkable = table.create(20 * 20, true)
	for cy = 0, 14 do
		walkable[cy * 20 + 10 + 1] = false
	end
	return NavGrid.new(20, 20, 4, 0, 0, walkable)
end

return {
	["spawning registers a body, tells the clients and counts towards the cap"] = function()
		local combat, ctx, sim = world()
		local enemy = spawn(combat, ctx, sim, "grunt", 3, 4)
		Expect.equal(enemy.body.hp, 40)
		Expect.equal(enemy.body.team, "enemy")
		Expect.equal(CombatSim.get(combat, enemy.body.id), enemy.body)
		Expect.equal(sim.aliveCount, 1)

		local events = eventsOf(ctx, "spawn")
		Expect.equal(#events, 1)
		Expect.equal(events[1].id, enemy.body.id)
		Expect.equal(events[1].def, EnemyDefs.indexOf("grunt"))

		Expect.equal(EnemySim.spawn(sim, combat, ctx, "nobody", 0, 0, nil, 1), nil)
	end,

	["the cap stops spawns but not the boss"] = function()
		local combat, ctx, sim = world()
		for index = 1, EnemySim.MAX_ALIVE do
			spawn(combat, ctx, sim, "grunt", index, 0)
		end
		Expect.equal(EnemySim.capacity(sim), 0)
		Expect.equal(EnemySim.spawn(sim, combat, ctx, "grunt", 0, 0, nil, 1), nil)
		Expect.equal(EnemySim.spawn(sim, combat, ctx, "golem", 0, 0, nil, 1) ~= nil, true)
	end,

	["hp scales with the difficulty it spawns under, and damage too"] = function()
		local combat, ctx, sim = world()
		EnemySim.setScaling(sim, 2, 1.5)
		local enemy = spawn(combat, ctx, sim, "grunt", 0, 0)
		Expect.equal(enemy.body.maxHp, 80)
		Expect.equal(enemy.damageScale, 1.5)
		EnemySim.setScaling(sim, 1, 1)
		Expect.equal(enemy.damageScale, 1.5, "enemies already alive keep theirs")
	end,

	["without a loot seed it takes the next one from the run's stream, the same every time"] = function()
		local function seeds(): { number }
			local combat, ctx, sim = world()
			local list = {}
			for _ = 1, 3 do
				table.insert(list, (EnemySim.spawn(sim, combat, ctx, "grunt", 0, 0) :: EnemySim.Enemy).lootSeed)
			end
			return list
		end
		local first = seeds()
		Expect.deepEqual(first, seeds())
		Expect.equal(first[1] ~= first[2], true)
	end,

	["a hunting enemy walks at its speed towards the nearest hero"] = function()
		local combat, ctx, sim = world()
		hero(combat, ctx, 50, 0)
		local enemy = spawn(combat, ctx, sim, "grunt", 0, 0)
		run(combat, ctx, sim, 10)
		-- 9 studs a second for half a second.
		near(enemy.body.x, 4.5, 1e-9, "x")
		near(enemy.body.z, 0, 1e-9, "z")
		Expect.equal(enemy.angle, 16384, "faces +X")
	end,

	["enemies walk round walls by the flow field"] = function()
		local combat, ctx, sim = world()
		EnemySim.setNavGrid(sim, room())
		-- The wall is at x = 40 to 44, down to z = 60: the way round is below it.
		hero(combat, ctx, 60, 10)
		local enemy = spawn(combat, ctx, sim, "runner", 20, 10)
		run(combat, ctx, sim, 120)
		Expect.equal(enemy.body.x > 44, true, `went round the wall, at {enemy.body.x}`)
	end,

	["an attack winds up, then hits only if the hero is still in reach"] = function()
		local combat, ctx, sim = world()
		local target = hero(combat, ctx, 2, 0)
		spawn(combat, ctx, sim, "grunt", 0, 0)

		-- Ready at tick 10, the wind-up is 0.4 s = 8 ticks.
		run(combat, ctx, sim, 18)
		Expect.equal(target.hp, 100, "no damage before the wind-up ends")
		run(combat, ctx, sim, 1)
		Expect.equal(target.hp, 92)

		-- The cooldown is 1.2 s = 24 ticks from the hit.
		run(combat, ctx, sim, 23)
		Expect.equal(target.hp, 92)
		-- Next wind-up starts at tick 18 + 24 = 42; the hero steps out of reach.
		run(combat, ctx, sim, 1)
		target.x = 30
		run(combat, ctx, sim, 20)
		Expect.equal(target.hp, 92, "a hero that left the reach isn't hit")
	end,

	["a ranged enemy keeps its distance and its projectile hits"] = function()
		local combat, ctx, sim = world()
		local target = hero(combat, ctx, 20, 0)
		local enemy = spawn(combat, ctx, sim, "spitter", 0, 0)
		run(combat, ctx, sim, 45)
		Expect.equal(target.hp, 90)
		Expect.equal(#eventsOf(ctx, "projectile"), 1)
		Expect.equal(#sim.projectiles, 0, "spent on the hit")
		near(enemy.body.x, 0, 1e-9, "it stood its ground")

		local shot = eventsOf(ctx, "projectile")[1]
		near(shot.vx, 40, 1e-3)
		near(shot.life, 1.2, 1e-9)
	end,

	["stun stops an enemy and breaks its wind-up, and never shortens"] = function()
		local combat, ctx, sim = world()
		local target = hero(combat, ctx, 2, 0)
		local enemy = spawn(combat, ctx, sim, "grunt", 0, 0)
		run(combat, ctx, sim, 12)
		Expect.equal(enemy.telegraphUntil > 0, true, "winding up")

		EnemySim.stun(sim, ctx, enemy.body.id, 30)
		EnemySim.stun(sim, ctx, enemy.body.id, 5)
		Expect.equal(enemy.stunUntil, ctx.tick + 30)
		run(combat, ctx, sim, 29)
		Expect.equal(enemy.telegraphUntil, 0)
		Expect.equal(target.hp, 100)
		-- Out of the stun, it winds up and hits again.
		run(combat, ctx, sim, 30)
		Expect.equal(target.hp, 92)
	end,

	["the boss shrugs off stuns"] = function()
		local combat, ctx, sim = world()
		local boss = spawn(combat, ctx, sim, "golem", 0, 0)
		EnemySim.stun(sim, ctx, boss.body.id, 100)
		Expect.equal(boss.stunUntil, 0)
	end,

	["a camp stands idle until a hero comes close, then all of it wakes"] = function()
		local combat, ctx, sim = world()
		local target = hero(combat, ctx, 0, 0)
		local a = spawn(combat, ctx, sim, "grunt", 100, 0, "camp_1")
		local b = spawn(combat, ctx, sim, "grunt", 105, 0, "camp_1")
		local other = spawn(combat, ctx, sim, "grunt", 100, 80, "camp_2")
		run(combat, ctx, sim, 20)
		Expect.equal(a.body.x, 100, "idle")
		Expect.equal(b.body.x, 105)

		target.x = 75
		run(combat, ctx, sim, 2)
		Expect.equal(a.body.x < 100, true, "the member in range hunts")
		Expect.equal(b.body.x < 105, true, "so does the rest of its camp, however far")
		Expect.equal(other.body.z, 80, "another camp is left alone")
	end,

	["hurting one of a camp wakes all of it"] = function()
		local combat, ctx, sim = world()
		-- Too far to wake them (30), near enough to hunt (90).
		hero(combat, ctx, 30, 0)
		local a = spawn(combat, ctx, sim, "grunt", 100, 0, "camp_1")
		local b = spawn(combat, ctx, sim, "grunt", 105, 0, "camp_1")
		run(combat, ctx, sim, 3)
		Expect.equal(b.body.x, 105)

		CombatSim.applyDamage(combat, ctx, nil, a.body.id, 1, "true")
		run(combat, ctx, sim, 2)
		Expect.equal(b.body.x < 105, true)
	end,

	["near finds the living enemies in range, wherever they stand in the crowd"] = function()
		local combat, ctx, sim = world()
		local a = spawn(combat, ctx, sim, "grunt", 10, 0)
		local b = spawn(combat, ctx, sim, "grunt", 14, 0)
		spawn(combat, ctx, sim, "grunt", 60, 0)
		local dead = spawn(combat, ctx, sim, "grunt", 11, 1)
		CombatSim.applyDamage(combat, ctx, nil, dead.body.id, 999, "true")

		local found = EnemySim.near(sim, 10, 0, 8)
		local ids = {}
		for _, point in found do
			table.insert(ids, point.id)
		end
		table.sort(ids)
		Expect.deepEqual(ids, { a.body.id, b.body.id })
		Expect.equal(found[1].x, if found[1].id == a.body.id then 10 else 14)
	end,

	["a crowd spreads out, the same way every time"] = function()
		local function crowd(): { number }
			local combat, ctx, sim = world()
			-- Within hunting range (90), so they all walk, and push each other as they go.
			hero(combat, ctx, 100, 150)
			local enemies = {}
			for index = 1, 30 do
				-- A tight bunch: 30 enemies within a 1.5 stud square.
				table.insert(
					enemies,
					spawn(combat, ctx, sim, "grunt", 100 + (index % 6) * 0.3, 100 + (index // 6) * 0.3)
				)
			end
			run(combat, ctx, sim, 60)
			local trace = {}
			for _, enemy in enemies do
				table.insert(trace, enemy.body.x)
				table.insert(trace, enemy.body.z)
			end
			return trace
		end

		local first = crowd()
		Expect.deepEqual(first, crowd())

		local minX, maxX = math.huge, -math.huge
		for index = 1, #first, 2 do
			minX, maxX = math.min(minX, first[index]), math.max(maxX, first[index])
		end
		Expect.equal(maxX - minX > 4, true, `spread {maxX - minX} studs wide, from 1.5`)
	end,

	["two enemies too close push each other apart by the separation formula"] = function()
		local combat, ctx, sim = world()
		hero(combat, ctx, 100.5, 140)
		local left = spawn(combat, ctx, sim, "grunt", 100, 100)
		local right = spawn(combat, ctx, sim, "grunt", 101, 100)
		EnemySim.step(sim, combat, ctx)

		-- reach = 3.6 and distance = 1, so each is pushed (3.6 - 1) / 3.6 away from the other,
		-- on top of its step towards the hero (a little inwards: the hero is between them).
		local push = (3.6 - 1) / 3.6
		local inwards = 0.5 / math.sqrt(0.5 * 0.5 + 40 * 40) * 9
		near(left.body.x, 100 + (inwards - push * 6) * SimClock.TICK, 1e-9, "left")
		near(right.body.x, 101 + (push * 6 - inwards) * SimClock.TICK, 1e-9, "right")
	end,

	["removing a killed enemy reports it and hands it back"] = function()
		local combat, ctx, sim = world()
		local enemy = spawn(combat, ctx, sim, "grunt", 5, 6)
		CombatSim.applyDamage(combat, ctx, nil, enemy.body.id, 999, "true")
		local deaths = CombatSim.popDeaths(combat)
		table.clear(ctx.events)

		local removed = EnemySim.onDeath(sim, combat, ctx, deaths[1].id)
		Expect.equal(removed, enemy)
		Expect.equal(enemy.lootSeed, 1)
		Expect.equal(sim.aliveCount, 0)
		Expect.equal(CombatSim.get(combat, enemy.body.id), nil)
		Expect.equal(#eventsOf(ctx, "despawn"), 1)
		Expect.equal(EnemySim.onDeath(sim, combat, ctx, 999), nil, "not an enemy")
		Expect.equal(#EnemySim.near(sim, 5, 6, 10), 0, "gone from the hash too")
	end,

	["despawnAll clears everything without reporting kills"] = function()
		local combat, ctx, sim = world()
		hero(combat, ctx, 20, 0)
		spawn(combat, ctx, sim, "spitter", 0, 0)
		spawn(combat, ctx, sim, "grunt", 3, 3, "camp_1")
		sim.wokenGroups.camp_1 = true
		table.clear(ctx.events)

		EnemySim.despawnAll(sim, combat, ctx)
		Expect.equal(sim.aliveCount, 0)
		Expect.equal(#sim.enemies, 0)
		Expect.equal(#eventsOf(ctx, "despawn"), 2)
		Expect.equal(next(sim.wokenGroups), nil)
		Expect.equal(#CombatSim.popDeaths(combat), 0)
	end,

	["the snapshot shows wind-ups, slams and stuns"] = function()
		local combat, ctx, sim = world()
		hero(combat, ctx, 2, 0)
		local grunt = spawn(combat, ctx, sim, "grunt", 0, 0)
		run(combat, ctx, sim, 12)
		local entries = EnemySim.snapshot(sim, ctx)
		Expect.equal(#entries, 1)
		Expect.equal(bit32.band(entries[1].flags, EnemySnapshot.TELEGRAPHING), EnemySnapshot.TELEGRAPHING)

		EnemySim.stun(sim, ctx, grunt.body.id, 40)
		Expect.equal(bit32.band(EnemySim.snapshot(sim, ctx)[1].flags, EnemySnapshot.STUNNED), EnemySnapshot.STUNNED)
	end,

	["the boss slams, with a telegraph first, and summons"] = function()
		local combat, ctx, sim = world()
		local target = hero(combat, ctx, 6, 0, 100000)
		local boss = spawn(combat, ctx, sim, "golem", 0, 0)

		local slammed, summoned, telegraphed = false, false, false
		for _ = 1, 260 do
			EnemySim.step(sim, combat, ctx)
			if boss.slamming and bit32.band(EnemySim.snapshot(sim, ctx)[1].flags, EnemySnapshot.SLAM) ~= 0 then
				telegraphed = true
			end
			ctx.tick += 1
		end
		for _, event in ctx.events do
			if event.kind == "damage" and event.id == target.id and event.damage == 70 then
				slammed = true
			end
			if event.kind == "spawn" and event.def == EnemyDefs.indexOf("grunt") then
				summoned = true
			end
		end
		Expect.equal(telegraphed, true, "the slam shows its area first")
		Expect.equal(slammed, true, "double damage, 2 x 35")
		Expect.equal(summoned, true)
		Expect.equal(sim.aliveCount > 4, true)
	end,

	["the boss's health is reported when it changes, once"] = function()
		local combat, ctx, sim = world()
		local boss = spawn(combat, ctx, sim, "golem", 0, 0)
		run(combat, ctx, sim, 3)
		Expect.equal(#eventsOf(ctx, "bossHealth"), 1)
		Expect.equal(eventsOf(ctx, "bossHealth")[1].hp, 1500)

		CombatSim.applyDamage(combat, ctx, nil, boss.body.id, 100, "true")
		run(combat, ctx, sim, 3)
		local events = eventsOf(ctx, "bossHealth")
		Expect.equal(#events, 2)
		Expect.equal(events[2].hp, 1400)
	end,

	["two runs of the same fight end in the same state"] = function()
		local function fight(): number
			local combat, ctx, sim = world()
			EnemySim.setNavGrid(sim, room())
			hero(combat, ctx, 60, 10, 5000)
			hero(combat, ctx, 62, 12, 5000)
			for index = 1, 12 do
				spawn(
					combat,
					ctx,
					sim,
					if index % 3 == 0 then "spitter" elseif index % 2 == 0 then "runner" else "grunt",
					8 + index * 2,
					8 + index % 5
				)
			end
			spawn(combat, ctx, sim, "golem", 30, 70)
			run(combat, ctx, sim, 400)

			local hash = Checksum.new()
			CombatSim.checksum(hash, combat)
			EnemySim.checksum(hash, sim)
			return Checksum.result(hash)
		end
		Expect.equal(fight(), fight())
	end,
}
