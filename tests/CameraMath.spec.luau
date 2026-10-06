local CameraMath = require("../src/features/camera/modules/CameraMath")
local Expect = require("./Expect")

local function near(actual: number, expected: number, label: string?)
	if math.abs(actual - expected) > 1e-9 then
		error(`{label or "value"}: expected {expected}, got {actual}`, 2)
	end
end

return {
	["offset is the given distance away"] = function()
		local x, y, z = CameraMath.offset(57, 30, 50)
		near(math.sqrt(x * x + y * y + z * z), 50)
	end,

	["offset height follows the pitch"] = function()
		local _, y = CameraMath.offset(57, 0, 50)
		near(y, 50 * math.sin(math.rad(57)))
		local _, top = CameraMath.offset(90, 0, 50)
		near(top, 50, "straight down is straight above")
		local _, flat = CameraMath.offset(0, 0, 50)
		near(flat, 0, "horizon is level")
	end,

	["yaw turns the camera around the focus"] = function()
		local x0, _, z0 = CameraMath.offset(0, 0, 10)
		near(x0, 0)
		near(z0, 10, "yaw 0 is +Z")
		local x90, _, z90 = CameraMath.offset(0, 90, 10)
		near(x90, 10, "yaw 90 is +X")
		near(z90, 0)
	end,

	["looking straight down has no horizontal offset"] = function()
		local x, _, z = CameraMath.offset(90, 45, 50)
		near(x, 0)
		near(z, 0)
	end,

	["smoothAlpha stays between 0 and 1"] = function()
		Expect.equal(CameraMath.smoothAlpha(0, 12), 0)
		Expect.equal(CameraMath.smoothAlpha(-1, 12), 0)
		local alpha = CameraMath.smoothAlpha(1 / 60, 12)
		Expect.equal(alpha > 0 and alpha < 1, true, "alpha in (0, 1)")
		Expect.equal(CameraMath.smoothAlpha(10, 12) > 0.999, true, "a long frame arrives")
	end,

	["smoothAlpha doesn't depend on the frame rate"] = function()
		local single = CameraMath.smoothAlpha(1 / 30, 12)
		local half = CameraMath.smoothAlpha(1 / 60, 12)
		-- Two half frames leave (1 - half)^2 of the distance, like one whole frame.
		near(1 - (1 - half) * (1 - half), single)
	end,
}
