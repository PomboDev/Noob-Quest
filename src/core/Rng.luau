--!strict

--[=[
	Seeded pseudo-random numbers that give the same sequence on every
	platform, so the server and clients can generate the same thing from the
	same seed (`Random` and `math.random` make no such promise).

	xorshift32 over `bit32`: only integer operations, no floats until the
	final divide by 2^32, which is exact. Not for anything security related.
]=]

local TWO_32 = 4294967296

export type Rng = { state: number }

local Rng = {}

local function step(x: number): number
	x = bit32.bxor(x, bit32.lshift(x, 13))
	x = bit32.bxor(x, bit32.rshift(x, 17))
	return bit32.bxor(x, bit32.lshift(x, 5))
end

function Rng.new(seed: number): Rng
	local x = bit32.bxor(math.floor(seed) % TWO_32, 0x9E3779B9)
	if x == 0 then
		x = 1
	end
	-- Spread nearby seeds apart before the first value is used.
	for _ = 1, 4 do
		x = step(x)
	end
	return { state = x }
end

-- A float in [0, 1).
function Rng.next(rng: Rng): number
	rng.state = step(rng.state)
	return rng.state / TWO_32
end

-- An integer in [min, max], both included.
function Rng.int(rng: Rng, min: number, max: number): number
	return min + math.floor(Rng.next(rng) * (max - min + 1))
end

-- An index into `weights`, chosen in proportion to its weight. Zero weights
-- are never chosen. Errors if no weight is positive.
function Rng.weighted(rng: Rng, weights: { number }): number
	local total = 0
	for _, weight in weights do
		total += weight
	end
	assert(total > 0, "Rng.weighted needs a positive weight")

	local roll = Rng.next(rng) * total
	local last = 0
	local accumulated = 0
	for index, weight in weights do
		if weight > 0 then
			last = index
			accumulated += weight
			if roll < accumulated then
				return index
			end
		end
	end
	return last
end

-- A new seed from a seed and a salt (an attempt number, an act index, ...).
-- Products stay under 2^53, so the arithmetic is exact.
function Rng.derive(seed: number, salt: number): number
	local mixed = (math.floor(seed) % TWO_32 * 1664525 + 1013904223) % TWO_32
	mixed = (bit32.bxor(mixed, math.floor(salt) % TWO_32) * 1664525 + 1013904223) % TWO_32
	return step(mixed)
end

return Rng
