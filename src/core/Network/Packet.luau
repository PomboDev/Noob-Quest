--!strict
--!native
--!optimize 2

--[=[
	Binary encoding for Network schemas. Codec is the only caller:

		Packet.beginWrite()
		Packet.writes[dataType](value) -- once per argument
		local buf, inst = Packet.finishWrite()

		Packet.beginRead(buf, inst)
		local value = Packet.reads[dataType]()

	Neither side yields or calls user code, so a single shared cursor serves
	every message and encoding reuses one scratch buffer (it only grows).

	Data types (bytes on the wire):

	| Type                  | Bytes | Values                                                |
	| --------------------- | ----- | ----------------------------------------------------- |
	| NumberU8/U16/U32      | 1/2/4 | 0..255 / 0..65535 / 0..4294967295                     |
	| NumberS8/S16/S32      | 1/2/4 | -128..127 / -32768..32767 / -2^31..2^31-1             |
	| NumberF32             | 4     | ~7 significant digits                                 |
	| NumberF64             | 8     | any number, lossless                                  |
	| String, Buffer        | 1 + n | at most 255 bytes                                     |
	| StringLong, BufferLong| 2 + n | at most 65535 bytes                                   |
	| Boolean               | 1     |                                                       |
	| Vector2F32/Vector3F32 | 8/12  | F32 components                                        |
	| Vector3S16            | 6     | integer components in S16 range                       |
	| Color3                | 3     | 8 bits per channel, clamped to 0..1                   |
	| CFrameF32             | 18    | F32 position, 16-bit angles (~0.0055 degree steps)    |
	| Instance              | 0     | travels beside the buffer                             |
	| Any                   | 1 + v | nil, boolean, number, string (<= 255 bytes), Vector3  |
	|                       |       | or Instance, tagged with its type                     |

	Integer types truncate fractions and wrap out-of-range values. `Any` sends
	whole numbers 0..2^32-1 compactly and every other number as F64.

	An Instance the receiver can't see (not replicated, streamed out,
	destroyed) arrives as nil, and so does anything in a received array that
	isn't an Instance: clients control that array.
]=]

local SCRATCH_SIZE = 256
local ANGLE_SCALE = 65536 / (2 * math.pi)

local ANY_NIL = 0
local ANY_U8 = 1
local ANY_U16 = 2
local ANY_U32 = 3
local ANY_F64 = 4
local ANY_STRING = 5
local ANY_BOOLEAN = 6
local ANY_VECTOR3 = 7
local ANY_INSTANCE = 8

local EMPTY: { any } = table.freeze({} :: { any })

-- The cursor: beginWrite points it at the scratch buffer, beginRead at the
-- message being decoded. Only writes grow it.
local scratch = buffer.create(SCRATCH_SIZE)
local scratchLength = SCRATCH_SIZE
local activeBuffer = scratch
local bufferOffset = 0

-- Instances travel beside the buffer. Writing and reading keep separate
-- state so a write can never touch an array that was received.
local writeInstances: { Instance | false } = {}
local writeInstanceCount = 0
local readInstances: { any } = EMPTY
local readInstanceIndex = 0

local reads: { [string]: () -> any } = {}
local writes: { [string]: (any) -> () } = {}
local anyReads: { [number]: () -> any } = {}
local anyWrites: { [string]: (any) -> () } = {}

local function allocate(bytes: number)
	local needed = bufferOffset + bytes
	if needed > scratchLength then
		repeat
			scratchLength *= 2
		until scratchLength >= needed

		local grown = buffer.create(scratchLength)
		buffer.copy(grown, 0, scratch, 0, bufferOffset)
		scratch = grown
		activeBuffer = grown
	end
end

-- // Primitives //

local function readS8(): number
	local value = buffer.readi8(activeBuffer, bufferOffset)
	bufferOffset += 1
	return value
end
local function writeS8(value: number)
	buffer.writei8(activeBuffer, bufferOffset, value)
	bufferOffset += 1
end
local function readS16(): number
	local value = buffer.readi16(activeBuffer, bufferOffset)
	bufferOffset += 2
	return value
end
local function writeS16(value: number)
	buffer.writei16(activeBuffer, bufferOffset, value)
	bufferOffset += 2
end
local function readS32(): number
	local value = buffer.readi32(activeBuffer, bufferOffset)
	bufferOffset += 4
	return value
end
local function writeS32(value: number)
	buffer.writei32(activeBuffer, bufferOffset, value)
	bufferOffset += 4
end
local function readU8(): number
	local value = buffer.readu8(activeBuffer, bufferOffset)
	bufferOffset += 1
	return value
end
local function writeU8(value: number)
	buffer.writeu8(activeBuffer, bufferOffset, value)
	bufferOffset += 1
end
local function readU16(): number
	local value = buffer.readu16(activeBuffer, bufferOffset)
	bufferOffset += 2
	return value
end
local function writeU16(value: number)
	buffer.writeu16(activeBuffer, bufferOffset, value)
	bufferOffset += 2
end
local function readU32(): number
	local value = buffer.readu32(activeBuffer, bufferOffset)
	bufferOffset += 4
	return value
end
local function writeU32(value: number)
	buffer.writeu32(activeBuffer, bufferOffset, value)
	bufferOffset += 4
end
local function readF32(): number
	local value = buffer.readf32(activeBuffer, bufferOffset)
	bufferOffset += 4
	return value
end
local function writeF32(value: number)
	buffer.writef32(activeBuffer, bufferOffset, value)
	bufferOffset += 4
end
local function readF64(): number
	local value = buffer.readf64(activeBuffer, bufferOffset)
	bufferOffset += 8
	return value
end
local function writeF64(value: number)
	buffer.writef64(activeBuffer, bufferOffset, value)
	bufferOffset += 8
end
local function readString(length: number): string
	local value = buffer.readstring(activeBuffer, bufferOffset, length)
	bufferOffset += length
	return value
end
local function writeString(value: string)
	buffer.writestring(activeBuffer, bufferOffset, value)
	bufferOffset += #value
end
local function readBuffer(length: number): buffer
	local value = buffer.create(length)
	buffer.copy(value, 0, activeBuffer, bufferOffset, length)
	bufferOffset += length
	return value
end
local function writeBuffer(value: buffer)
	buffer.copy(activeBuffer, bufferOffset, value)
	bufferOffset += buffer.len(value)
end

local function readInstance(): Instance?
	readInstanceIndex += 1
	local value = readInstances[readInstanceIndex]
	return if typeof(value) == "Instance" then value else nil
end
local function writeInstance(value: Instance?)
	-- Each message gets its own array: finishWrite hands it out and it may
	-- wait in a send queue until the end of the frame.
	if writeInstanceCount == 0 then
		writeInstances = {}
	end
	writeInstanceCount += 1
	-- false keeps the array dense; remotes don't preserve nil gaps.
	writeInstances[writeInstanceCount] = if value == nil then false else value
end

local function writeChannel(value: number)
	writeU8(math.clamp(value, 0, 1) * 255 + 0.5)
end

local function writeAngle(value: number)
	writeU16(math.floor(value * ANGLE_SCALE + 0.5))
end

-- // Data types //

local function define(name: string, read: () -> any, write: (any) -> ()): string
	reads[name] = read
	writes[name] = write
	return name
end

local Packet = {
	reads = reads,
	writes = writes,
}

Packet.NumberS8 = define("NumberS8", readS8, function(value: number)
	allocate(1)
	writeS8(value)
end)

Packet.NumberS16 = define("NumberS16", readS16, function(value: number)
	allocate(2)
	writeS16(value)
end)

Packet.NumberS32 = define("NumberS32", readS32, function(value: number)
	allocate(4)
	writeS32(value)
end)

Packet.NumberU8 = define("NumberU8", readU8, function(value: number)
	allocate(1)
	writeU8(value)
end)

Packet.NumberU16 = define("NumberU16", readU16, function(value: number)
	allocate(2)
	writeU16(value)
end)

Packet.NumberU32 = define("NumberU32", readU32, function(value: number)
	allocate(4)
	writeU32(value)
end)

Packet.NumberF32 = define("NumberF32", readF32, function(value: number)
	allocate(4)
	writeF32(value)
end)

Packet.NumberF64 = define("NumberF64", readF64, function(value: number)
	allocate(8)
	writeF64(value)
end)

Packet.String = define("String", function()
	return readString(readU8())
end, function(value: string)
	local length = #value
	assert(length <= 255, "Packet.String is limited to 255 bytes, use StringLong")
	allocate(1 + length)
	writeU8(length)
	writeString(value)
end)

Packet.StringLong = define("StringLong", function()
	return readString(readU16())
end, function(value: string)
	local length = #value
	assert(length <= 65535, "Packet.StringLong is limited to 65535 bytes")
	allocate(2 + length)
	writeU16(length)
	writeString(value)
end)

Packet.Buffer = define("Buffer", function()
	return readBuffer(readU8())
end, function(value: buffer)
	local length = buffer.len(value)
	assert(length <= 255, "Packet.Buffer is limited to 255 bytes, use BufferLong")
	allocate(1 + length)
	writeU8(length)
	writeBuffer(value)
end)

Packet.BufferLong = define("BufferLong", function()
	return readBuffer(readU16())
end, function(value: buffer)
	local length = buffer.len(value)
	assert(length <= 65535, "Packet.BufferLong is limited to 65535 bytes")
	allocate(2 + length)
	writeU16(length)
	writeBuffer(value)
end)

Packet.Instance = define("Instance", readInstance, writeInstance)

Packet.Boolean = define("Boolean", function()
	return readU8() == 1
end, function(value: boolean)
	allocate(1)
	writeU8(if value then 1 else 0)
end)

Packet.Vector2F32 = define("Vector2F32", function()
	return Vector2.new(readF32(), readF32())
end, function(value: Vector2)
	allocate(8)
	writeF32(value.X)
	writeF32(value.Y)
end)

Packet.Vector3F32 = define("Vector3F32", function()
	return vector.create(readF32(), readF32(), readF32())
end, function(value: Vector3)
	allocate(12)
	writeF32(value.X)
	writeF32(value.Y)
	writeF32(value.Z)
end)

Packet.Vector3S16 = define("Vector3S16", function()
	return vector.create(readS16(), readS16(), readS16())
end, function(value: Vector3)
	allocate(6)
	writeS16(value.X)
	writeS16(value.Y)
	writeS16(value.Z)
end)

Packet.Color3 = define("Color3", function()
	return Color3.fromRGB(readU8(), readU8(), readU8())
end, function(value: Color3)
	allocate(3)
	writeChannel(value.R)
	writeChannel(value.G)
	writeChannel(value.B)
end)

Packet.CFrameF32 = define("CFrameF32", function()
	local rx, ry, rz = readU16() / ANGLE_SCALE, readU16() / ANGLE_SCALE, readU16() / ANGLE_SCALE
	return CFrame.fromEulerAnglesXYZ(rx, ry, rz) + Vector3.new(readF32(), readF32(), readF32())
end, function(value: CFrame)
	local rx, ry, rz = value:ToEulerAnglesXYZ()
	allocate(18)
	writeAngle(rx)
	writeAngle(ry)
	writeAngle(rz)
	writeF32(value.X)
	writeF32(value.Y)
	writeF32(value.Z)
end)

Packet.Any = define("Any", function()
	local read = anyReads[readU8()]
	if not read then
		error("Packet.Any: unknown type tag")
	end
	return read()
end, function(value: any)
	local write = anyWrites[typeof(value)]
	if not write then
		error(`Packet.Any cannot send values of type '{typeof(value)}'`)
	end
	write(value)
end)

-- // Any //

anyReads[ANY_NIL] = function()
	return nil
end
anyWrites["nil"] = function()
	allocate(1)
	writeU8(ANY_NIL)
end

anyReads[ANY_U8] = readU8
anyReads[ANY_U16] = readU16
anyReads[ANY_U32] = readU32
anyReads[ANY_F64] = readF64
anyWrites.number = function(value: number)
	if value % 1 == 0 and value >= 0 and value < 4294967296 then
		if value < 256 then
			allocate(2)
			writeU8(ANY_U8)
			writeU8(value)
		elseif value < 65536 then
			allocate(3)
			writeU8(ANY_U16)
			writeU16(value)
		else
			allocate(5)
			writeU8(ANY_U32)
			writeU32(value)
		end
	else
		allocate(9)
		writeU8(ANY_F64)
		writeF64(value)
	end
end

anyReads[ANY_STRING] = function()
	return readString(readU8())
end
anyWrites.string = function(value: string)
	local length = #value
	assert(length <= 255, "Packet.Any strings are limited to 255 bytes")
	allocate(2 + length)
	writeU8(ANY_STRING)
	writeU8(length)
	writeString(value)
end

anyReads[ANY_BOOLEAN] = function()
	return readU8() == 1
end
anyWrites.boolean = function(value: boolean)
	allocate(2)
	writeU8(ANY_BOOLEAN)
	writeU8(if value then 1 else 0)
end

anyReads[ANY_VECTOR3] = function()
	return vector.create(readF32(), readF32(), readF32())
end
anyWrites.Vector3 = function(value: Vector3)
	allocate(13)
	writeU8(ANY_VECTOR3)
	writeF32(value.X)
	writeF32(value.Y)
	writeF32(value.Z)
end

anyReads[ANY_INSTANCE] = readInstance
anyWrites.Instance = function(value: Instance)
	allocate(1)
	writeU8(ANY_INSTANCE)
	writeInstance(value)
end

-- // Cursor //

-- Starts a message in the scratch buffer.
function Packet.beginWrite()
	activeBuffer = scratch
	bufferOffset = 0
	writeInstanceCount = 0
end

-- Copies the message out of the scratch buffer. The Instance array (if any
-- argument used one) now belongs to the caller.
function Packet.finishWrite(): (buffer, { Instance | false }?)
	local result = buffer.create(bufferOffset)
	buffer.copy(result, 0, scratch, 0, bufferOffset)
	return result, if writeInstanceCount > 0 then writeInstances else nil
end

-- Points the reader at a received message. Reading past its end errors.
function Packet.beginRead(buf: buffer, inst: { any }?)
	activeBuffer = buf
	bufferOffset = 0
	readInstances = inst or EMPTY
	readInstanceIndex = 0
end

return Packet
