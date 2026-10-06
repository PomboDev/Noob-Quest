local Angle = require("../src/core/Angle")
local Expect = require("./Expect")
local HeroDefs = require("../src/features/heroes/modules/HeroDefs")
local HeroInput = require("../src/features/heroes/modules/HeroInput")
local HeroInputQueue = require("../src/features/heroes/modules/HeroInputQueue")
local HeroMotion = require("../src/features/heroes/modules/HeroMotion")
local HeroPrediction = require("../src/features/heroes/modules/HeroPrediction")
local HeroSim = require("../src/features/heroes/modules/HeroSim")
local NavGrid = require("../src/features/enemies/modules/NavGrid")
local Rng = require("../src/core/Rng")

local def = HeroDefs.get(HeroDefs.DEFAULT) :: HeroDefs.HeroDef

local function gridOf(rows: { string }): NavGrid.Grid
	local walkable = {}
	for _, row in rows do
		for column = 1, #row do
			table.insert(walkable, string.sub(row, column, column) ~= "#")
		end
	end
	return NavGrid.new(#rows[1], #rows, 4, 0, 0, walkable)
end

-- A big room with a pillar in the middle.
local function room(pillar: boolean): NavGrid.Grid
	local rows = {}
	for y = 1, 20 do
		local row = {}
		for x = 1, 20 do
			local wall = x == 1 or y == 1 or x == 20 or y == 20
			if pillar and x >= 9 and x <= 12 and y >= 9 and y <= 12 then
				wall = true
			end
			table.insert(row, if wall then "#" else ".")
		end
		table.insert(rows, table.concat(row))
	end
	return gridOf(rows)
end

type Link = { latency: number, jitter: number, loss: number }

-- A client and a server joined by a bad network. Returns how many times the
-- client had to correct itself, and the two final heroes.
local function play(
	clientGrid: NavGrid.Grid,
	serverGrid: NavGrid.Grid,
	link: Link,
	ticks: number,
	script: (tick: number, rng: Rng.Rng) -> HeroInput.Input
): (number, HeroSim.Sim, HeroPrediction.Prediction)
	local rng = Rng.new(2468)
	local network = Rng.new(1357)

	local server = HeroSim.new(def, 40, 40)
	local queue = HeroInputQueue.new()
	local lastSeq = 0
	local client = HeroPrediction.new(HeroSim.new(def, 40, 40))

	local toServer: { { at: number, last: number, inputs: { HeroInput.Input } } } = {}
	local toClient: { { at: number, ack: HeroPrediction.Ack } } = {}
	local corrections = 0

	local function delay(): number
		return link.latency + Rng.int(network, 0, link.jitter)
	end

	-- Past the script the client idles while the network drains.
	for tick = 1, ticks + 60 do
		local input = if tick <= ticks then script(tick, rng) else HeroInput.idle()

		-- The client uses its input and sends the last three.
		HeroPrediction.step(client, input, clientGrid, true)
		local inputs = {}
		for seq = math.max(1, client.seq - 2), client.seq do
			table.insert(inputs, (client.records[seq] or { input = HeroInput.idle() }).input)
		end
		if Rng.next(network) >= link.loss then
			table.insert(toServer, { at = tick + delay(), last = client.seq, inputs = inputs })
		end

		-- The server gets what has arrived, then uses one input.
		for index = #toServer, 1, -1 do
			local message = toServer[index]
			if message.at <= tick then
				HeroInputQueue.receive(queue, message.last, message.inputs)
				table.remove(toServer, index)
			end
		end
		local used, seq = HeroInputQueue.take(queue)
		if used and seq then
			HeroSim.step(server, used, serverGrid, true)
			lastSeq = seq
			if tick % 2 == 0 then
				local remaining = {}
				for index in def.abilities do
					remaining[index] = HeroSim.remaining(server, index)
				end
				table.insert(toClient, {
					at = tick + delay(),
					ack = {
						seq = lastSeq,
						motion = HeroMotion.copy(server.motion),
						tick = server.tick,
						remaining = remaining,
					},
				})
			end
		end

		-- The client gets the reports, in the order they were sent.
		table.sort(toClient, function(a, b)
			return a.ack.seq < b.ack.seq
		end)
		while toClient[1] and toClient[1].at <= tick do
			local message = table.remove(toClient, 1) :: { at: number, ack: HeroPrediction.Ack }
			if HeroPrediction.acknowledge(client, message.ack, clientGrid) then
				corrections += 1
			end
		end
	end
	return corrections, server, client
end

local function wander(tick: number, rng: Rng.Rng): HeroInput.Input
	local input = HeroInput.idle()
	-- Changes direction now and then, so it runs into the pillar and the walls.
	input.moving = tick % 97 > 10
	input.moveAngle = (tick // 23 * 53) % 256
	input.aim = Rng.int(rng, 0, 65535)
	input.attack = tick % 11 < 4
	return input
end

local function sameHero(a: HeroSim.Sim, b: HeroSim.Sim)
	Expect.equal(math.abs(a.motion.x - b.motion.x) < 1e-9, true, `x {a.motion.x} vs {b.motion.x}`)
	Expect.equal(math.abs(a.motion.z - b.motion.z) < 1e-9, true, `z {a.motion.z} vs {b.motion.z}`)
end

return {
	["a client on a bad network never has to correct itself"] = function()
		local grid = room(true)
		for _, link in
			{
				{ latency = 0, jitter = 0, loss = 0 },
				{ latency = 4, jitter = 3, loss = 0 },
				{ latency = 8, jitter = 5, loss = 0.05 },
				{ latency = 3, jitter = 6, loss = 0.08 },
			}
		do
			local corrections, server, client = play(grid, grid, link, 900, wander)
			Expect.equal(corrections, 0, `latency {link.latency} jitter {link.jitter} loss {link.loss}`)
			sameHero(server, client.sim)
		end
	end,

	-- Three packets in a row (an input and both copies) can be lost here. The
	-- server takes the gap as "did nothing", and the client recovers.
	["a client on a terrible network corrects itself rarely and ends up in the right place"] = function()
		local grid = room(true)
		local corrections, server, client = play(grid, grid, { latency = 3, jitter = 8, loss = 0.1 }, 900, wander)
		Expect.equal(corrections <= 3, true, `{corrections} corrections`)
		sameHero(server, client.sim)
	end,

	["abilities don't make a client correct itself"] = function()
		local grid = room(false)
		local function dashing(tick: number, rng: Rng.Rng): HeroInput.Input
			local input = wander(tick, rng)
			-- Presses the dash every 50 ticks: ready again only every 120.
			if tick % 50 == 0 then
				input.ability = 1
			end
			if tick % 70 == 0 then
				input.ability = 2
			end
			return input
		end
		local corrections, server, client = play(grid, grid, { latency = 5, jitter = 4, loss = 0.03 }, 900, dashing)
		Expect.equal(corrections, 0)
		sameHero(server, client.sim)
	end,

	["a client that walks through a wall is put back"] = function()
		-- The client thinks the pillar isn't there. The server knows better.
		local corrections, server, client = play(
			room(false),
			room(true),
			{ latency = 4, jitter = 2, loss = 0 },
			900,
			function(tick: number): HeroInput.Input
				local input = HeroInput.idle()
				-- Straight at the pillar, then away.
				input.moving = true
				input.moveAngle = if tick < 300 then 64 else 192
				return input
			end
		)
		Expect.equal(corrections > 0, true)
		sameHero(server, client.sim)
		-- The server's hero never entered the pillar.
		Expect.equal(HeroMotion.blocked(room(true), server.motion.x, server.motion.z), false)
	end,

	["a client that ignores its cooldown is put back"] = function()
		local grid = room(false)
		local function spam(tick: number): HeroInput.Input
			local input = HeroInput.idle()
			input.ability = 1
			input.aim = Angle.QUARTER
			return input
		end
		-- The honest client refuses the second dash itself, so tamper with its sim.
		local rng = Rng.new(1)
		local client = HeroPrediction.new(HeroSim.new(def, 40, 40))
		local server = HeroSim.new(def, 40, 40)
		HeroPrediction.step(client, spam(1), grid, true)
		HeroSim.step(server, spam(1), grid, true)
		-- The cheating client forgets its cooldown before every press.
		for tick = 2, 40 do
			client.sim.readyAt = {}
			HeroPrediction.step(client, spam(tick), grid, true)
			HeroSim.step(server, spam(tick), grid, true)
			local remaining = { HeroSim.remaining(server, 1), HeroSim.remaining(server, 2) }
			HeroPrediction.acknowledge(client, {
				seq = client.seq,
				motion = HeroMotion.copy(server.motion),
				tick = server.tick,
				remaining = remaining,
			}, grid)
		end
		local _ = rng
		-- The server dashed once: 20 studs. The client's own state follows it.
		sameHero(server, client.sim)
		Expect.equal(server.motion.x < 40 + 25, true)
	end,

	["a report ahead of the client starts it from the server's state"] = function()
		local grid = room(false)
		local client = HeroPrediction.new(HeroSim.new(def, 40, 40))
		local moved = HeroMotion.new(100, 100)
		local corrected = HeroPrediction.acknowledge(client, {
			seq = 5,
			motion = moved,
			tick = 5,
			remaining = {},
		}, grid)
		Expect.equal(corrected, true)
		Expect.equal(client.sim.motion.x, 100)
		Expect.equal(client.seq, 5)
	end,

	["reset forgets old inputs"] = function()
		local grid = room(false)
		local client = HeroPrediction.new(HeroSim.new(def, 40, 40))
		HeroPrediction.step(client, HeroInput.idle(), grid, true)
		HeroPrediction.reset(client, 10, HeroMotion.new(60, 60))
		Expect.equal(client.seq, 10)
		Expect.equal(client.sim.motion.x, 60)
		Expect.equal(next(client.records), nil)
	end,
	["a report at the starting input matches the starting state, and a different one is a correction"] = function()
		local grid = room(false)
		local prediction = HeroPrediction.new(HeroSim.new(def, 8, 8))
		local ack = {
			seq = 0,
			motion = { x = 8, z = 8, dashLeft = 0, dashX = 0, dashZ = 0 },
			tick = 0,
			remaining = { 0, 0, 0 },
		}
		-- Nothing sent yet and the server agrees: no correction, however often it says so.
		for _ = 1, 3 do
			Expect.equal(HeroPrediction.acknowledge(prediction, ack, grid), false)
		end

		ack.motion.x = 20
		Expect.equal(HeroPrediction.acknowledge(prediction, ack, grid), true, "the server moved the hero")
		Expect.equal(prediction.sim.motion.x, 20)
		Expect.equal(HeroPrediction.acknowledge(prediction, ack, grid), false, "and now they agree")
	end,
}
