local CombatSim = require("../src/features/combat/modules/CombatSim")
local Expect = require("./Expect")
local HeroActions = require("../src/features/heroes/modules/HeroActions")
local HeroInput = require("../src/features/heroes/modules/HeroInput")
local LobbySpace = require("../src/features/world/modules/LobbySpace")
local Rng = require("../src/core/Rng")
local Sim = require("../src/features/sim/modules/Sim")
local SimBot = require("./SimBot")
local SimContext = require("../src/features/sim/modules/SimContext")
local SimScenario = require("./SimScenario")

local MAP_SEED = 20240601
local LOOT_SEED = 99

-- A whole run: the party enters the portal, plays the act and is back in the lobby.
local function fullRun(options: { mapSeed: number?, lootSeed: number?, tamper: SimBot.Tamper? }): SimBot.Result
	return SimBot.run({
		heroes = 2,
		mapSeed = options.mapSeed or MAP_SEED,
		lootSeed = options.lootSeed or LOOT_SEED,
		maxTicks = 4000,
		durable = true,
		tamper = options.tamper,
		stopWhen = function(sim: Sim.State)
			return sim.run.result.coins > 0 and sim.run.run.currentState == "Waiting"
		end,
	})
end

local function names(phases: { string }): { string }
	local list = {}
	for _, entry in phases do
		table.insert(list, string.match(entry, "%d+ (%a+)") :: string)
	end
	return list
end

-- The first checkpoint tick the two runs disagree on, or nil.
local function firstDifference(a: SimBot.Result, b: SimBot.Result): number?
	local ticks = {}
	for tick in a.checksums do
		table.insert(ticks, tick)
	end
	table.sort(ticks)
	for _, tick in ticks do
		if a.checksums[tick] ~= b.checksums[tick] then
			return tick
		end
	end
	return nil
end

-- The sim as it is just after an act has been generated, with two heroes in it.
local function inAct(lootSeed: number): Sim.State
	return SimBot.run({
		heroes = 2,
		mapSeed = MAP_SEED,
		lootSeed = lootSeed,
		maxTicks = 200,
		durable = true,
		stopWhen = function(sim: Sim.State)
			return sim.run.run.currentState == "Exploring"
		end,
	}).sim
end

local function step(sim: Sim.State, inputs: { [number]: HeroInput.Input }?, commands: { Sim.Command }?)
	return Sim.step(sim, { inputs = inputs or {}, commands = commands or {} })
end

return {
	["a scripted party plays a whole run, from the lobby portal to the lobby"] = function()
		local result = fullRun({})
		Expect.deepEqual(
			names(result.phases),
			{ "Waiting", "Exploring", "Charging", "Boss", "ExitOpen", "Victory", "Waiting" }
		)

		Expect.equal(result.counts.heroJoined, 2)
		Expect.equal(result.counts.runRequested, 1, "asked once, though two heroes stood at the portal")
		Expect.equal(result.counts.actGenerated, 1)
		Expect.equal(result.counts.victory, 1)
		Expect.equal(result.counts.lobby, 1)
		Expect.equal((result.counts.spawn or 0) > 10, true, "camps woke and waves came")
		Expect.equal((result.counts.died or 0) > 10, true, "and were killed")
		Expect.equal((result.counts.drop or 0) > 10, true)
		Expect.equal((result.counts.pickup or 0) > 0, true)
		Expect.equal(result.sim.run.result.coins > 0, true, "loot was collected")

		-- Back in the lobby: everyone at full health, nothing left in the world.
		Expect.equal(result.sim.enemies.aliveCount, 0)
		Expect.equal(#result.sim.loot.drops, 0)
		for _, hero in result.sim.heroes do
			Expect.equal(LobbySpace.contains(hero.sim.motion.x, hero.sim.motion.z), true)
			Expect.equal(hero.entity.hp, hero.entity.maxHp)
		end
	end,

	["the same seeds and inputs give the same run, tick by tick"] = function()
		local first = fullRun({})
		local second = fullRun({})

		Expect.equal(first.ticks, second.ticks)
		Expect.equal(firstDifference(first, second), nil, "every checkpoint matches")
		Expect.equal(first.eventsHash, second.eventsHash, "so does every event")
		Expect.deepEqual(first.counts, second.counts)
		Expect.deepEqual(first.phases, second.phases)
		Expect.equal(Sim.checksum(first.sim), Sim.checksum(second.sim))
	end,

	["another map seed plays a different run"] = function()
		local a = fullRun({})
		local b = fullRun({ mapSeed = MAP_SEED + 1 })
		Expect.equal(a.eventsHash ~= b.eventsHash, true)
		Expect.equal(firstDifference(a, b) ~= nil, true)
	end,

	["changing one input of one hero makes the run diverge from that tick on"] = function()
		local honest = fullRun({})
		local tampered = fullRun({
			tamper = {
				tick = 300,
				slot = 1,
				apply = function(input: HeroInput.Input)
					input.moving = false
				end,
			},
		})

		local difference = firstDifference(honest, tampered)
		Expect.equal(difference ~= nil, true, "the change shows up")
		Expect.equal(
			(difference :: number) >= 300 and (difference :: number) <= 300 + SimBot.CHECK_EVERY,
			true,
			`first difference at tick {difference}`
		)
		Expect.equal(honest.checksums[280], tampered.checksums[280], "nothing differs before it")
		Expect.equal(honest.eventsHash ~= tampered.eventsHash, true)
	end,

	["a party that is wiped out loses the run, then wakes up in the lobby"] = function()
		local result = SimBot.run({
			heroes = 2,
			mapSeed = MAP_SEED,
			lootSeed = LOOT_SEED,
			maxTicks = 1500,
			durable = false,
			onTick = function(sim: Sim.State, tick: number)
				if tick == 700 then
					for _, hero in sim.heroes do
						CombatSim.applyDamage(sim.combat, sim.ctx, nil, hero.entity.id, 1e9, "true")
					end
				end
			end,
			stopWhen = function(sim: Sim.State, tick: number)
				return tick > 700 and sim.run.run.currentState == "Waiting"
			end,
		})

		Expect.deepEqual(names(result.phases), { "Waiting", "Exploring", "Charging", "Defeat", "Waiting" })
		Expect.equal(result.counts.defeat, 1)
		Expect.equal(result.counts.lobby, 1)
		Expect.equal(result.counts.victory, nil)
		Expect.equal(result.sim.enemies.aliveCount, 0)
		for _, hero in result.sim.heroes do
			Expect.equal(hero.entity.dead, false)
			Expect.equal(hero.entity.hp, hero.entity.maxHp)
			Expect.equal(LobbySpace.contains(hero.sim.motion.x, hero.sim.motion.z), true)
		end

		-- The defeat timer is 3 s of ticks, not of the clock.
		local defeatTick = tonumber(string.match(result.phases[4], "^(%d+)")) :: number
		local lobbyTick = tonumber(string.match(result.phases[5], "^(%d+)")) :: number
		Expect.equal(lobbyTick - defeatTick, 60)
	end,

	["what camps drop is fixed by the loot seed, not by the map seed"] = function()
		local a, b = inAct(LOOT_SEED), inAct(LOOT_SEED)
		local other = inAct(LOOT_SEED + 1)

		local function seeds(sim: Sim.State): { number }
			local list = {}
			for _, camp in sim.world.camps do
				for _, member in camp.enemies do
					table.insert(list, member.lootSeed)
				end
			end
			return list
		end

		Expect.equal(#seeds(a) > 10, true, "the act has camps")
		Expect.deepEqual(seeds(a), seeds(b))
		Expect.equal(#seeds(other), #seeds(a), "the same act...")
		Expect.equal(a.world.act.seed, other.world.act.seed)
		Expect.equal(seeds(a)[1] ~= seeds(other)[1], true, "...with other loot")

		-- Each enemy has a seed of its own.
		local seen: { [number]: boolean } = {}
		for _, seed in seeds(a) do
			Expect.equal(seen[seed], nil, "a seed was handed out twice")
			seen[seed] = true
		end
	end,

	["a chest pays what its seed says, to the hero that opened it"] = function()
		local function open(lootSeed: number): { string }
			local sim = inAct(lootSeed)
			local chest
			for _, object in sim.world.objects do
				if object.kind == "chest" then
					chest = object
					break
				end
			end

			-- Slot 2 walks up to the chest and opens it.
			local hero = Sim.hero(sim, 2) :: HeroActions.Hero
			HeroActions.place(sim.ctx, hero, chest.x + 3, chest.z)
			local input = HeroInput.idle()
			input.interact = chest.objectId
			local events = step(sim, { [2] = input })

			local paid = {}
			for _, event in events do
				if event.kind == "drop" then
					table.insert(paid, `slot {event.slot} item {event.item} amount {event.amount}`)
				end
			end

			-- A chest opens once.
			Expect.equal(chest.used, true)
			local again = step(sim, { [2] = input })
			for _, event in again do
				Expect.equal(event.kind ~= "drop", true, "a used chest pays nothing more")
			end
			return paid
		end

		local first = open(LOOT_SEED)
		Expect.equal(#first >= 5, true, "four piles of coins and an orb")
		for _, line in first do
			Expect.equal(string.find(line, "slot 2", 1, true) ~= nil, true, line)
		end
		Expect.deepEqual(first, open(LOOT_SEED))
		Expect.equal(table.concat(first, ",") ~= table.concat(open(LOOT_SEED + 1), ","), true)
	end,

	["heroes can leave and join, and a hero out of reach can't use an object"] = function()
		local sim = Sim.new()
		step(sim, nil, { { kind = "join", slot = 2, userId = 22, defId = "warrior" } })
		step(sim, nil, { { kind = "join", slot = 1, userId = 11, defId = "warrior" } })
		Expect.deepEqual({ sim.heroes[1].slot, sim.heroes[2].slot }, { 1, 2 }, "kept in slot order")

		local events = step(sim, nil, { { kind = "join", slot = 1, userId = 99, defId = "warrior" } })
		Expect.equal(#sim.heroes, 2, "a slot can't be taken twice")
		Expect.equal(#events, 0)
		step(sim, nil, { { kind = "join", slot = 3, userId = 33, defId = "nobody" } })
		Expect.equal(#sim.heroes, 2, "an unknown hero is refused")

		-- Slot 1 is nowhere near the portal.
		local input = HeroInput.idle()
		input.interact = 1
		Expect.equal(#step(sim, { [1] = input }), 0)

		local entityId = (Sim.hero(sim, 1) :: HeroActions.Hero).entity.id
		local left = step(sim, nil, { { kind = "leave", slot = 1 } })
		Expect.equal(left[1].kind, "heroLeft")
		Expect.equal(#sim.heroes, 1)
		Expect.equal(sim.combat.byId[entityId], nil, "its body is gone too")
	end,

	["a hero with no input waits, and a hero that sends more is no faster"] = function()
		local sim = Sim.new()
		step(sim, nil, { { kind = "join", slot = 1, userId = 11, defId = "warrior" } })
		local hero = sim.heroes[1]
		local startX = hero.sim.motion.x

		local walk = HeroInput.idle()
		walk.moving = true
		walk.moveAngle = 64
		for _ = 1, 10 do
			step(sim, {})
		end
		Expect.equal(hero.sim.motion.x, startX)
		Expect.equal(hero.sim.tick, 0, "the hero's own clock didn't move")

		for _ = 1, 10 do
			step(sim, { [1] = walk })
		end
		Expect.equal(hero.sim.tick, 10)
		-- 18 studs a second, 10 ticks of 1/20 s.
		Expect.equal(math.abs(hero.sim.motion.x - startX - 9) < 1e-6, true)
	end,

	["a hero is placed over the lobby's plaza by its slot"] = function()
		local sim = Sim.new()
		for slot = 1, 5 do
			step(sim, nil, { { kind = "join", slot = slot, userId = slot, defId = "warrior" } })
		end
		local seen: { [string]: boolean } = {}
		for _, hero in sim.heroes do
			Expect.equal(LobbySpace.contains(hero.sim.motion.x, hero.sim.motion.z), true)
			local key = `{hero.sim.motion.x} {hero.sim.motion.z}`
			Expect.equal(seen[key], nil, "two heroes on one spot")
			seen[key] = true
		end
	end,

	["the view tells the clients where the run is"] = function()
		local sim = inAct(LOOT_SEED)
		local view = Sim.view(sim)
		Expect.equal(view.phase, "Exploring")
		Expect.equal(view.act, 1)
		Expect.equal(view.alive, 2)
		Expect.equal(view.charge, 0)
		Expect.equal(view.coefficient >= 1, true)
	end,
	-- Pinned: the same fight gave exactly this inside Roblox Studio. If it moves,
	-- the simulation changed, and recorded runs no longer replay. Last moved when
	-- enemy melee hits stopped landing beyond their attack range (two fewer hits).
	["gives the same checksum and events on every platform"] = function()
		local checksum, counts = SimScenario({
			Sim = Sim,
			Rng = Rng,
			HeroInput = HeroInput,
			HeroActions = HeroActions,
		})
		Expect.equal(checksum, 3273378176)
		Expect.deepEqual(counts, {
			abilityRejected = 44,
			abilityUsed = 22,
			actGenerated = 1,
			damage = 31,
			despawn = 14,
			died = 14,
			drop = 46,
			heroAttack = 146,
			heroHealth = 12,
			heroJoined = 2,
			lootClear = 1,
			objectAdded = 11,
			pickup = 20,
			runChanged = 1,
			spawn = 32,
			teleport = 2,
		})
	end,

	["a hero catching up uses its second input as if it came a tick later"] = function()
		local function walking(angle: number): HeroInput.Input
			local input = HeroInput.idle()
			input.moving = true
			input.moveAngle = angle
			return input
		end

		local apart = inAct(LOOT_SEED)
		step(apart, { [1] = walking(0) })
		step(apart, { [1] = walking(64) })

		local together = inAct(LOOT_SEED)
		Sim.step(together, { inputs = { [1] = walking(0) }, catchUp = { [1] = walking(64) }, commands = {} })

		local a, b = (Sim.hero(apart, 1) :: any).sim, (Sim.hero(together, 1) :: any).sim
		Expect.equal(b.motion.x, a.motion.x)
		Expect.equal(b.motion.z, a.motion.z)
		Expect.equal(b.tick, a.tick, "two inputs on the hero's own clock")
		Expect.equal(together.ctx.tick + 1, apart.ctx.tick, "in one server tick")
	end,
}
