local Expect = require("./Expect")
local StateMachine = require("../src/core/StateMachine")

type Context = { log: { string } }

-- Records "<name>:enter" / "<name>:exit" so tests can assert the exact order.
local function tracked(name: string, parent: StateMachine.State<Context>?): StateMachine.State<Context>
	return StateMachine.state({
		name = name,
		parent = parent,
		enter = function(context: Context)
			table.insert(context.log, `{name}:enter`)
		end,
		exit = function(context: Context)
			table.insert(context.log, `{name}:exit`)
		end,
	})
end

-- Grounded > (Idle, Walking), Airborne
local function build(extra: { transitions: { StateMachine.TransitionConfig<Context> }? }?)
	local Grounded = tracked("Grounded")
	local Idle = tracked("Idle", Grounded)
	local Walking = tracked("Walking", Grounded)
	local Airborne = tracked("Airborne")

	local context: Context = { log = {} }
	local transitions: { StateMachine.TransitionConfig<Context> } = {
		{ from = Idle, to = Walking, event = "Walk" },
		{ from = Grounded, to = Airborne, event = "Jump" },
		{ to = Idle, event = "Land" },
	}
	for _, transition in (extra and extra.transitions) or {} do
		table.insert(transitions, transition)
	end

	local machine = StateMachine.create({
		initial = Idle,
		states = { Grounded, Idle, Walking, Airborne },
		transitions = transitions,
		context = context,
	})
	return machine, context, { Grounded = Grounded, Idle = Idle, Walking = Walking, Airborne = Airborne }
end

return {
	["enters the initial chain outermost first"] = function()
		local machine, context = build()
		Expect.equal(StateMachine.getState(machine), "Idle")
		Expect.deepEqual(context.log, { "Grounded:enter", "Idle:enter" })
	end,

	["siblings share their parent"] = function()
		local machine, context = build()
		table.clear(context.log)

		Expect.equal(StateMachine.send(machine, "Walk"), true)
		Expect.deepEqual(context.log, { "Idle:exit", "Walking:enter" })
		Expect.equal(machine.previousState, "Idle")
	end,

	["a transition from an ancestor applies to its descendants"] = function()
		local machine, context = build()
		table.clear(context.log)

		Expect.equal(StateMachine.send(machine, "Jump"), true)
		Expect.deepEqual(context.log, { "Idle:exit", "Grounded:exit", "Airborne:enter" })
	end,

	["transitions without a source fire from anywhere"] = function()
		local machine, context = build()
		StateMachine.send(machine, "Jump")
		table.clear(context.log)

		Expect.equal(StateMachine.send(machine, "Land"), true)
		Expect.deepEqual(context.log, { "Airborne:exit", "Grounded:enter", "Idle:enter" })
	end,

	["moving to the current state or an ancestor is local"] = function()
		local machine, context = build()
		table.clear(context.log)

		StateMachine.send(machine, "Land") -- Idle -> Idle
		Expect.deepEqual(context.log, {}, "self transition")
		Expect.equal(StateMachine.getState(machine), "Idle")
	end,

	["unknown events are ignored"] = function()
		local machine, context = build()
		table.clear(context.log)

		Expect.equal(StateMachine.send(machine, "Nope"), false)
		Expect.equal(StateMachine.send(machine, "Walk"), true)
		Expect.equal(StateMachine.send(machine, "Walk"), false, "Walk only applies to Idle")
		Expect.equal(StateMachine.getState(machine), "Walking")
	end,

	["guards decide, and the first passing transition wins"] = function()
		local Idle = StateMachine.state({ name = "Idle" })
		local A = StateMachine.state({ name = "A" })
		local B = StateMachine.state({ name = "B" })
		local context = { allowA = false }

		local machine = StateMachine.create({
			initial = Idle,
			states = { Idle, A, B },
			transitions = {
				{
					from = Idle,
					to = A,
					event = "Go",
					guard = function(c: typeof(context))
						return c.allowA
					end,
				},
				{ from = Idle, to = B, event = "Go" },
			},
			context = context,
		})

		StateMachine.send(machine, "Go")
		Expect.equal(StateMachine.getState(machine), "B")
	end,

	["isState matches the state and its ancestors"] = function()
		local machine = build()
		Expect.equal(StateMachine.isState(machine, "Idle"), true)
		Expect.equal(StateMachine.isState(machine, "Grounded"), true)
		Expect.equal(StateMachine.isState(machine, "Airborne"), false)
	end,

	["update runs the chain outermost first"] = function()
		local order = {}
		local Parent = StateMachine.state({
			name = "Parent",
			update = function(_, dt: number)
				table.insert(order, `Parent:{dt}`)
			end,
		})
		local Child = StateMachine.state({
			name = "Child",
			parent = Parent,
			update = function(_, dt: number)
				table.insert(order, `Child:{dt}`)
			end,
		})

		local machine = StateMachine.create({ initial = Child, states = { Parent, Child }, context = {} })
		StateMachine.update(machine, 0.5)
		Expect.deepEqual(order, { "Parent:0.5", "Child:0.5" })
	end,

	["update stops once an update changes the state"] = function()
		local childUpdates = 0
		local machine: StateMachine.Machine<{}>
		local Parent = StateMachine.state({
			name = "Parent",
			update = function()
				StateMachine.send(machine, "Leave")
			end,
		})
		local Child = StateMachine.state({
			name = "Child",
			parent = Parent,
			update = function()
				childUpdates += 1
			end,
		})
		local Other = StateMachine.state({ name = "Other" })

		machine = StateMachine.create({
			initial = Child,
			states = { Parent, Child, Other },
			transitions = { { to = Other, event = "Leave" } },
			context = {},
		})

		StateMachine.update(machine, 1)
		Expect.equal(StateMachine.getState(machine), "Other")
		Expect.equal(childUpdates, 0, "exited state was still updated")
	end,

	["send from enter is queued until the transition finishes"] = function()
		local log = {}
		local machine: StateMachine.Machine<{}>
		local Start = StateMachine.state({
			name = "Start",
			exit = function()
				table.insert(log, "Start:exit")
			end,
		})
		local Middle = StateMachine.state({
			name = "Middle",
			enter = function()
				table.insert(log, "Middle:enter")
				table.insert(log, `send returned {StateMachine.send(machine, "Next")}`)
			end,
			exit = function()
				table.insert(log, "Middle:exit")
			end,
		})
		local End = StateMachine.state({
			name = "End",
			enter = function()
				table.insert(log, "End:enter")
			end,
		})

		machine = StateMachine.create({
			initial = Start,
			states = { Start, Middle, End },
			transitions = {
				{ from = Start, to = Middle, event = "Go" },
				{ from = Middle, to = End, event = "Next" },
			},
			context = {},
		})

		StateMachine.send(machine, "Go")
		Expect.deepEqual(log, {
			"Start:exit",
			"Middle:enter",
			"send returned false",
			"Middle:exit",
			"End:enter",
		})
		Expect.equal(StateMachine.getState(machine), "End")
	end,

	["events sent while another machine's enter runs are independent"] = function()
		-- Each machine has its own queue: sending to B from A's callback is a
		-- normal, immediate transition.
		local B: StateMachine.Machine<{}>
		local Start = StateMachine.state({ name = "Start" })
		local Done = StateMachine.state({ name = "Done" })
		B = StateMachine.create({
			initial = Start,
			states = { Start, Done },
			transitions = { { from = Start, to = Done, event = "Finish" } },
			context = {},
		})

		local result: boolean? = nil
		local Idle = StateMachine.state({ name = "Idle" })
		local Busy = StateMachine.state({
			name = "Busy",
			enter = function()
				result = StateMachine.send(B, "Finish")
			end,
		})
		local A = StateMachine.create({
			initial = Idle,
			states = { Idle, Busy },
			transitions = { { from = Idle, to = Busy, event = "Work" } },
			context = {},
		})

		StateMachine.send(A, "Work")
		Expect.equal(result, true)
		Expect.equal(StateMachine.getState(B), "Done")
	end,

	["an erroring callback leaves the machine usable"] = function()
		local explode = true
		local A = StateMachine.state({ name = "A" })
		local B = StateMachine.state({
			name = "B",
			enter = function()
				if explode then
					error("boom")
				end
			end,
		})
		local C = StateMachine.state({ name = "C" })

		local machine = StateMachine.create({
			initial = A,
			states = { A, B, C },
			transitions = {
				{ from = A, to = B, event = "ToB" },
				{ from = B, to = C, event = "ToC" },
			},
			context = {},
		})

		Expect.errors(function()
			StateMachine.send(machine, "ToB")
		end, "boom")

		-- The transition happened before the callback failed, and the machine
		-- still accepts events.
		Expect.equal(machine.transitioning, false)
		Expect.equal(StateMachine.send(machine, "ToC"), true)
		Expect.equal(StateMachine.getState(machine), "C")
	end,

	["create validates its configuration"] = function()
		local A = StateMachine.state({ name = "A" })
		local B = StateMachine.state({ name = "B" })
		local Orphan = StateMachine.state({ name = "Orphan", parent = B })

		Expect.errors(function()
			StateMachine.create({ initial = A, states = { A, A }, context = {} })
		end, "Duplicate state")
		Expect.errors(function()
			StateMachine.create({ initial = B, states = { A }, context = {} })
		end, "missing from states")
		Expect.errors(function()
			StateMachine.create({ initial = A, states = { A, Orphan }, context = {} })
		end, "missing from states")
		Expect.errors(function()
			StateMachine.state({ name = "" })
		end, "non-empty name")
	end,
}
