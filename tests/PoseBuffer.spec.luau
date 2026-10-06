local Expect = require("./Expect")
local PoseBuffer = require("../src/features/heroes/modules/PoseBuffer")

local function near(actual: number?, expected: number, label: string?)
	if actual == nil or math.abs(actual - expected) > 1e-9 then
		error(`{label or "value"}: expected {expected}, got {actual}`, 2)
	end
end

return {
	["an empty buffer has no pose"] = function()
		local x, z, facing = PoseBuffer.sample(PoseBuffer.new(), 5)
		Expect.equal(x, nil)
		Expect.equal(z, nil)
		Expect.equal(facing, nil)
	end,

	["blends between the samples either side of the time"] = function()
		local buf = PoseBuffer.new()
		PoseBuffer.push(buf, 1, 0, 0, 0)
		PoseBuffer.push(buf, 2, 10, -20, 1000)
		local x, z, facing = PoseBuffer.sample(buf, 1.25)
		near(x, 2.5)
		near(z, -5)
		near(facing, 250)
	end,

	["outside the samples it holds the nearest one"] = function()
		local buf = PoseBuffer.new()
		PoseBuffer.push(buf, 1, 4, 4, 100)
		PoseBuffer.push(buf, 2, 8, 8, 200)
		near(PoseBuffer.sample(buf, 0), 4)
		near(PoseBuffer.sample(buf, 9), 8)
	end,

	["facing turns the short way round"] = function()
		local buf = PoseBuffer.new()
		PoseBuffer.push(buf, 0, 0, 0, 65000)
		PoseBuffer.push(buf, 1, 0, 0, 500)
		local _, _, facing = PoseBuffer.sample(buf, 0.5)
		-- The short way is 1036 units (65000 to 65536, then 0 to 500): halfway is 65518.
		near(facing, 65518)
	end,

	["old and repeated samples are ignored"] = function()
		local buf = PoseBuffer.new()
		PoseBuffer.push(buf, 2, 5, 5, 0)
		PoseBuffer.push(buf, 1, 99, 99, 0)
		PoseBuffer.push(buf, 2, 98, 98, 0)
		Expect.equal(#buf.samples, 1)
		near(PoseBuffer.sample(buf, 2), 5)
	end,

	["only the latest samples are kept"] = function()
		local buf = PoseBuffer.new()
		for t = 1, 30 do
			PoseBuffer.push(buf, t, t, 0, 0)
		end
		Expect.equal(#buf.samples <= 10, true)
		near(PoseBuffer.sample(buf, 30), 30)
	end,
}
