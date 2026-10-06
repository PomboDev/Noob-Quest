--!strict

--[=[
	Heroes, server side: the link between each player and their hero in the
	simulation (see SimService).

	The server never takes a position from a client. A player's client sends
	numbered inputs (`sendInputs`), and each tick this feature gives the sim the
	next one of every hero (see HeroInputQueue): the sim moves the hero, swings,
	dashes and works out what is hit. The client runs the same HeroSim to
	predict, and is told where its hero really is (`onHeroAck`) so it can
	correct itself.

	The player's Roblox character is only a puppet: it is anchored here and
	each client moves it from the numbers it is given.

	Heroes in the sim belong to slots, never to Players. A slot is the lowest
	free number when the character spawns; it is freed when it goes.
]=]

local Players = game:GetService("Players")

local Angle = require("@Core/Angle")
local HeroDefs = require("@Features/heroes/modules/HeroDefs")
local HeroInput = require("@Features/heroes/modules/HeroInput")
local HeroInputQueue = require("@Features/heroes/modules/HeroInputQueue")
local HeroMotion = require("@Features/heroes/modules/HeroMotion")
local HeroSim = require("@Features/heroes/modules/HeroSim")
local HeroSnapshot = require("@Features/heroes/modules/HeroSnapshot")
local Log = require("@Core/Log")
local Network = require("@Core/Network")
local RateLimit = require("@Core/RateLimit")
local Sim = require("@Features/sim/modules/Sim")
local SimClock = require("@Features/sim/modules/SimClock")
local SimContext = require("@Features/sim/modules/SimContext")
local SimService = require("@Features/sim/SimServiceServer")

local Packet = Network.Packet

type Link = {
	player: Player,
	slot: number,
	queue: HeroInputQueue.Queue,
	-- The number of the last input used (0 before any).
	lastSeq: number,
	-- Held in place (while the map loads): inputs are used as "did nothing".
	frozen: boolean,
}

local HeroService = {}

-- Bytes before the inputs in a sendInputs buffer: the last input number (u32) and the count (u8).
local PACKET_HEADER = 5

local network: Network.ServerNetwork

local byPlayer: { [Player]: Link } = {}
local bySlot: { [number]: Link } = {}
-- By slot, so every loop runs in the same order.
local ordered: { Link } = {}

local inputLimit = RateLimit.new({ burst = 60, perSecond = 30 })
local heroLimit = RateLimit.new({ burst = 2, perSecond = 0.5 })

local function reorder()
	table.clear(ordered)
	for _, link in byPlayer do
		table.insert(ordered, link)
	end
	table.sort(ordered, function(a, b)
		return a.slot < b.slot
	end)
end

local function lowestFreeSlot(): number
	local slot = 1
	while bySlot[slot] do
		slot += 1
	end
	return slot
end

local function removeHero(player: Player)
	local link = byPlayer[player]
	if link then
		SimService.command({ kind = "leave", slot = link.slot })
		byPlayer[player] = nil
		bySlot[link.slot] = nil
		reorder()
	end
end

-- Anchors the character: nothing moves it on the server, and each client
-- places it from the hero's numbers.
local function anchor(character: Model)
	task.spawn(function()
		local root = character:WaitForChild("HumanoidRootPart", 10)
		if root and root:IsA("BasePart") then
			root.Anchored = true
		end
		local humanoid = character:FindFirstChildOfClass("Humanoid")
		if humanoid then
			humanoid.EvaluateStateMachine = false
		end
	end)
end

local function addHero(player: Player, character: Model)
	removeHero(player)

	local slot = lowestFreeSlot()
	local link: Link = {
		player = player,
		slot = slot,
		queue = HeroInputQueue.new(),
		lastSeq = 0,
		frozen = false,
	}
	byPlayer[player] = link
	bySlot[slot] = link
	reorder()
	anchor(character)

	SimService.command({ kind = "join", slot = slot, userId = player.UserId, defId = HeroDefs.DEFAULT })
end

local function watch(player: Player)
	player.CharacterAdded:Connect(function(character)
		addHero(player, character)
	end)
	player.CharacterRemoving:Connect(function()
		removeHero(player)
	end)
	if player.Character then
		addHero(player, player.Character)
	end
end

-- The player whose hero is in `slot`, if any.
function HeroService.playerOfSlot(slot: number): Player?
	local link = bySlot[slot]
	return if link then link.player else nil
end

-- The slot of the player's hero, if it has one.
function HeroService.slotOf(player: Player): number?
	local link = byPlayer[player]
	return if link then link.slot else nil
end

local function sendAck(link: Link)
	local hero = Sim.hero(SimService.state(), link.slot)
	if hero == nil then
		return
	end

	local sim = hero.sim
	network:fireClientUnreliable(
		link.player,
		"onHeroAck",
		link.lastSeq,
		sim.motion.x,
		sim.motion.z,
		sim.motion.dashLeft,
		sim.motion.dashX,
		sim.motion.dashZ,
		sim.tick,
		if link.frozen then 1 else 0,
		HeroSim.remaining(sim, 1),
		HeroSim.remaining(sim, 2),
		HeroSim.remaining(sim, 3)
	)
end

-- Holds a hero in place (inputs are used as "did nothing") or lets it go.
function HeroService.setFrozen(player: Player, frozen: boolean)
	local link = byPlayer[player]
	if link then
		link.frozen = frozen
		sendAck(link)
	end
end

-- What each hero does this tick: its next input, in order (see HeroInputQueue).
local function provideInputs(): { [number]: HeroInput.Input }
	local inputs: { [number]: HeroInput.Input } = {}
	for _, link in ordered do
		local input, seq = HeroInputQueue.take(link.queue)
		-- Nothing has arrived: the hero waits, and so does its clock.
		if input and seq then
			inputs[link.slot] = if link.frozen then HeroInput.idle() else input
			link.lastSeq = seq
		end
	end
	return inputs
end

-- After every tick: tell each player where their hero is, and everyone where all heroes are.
local function sendStates(state: Sim.State)
	local entries: { HeroSnapshot.Entry } = {}
	for _, hero in state.heroes do
		local link = bySlot[hero.slot]
		if link then
			sendAck(link)
		end
		table.insert(entries, {
			userId = hero.userId,
			x = hero.sim.motion.x,
			z = hero.sim.motion.z,
			facing = hero.sim.facing,
			flags = if HeroMotion.isDashing(hero.sim.motion) then HeroSnapshot.DASHING else 0,
		})
	end
	if #entries > 0 then
		network:fireAllClientsUnreliable("onHeroes", HeroSnapshot.encode(entries))
	end
end

function HeroService.init()
	network = Network.server("Hero", HeroService, {
		requestHero = {}, -- client -> server
		sendInputs = { Packet.Buffer }, -- client -> server: the last input's number, a count and the inputs
		onHeroEntity = { Packet.NumberU16 }, -- the combat entity of the player's hero
		-- The hero's state after input `seq`: seq, x, z, dash ticks left, dash step x and z,
		-- ticks used, flags (1 = held), and the ticks left on abilities 1 to 3.
		onHeroAck = {
			Packet.NumberU32,
			Packet.NumberF64,
			Packet.NumberF64,
			Packet.NumberU8,
			Packet.NumberF32,
			Packet.NumberF32,
			Packet.NumberU32,
			Packet.NumberU8,
			Packet.NumberU16,
			Packet.NumberU16,
			Packet.NumberU16,
		},
		onHeroes = { Packet.BufferLong }, -- every hero's position, see HeroSnapshot
		onHeroAttack = { Packet.NumberU32, Packet.NumberF32 }, -- user id, angle
		onAbilityUsed = { Packet.NumberU32, Packet.NumberU8, Packet.NumberF32 }, -- user id, ability, angle
		onAbilityRejected = { Packet.NumberU8, Packet.NumberF32 }, -- ability, seconds until ready
	})

	SimService.setInputProvider(provideInputs)
	SimService.afterStep(sendStates)

	SimService.observe("heroJoined", function(event: SimContext.Event)
		local link = bySlot[event.slot]
		if link then
			-- Dropped if the client hasn't connected yet: it asks again with requestHero.
			network:fireClient(link.player, "onHeroEntity", event.entityId)
			sendAck(link)
		end
	end)

	-- Put somewhere (a spawn, the lobby): whatever it was doing stops, and the
	-- inputs sent for the old place are dropped. The client is told at once.
	SimService.observe("teleport", function(event: SimContext.Event)
		local link = bySlot[event.slot]
		if link then
			HeroInputQueue.skipTo(link.queue, link.queue.newest)
			local nextSeq = link.queue.nextSeq
			link.lastSeq = math.max(link.lastSeq, if nextSeq then nextSeq - 1 else 0)
			sendAck(link)
		end
	end)

	SimService.observe("heroAttack", function(event: SimContext.Event)
		network:fireAllClients("onHeroAttack", event.userId, Angle.toRadians(event.angle))
	end)

	SimService.observe("abilityUsed", function(event: SimContext.Event)
		network:fireAllClients("onAbilityUsed", event.userId, event.index, Angle.toRadians(event.angle))
	end)

	SimService.observe("abilityRejected", function(event: SimContext.Event)
		local link = bySlot[event.slot]
		if link then
			network:fireClient(link.player, "onAbilityRejected", event.index, event.ticks / SimClock.RATE)
		end
	end)

	for _, player in Players:GetPlayers() do
		watch(player)
	end
	Players.PlayerAdded:Connect(watch)
	Players.PlayerRemoving:Connect(removeHero)
end

-- Network (client -> server)
function HeroService.requestHero(player: Player)
	local link = byPlayer[player]
	local hero = if link then Sim.hero(SimService.state(), link.slot) else nil
	if hero and RateLimit.take(heroLimit, player) then
		network:fireClient(player, "onHeroEntity", hero.entity.id)
	end
end

function HeroService.sendInputs(player: Player, data: buffer)
	local link = byPlayer[player]
	if link == nil or type(data) ~= "buffer" or not RateLimit.take(inputLimit, player) then
		return
	end

	local length = buffer.len(data)
	if length < PACKET_HEADER then
		return
	end
	local last = buffer.readu32(data, 0)
	local count = buffer.readu8(data, 4)
	if count < 1 or length ~= PACKET_HEADER + count * HeroInput.SIZE then
		return
	end

	local inputs: { HeroInput.Input } = {}
	for index = 0, count - 1 do
		local input = HeroInput.read(data, PACKET_HEADER + index * HeroInput.SIZE)
		if input == nil then
			return
		end
		table.insert(inputs, input)
	end

	if not HeroInputQueue.receive(link.queue, last, inputs) then
		Log.debug(`{player.Name} sent a bad input packet`)
	end
end

return HeroService
