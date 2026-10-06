--!strict

--[=[
	A running hash of a simulation's state, to compare two runs tick by tick.
	Numbers go in as their exact 64-bit float bits, so two states that differ
	in the last bit hash differently, and the arithmetic stays below 2^53 (a
	32-bit word times a 21-bit multiplier), so it is exact on every platform.
	Not for anything security related.
]=]

local TWO_32 = 4294967296
local MULTIPLIER = 1664525
local INCREMENT = 1013904223

export type Hash = { value: number, scratch: buffer }

local Checksum = {}

function Checksum.new(): Hash
	return { value = 2166136261, scratch = buffer.create(8) }
end

local function word(hash: Hash, input: number)
	local mixed = (bit32.bxor(hash.value, input) * MULTIPLIER + INCREMENT) % TWO_32
	hash.value = bit32.bxor(mixed, bit32.rshift(mixed, 15))
end

-- Any number: integers and floats alike, by their bits (-0 counts as 0).
function Checksum.number(hash: Hash, value: number)
	buffer.writef64(hash.scratch, 0, value + 0)
	word(hash, buffer.readu32(hash.scratch, 0))
	word(hash, buffer.readu32(hash.scratch, 4))
end

function Checksum.bool(hash: Hash, value: boolean)
	word(hash, if value then 1 else 0)
end

function Checksum.string(hash: Hash, value: string)
	word(hash, #value)
	for index = 1, #value do
		word(hash, string.byte(value, index))
	end
end

-- Marks the start of a section, so an empty list isn't the same as a missing one.
function Checksum.section(hash: Hash, name: string)
	Checksum.string(hash, name)
end

function Checksum.result(hash: Hash): number
	return hash.value
end

return Checksum
