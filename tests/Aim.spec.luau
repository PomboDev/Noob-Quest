local Aim = require("../src/features/heroes/modules/Aim")
local Expect = require("./Expect")

local function near(actual: number?, expected: number, label: string?)
	if actual == nil or math.abs(actual - expected) > 1e-6 then
		error(`{label or "value"}: expected {expected}, got {tostring(actual)}`, 2)
	end
end

return {
	["groundPoint intersects a ray with the plane"] = function()
		-- From 10 up and 10 back, looking down at 45°: lands 10 forward.
		local x, z = Aim.groundPoint(0, 10, 10, 0, -1, -1, 0)
		near(x, 0)
		near(z, 0)
		local x2, z2 = Aim.groundPoint(5, 10, 0, 1, -2, 0, 4)
		near(x2, 8)
		near(z2, 0)
	end,

	["groundPoint is nil when the ray never reaches the plane"] = function()
		local x, z = Aim.groundPoint(0, 10, 0, 0, 1, 0, 0)
		Expect.equal(x, nil, "pointing away from the plane")
		Expect.equal(z, nil)
		Expect.equal((Aim.groundPoint(0, 10, 0, 1, 0, 0, 0)), nil, "level ray")
		Expect.equal((Aim.groundPoint(0, 10, 0, 0, 0 / 0, 0, 0)), nil, "NaN direction")
		Expect.equal((Aim.groundPoint(0, 10, 0, 1, -1e-300, 0, 0)), nil, "hits infinitely far away")
	end,

	["angleTo points the way Targeting does"] = function()
		near(Aim.angleTo(0, 0, 0, 5), 0, "+Z is angle 0")
		near(Aim.angleTo(0, 0, 5, 0), math.pi / 2, "+X is a quarter turn")
		near(Aim.angleTo(1, 1, 1, -4), math.pi, "-Z is half a turn")
		Expect.equal(Aim.angleTo(3, 3, 3, 3), nil, "no direction on the spot")
	end,

	["resolve snaps to an enemy near the cursor"] = function()
		local enemies = { { id = 4, x = 10, z = 0 }, { id = 9, x = 0, z = 20 } }
		local snapped = Aim.resolve(enemies, 0, 0, 9, 2, 3)
		Expect.equal(snapped and snapped.targetId, 4)
		near(snapped and snapped.angle, math.pi / 2, "aims at the enemy, not the cursor")
	end,

	["resolve aims at the cursor when nothing is close"] = function()
		local enemies = { { id = 4, x = 10, z = 0 } }
		local aimed = Aim.resolve(enemies, 0, 0, 0, 6, 3)
		Expect.equal(aimed and aimed.targetId, nil)
		near(aimed and aimed.angle, 0)
	end,

	["resolve has no aim on the hero's own spot"] = function()
		Expect.equal(Aim.resolve({}, 2, 2, 2, 2, 3), nil)
		-- An enemy exactly under the hero can't be aimed at either; the cursor decides.
		local result = Aim.resolve({ { id = 1, x = 2, z = 2 } }, 2, 2, 2, 5, 4)
		Expect.equal(result and result.targetId, nil)
		near(result and result.angle, 0)
	end,
}
