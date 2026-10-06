--!strict

--[=[
	Damage maths on plain numbers, so Lune can test it. Randomness is passed
	in (`roll`), so the same input always gives the same result.
]=]

local CombatMath = {}

export type DamageKind = "physical" | "true"

-- A critical hit deals this many times the damage.
CombatMath.CRIT_MULTIPLIER = 2

-- What's left of a hit after armor: each point is worth less than the last,
-- so armor never makes anything immune. 100 armor halves a hit.
function CombatMath.mitigation(armor: number): number
	return 100 / (100 + math.max(0, armor))
end

-- `roll` is a number in [0, 1). `chance` is the crit chance in [0, 1].
function CombatMath.isCrit(chance: number, roll: number): boolean
	return roll < chance
end

-- The damage a hit does, rounded and at least 1 (a hit never does nothing).
-- "true" damage ignores armor.
function CombatMath.finalDamage(amount: number, armor: number, kind: DamageKind, crit: boolean): number
	local damage = amount
	if crit then
		damage *= CombatMath.CRIT_MULTIPLIER
	end
	if kind == "physical" then
		damage *= CombatMath.mitigation(armor)
	end
	return math.max(1, math.floor(damage + 0.5))
end

-- A stat that grows by `perLevel` (0.1 is +10%) of its base for each level
-- after the first.
function CombatMath.scale(base: number, perLevel: number, level: number): number
	return base * (1 + perLevel * (math.max(1, level) - 1))
end

return CombatMath
