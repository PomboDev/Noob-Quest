--!strict

--[=[
	How hard a run is at a given moment, in the style of Risk of Rain: it
	creeps up with the clock, faster with more players, and steps up with every
	act.

		coefficient = (1 + K * minutes * partyFactor) * 1.15 ^ (act - 1)

	It scales enemy HP and damage, and how fast the wave director earns credits.
]=]

local Difficulty = {}

-- Added to the coefficient every minute of a solo run.
Difficulty.PER_MINUTE = 0.12
-- Each act is this much harder than the one before.
Difficulty.PER_ACT = 1.15
-- Each extra player makes time count this much more.
Difficulty.PER_EXTRA_PLAYER = 0.5

function Difficulty.partyFactor(partySize: number): number
	return 1 + Difficulty.PER_EXTRA_PLAYER * (math.max(1, partySize) - 1)
end

-- `base ^ count` by repeated multiplication: `^` goes through the platform's
-- libm, which may round differently from one machine to the next, and the
-- coefficient feeds the simulation.
local function power(base: number, count: number): number
	local result = 1
	for _ = 1, math.floor(count) do
		result *= base
	end
	return result
end

function Difficulty.coefficient(minutes: number, actIndex: number, partySize: number): number
	local time = 1 + Difficulty.PER_MINUTE * math.max(0, minutes) * Difficulty.partyFactor(partySize)
	return time * power(Difficulty.PER_ACT, math.max(1, actIndex) - 1)
end

-- Enemy HP grows with the full coefficient.
function Difficulty.hpScale(coefficient: number): number
	return coefficient
end

-- Damage grows at half the pace, so a long run stays survivable.
function Difficulty.damageScale(coefficient: number): number
	return 1 + (coefficient - 1) * 0.5
end

return Difficulty
