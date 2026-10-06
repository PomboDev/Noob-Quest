--!strict

--[=[
	What dying in a run costs, in the style of Diablo: a share of the coins the
	player carries and of the XP they have towards the next level. The level
	itself is never lost (the XP is progress within the level), so a death
	stings without undoing hours of play.

	Pure: the run feature applies the loss to the player's data.
]=]

local DeathPenalty = {}

export type Loss = {
	coins: number,
	xp: number,
}

-- Shares of what the player has, 0 to 1.
DeathPenalty.COIN_SHARE = 0.2
DeathPenalty.XP_SHARE = 0.2

-- What `coins` carried and `xp` of progress lose to a death. Never more than
-- the player has, and nothing for nothing.
function DeathPenalty.compute(coins: number, xp: number): Loss
	local carried, progress = math.max(0, coins), math.max(0, xp)
	return {
		coins = math.min(carried, math.floor(carried * DeathPenalty.COIN_SHARE)),
		xp = math.min(progress, math.floor(progress * DeathPenalty.XP_SHARE)),
	}
end

return DeathPenalty
