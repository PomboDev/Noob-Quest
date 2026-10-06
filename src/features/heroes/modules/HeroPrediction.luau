--!strict

--[=[
	The client's side of owned movement: it runs its own hero ahead of the
	server (so the controls feel instant) and fixes itself when the server
	disagrees. Plain tables, so Lune can test it.

	Each input is numbered. The server says "after input N your hero is
	here". The client looks up what it predicted after input N: if the two
	match, nothing happens. If not (the server rejected an ability, moved the
	hero, or the client was cheating), it takes the server's state and replays
	the inputs it has sent since. Because the comparison is always between
	states after the same input, latency never causes a false mismatch.
]=]

local HeroInput = require("@Features/heroes/modules/HeroInput")
local HeroMotion = require("@Features/heroes/modules/HeroMotion")
local HeroSim = require("@Features/heroes/modules/HeroSim")
local NavGrid = require("@Features/enemies/modules/NavGrid")

local HeroPrediction = {}

type Record = {
	input: HeroInput.Input,
	canAct: boolean,
	-- The state after the input was used.
	motion: HeroMotion.State,
	tick: number,
	readyAt: { [number]: number },
}

export type Prediction = {
	sim: HeroSim.Sim,
	-- The number of the latest input used.
	seq: number,
	records: { [number]: Record },
}

-- What the server reports after an input.
export type Ack = {
	seq: number,
	motion: HeroMotion.State,
	tick: number,
	-- Per ability index: ticks until it is ready.
	remaining: { number },
}

-- Records kept for replay (5 seconds of ticks).
local MAX_RECORDS = 150

function HeroPrediction.new(sim: HeroSim.Sim): Prediction
	return { sim = sim, seq = 0, records = {} }
end

local function record(prediction: Prediction, input: HeroInput.Input, canAct: boolean)
	local sim = prediction.sim
	prediction.records[prediction.seq] = {
		input = input,
		canAct = canAct,
		motion = HeroMotion.copy(sim.motion),
		tick = sim.tick,
		readyAt = table.clone(sim.readyAt),
	}
	prediction.records[prediction.seq - MAX_RECORDS] = nil
end

-- Uses the next input, numbered `prediction.seq + 1` after the call.
function HeroPrediction.step(
	prediction: Prediction,
	input: HeroInput.Input,
	grid: NavGrid.Grid,
	canAct: boolean
): HeroSim.Result
	prediction.seq += 1
	local result = HeroSim.step(prediction.sim, input, grid, canAct)
	record(prediction, input, canAct)
	return result
end

-- Starts again from a state the server gave (a teleport, or a new run): the
-- inputs numbered up to `seq` are forgotten.
function HeroPrediction.reset(prediction: Prediction, seq: number, motion: HeroMotion.State)
	prediction.sim.motion = HeroMotion.copy(motion)
	prediction.seq = seq
	prediction.records = {}
end

local function matches(prediction: Prediction, ack: Ack): boolean
	local saved = prediction.records[ack.seq]
	if saved == nil and ack.seq == prediction.seq then
		-- Nothing was sent since the last reset: the state after input `seq` is the current one.
		local sim = prediction.sim
		saved = { input = HeroInput.idle(), canAct = true, motion = sim.motion, tick = sim.tick, readyAt = sim.readyAt }
	end
	if saved == nil or not HeroSim.sameMotion(saved.motion, ack.motion) then
		return false
	end
	for index in prediction.sim.def.abilities do
		local predicted = math.max(0, (saved.readyAt[index] or 0) - saved.tick)
		if predicted ~= (ack.remaining[index] or 0) then
			return false
		end
	end
	return true
end

-- Checks the server's report. Returns true if the prediction was wrong and
-- has been corrected (the caller can smooth the jump).
function HeroPrediction.acknowledge(prediction: Prediction, ack: Ack, grid: NavGrid.Grid): boolean
	if ack.seq > prediction.seq then
		-- The server is ahead of anything this client sent: start from its state.
		HeroPrediction.reset(prediction, ack.seq, ack.motion)
		prediction.sim.tick = ack.tick
		prediction.sim.readyAt = {}
		for index, left in ack.remaining do
			prediction.sim.readyAt[index] = ack.tick + left
		end
		return true
	end

	if matches(prediction, ack) then
		-- Reports older than this one can never be asked about again.
		for seq in prediction.records do
			if seq < ack.seq then
				prediction.records[seq] = nil
			end
		end
		return false
	end

	-- Wrong: take the server's state and replay what was sent after it.
	local sim = prediction.sim
	local replay: { Record } = {}
	for seq = ack.seq + 1, prediction.seq do
		local saved = prediction.records[seq]
		if saved then
			table.insert(replay, saved)
		end
	end

	sim.motion = HeroMotion.copy(ack.motion)
	sim.tick = ack.tick
	sim.readyAt = {}
	for index, left in ack.remaining do
		sim.readyAt[index] = ack.tick + left
	end

	local latest = prediction.seq
	prediction.records = {}
	prediction.seq = ack.seq
	-- A hole in the records (the client was far ahead) is replayed as nothing.
	for _, saved in replay do
		HeroPrediction.step(prediction, saved.input, grid, saved.canAct)
	end
	prediction.seq = math.max(prediction.seq, latest)
	return true
end

return HeroPrediction
