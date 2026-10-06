local Expect = require("./Expect")
local NavGrid = require("../src/features/enemies/modules/NavGrid")
local WaveDirector = require("../src/features/run/modules/WaveDirector")

-- A fixed sequence of "random" numbers.
local function sequence(values: { number }): () -> number
	local index = 0
	return function()
		index += 1
		return values[(index - 1) % #values + 1]
	end
end

local function total(phase: string, seconds: number, coefficient: number?, minutes: number?): number
	local state = WaveDirector.new()
	local count = 0
	local random = sequence({ 0.1, 0.5, 0.9, 0.3, 0.7 })
	for _ = 1, seconds * 10 do
		count += #WaveDirector.update(state, 0.1, phase, coefficient or 1, 0, minutes or 10, random)
	end
	return count
end

return {
	["earns nothing outside the phases that spawn"] = function()
		for _, phase in { "Waiting", "Generating", "ExitOpen", "Victory", "Defeat" } do
			Expect.equal(total(phase, 60), 0, phase)
		end
	end,

	["charging brings far more enemies than exploring"] = function()
		local exploring = total("Exploring", 30)
		local charging = total("Charging", 30)
		Expect.equal(exploring > 0, true)
		Expect.equal(charging > exploring * 2, true)
	end,

	["a higher coefficient brings more"] = function()
		Expect.equal(total("Exploring", 30, 3) > total("Exploring", 30, 1), true)
	end,

	["spends no more than it earns"] = function()
		local state = WaveDirector.new()
		local spent = 0
		local random = sequence({ 0.2, 0.8 })
		local cost: { [string]: number } = {}
		for _, entry in WaveDirector.ENTRIES do
			cost[entry.defId] = entry.cost
		end

		local earned = 0
		for _ = 1, 100 do
			earned += WaveDirector.rate("Charging", 1) * 0.1
			for _, defId in WaveDirector.update(state, 0.1, "Charging", 1, 0, 10, random) do
				spent += cost[defId]
			end
		end
		Expect.equal(spent <= earned + 1e-6, true)
		Expect.equal(math.abs(earned - spent - state.credits) < 1e-6 or state.credits >= WaveDirector.MAX_CREDITS, true)
	end,

	["never spawns past the alive cap"] = function()
		local state = WaveDirector.new()
		state.credits = 60
		local random = sequence({ 0.5 })
		Expect.deepEqual(WaveDirector.update(state, 0, "Charging", 1, WaveDirector.ALIVE_CAP, 10, random), {})
		Expect.equal(
			#WaveDirector.update(state, 0, "Charging", 1, WaveDirector.ALIVE_CAP - 1, 10, random),
			1,
			"room for exactly one"
		)
	end,

	["a long frame spawns at most a few at once, and credits stay capped"] = function()
		local state = WaveDirector.new()
		local spawns = WaveDirector.update(state, 1000, "Charging", 1, 0, 10, sequence({ 0.5 }))
		Expect.equal(#spawns, WaveDirector.MAX_PER_UPDATE)
		Expect.equal(state.credits <= WaveDirector.MAX_CREDITS, true)
	end,

	["new kinds appear only once the run is old enough"] = function()
		local seen: { [string]: boolean } = {}
		local state = WaveDirector.new()
		local random = sequence({ 0.05, 0.4, 0.6, 0.95, 0.75, 0.2 })
		for _ = 1, 300 do
			for _, defId in WaveDirector.update(state, 0.5, "Charging", 1, 0, 0.5, random) do
				seen[defId] = true
			end
		end
		Expect.equal(seen.grunt, true)
		Expect.equal(seen.runner, nil, "runners wait for minute 1")
		Expect.equal(seen.spitter, nil, "spitters wait for minute 2")

		local later: { [string]: boolean } = {}
		state = WaveDirector.new()
		for _ = 1, 300 do
			for _, defId in WaveDirector.update(state, 0.5, "Charging", 1, 0, 5, random) do
				later[defId] = true
			end
		end
		Expect.equal(later.grunt and later.runner and later.spitter, true)
	end,

	["the same numbers give the same waves"] = function()
		local function run()
			local state = WaveDirector.new()
			local random = sequence({ 0.13, 0.57, 0.91, 0.33 })
			local out = {}
			for _ = 1, 100 do
				for _, defId in WaveDirector.update(state, 0.25, "Charging", 1.5, 0, 5, random) do
					table.insert(out, defId)
				end
			end
			return table.concat(out, ",")
		end
		Expect.equal(run(), run())
	end,

	["it saves up for a costly enemy instead of spending on cheap ones"] = function()
		-- The roll picks the spitter (cost 20) first: nothing spawns until there are 20 credits.
		local state = WaveDirector.new()
		state.credits = 12
		local random = sequence({ 0.99 })
		Expect.deepEqual(WaveDirector.update(state, 0, "Exploring", 1, 0, 10, random), {})
		Expect.equal(state.credits, 12)

		state.credits = 19.9
		Expect.deepEqual(WaveDirector.update(state, 0, "Exploring", 1, 0, 10, random), {})
		state.credits = 20
		Expect.deepEqual(WaveDirector.update(state, 0, "Exploring", 1, 0, 10, random), { "spitter" })
		Expect.equal(state.credits, 0)
	end,

	["a cheap pick spawns as soon as it is affordable"] = function()
		local state = WaveDirector.new()
		state.credits = 12
		Expect.deepEqual(WaveDirector.update(state, 0, "Exploring", 1, 0, 10, sequence({ 0 })), { "grunt" })
		Expect.equal(state.credits, 2)
	end,

	["every kind gets its turn over a long fight"] = function()
		local state = WaveDirector.new()
		local random = sequence({ 0.05, 0.4, 0.6, 0.95, 0.75, 0.2 })
		local counts: { [string]: number } = {}
		for _ = 1, 400 do
			for _, defId in WaveDirector.update(state, 0.5, "Charging", 1, 0, 10, random) do
				counts[defId] = (counts[defId] or 0) + 1
			end
		end
		Expect.equal((counts.grunt or 0) > 0 and (counts.runner or 0) > 0 and (counts.spitter or 0) > 0, true)
		Expect.equal((counts.grunt or 0) > (counts.spitter or 0), true, "weights still matter")
	end,

	["pickSpawnPoint lands on a walkable cell in the ring"] = function()
		local grid = NavGrid.new(50, 50, 4, -100, -100, table.create(2500, true))
		local random = sequence({ 0.1, 0.3, 0.5, 0.7, 0.9 })
		for _ = 1, 50 do
			local x, z = WaveDirector.pickSpawnPoint(grid, 0, 0, 30, 50, random)
			Expect.equal(x ~= nil and z ~= nil, true)
			local distance = math.sqrt((x :: number) ^ 2 + (z :: number) ^ 2)
			Expect.equal(distance >= 30 - 1e-6 and distance <= 50 + 1e-6, true, "distance")
			Expect.equal(NavGrid.walkableAt(grid, x :: number, z :: number), true)
		end
	end,

	["pickSpawnPoint gives up when nothing is walkable"] = function()
		local grid = NavGrid.new(4, 4, 4, 0, 0, table.create(16, false))
		local x, z = WaveDirector.pickSpawnPoint(grid, 8, 8, 2, 6, sequence({ 0.4, 0.6 }))
		Expect.equal(x, nil)
		Expect.equal(z, nil)
	end,
}
