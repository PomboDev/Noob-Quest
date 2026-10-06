--!strict

--[=[
	Run director, server side: ties the run in the simulation (see RunSim) to
	players and their saved data.

		Waiting (the lobby) ─▶ Generating ─▶ Exploring ─▶ Charging ─▶ Boss ─▶ ExitOpen ─▶ Victory
		                                  any phase of an act ─▶ Defeat
		Victory or Defeat ─▶ Waiting

	The sim runs the run: the phases, the camps, the waves, the teleporter and
	the boss. A run starts when a hero uses the lobby portal; the sim says so
	(`runRequested`) and this feature picks the run's two random seeds (the map
	and the loot) and starts it. Seeds are the only randomness that comes from
	outside the sim, and they go in as a command, so a run can be played again.

	Loot is saved the moment it is picked up, so nothing waits for the end of a
	run. Dying costs a share of the player's coins and XP (DeathPenalty) and
	sends everyone back to the lobby; winning pays a bonus and shows the
	results first. The act number, timer and difficulty are shared with every
	client as a small view (RunProtocol).
]=]

local Players = game:GetService("Players")

local DeathPenalty = require("@Features/run/modules/DeathPenalty")
local HeroService = require("@Features/heroes/HeroServiceServer")
local Log = require("@Core/Log")
local LootTables = require("@Features/loot/modules/LootTables")
local Network = require("@Core/Network")
local PlayerService = require("@Features/player/PlayerServiceServer")
local RateLimit = require("@Core/RateLimit")
local RunProtocol = require("@Features/run/modules/RunProtocol")
local RunRewards = require("@Features/run/modules/RunRewards")
local Sim = require("@Features/sim/modules/Sim")
local SimClock = require("@Features/sim/modules/SimClock")
local SimContext = require("@Features/sim/modules/SimContext")
local SimService = require("@Features/sim/SimServiceServer")

local Packet = Network.Packet

local RunFeature = {}

-- The view is sent if it changed, at most this often (in ticks): 4 a second.
local BROADCAST_EVERY = SimClock.RATE // 4

local network: Network.ServerNetwork

local lastView: RunProtocol.View? = nil
local sinceBroadcast = 0

local lobbyLimit = RateLimit.new({ burst = 1, perSecond = 0.5 })
local requestLimit = RateLimit.new({ burst = 2, perSecond = 0.5 })

local function sameView(a: RunProtocol.View, b: RunProtocol.View): boolean
	for key, value in a :: any do
		if (b :: any)[key] ~= value then
			return false
		end
	end
	return true
end

-- Sends the view if it changed, at most a few times a second (always when `force`).
local function broadcast(force: boolean)
	sinceBroadcast += 1
	if not force and sinceBroadcast < BROADCAST_EVERY then
		return
	end

	local view = Sim.view(SimService.state())
	if not force and lastView and sameView(view, lastView) then
		return
	end

	lastView = view
	sinceBroadcast = 0
	network:fireAllClients("onRunState", RunProtocol.encode(view))
end

-- The party fell. The price is paid at once (leaving can't dodge it).
local function onDefeat()
	for _, player in Players:GetPlayers() do
		local lost: DeathPenalty.Loss = { coins = 0, xp = 0 }
		PlayerService.updateData(player, function(data)
			lost = DeathPenalty.compute(data.coins, data.xp)
			data.coins -= lost.coins
			data.xp -= lost.xp
		end)
		network:fireClient(player, "onDeathPenalty", lost.coins, lost.xp)
		Log.debug(`{player.Name} died: -{lost.coins} coins, -{lost.xp} xp`)
	end
	Log.info("Run over: defeat")
end

-- The last exit was taken: everyone gets the bonus for winning.
local function onVictory(event: SimContext.Event)
	for _, player in Players:GetPlayers() do
		PlayerService.updateData(player, function(data)
			data.coins += event.coins
			data.level, data.xp = RunRewards.addXp(data.level, data.xp, event.xp)
		end)
	end
	local result = SimService.state().run.result
	Log.info(`Run over: victory, {result.coins} coins and {result.xp} xp collected`)
end

-- Saves what a player picked up.
local function onPickup(event: SimContext.Event)
	if not event.collected then
		return
	end

	local player = HeroService.playerOfSlot(event.slot)
	local kind = LootTables.KINDS[event.item]
	if player == nil or kind == nil then
		return
	end

	PlayerService.updateData(player, function(data)
		if kind == "coin" then
			data.coins += event.amount
		else
			data.level, data.xp = RunRewards.addXp(data.level, data.xp, event.amount)
		end
	end)
end

function RunFeature.init()
	network = Network.server("Run", RunFeature, {
		requestRun = {}, -- client -> server
		requestLobby = {}, -- client -> server: leave the results screen
		onRunState = { Packet.BufferLong },
		-- Coins and XP the player's death cost.
		onDeathPenalty = { Packet.NumberU32, Packet.NumberU32 },
	})

	-- A hero used the lobby portal: the run's seeds are picked here, outside the sim.
	local seeds = Random.new()
	SimService.observe("runRequested", function()
		SimService.command({
			kind = "startRun",
			mapSeed = seeds:NextInteger(1, 2 ^ 31),
			lootSeed = seeds:NextInteger(1, 2 ^ 31),
		})
	end)

	SimService.observe("pickup", onPickup)
	SimService.observe("defeat", onDefeat)
	SimService.observe("victory", onVictory)
	SimService.observe("runChanged", function()
		broadcast(true)
	end)
	SimService.observe("lobby", function()
		Log.debug("Back in the lobby")
	end)

	SimService.afterStep(function()
		broadcast(false)
	end)
end

-- Network (client -> server)
function RunFeature.requestRun(player: Player)
	if RateLimit.take(requestLimit, player) then
		network:fireClient(player, "onRunState", RunProtocol.encode(Sim.view(SimService.state())))
	end
end

-- Leaves the results screen: everyone goes back to the lobby.
function RunFeature.requestLobby(player: Player)
	if not RateLimit.take(lobbyLimit, player) then
		return
	end

	SimService.command({ kind = "toLobby" })
end

return RunFeature
