--!strict

--[=[
	The phases of a run. Pure: RunServiceServer owns one machine, and the specs
	drive it directly.

		Waiting ─Start─▶ Generating ─Generated─▶ Exploring ─Charge─▶ Charging
		                      ▲                                          │
		                      │                                      Charged
		                  NextAct                                        ▼
		                      │                                        Boss
		                  ExitOpen ◀─────────BossDefeated────────────────┘
		                      │
		                     Win ─▶ Victory

		any phase between Generating and ExitOpen ─Downed─▶ Defeat
		Victory or Defeat ─Start─▶ Generating (play again)

	The act number counts from 1 and moves on `advance`.
]=]

local StateMachine = require("@Core/StateMachine")

export type Phase = "Waiting" | "Generating" | "Exploring" | "Charging" | "Boss" | "ExitOpen" | "Victory" | "Defeat"

type Context = {
	actIndex: number,
	totalActs: number,
}

export type Run = StateMachine.Machine<Context>

local Waiting: StateMachine.State<Context> = StateMachine.state({ name = "Waiting" } :: StateMachine.State<Context>)
-- Every phase of an act in progress: a downed party ends them all.
local Active: StateMachine.State<Context> = StateMachine.state({ name = "Active" } :: StateMachine.State<Context>)
local Generating: StateMachine.State<Context> =
	StateMachine.state({ name = "Generating", parent = Active } :: StateMachine.State<Context>)
local Exploring: StateMachine.State<Context> =
	StateMachine.state({ name = "Exploring", parent = Active } :: StateMachine.State<Context>)
local Charging: StateMachine.State<Context> =
	StateMachine.state({ name = "Charging", parent = Active } :: StateMachine.State<Context>)
local Boss: StateMachine.State<Context> =
	StateMachine.state({ name = "Boss", parent = Active } :: StateMachine.State<Context>)
local ExitOpen: StateMachine.State<Context> =
	StateMachine.state({ name = "ExitOpen", parent = Active } :: StateMachine.State<Context>)
local Victory: StateMachine.State<Context> = StateMachine.state({ name = "Victory" } :: StateMachine.State<Context>)
local Defeat: StateMachine.State<Context> = StateMachine.state({ name = "Defeat" } :: StateMachine.State<Context>)

local STATES = { Waiting, Active, Generating, Exploring, Charging, Boss, ExitOpen, Victory, Defeat }

local TRANSITIONS: { StateMachine.TransitionConfig<Context> } = {
	{ from = Waiting, to = Generating, event = "Start" },
	{ from = Victory, to = Generating, event = "Start" },
	{ from = Defeat, to = Generating, event = "Start" },
	{ from = Generating, to = Exploring, event = "Generated" },
	{ from = Exploring, to = Charging, event = "Charge" },
	{ from = Charging, to = Boss, event = "Charged" },
	{ from = Boss, to = ExitOpen, event = "BossDefeated" },
	{
		from = ExitOpen,
		to = Generating,
		event = "NextAct",
		guard = function(context: Context): boolean
			return context.actIndex < context.totalActs
		end,
	},
	{
		from = ExitOpen,
		to = Victory,
		event = "Win",
		guard = function(context: Context): boolean
			return context.actIndex >= context.totalActs
		end,
	},
	{ from = Active, to = Defeat, event = "Downed" },
}

local RunStateMachine = {}

function RunStateMachine.create(totalActs: number): Run
	return StateMachine.create({
		initial = Waiting,
		states = STATES,
		transitions = TRANSITIONS,
		context = { actIndex = 1, totalActs = math.max(1, totalActs) },
	})
end

function RunStateMachine.getPhase(run: Run): Phase
	return StateMachine.getState(run) :: Phase
end

function RunStateMachine.actIndex(run: Run): number
	return run.context.actIndex
end

function RunStateMachine.totalActs(run: Run): number
	return run.context.totalActs
end

-- Waiting, Victory or Defeat -> Generating, back at act 1. False in any other phase.
function RunStateMachine.start(run: Run): boolean
	local ok = StateMachine.send(run, "Start")
	if ok then
		run.context.actIndex = 1
	end
	return ok
end

function RunStateMachine.generated(run: Run): boolean
	return StateMachine.send(run, "Generated")
end

function RunStateMachine.charge(run: Run): boolean
	return StateMachine.send(run, "Charge")
end

function RunStateMachine.charged(run: Run): boolean
	return StateMachine.send(run, "Charged")
end

function RunStateMachine.bossDefeated(run: Run): boolean
	return StateMachine.send(run, "BossDefeated")
end

-- Through the exit: the next act, or Victory after the last. False outside ExitOpen.
function RunStateMachine.advance(run: Run): boolean
	if StateMachine.send(run, "NextAct") then
		run.context.actIndex += 1
		return true
	end
	return StateMachine.send(run, "Win")
end

-- Every hero is down: any phase of an act ends in Defeat. False otherwise.
function RunStateMachine.downed(run: Run): boolean
	return StateMachine.send(run, "Downed")
end

return RunStateMachine
