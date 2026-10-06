local Expect = require("./Expect")
local Rng = require("../src/core/Rng")

return {
	-- Pinned values: if these change, every generated map changes with them,
	-- and the server and clients stop agreeing across versions.
	["gives the same values on every platform"] = function()
		local rng = Rng.new(12345)
		Expect.equal(Rng.next(rng) * 4294967296, 3438003404)
		Expect.equal(Rng.next(rng) * 4294967296, 976339029)
		Expect.equal(Rng.next(rng) * 4294967296, 1163348040)

		Expect.equal(Rng.derive(12345, 7), 2982614267)
		Expect.equal(Rng.derive(0, 0), 213862697)
		Expect.equal(Rng.derive(4294967295, 4294967295), 454212796)
	end,

	["repeats a seed and separates different seeds"] = function()
		local a, b, c = Rng.new(7), Rng.new(7), Rng.new(8)
		local different = false
		for _ = 1, 20 do
			local value = Rng.next(a)
			Expect.equal(Rng.next(b), value)
			if Rng.next(c) ~= value then
				different = true
			end
		end
		Expect.equal(different, true, "seeds 7 and 8 differ")
	end,

	["accepts seed 0 and large or negative seeds"] = function()
		for _, seed in { 0, 1, 4294967295, 4294967296 * 3 + 5, -1, 2 ^ 40 } do
			local rng = Rng.new(seed)
			local first = Rng.next(rng)
			Expect.equal(first >= 0 and first < 1, true, `seed {seed}`)
			Expect.equal(Rng.next(rng) ~= first, true, `seed {seed} moves on`)
		end
	end,

	["next stays in [0, 1)"] = function()
		local rng = Rng.new(99)
		for _ = 1, 5000 do
			local value = Rng.next(rng)
			Expect.equal(value >= 0 and value < 1, true)
		end
	end,

	["int covers its whole inclusive range"] = function()
		local rng = Rng.new(3)
		local seen: { [number]: boolean } = {}
		for _ = 1, 500 do
			local value = Rng.int(rng, -2, 2)
			Expect.equal(value, math.floor(value), "an integer")
			Expect.equal(value >= -2 and value <= 2, true, `{value} in range`)
			seen[value] = true
		end
		for value = -2, 2 do
			Expect.equal(seen[value], true, `saw {value}`)
		end
		Expect.equal(Rng.int(rng, 5, 5), 5)
	end,

	["weighted follows the weights and skips zeros"] = function()
		local rng = Rng.new(11)
		local counts = { 0, 0, 0 }
		for _ = 1, 4000 do
			local index = Rng.weighted(rng, { 1, 0, 3 })
			counts[index] += 1
		end
		Expect.equal(counts[2], 0, "zero weight is never chosen")
		local ratio = counts[3] / counts[1]
		Expect.equal(ratio > 2.5 and ratio < 3.5, true, `ratio {ratio} is near 3`)
	end,

	["weighted needs a positive weight"] = function()
		Expect.errors(function()
			Rng.weighted(Rng.new(1), { 0, 0 })
		end, "positive weight")
	end,

	["derive depends on both seed and salt"] = function()
		Expect.equal(Rng.derive(5, 1), Rng.derive(5, 1))
		Expect.equal(Rng.derive(5, 1) ~= Rng.derive(5, 2), true, "salt")
		Expect.equal(Rng.derive(5, 1) ~= Rng.derive(6, 1), true, "seed")
		local value = Rng.derive(2 ^ 32 - 1, 2 ^ 32 - 1)
		Expect.equal(value >= 0 and value < 2 ^ 32, true, "stays a uint32")
	end,
}
