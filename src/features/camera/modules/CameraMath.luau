--!strict

--[=[
	Maths for the fixed top-down camera, on plain numbers so Lune can test it.
]=]

local CameraMath = {}

-- Offset from the focus point to the camera. Yaw 0 puts the camera on the +Z
-- side looking towards -Z, and yaw 90 puts it on the +X side. Pitch is the
-- angle above the horizon in degrees: 90 looks straight down.
function CameraMath.offset(pitchDegrees: number, yawDegrees: number, distance: number): (number, number, number)
	local pitch = math.rad(pitchDegrees)
	local yaw = math.rad(yawDegrees)
	local flat = math.cos(pitch) * distance
	return math.sin(yaw) * flat, math.sin(pitch) * distance, math.cos(yaw) * flat
end

-- How far to move towards the target this frame, from 0 (stay) to 1 (arrive).
-- Exponential, so the result doesn't depend on the frame rate: two frames of
-- dt / 2 cover the same distance as one frame of dt.
function CameraMath.smoothAlpha(dt: number, rate: number): number
	if dt <= 0 then
		return 0
	end
	return 1 - math.exp(-rate * dt)
end

return CameraMath
