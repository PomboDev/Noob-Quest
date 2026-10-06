local Angle = require("../src/core/Angle")
local Expect = require("./Expect")
local Rng = require("../src/core/Rng")
local SimClock = require("../src/features/sim/modules/SimClock")
local TrigTables = require("../src/core/TrigTables")

local function within(actual: number, expected: number, tolerance: number, label: string?)
	if math.abs(actual - expected) > tolerance then
		error(`{label or "value"}: expected {expected} ± {tolerance}, got {actual}`, 2)
	end
end

return {
	["the tables still match the platform's sin and atan"] = function()
		-- If this fails, run `pesde run gentrig`.
		local perRadian = 65536 / (2 * math.pi)
		for index = 0, 1024 do
			within(TrigTables.SINE[index + 1], math.sin(index / 1024 * math.pi / 2), 1e-15, `sine {index}`)
			within(TrigTables.ATAN[index + 1], math.atan(index / 1024) * perRadian, 1e-9, `atan {index}`)
		end
	end,

	["sin and cos are exact at the quarter turns"] = function()
		Expect.equal(Angle.sin(0), 0)
		Expect.equal(Angle.sin(Angle.QUARTER), 1)
		Expect.equal(Angle.sin(Angle.HALF), 0)
		Expect.equal(Angle.sin(Angle.HALF + Angle.QUARTER), -1)
		Expect.equal(Angle.cos(0), 1)
		Expect.equal(Angle.cos(Angle.QUARTER), 0)
		Expect.equal(Angle.cos(Angle.HALF), -1)
		Expect.equal(Angle.cos(Angle.HALF + Angle.QUARTER), 0)
		-- No negative zero: it would print differently in a log.
		Expect.equal(tostring(Angle.sin(Angle.HALF)), "0")
	end,

	["sin and cos stay within 1e-6 of the platform's"] = function()
		for angle = 0, 65535, 7 do
			local radians = Angle.toRadians(angle)
			within(Angle.sin(angle), math.sin(radians), 1e-6, `sin {angle}`)
			within(Angle.cos(angle), math.cos(radians), 1e-6, `cos {angle}`)
		end
	end,

	["angles wrap"] = function()
		Expect.equal(Angle.wrap(65536), 0)
		Expect.equal(Angle.wrap(-1), 65535)
		Expect.equal(Angle.sin(100 + 65536 * 3), Angle.sin(100))
		Expect.equal(Angle.sin(-100), Angle.sin(65436))
	end,

	["angle 0 faces +Z and a quarter turn faces +X, like Targeting"] = function()
		local x, z = Angle.direction(0)
		Expect.equal(x, 0)
		Expect.equal(z, 1)
		x, z = Angle.direction(Angle.QUARTER)
		Expect.equal(x, 1)
		Expect.equal(z, 0)
	end,

	["atan2 finds the angle of a direction"] = function()
		Expect.equal(Angle.atan2(0, 1), 0)
		Expect.equal(Angle.atan2(1, 0), Angle.QUARTER)
		Expect.equal(Angle.atan2(0, -1), Angle.HALF)
		Expect.equal(Angle.atan2(-1, 0), Angle.HALF + Angle.QUARTER)
		Expect.equal(Angle.atan2(1, 1), 8192)
		Expect.equal(Angle.atan2(-1, 1), 65536 - 8192)
		Expect.equal(Angle.atan2(0, 0), 0)
		Expect.equal(Angle.atan2(3, 3), Angle.atan2(1, 1), "scale doesn't matter")
	end,

	["atan2 undoes sin and cos to within one unit"] = function()
		for angle = 0, 65535, 11 do
			local back = Angle.atan2(Angle.sin(angle), Angle.cos(angle))
			local difference = math.abs(back - angle)
			Expect.equal(math.min(difference, 65536 - difference) <= 1, true, `angle {angle} came back as {back}`)
		end
	end,

	["atan2 stays within one unit of the platform's"] = function()
		local rng = Rng.new(99)
		for _ = 1, 500 do
			local dx, dz = (Rng.next(rng) - 0.5) * 200, (Rng.next(rng) - 0.5) * 200
			local expected = Angle.fromRadians(math.atan2(dx, dz))
			local difference = math.abs(Angle.atan2(dx, dz) - expected)
			Expect.equal(math.min(difference, 65536 - difference) <= 1, true, `({dx}, {dz})`)
		end
	end,

	["between is nil for the same point"] = function()
		Expect.equal(Angle.between(5, 5, 5, 5), nil)
		Expect.equal(Angle.between(0, 0, 0, 9), 0)
		Expect.equal(Angle.between(10, 10, 20, 10), Angle.QUARTER)
	end,

	-- Pinned: if these change, an old run log no longer replays.
	["gives the same values on every platform"] = function()
		Expect.equal(
			string.format("%.17g %.17g %d", Angle.sin(1000), Angle.cos(12345), Angle.atan2(123.5, -77.25)),
			"0.095726963342445792 0.37762881097557022 22214"
		)
	end,

	-- The same sweep was run inside Roblox Studio and gave exactly this number.
	["a sweep over every angle gives the same checksum on every platform"] = function()
		local sum = 0
		for angle = 0, 65535, 3 do
			sum += Angle.sin(angle) * 1.5 + Angle.cos(angle) * 0.25 + Angle.atan2(Angle.sin(angle), Angle.cos(angle))
		end
		Expect.equal(string.format("%.17g", sum), "715838805.16662061")
	end,

	["fromDegrees gives the nearest whole unit"] = function()
		Expect.equal(Angle.fromDegrees(0), 0)
		Expect.equal(Angle.fromDegrees(90), Angle.QUARTER)
		Expect.equal(Angle.fromDegrees(180), Angle.HALF)
		Expect.equal(Angle.fromDegrees(360), Angle.TURN)
		Expect.equal(Angle.fromDegrees(100), 18204)
	end,

	["the clock rounds durations up to whole ticks"] = function()
		Expect.equal(SimClock.ticks(0.2), 4)
		Expect.equal(SimClock.ticks(0.55), 11)
		Expect.equal(SimClock.ticks(1), 20)
		Expect.equal(SimClock.ticks(0), 0)
		Expect.equal(SimClock.ticks(0.001), 1)
		Expect.equal(SimClock.ticks(-1), 0)
	end,
}
