local Expect = require("./Expect")
local RunStateMachine = require("../src/features/run/modules/RunStateMachine")

return {
	["a run goes through its phases in order"] = function()
		local run = RunStateMachine.create(1)
		Expect.equal(RunStateMachine.getPhase(run), "Waiting")
		Expect.equal(RunStateMachine.start(run), true)
		Expect.equal(RunStateMachine.getPhase(run), "Generating")
		Expect.equal(RunStateMachine.generated(run), true)
		Expect.equal(RunStateMachine.getPhase(run), "Exploring")
		Expect.equal(RunStateMachine.charge(run), true)
		Expect.equal(RunStateMachine.getPhase(run), "Charging")
		Expect.equal(RunStateMachine.charged(run), true)
		Expect.equal(RunStateMachine.getPhase(run), "Boss")
		Expect.equal(RunStateMachine.bossDefeated(run), true)
		Expect.equal(RunStateMachine.getPhase(run), "ExitOpen")
		Expect.equal(RunStateMachine.advance(run), true)
		Expect.equal(RunStateMachine.getPhase(run), "Victory", "one act: the exit is the end")
	end,

	["events out of order do nothing"] = function()
		local run = RunStateMachine.create(1)
		Expect.equal(RunStateMachine.charge(run), false)
		Expect.equal(RunStateMachine.bossDefeated(run), false)
		Expect.equal(RunStateMachine.advance(run), false)
		Expect.equal(RunStateMachine.downed(run), false, "nothing to lose while waiting")
		Expect.equal(RunStateMachine.getPhase(run), "Waiting")

		RunStateMachine.start(run)
		Expect.equal(RunStateMachine.start(run), false, "already started")
		Expect.equal(RunStateMachine.charged(run), false)
		Expect.equal(RunStateMachine.getPhase(run), "Generating")
	end,

	["with more acts the exit leads to the next one"] = function()
		local run = RunStateMachine.create(2)
		RunStateMachine.start(run)
		Expect.equal(RunStateMachine.actIndex(run), 1)

		RunStateMachine.generated(run)
		RunStateMachine.charge(run)
		RunStateMachine.charged(run)
		RunStateMachine.bossDefeated(run)
		Expect.equal(RunStateMachine.advance(run), true)
		Expect.equal(RunStateMachine.getPhase(run), "Generating")
		Expect.equal(RunStateMachine.actIndex(run), 2)

		RunStateMachine.generated(run)
		RunStateMachine.charge(run)
		RunStateMachine.charged(run)
		RunStateMachine.bossDefeated(run)
		Expect.equal(RunStateMachine.advance(run), true)
		Expect.equal(RunStateMachine.getPhase(run), "Victory")
		Expect.equal(RunStateMachine.actIndex(run), 2, "the act number stops at the last")
	end,

	["a downed party ends any phase of an act in defeat"] = function()
		local steps = {
			function() end,
			RunStateMachine.generated,
			RunStateMachine.charge,
			RunStateMachine.charged,
			RunStateMachine.bossDefeated,
		}
		local phases = { "Generating", "Exploring", "Charging", "Boss", "ExitOpen" }

		for index, phase in phases do
			local run = RunStateMachine.create(1)
			RunStateMachine.start(run)
			for step = 1, index do
				steps[step](run)
			end
			Expect.equal(RunStateMachine.getPhase(run), phase)
			Expect.equal(RunStateMachine.downed(run), true, phase)
			Expect.equal(RunStateMachine.getPhase(run), "Defeat", phase)
		end
	end,

	["defeat and victory are final until play again"] = function()
		local run = RunStateMachine.create(1)
		RunStateMachine.start(run)
		RunStateMachine.downed(run)
		Expect.equal(RunStateMachine.downed(run), false)
		Expect.equal(RunStateMachine.generated(run), false)
		Expect.equal(RunStateMachine.charge(run), false)
	end,

	["play again starts over at act 1"] = function()
		local run = RunStateMachine.create(2)
		RunStateMachine.start(run)
		RunStateMachine.generated(run)
		RunStateMachine.charge(run)
		RunStateMachine.charged(run)
		RunStateMachine.bossDefeated(run)
		RunStateMachine.advance(run)
		Expect.equal(RunStateMachine.actIndex(run), 2)
		RunStateMachine.downed(run)

		Expect.equal(RunStateMachine.start(run), true)
		Expect.equal(RunStateMachine.getPhase(run), "Generating")
		Expect.equal(RunStateMachine.actIndex(run), 1)
	end,

	["the number of acts is at least one"] = function()
		Expect.equal(RunStateMachine.totalActs(RunStateMachine.create(0)), 1)
		Expect.equal(RunStateMachine.totalActs(RunStateMachine.create(3)), 3)
	end,
}
