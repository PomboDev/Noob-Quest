local Codec = require("../src/core/Network/Codec")
local Expect = require("./Expect")
local Packet = require("../src/core/Network/Packet")

-- Encodes and decodes one message, checking the header on the way.
local function roundTrip(schema: { string }, ...: any): { any }
	local entry = Codec.encode(3, 7, schema, ...)
	local buf, inst = Codec.unpack(entry)
	assert(buf, "unpack rejected a valid entry")
	Expect.equal(buffer.readu8(buf, 0), 3, "service id")
	Expect.equal(buffer.readu8(buf, 1), 7, "method id")
	return Codec.decode(schema, buf, inst)
end

return {
	["round-trips the portable data types"] = function()
		local long = string.rep("x", 1000)
		local schema = {
			Packet.NumberU8,
			Packet.NumberU16,
			Packet.NumberU32,
			Packet.NumberS8,
			Packet.NumberS16,
			Packet.NumberS32,
			Packet.NumberF32,
			Packet.NumberF64,
			Packet.Boolean,
			Packet.Boolean,
			Packet.String,
			Packet.StringLong,
		}
		local args =
			roundTrip(schema, 255, 65535, 4294967295, -128, -32768, -2147483648, 0.5, 0.1, true, false, "hi", long)
		Expect.deepEqual(args, { 255, 65535, 4294967295, -128, -32768, -2147483648, 0.5, 0.1, true, false, "hi", long })
	end,

	["round-trips buffers"] = function()
		local args = roundTrip({ Packet.Buffer, Packet.BufferLong }, buffer.fromstring("raw"), buffer.create(4000))
		Expect.equal(buffer.tostring(args[1]), "raw")
		Expect.equal(buffer.len(args[2]), 4000)
	end,

	["integer types truncate and wrap"] = function()
		Expect.deepEqual(
			roundTrip({ Packet.NumberU8, Packet.NumberU8, Packet.NumberS8 }, 1.7, 256, 128),
			{ 1, 0, -128 }
		)
	end,

	["Any keeps every value exact"] = function()
		for _, value in
			{ 0, 255, 256, 65536, 4294967295, 4294967296, -1, -16777217, 0.1, 1.7e9 + 0.25, "text", true, false }
		do
			Expect.equal(roundTrip({ Packet.Any }, value)[1], value)
		end
		Expect.equal(roundTrip({ Packet.Any, Packet.NumberU8 }, nil, 5)[2], 5)
	end,

	["Any rejects unsupported values"] = function()
		Expect.errors(function()
			Codec.encode(1, 1, { Packet.Any }, {})
		end, "cannot send values of type 'table'")
	end,

	["enforces length limits"] = function()
		Expect.errors(function()
			Codec.encode(1, 1, { Packet.String }, string.rep("x", 256))
		end, "limited to 255 bytes")
		Expect.errors(function()
			Codec.encode(1, 1, { Packet.BufferLong }, buffer.create(65536))
		end, "limited to 65535 bytes")
	end,

	["grows past the scratch buffer"] = function()
		local long = string.rep("y", 5000)
		Expect.deepEqual(roundTrip({ Packet.StringLong, Packet.StringLong }, long, long), { long, long })
	end,

	["each message owns its buffer"] = function()
		local first = Codec.encode(1, 1, { Packet.String }, "first")
		local second = Codec.encode(1, 1, { Packet.String }, "second")
		Expect.equal(Codec.decode({ Packet.String }, first :: buffer)[1], "first")
		Expect.equal(Codec.decode({ Packet.String }, second :: buffer)[1], "second")
	end,

	["a failed encode doesn't leak into the next message"] = function()
		pcall(Codec.encode, 1, 1, { Packet.NumberU8, Packet.Instance, Packet.String }, 5, "stale", string.rep("x", 300))

		local entry = Codec.encode(1, 1, { Packet.NumberU8 }, 9)
		Expect.equal(typeof(entry), "buffer")
		Expect.equal(buffer.len(entry :: buffer), 3, "message length")
	end,

	["messages without Instances are bare buffers"] = function()
		Expect.equal(typeof(Codec.encode(1, 1, { Packet.NumberU8 }, 1)), "buffer")
	end,

	["Instance arrays stay dense and are never shared"] = function()
		-- Lune has no Instances, so tables stand in for them on the way out.
		local part = { name = "Part" }
		local first = Codec.encode(1, 1, { Packet.Instance, Packet.Instance }, nil, part) :: any
		local second = Codec.encode(1, 1, { Packet.Instance }, part) :: any

		Expect.deepEqual(first.inst, { false, part })
		assert(first.inst ~= second.inst, "messages must not share an Instance array")
	end,

	["received non-Instances read as nil"] = function()
		local buf = Codec.encode(1, 1, { Packet.NumberU8 }, 0) :: buffer
		local header = buffer.create(2)
		buffer.copy(header, 0, buf, 0, 2)

		local args = Codec.decode(
			{ Packet.Instance, Packet.Instance, Packet.Instance },
			header,
			{ false, "spoofed", 42 }
		)
		Expect.deepEqual(args, {})
	end,

	["unpack rejects malformed entries"] = function()
		Expect.equal(Codec.unpack(nil), nil)
		for _, garbage in { 5, "text", buffer.create(1), {}, { buf = "x" }, { buf = buffer.create(2), inst = 5 } } do
			Expect.equal(Codec.unpack(garbage), nil)
		end
	end,

	["decode errors on truncated or corrupt input"] = function()
		Expect.errors(function()
			Codec.decode({ Packet.NumberU32 }, buffer.create(4))
		end)
		Expect.errors(function()
			Codec.decode({ Packet.Any }, buffer.fromstring("\1\1\200"))
		end, "unknown type tag")
	end,

	["validateSchema rejects unknown data types"] = function()
		Expect.errors(function()
			Codec.validateSchema({ "Nope" }, "Test.method")
		end, "unknown data type 'Nope'")
	end,

	["chunk keeps unreliable batches within budget"] = function()
		local batch = {}
		for _ = 1, 40 do
			table.insert(batch, buffer.create(100))
		end

		local total = 0
		for _, chunk in Codec.chunk(batch) do
			local size = 0
			for _, entry in chunk do
				size += 50 + buffer.len(entry :: buffer)
			end
			assert(size <= 900, `chunk of {size} bytes is over budget`)
			total += #chunk
		end
		Expect.equal(total, 40, "entries sent")

		-- An oversized entry still goes out, alone.
		Expect.equal(#Codec.chunk({ buffer.create(2000) }), 1)
	end,
}
