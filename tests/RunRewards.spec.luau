local Expect = require("./Expect")
local RunRewards = require("../src/features/run/modules/RunRewards")

return {
	["victory pays a bonus, defeat pays what was earned"] = function()
		local defeat = RunRewards.compute(40, 25, false)
		Expect.equal(defeat.coins, 65)
		Expect.equal(defeat.xp, 200)

		local victory = RunRewards.compute(40, 25, true)
		Expect.equal(victory.coins, 65, "coins don't depend on winning")
		Expect.equal(victory.xp, 300)
	end,

	["nothing earned pays nothing, bad input pays nothing"] = function()
		Expect.deepEqual(RunRewards.compute(0, 0, false), { coins = 0, xp = 0 })
		Expect.deepEqual(RunRewards.compute(-5, -5, false), { coins = 0, xp = 0 })
	end,

	["xp rolls over into levels"] = function()
		local level, xp = RunRewards.addXp(1, 0, 50)
		Expect.equal(level, 1)
		Expect.equal(xp, 50)

		level, xp = RunRewards.addXp(1, 50, 60)
		Expect.equal(level, 2, "100 needed at level 1")
		Expect.equal(xp, 10)

		-- 100 for level 1, 200 for level 2, 300 for level 3 = 600 to reach level 4.
		level, xp = RunRewards.addXp(1, 0, 650)
		Expect.equal(level, 4)
		Expect.equal(xp, 50)
	end,

	["xp that exactly fills a level starts the next one"] = function()
		local level, xp = RunRewards.addXp(2, 0, 200)
		Expect.equal(level, 3)
		Expect.equal(xp, 0)
	end,

	["the level stops at the maximum"] = function()
		local level, xp = RunRewards.addXp(99, 0, 1e9)
		Expect.equal(level, 100)
		Expect.equal(xp, 0)
		level, xp = RunRewards.addXp(100, 0, 500)
		Expect.equal(level, 100)
		Expect.equal(xp, 0)
	end,

	["losing xp or levels is impossible"] = function()
		local level, xp = RunRewards.addXp(5, 30, -1000)
		Expect.equal(level, 5)
		Expect.equal(xp, 30)
	end,
}
