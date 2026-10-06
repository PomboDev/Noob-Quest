--!strict

--[=[
	Hierarchical state machine configured with plain tables.

		local Grounded = StateMachine.state({ name = "Grounded" })
		local Idle = StateMachine.state({ name = "Idle", parent = Grounded })
		local Airborne = StateMachine.state({
			name = "Airborne",
			enter = function(context)
				Log.debug("Jumped")
			end,
		})

		local machine = StateMachine.create({
			initial = Idle,
			states = { Grounded, Idle, Airborne },
			transitions = {
				{ from = Grounded, to = Airborne, event = "Jump" }, -- also fires while in Idle
				{ to = Idle, event = "Land" }, -- no `from`: fires from any state
			},
			context = {},
		})

		StateMachine.send(machine, "Jump")
		StateMachine.update(machine, dt)

	Resolving an event checks the current state, then each ancestor, then the
	transitions without a `from`. The first one whose guard passes wins.

	A transition exits states up to the common ancestor (innermost first) and
	enters the target's chain below it (outermost first). Moving to the current
	state or one of its ancestors is local: states that stay active are not
	exited or re-entered.

	send() from an enter/exit callback is queued and runs right after the
	current transition finishes, so callbacks always see a consistent machine.
	Guards should be pure: no side effects and no send().
]=]

local Log = require("@Core/Log")

export type State<T> = {
	name: string,
	parent: State<T>?,
	enter: ((context: T) -> ())?,
	exit: ((context: T) -> ())?,
	update: ((context: T, dt: number) -> ())?,
}

export type TransitionConfig<T> = {
	from: State<T>?,
	to: State<T>,
	event: any,
	guard: ((context: T) -> boolean)?,
}

export type MachineConfig<T> = {
	initial: State<T>,
	states: { State<T> },
	transitions: { TransitionConfig<T> }?,
	context: T,
}

type Transition<T> = {
	from: string?,
	to: string,
	guard: ((context: T) -> boolean)?,
}

export type Machine<T> = {
	currentState: string,
	previousState: string?,
	context: T,
	-- Each state's chain from the root down to itself, built once in create().
	lineages: { [string]: { State<T> } },
	transitionsByEvent: { [any]: { Transition<T> } },
	-- True while enter/exit callbacks run; send() queues events meanwhile.
	transitioning: boolean,
	queue: { any },
}

local function buildLineages<T>(states: { [string]: State<T> }): { [string]: { State<T> } }
	local lineages: { [string]: { State<T> } } = {}

	for name, state in states do
		local reversed: { State<T> } = {}
		local current: State<T>? = state
		while current do
			assert(
				states[current.name] == current,
				`State '{current.name}' is used as a parent but missing from states`
			)
			table.insert(reversed, current)
			current = current.parent
		end

		local lineage: { State<T> } = {}
		for index = #reversed, 1, -1 do
			table.insert(lineage, reversed[index])
		end
		lineages[name] = lineage
	end

	return lineages
end

local function passes<T>(transition: Transition<T>, context: T): boolean
	local guard = transition.guard
	return guard == nil or guard(context)
end

-- The state an event leads to from the current state, if any.
local function findTarget<T>(machine: Machine<T>, event: any): string?
	local candidates = machine.transitionsByEvent[event]
	if not candidates then
		return nil
	end

	local context = machine.context
	local lineage = machine.lineages[machine.currentState]

	for index = #lineage, 1, -1 do
		local name = lineage[index].name
		for _, transition in candidates do
			if transition.from == name and passes(transition, context) then
				return transition.to
			end
		end
	end

	for _, transition in candidates do
		if transition.from == nil and passes(transition, context) then
			return transition.to
		end
	end

	return nil
end

local function enterInitial<T>(machine: Machine<T>)
	for _, state in machine.lineages[machine.currentState] do
		local enter = state.enter
		if enter then
			enter(machine.context)
		end
	end
end

local function moveTo<T>(machine: Machine<T>, target: string, event: any)
	local context = machine.context
	local fromLineage = machine.lineages[machine.currentState]
	local toLineage = machine.lineages[target]

	local common = 0
	for index = 1, math.min(#fromLineage, #toLineage) do
		if fromLineage[index] ~= toLineage[index] then
			break
		end
		common = index
	end

	for index = #fromLineage, common + 1, -1 do
		local exit = fromLineage[index].exit
		if exit then
			exit(context)
		end
	end

	machine.previousState = machine.currentState
	machine.currentState = target
	Log.debug(`Transition: {machine.previousState} -> {target} (event: {event})`)

	for index = common + 1, #toLineage do
		local enter = toLineage[index].enter
		if enter then
			enter(context)
		end
	end
end

local function traceback(message: any): string
	return debug.traceback(tostring(message), 2)
end

-- Runs enter/exit callbacks with the machine marked as transitioning. If one
-- errors, the flag and the queue are reset before the error propagates, so
-- the machine stays usable.
local function guarded<T>(machine: Machine<T>, fn: (Machine<T>, ...any) -> (), ...: any)
	machine.transitioning = true
	-- `:: any`: strict mode has no type for the error of a call that returns nothing
	local ok, err = xpcall(fn :: any, traceback, machine, ...)
	machine.transitioning = false

	if not ok then
		table.clear(machine.queue)
		error(err, 0)
	end
end

-- Processes the events callbacks sent, in order. Each one may queue more.
local function drain<T>(machine: Machine<T>)
	local queue = machine.queue
	while #queue > 0 do
		local event = table.remove(queue, 1)
		local target = findTarget(machine, event)
		if target then
			guarded(machine, moveTo, target, event)
		end
	end
end

local StateMachine = {}

-- Declares a state. Returns a frozen copy, so states can be shared safely.
function StateMachine.state<T>(config: State<T>): State<T>
	assert(type(config.name) == "string" and #config.name > 0, "State requires a non-empty name")
	return table.freeze(table.clone(config)) :: any
end

function StateMachine.create<T>(config: MachineConfig<T>): Machine<T>
	local states: { [string]: State<T> } = {}
	for _, state in config.states do
		assert(states[state.name] == nil, `Duplicate state '{state.name}'`)
		states[state.name] = state
	end

	assert(
		states[config.initial.name] == config.initial,
		`Initial state '{config.initial.name}' is missing from states`
	)

	local transitionsByEvent: { [any]: { Transition<T> } } = {}
	local configured: { TransitionConfig<T> } = config.transitions or {}
	for _, transition in configured do
		assert(
			states[transition.to.name] == transition.to,
			`Transition target '{transition.to.name}' is missing from states`
		)
		local from = transition.from
		if from then
			assert(states[from.name] == from, `Transition source '{from.name}' is missing from states`)
		end

		local list = transitionsByEvent[transition.event]
		if not list then
			list = {}
			transitionsByEvent[transition.event] = list
		end
		table.insert(list, {
			from = if from then from.name else nil,
			to = transition.to.name,
			guard = transition.guard,
		})
	end

	local machine: Machine<T> = {
		currentState = config.initial.name,
		previousState = nil,
		context = config.context,
		lineages = buildLineages(states),
		transitionsByEvent = transitionsByEvent,
		transitioning = false,
		queue = {},
	}

	guarded(machine, enterInitial)
	drain(machine)

	return machine
end

-- Fires an event. Returns whether a transition was taken. From inside an
-- enter/exit callback the event is queued instead and false is returned.
function StateMachine.send<T>(machine: Machine<T>, event: any): boolean
	if machine.transitioning then
		table.insert(machine.queue, event)
		return false
	end

	local target = findTarget(machine, event)
	if target == nil then
		return false
	end

	guarded(machine, moveTo, target, event)
	drain(machine)
	return true
end

-- Runs update() on the current state's chain, outermost first. Stops early
-- if an update sends an event that changes the state.
function StateMachine.update<T>(machine: Machine<T>, dt: number)
	local context = machine.context
	local current = machine.currentState
	for _, state in machine.lineages[current] do
		local update = state.update
		if update then
			update(context, dt)
			if machine.currentState ~= current then
				return
			end
		end
	end
end

function StateMachine.getState<T>(machine: Machine<T>): string
	return machine.currentState
end

function StateMachine.getContext<T>(machine: Machine<T>): T
	return machine.context
end

-- Whether the machine is in `stateName` or one of its descendants.
function StateMachine.isState<T>(machine: Machine<T>, stateName: string): boolean
	for _, state in machine.lineages[machine.currentState] do
		if state.name == stateName then
			return true
		end
	end
	return false
end

return StateMachine
