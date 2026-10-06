local DeathPenalty = require("../src/features/run/modules/DeathPenalty")
local Expect = require("./Expect")

return {
	["a death costs a share of coins and xp"] = function()
		Expect.deepEqual(DeathPenalty.compute(1000, 80), { coins = 200, xp = 16 })
	end,

	["the loss rounds down"] = function()
		Expect.deepEqual(DeathPenalty.compute(9, 9), { coins = 1, xp = 1 })
		Expect.deepEqual(DeathPenalty.compute(4, 4), { coins = 0, xp = 0 })
	end,

	["nothing to lose costs nothing"] = function()
		Expect.deepEqual(DeathPenalty.compute(0, 0), { coins = 0, xp = 0 })
	end,

	["bad input costs nothing"] = function()
		Expect.deepEqual(DeathPenalty.compute(-50, -50), { coins = 0, xp = 0 })
	end,

	["it never costs more than the player has"] = function()
		for _, coins in { 0, 1, 7, 99, 5000, 1e9 } do
			for _, xp in { 0, 3, 40, 99 } do
				local loss = DeathPenalty.compute(coins, xp)
				Expect.equal(loss.coins >= 0 and loss.coins <= coins, true, `coins {coins}`)
				Expect.equal(loss.xp >= 0 and loss.xp <= xp, true, `xp {xp}`)
			end
		end
	end,

	["the shares are real fractions"] = function()
		Expect.equal(DeathPenalty.COIN_SHARE > 0 and DeathPenalty.COIN_SHARE < 1, true)
		Expect.equal(DeathPenalty.XP_SHARE > 0 and DeathPenalty.XP_SHARE < 1, true)
	end,
}
