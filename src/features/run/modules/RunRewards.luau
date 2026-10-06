--!strict

--[=[
	What a run pays out, worked out when it ends. Nothing a player picked up is
	lost: defeat pays what was earned, victory adds a bonus.
]=]

local RunRewards = {}

export type Result = {
	coins: number,
	xp: number,
}

local XP_PER_POINT = 5
local VICTORY_XP = 100
local MAX_LEVEL = 100

-- `points` is the reward of every enemy killed, `pickedUpCoins` what chests gave.
function RunRewards.compute(points: number, pickedUpCoins: number, victory: boolean): Result
	return {
		coins = math.floor(math.max(0, pickedUpCoins) + math.max(0, points)),
		xp = math.floor(math.max(0, points) * XP_PER_POINT + (if victory then VICTORY_XP else 0)),
	}
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
