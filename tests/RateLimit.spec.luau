local Expect = require("./Expect")
local RateLimit = require("../src/core/RateLimit")

-- A limiter on a clock the test moves by hand.
local function newLimiter(burst: number, perSecond: number): (RateLimit.Limiter, (seconds: number) -> ())
	local now = 0
	local limiter = RateLimit.new({
		burst = burst,
		perSecond = perSecond,
		clock = function()
			return now
		end,
	})
	return limiter, function(seconds: number)
		now += seconds
	end
end

local function count(buckets: { [any]: any }): number
	local total = 0
	for _ in buckets do
		total += 1
	end
	return total
end

return {
	["allows a burst, then refuses"] = function()
		local limiter = newLimiter(3, 1)
		for i = 1, 3 do
			Expect.equal(RateLimit.take(limiter, "a"), true, `request {i}`)
		end
		Expect.equal(RateLimit.take(limiter, "a"), false)
	end,

	["refills over time, up to the burst"] = function()
		local limiter, advance = newLimiter(2, 0.5)
		RateLimit.take(limiter, "a")
		RateLimit.take(limiter, "a")

		advance(1.9)
		Expect.equal(RateLimit.take(limiter, "a"), false, "before a token refills")
		advance(0.1)
		Expect.equal(RateLimit.take(limiter, "a"), true, "after one token")
		Expect.equal(RateLimit.take(limiter, "a"), false, "only one token")

		advance(100)
		Expect.equal(RateLimit.take(limiter, "a"), true)
		Expect.equal(RateLimit.take(limiter, "a"), true)
		Expect.equal(RateLimit.take(limiter, "a"), false, "capped at the burst")
	end,

	["works as a cooldown"] = function()
		local limiter, advance = newLimiter(1, 1 / 2)
		Expect.equal(RateLimit.take(limiter, "a"), true)
		advance(1.5)
		Expect.equal(RateLimit.take(limiter, "a"), false)
		advance(0.5)
		Expect.equal(RateLimit.take(limiter, "a"), true)
	end,

	["keys are independent"] = function()
		local limiter = newLimiter(1, 1)
		Expect.equal(RateLimit.take(limiter, "a"), true)
		Expect.equal(RateLimit.take(limiter, "a"), false)
		Expect.equal(RateLimit.take(limiter, "b"), true)
	end,

	["cost takes several tokens, or none"] = function()
		local limiter = newLimiter(5, 1)
		Expect.equal(RateLimit.take(limiter, "a", 4), true)
		Expect.equal(RateLimit.take(limiter, "a", 2), false, "only one token left")
		Expect.equal(RateLimit.take(limiter, "a"), true, "a refused request takes nothing")
		Expect.equal(RateLimit.take(limiter, "b", 6), false, "more than the burst")
	end,

	["drops buckets that have refilled"] = function()
		local limiter, advance = newLimiter(2, 1)
		RateLimit.take(limiter, "a")
		RateLimit.take(limiter, "b")
		RateLimit.take(limiter, "b")
		RateLimit.take(limiter, "b")
		Expect.equal(count(limiter.buckets), 2)

		-- Only "a" has refilled when the first pass runs (10 s minimum).
		advance(9.5)
		RateLimit.take(limiter, "b")
		advance(0.5)
		RateLimit.take(limiter, "c")
		Expect.equal(limiter.buckets.a, nil, "full bucket dropped")
		Expect.equal(count(limiter.buckets), 2, "b and c kept")
	end,

	["rejects bad options"] = function()
		Expect.errors(function()
			RateLimit.new({ burst = 0, perSecond = 1 })
		end, "burst")
		Expect.errors(function()
			RateLimit.new({ burst = 1, perSecond = 0 / 0 })
		end, "perSecond")
		Expect.errors(function()
			RateLimit.new({ burst = math.huge, perSecond = 1 })
		end, "burst")
	end,
}
