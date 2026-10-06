--!strict

--[=[
	Angles as whole numbers, for the deterministic simulation.

	A full turn is 65536 units (a "binary angle", 16 bits), so an angle fits a
	u16 on the wire and wraps by itself. Angle 0 faces +Z and 16384 faces +X,
	the same as Targeting: the direction of angle a is (sin a, cos a).

	`math.sin`, `math.cos` and `math.atan2` come from the platform's libm and may
	differ in the last bit between Roblox, Lune and phones, which would make a
	replay drift. These read the literal tables in TrigTables instead and only
	use + - * / and floor, which every IEEE 754 machine computes the same.
	Accuracy: sin and cos within 1e-6, atan2 within 1 unit (0.0055 degrees).
]=]

local TrigTables = require("@Core/TrigTables")

local Angle = {}

Angle.TURN = 65536
Angle.HALF = 32768
Angle.QUARTER = 16384

local TURN = Angle.TURN
local HALF = Angle.HALF
local QUARTER = Angle.QUARTER
local STEPS = 1024
-- Binary angle units between two table entries of the sine table.
local UNITS_PER_STEP = QUARTER // STEPS

local SINE = TrigTables.SINE :: { number }
local ATAN = TrigTables.ATAN :: { number }

-- Wraps any integer into [0, TURN).
function Angle.wrap(angle: number): number
	return math.floor(angle) % TURN
end

-- The sine of an angle in [0, QUARTER], interpolated between table entries.
local function quarterSine(angle: number): number
	local index = angle // UNITS_PER_STEP
	local fraction = (angle - index * UNITS_PER_STEP) / UNITS_PER_STEP
	local low = SINE[index + 1]
	if fraction == 0 then
		return low
	end
	return low + (SINE[index + 2] - low) * fraction
end

function Angle.sin(angle: number): number
	local a = Angle.wrap(angle)
	local quadrant = a // QUARTER
	local within = a - quadrant * QUARTER
	if quadrant == 0 then
		return quarterSine(within)
	elseif quadrant == 1 then
		return quarterSine(QUARTER - within)
	elseif quadrant == 2 then
		return 0 - quarterSine(within)
	end
	return 0 - quarterSine(QUARTER - within)
end

function Angle.cos(angle: number): number
	return Angle.sin(angle + QUARTER)
end

-- The unit vector (x, z) the angle faces.
function Angle.direction(angle: number): (number, number)
	return Angle.sin(angle), Angle.sin(angle + QUARTER)
end

-- atan(ratio) in binary angle units for a ratio in [0, 1].
local function ratioAngle(ratio: number): number
	local position = ratio * STEPS
	local index = math.min(math.floor(position), STEPS - 1)
	local fraction = position - index
	local low = ATAN[index + 1]
	return low + (ATAN[index + 2] - low) * fraction
end

-- The angle that faces from the origin towards (dx, dz), rounded to a whole
-- unit. (0, 0) has no direction and gives 0.
function Angle.atan2(dx: number, dz: number): number
	local ax, az = math.abs(dx), math.abs(dz)
	if ax == 0 and az == 0 then
		return 0
	end

	-- The angle from the +Z axis towards +X within the first quarter turn.
	local base
	if ax <= az then
		base = ratioAngle(ax / az)
	else
		base = QUARTER - ratioAngle(az / ax)
	end

	local angle
	if dx >= 0 and dz >= 0 then
		angle = base
	elseif dx >= 0 then
		angle = HALF - base
	elseif dz < 0 then
		angle = HALF + base
	else
		angle = TURN - base
	end
	return math.floor(angle + 0.5) % TURN
end

-- The angle from one point to another, or nil when they are the same point.
function Angle.between(fromX: number, fromZ: number, toX: number, toZ: number): number?
	local dx, dz = toX - fromX, toZ - fromZ
	if dx == 0 and dz == 0 then
		return nil
	end
	return Angle.atan2(dx, dz)
end

-- Radians to the nearest angle unit (for turning input into sim angles).
function Angle.fromRadians(radians: number): number
	return math.floor(radians / (2 * math.pi) * TURN + 0.5) % TURN
end

-- Degrees to the nearest angle unit (for turning a design number, such as the
-- width of a cleave, into a sim angle).
function Angle.fromDegrees(degrees: number): number
	return math.floor(degrees / 360 * TURN + 0.5)
end

-- Angle units to radians (for drawing only, never for the simulation).
function Angle.toRadians(angle: number): number
	return angle / TURN * 2 * math.pi
end

return Angle
