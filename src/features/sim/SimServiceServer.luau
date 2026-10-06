--!strict

--[=[
	Sim, server side: runs the simulation (see modules/Sim) at a fixed 20 ticks
	a second and hands what happens to the features that talk to players.

	Every other server feature is an adapter over this one:
	- inputs: the heroes feature gives `setInputProvider` a function that
	  returns what each hero does this tick (it is called once per tick, just
	  before the step);
	- commands: heroes joining and leaving, and the run starting, are queued
	  with `command` and applied at the start of the next step;
	- events: `observe(kind, callback)` runs a callback for every event of a
	  kind the step produced, in the order they happened. `afterStep` runs once
	  per tick after the events, for things sent every tick (acks, snapshots).

	The sim never calls out, so nothing here changes what it computes: the
	adapters only turn its events into network messages, Instances and saved
	data. A callback that errors is logged and skipped.
]=]

local RunService = game:GetService("RunService")

local HeroInput = require("@Features/heroes/modules/HeroInput")
local Log = require("@Core/Log")
local Sim = require("@Features/sim/modules/Sim")
local SimClock = require("@Features/sim/modules/SimClock")
local SimContext = require("@Features/sim/modules/SimContext")

export type InputProvider = () -> { [number]: HeroInput.Input }
export type AfterStep = (state: Sim.State) -> ()

local SimService = {}

-- A long frame runs at most this many ticks, then carries on from there.
local MAX_TICKS_PER_FRAME = 4

local state: Sim.State = Sim.new()
local commands: { Sim.Command } = {}
local inputProvider: InputProvider? = nil
local observers: { [string]: { (event: SimContext.Event) -> () } } = {}
local afterSteps: { AfterStep } = {}

-- Runs one tick: the inputs and commands in, the events out to the observers.
local function tick()
	local inputs: { [number]: HeroInput.Input } = {}
	local provider = inputProvider
	if provider then
		local ok, result = pcall(provider)
		if ok then
			inputs = result
		else
			Log.warn(`Hero inputs failed: {result}`)
		end
	end

	local frame: Sim.Frame = { inputs = inputs, commands = commands }
	commands = {}

	local ok, events = xpcall(Sim.step, debug.traceback, state, frame)
	if not ok then
		Log.warn(`Simulation step failed: {events}`)
		return
	end

	for _, event in events :: { SimContext.Event } do
		local callbacks = observers[event.kind]
		if callbacks then
			for _, callback in callbacks do
				local called, err = pcall(callback :: any, event)
				if not called then
					Log.warn(`Handling {event.kind} failed: {err}`)
				end
			end
		end
	end

	for _, callback in afterSteps do
		local called, err = pcall(callback :: any, state)
		if not called then
			Log.warn(`After-step hook failed: {err}`)
		end
	end
end

-- The simulation. Read it, never change it: everything changes through commands and inputs.
function SimService.state(): Sim.State
	return state
end

-- Applies a command at the start of the next tick.
function SimService.command(command: Sim.Command)
	table.insert(commands, command)
end

-- Sets who says what each hero does every tick (the heroes feature).
function SimService.setInputProvider(provider: InputProvider)
	inputProvider = provider
end

-- Runs `callback(event)` for every event of `kind`. Returns a function that stops it.
function SimService.observe(kind: string, callback: (event: SimContext.Event) -> ()): () -> ()
	local list = observers[kind]
	if list == nil then
		list = {}
		observers[kind] = list
	end
	table.insert(list, callback)

	return function()
		local index = table.find(list, callback)
		if index then
			table.remove(list, index)
		end
	end
end

-- Runs `callback(state)` after every tick, once the events are handled.
function SimService.afterStep(callback: AfterStep)
	table.insert(afterSteps, callback)
end

function SimService.init()
	local carried = 0
	RunService.Heartbeat:Connect(function(dt)
		carried += dt
		local ticks = 0
		while carried >= SimClock.TICK and ticks < MAX_TICKS_PER_FRAME do
			carried -= SimClock.TICK
			ticks += 1
			tick()
		end
		-- A frame that long is not made up for later.
		if carried > SimClock.TICK then
			carried = 0
		end
	end)
end

return SimService
