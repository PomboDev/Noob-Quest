--[=[
	A short fight played from fixed seeds and a fixed stream of random inputs,
	used to compare the simulation across runtimes: the spec pins what it
	returns, and the same function is run inside Roblox Studio. It takes the
	modules as arguments so it can run where `require` of paths doesn't.
]=]

return function(deps: any): (number, { [string]: number })
	local Sim, Rng, HeroInput, HeroActions = deps.Sim, deps.Rng, deps.HeroInput, deps.HeroActions
	local sim = Sim.new()
	local rng = Rng.new(5)
	local counts: { [string]: number } = {}

	local function step(inputs: any, commands: any)
		for _, event in Sim.step(sim, { inputs = inputs, commands = commands }) do
			counts[event.kind] = (counts[event.kind] or 0) + 1
		end
	end

	step({}, {
		{ kind = "join", slot = 1, userId = 11, defId = "warrior" },
		{ kind = "join", slot = 2, userId = 22, defId = "warrior" },
		{ kind = "startRun", mapSeed = 777, lootSeed = 888 },
	})

	-- Both heroes start in the middle of the first camp, and can't die.
	local camp = sim.world.camps[1]
	for index, hero in sim.heroes do
		HeroActions.place(sim.ctx, hero, camp.x + index, camp.z)
		hero.entity.maxHp, hero.entity.hp = 100000, 100000
	end

	for _ = 1, 800 do
		local inputs = {}
		for _, hero in sim.heroes do
			local input = HeroInput.idle()
			input.moving = Rng.next(rng) < 0.7
			input.moveAngle = if input.moving then Rng.int(rng, 0, 255) else 0
			input.aim = Rng.int(rng, 0, 65535)
			input.attack = true
			input.auto = Rng.next(rng) < 0.5
			input.ability = if Rng.next(rng) < 0.05 then Rng.int(rng, 1, 2) else 0
			inputs[hero.slot] = input
		end
		step(inputs, {})
	end

	return Sim.checksum(sim), counts
end
