--!strict

--[=[
	What the server tells every client about the run. The view is small, so it
	is sent whole (a DeltaCompress full sync) whenever it changes, like the
	trade view.
]=]

local DeltaCompress = require("@Core/DeltaCompress")
local RunStateMachine = require("@Features/run/modules/RunStateMachine")

export type View = {
	phase: RunStateMachine.Phase,
	act: number,
	totalActs: number,
	-- Whole seconds into the run.
	elapsed: number,
	-- The difficulty coefficient, to two decimals.
	coefficient: number,
	-- Teleporter charge, 0 to 1 in hundredths.
	charge: number,
	-- This run's earnings: shown while it runs, final once it has ended.
	coins: number,
	xp: number,
	-- Heroes still standing.
	alive: number,
}

local TEMPLATE: View = {
	phase = "Waiting",
	act = 1,
	totalActs = 1,
	elapsed = 0,
	coefficient = 1,
	charge = 0,
	coins = 0,
	xp = 0,
	alive = 0,
}

local CONTEXT = DeltaCompress.createContext(TEMPLATE)
DeltaCompress.registerStrings(CONTEXT, {
	"Waiting",
	"Generating",
	"Exploring",
	"Charging",
	"Boss",
	"ExitOpen",
	"Victory",
	"Defeat",
})

local RunProtocol = {}

RunProtocol.TEMPLATE = TEMPLATE

function RunProtocol.encode(view: View): buffer
	local delta = DeltaCompress.createDelta({} :: any, view, CONTEXT)
	return assert(delta, "a view is never empty")
end

function RunProtocol.decode(data: buffer): View
	return DeltaCompress.applyDelta({} :: any, data, CONTEXT)
end

return RunProtocol
