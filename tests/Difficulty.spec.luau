local Difficulty = require("../src/features/run/modules/Difficulty")
local Expect = require("./Expect")

local function near(actual: number, expected: number, label: string?)
	if math.abs(actual - expected) > 1e-9 then
		error(`{label or "value"}: expected {expected}, got {actual}`, 2)
	end
end

return {
	["a solo run starts at 1"] = function()
		near(Difficulty.coefficient(0, 1, 1), 1)
	end,

	["time raises it linearly"] = function()
		near(Difficulty.coefficient(10, 1, 1), 1 + Difficulty.PER_MINUTE * 10)
		Expect.equal(Difficulty.coefficient(5, 1, 1) < Difficulty.coefficient(6, 1, 1), true)
	end,

	["more players make time count more"] = function()
		local solo = Difficulty.coefficient(10, 1, 1)
		local duo = Difficulty.coefficient(10, 1, 2)
		local four = Difficulty.coefficient(10, 1, 4)
		Expect.equal(solo < duo and duo < four, true)
		near(Difficulty.coefficient(0, 1, 4), 1, "no time, no difference")
		near(Difficulty.partyFactor(0), 1, "a party is at least one")
	end,

	["each act multiplies it by 1.15"] = function()
		near(Difficulty.coefficient(0, 2, 1), 1.15)
		near(Difficulty.coefficient(0, 3, 1), 1.15 ^ 2)
		near(Difficulty.coefficient(10, 2, 1), Difficulty.coefficient(10, 1, 1) * 1.15)
	end,

	["negative time and acts below 1 are treated as the start"] = function()
		near(Difficulty.coefficient(-5, 0, 1), 1)
	end,

	["damage scales slower than health"] = function()
		near(Difficulty.hpScale(3), 3)
		near(Difficulty.damageScale(3), 2)
		near(Difficulty.damageScale(1), 1)
	end,
}
