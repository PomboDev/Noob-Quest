--!strict

--[=[
	Levels, and what finishing a run pays. Coins and XP are saved as they are
	picked up (see LootServiceServer), so the end of a run only adds a bonus
	for winning.
]=]

local RunRewards = {}

export type Result = {
	coins: number,
	xp: number,
}

local VICTORY_COINS = 50
local VICTORY_XP = 100
local MAX_LEVEL = 100

-- What beating the last act adds on top of everything picked up on the way.
function RunRewards.victoryBonus(): Result
	return { coins = VICTORY_COINS, xp = VICTORY_XP }
end

-- XP needed to get from `level` to the next one.
function RunRewards.xpToNext(level: number): number
	return 100 * math.max(1, level)
end

-- Adds XP to a level and its progress, rolling over into as many levels as it pays for.
function RunRewards.addXp(level: number, xp: number, gained: number): (number, number)
	local newLevel, newXp = math.max(1, level), math.max(0, xp) + math.max(0, gained)
	while newLevel < MAX_LEVEL and newXp >= RunRewards.xpToNext(newLevel) do
		newXp -= RunRewards.xpToNext(newLevel)
		newLevel += 1
	end
	if newLevel >= MAX_LEVEL then
		newXp = 0
	end
	return newLevel, newXp
end

return RunRewards
