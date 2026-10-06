--!strict

--[=[
	What a hero is asking to do, as the server sees it. Attacking is a held
	state: the client says when it goes down or up, and the server swings on
	its own timer while it is held, so a fast client can't swing faster.

	Everything a client sends is untrusted, so each setter checks its input
	and leaves the state alone when it is bad. Plain tables and numbers, and
	the clock is passed in, so Lune can test it.
]=]

local Angle = require("@Core/Angle")

local AttackInput = {}

export type State = {
	active: boolean,
	-- Where the client is aiming, in Angle units (ignored in auto mode).
	angle: number,
	-- Auto-target: swing at the nearest enemy and ignore the angle.
	auto: boolean,
	nextSwing: number,
}

-- A whole number in [0, Angle.TURN): an angle in Angle units.
function AttackInput.isAngle(value: any): boolean
	return type(value) == "number" and value % 1 == 0 and value >= 0 and value < Angle.TURN
end

function AttackInput.new(): State
	return { active = false, angle = 0, auto = false, nextSwing = 0 }
end

-- The button went down or up. Returns false, changing nothing, if the input is bad.
function AttackInput.setAttack(state: State, active: any, angle: any, auto: any): boolean
	if type(active) ~= "boolean" or type(auto) ~= "boolean" or not AttackInput.isAngle(angle) then
		return false
	end

	state.active = active
	state.auto = auto
	state.angle = angle
	return true
end

-- The aim moved while attacking. Returns false if the angle is bad.
function AttackInput.setAim(state: State, angle: any): boolean
	if not AttackInput.isAngle(angle) then
		return false
	end
	state.angle = angle
	return true
end

-- Whether a swing is due now: held, and the swing timer is up.
function AttackInput.due(state: State, now: number): boolean
	return state.active and now >= state.nextSwing
end

-- Which way to swing. In auto mode that's the way to the nearest enemy
-- (`autoAngle`, nil if none is in range) and the client's angle is ignored.
-- Otherwise it's the client's aim.
function AttackInput.swingAngle(state: State, autoAngle: number?): number?
	if state.auto then
		return autoAngle
	end
	return state.angle
end

-- A swing happened: the next one is `cooldown` later. It counts from the
-- scheduled time when the loop is only slightly late, so the rate stays even.
function AttackInput.swung(state: State, now: number, cooldown: number)
	local scheduled = state.nextSwing + cooldown
	state.nextSwing = if scheduled > now - cooldown then scheduled else now + cooldown
end

-- Stops attacking, e.g. when the hero goes down.
function AttackInput.stop(state: State)
	state.active = false
end

return AttackInput
