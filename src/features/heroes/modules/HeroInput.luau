--!strict

--[=[
	What a player is doing on one simulation tick: the only thing the client
	sends about its hero. The server runs movement and combat from these
	alone, and a run's log is a list of them, so every field is a whole number
	with a fixed range and any 6 bytes decode to a valid input.

	Wire layout (SIZE bytes, little endian):
		byte 0     flags: bit 0 moving, 1 attack, 2 unused (ignored), 3 auto-target,
		           bits 4-5 the ability pressed this tick (0 none, 1 to 3)
		byte 1     move direction in 1/256 turns (0 when not moving)
		bytes 2-3  aim direction in 1/65536 turns (see core/Angle)
		bytes 4-5  the object being interacted with (0 none)
]=]

local Angle = require("@Core/Angle")

local HeroInput = {}

export type Input = {
	moving: boolean,
	-- 0 to 255, in 1/256 turns: the angle is moveAngle * 256 in core/Angle units.
	moveAngle: number,
	-- 0 to 65535, in core/Angle units.
	aim: number,
	attack: boolean,
	-- Held with attack, the hero stays where it is.
	auto: boolean,
	-- 0 for none, else the 1-based ability index pressed on this tick.
	ability: number,
	-- 0 for none, else the id of the world object (chest, teleporter...) used.
	interact: number,
}

HeroInput.SIZE = 6
HeroInput.MAX_ABILITY = 3
-- Angle units per move direction step.
HeroInput.MOVE_STEP = Angle.TURN // 256

function HeroInput.idle(): Input
	return {
		moving = false,
		moveAngle = 0,
		aim = 0,
		attack = false,
		auto = false,
		ability = 0,
		interact = 0,
	}
end

-- The move direction as a core/Angle angle.
function HeroInput.moveDirection(input: Input): number
	return input.moveAngle * HeroInput.MOVE_STEP
end

-- A move direction field for an angle in core/Angle units (rounded to the nearest step).
function HeroInput.quantizeMove(angle: number): number
	return math.floor(Angle.wrap(angle) / HeroInput.MOVE_STEP + 0.5) % 256
end

-- Keeps every field in its range. Anything else (NaN, fractions, negatives)
-- becomes the nearest whole number inside it, so a hand-made input is valid.
local function whole(value: any, modulo: number): number
	if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then
		return 0
	end
	return math.floor(value) % modulo
end

-- Ability numbers above the last one are not wrapped round: they press nothing new.
local function clampAbility(value: any): number
	if type(value) ~= "number" or value ~= value then
		return 0
	end
	return math.clamp(math.floor(value), 0, HeroInput.MAX_ABILITY)
end

function HeroInput.normalize(input: Input): Input
	local moving = input.moving == true
	return {
		moving = moving,
		moveAngle = if moving then whole(input.moveAngle, 256) else 0,
		aim = whole(input.aim, 65536),
		attack = input.attack == true,
		auto = input.auto == true,
		ability = clampAbility(input.ability),
		interact = whole(input.interact, 65536),
	}
end

function HeroInput.equal(a: Input, b: Input): boolean
	return a.moving == b.moving
		and a.moveAngle == b.moveAngle
		and a.aim == b.aim
		and a.attack == b.attack
		and a.auto == b.auto
		and a.ability == b.ability
		and a.interact == b.interact
end

function HeroInput.write(output: buffer, offset: number, input: Input)
	local clean = HeroInput.normalize(input)
	local flags = (if clean.moving then 1 else 0)
		+ (if clean.attack then 2 else 0)
		+ (if clean.auto then 8 else 0)
		+ clean.ability * 16
	buffer.writeu8(output, offset, flags)
	buffer.writeu8(output, offset + 1, clean.moveAngle)
	buffer.writeu16(output, offset + 2, clean.aim)
	buffer.writeu16(output, offset + 4, clean.interact)
end

-- The input at `offset`, or nil if the buffer is too short to hold one.
function HeroInput.read(source: buffer, offset: number): Input?
	if offset < 0 or offset + HeroInput.SIZE > buffer.len(source) then
		return nil
	end

	local flags = buffer.readu8(source, offset)
	local moving = bit32.band(flags, 1) ~= 0
	return {
		moving = moving,
		moveAngle = if moving then buffer.readu8(source, offset + 1) else 0,
		aim = buffer.readu16(source, offset + 2),
		attack = bit32.band(flags, 2) ~= 0,
		auto = bit32.band(flags, 8) ~= 0,
		ability = math.min(bit32.band(bit32.rshift(flags, 4), 3), HeroInput.MAX_ABILITY),
		interact = buffer.readu16(source, offset + 4),
	}
end

return HeroInput
