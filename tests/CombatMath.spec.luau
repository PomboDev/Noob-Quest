local CombatMath = require("../src/features/combat/modules/CombatMath")
local Expect = require("./Expect")

return {
	["armor lowers physical damage, never to nothing"] = function()
		Expect.equal(CombatMath.finalDamage(100, 0, "physical", false), 100)
		Expect.equal(CombatMath.finalDamage(100, 100, "physical", false), 50)
		Expect.equal(CombatMath.finalDamage(100, 900, "physical", false), 10)
		Expect.equal(CombatMath.finalDamage(1, 10000, "physical", false), 1, "a hit does at least 1")
	end,

	["true damage ignores armor"] = function()
		Expect.equal(CombatMath.finalDamage(40, 500, "true", false), 40)
	end,

	["negative armor doesn't amplify damage"] = function()
		Expect.equal(CombatMath.finalDamage(100, -50, "physical", false), 100)
	end,

	["crits multiply before armor and round once"] = function()
		Expect.equal(CombatMath.finalDamage(30, 100, "physical", true), 30)
		Expect.equal(CombatMath.finalDamage(10, 0, "true", true), 20)
		Expect.equal(CombatMath.finalDamage(7, 50, "physical", false), 5)
	end,

	["isCrit compares the roll with the chance"] = function()
		Expect.equal(CombatMath.isCrit(0.25, 0), true)
		Expect.equal(CombatMath.isCrit(0.25, 0.249), true)
		Expect.equal(CombatMath.isCrit(0.25, 0.25), false)
		Expect.equal(CombatMath.isCrit(0, 0), false, "no chance never crits")
		Expect.equal(CombatMath.isCrit(1, 0.999), true, "full chance always crits")
	end,

	["scale grows linearly from level 1"] = function()
		Expect.equal(CombatMath.scale(100, 0.1, 1), 100)
		Expect.equal(CombatMath.scale(100, 0.1, 11), 200)
		Expect.equal(CombatMath.scale(100, 0.1, 0), 100, "levels below 1 count as 1")
	end,
}
