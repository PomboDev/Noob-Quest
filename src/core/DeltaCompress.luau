--!strict
--!native
--!optimize 2

--[=[
	Binary delta compression for replicating table state.

	createDelta(old, new) diffs two tables and serializes only what changed.
	applyDelta(old, delta) rebuilds the new table without mutating `old`:
	changed branches are cloned, untouched branches are shared.

	A context interns known strings (e.g. every key of a data template) so they
	travel as small integer ids. Both sides must build their context from the
	same table; createContext visits keys in sorted order so the ids match.

		local CONTEXT = DeltaCompress.createContext(TEMPLATE)

		-- sender: diff against a snapshot, never against the live table. The
		-- second result is the next snapshot, copied only where it changed.
		local delta
		delta, lastSent = DeltaCompress.createDelta(lastSent, current, CONTEXT)

		-- receiver
		state = DeltaCompress.applyDelta(state, delta, CONTEXT)
]=]

local TAG_END = 0
local TAG_NIL = 1
local TAG_TRUE = 2
local TAG_FALSE = 3
local TAG_NUMBER = 4
local TAG_STRING = 5
local TAG_STRING_REF = 6
local TAG_TABLE = 7
local TAG_NONE = 8
local TAG_UINT = 9
local TAG_CFRAME = 10
local TAG_VECTOR3 = 11
local TAG_COLOR3 = 12
local TAG_NINT = 13

local VARINT_LIMIT = 2 ^ 32
local INITIAL_BUFFER_SIZE = 256

export type Context = {
	stringToId: { [string]: number },
	idToString: { [number]: string },
	nextId: number,
}

-- Marks a key that was removed.
local None = newproxy(true)
getmetatable(None).__tostring = function()
	return "DeltaCompress.None"
end

-- // Writer //
-- Serialization never yields, so one scratch buffer is shared by every call.

local writeBuffer = buffer.create(INITIAL_BUFFER_SIZE)
local writeCursor = 0

local function reserve(bytes: number)
	local needed = writeCursor + bytes
	local size = buffer.len(writeBuffer)
	if needed > size then
		local grown = buffer.create(math.max(size * 2, needed))
		buffer.copy(grown, 0, writeBuffer, 0, writeCursor)
		writeBuffer = grown
	end
end

local function writeU8(value: number)
	reserve(1)
	buffer.writeu8(writeBuffer, writeCursor, value)
	writeCursor += 1
end

local function writeF64(value: number)
	reserve(8)
	buffer.writef64(writeBuffer, writeCursor, value)
	writeCursor += 8
end

local function writeVarint(value: number)
	repeat
		local byte = bit32.band(value, 0x7F)
		value = bit32.rshift(value, 7)
		if value ~= 0 then
			byte = bit32.bor(byte, 0x80)
		end
		writeU8(byte)
	until value == 0
end

local function writeString(value: string)
	local length = #value
	writeVarint(length)
	reserve(length)
	buffer.writestring(writeBuffer, writeCursor, value)
	writeCursor += length
end

-- // Reader //

local readBuffer: buffer = buffer.create(0)
local readCursor = 0

local function readU8(): number
	local value = buffer.readu8(readBuffer, readCursor)
	readCursor += 1
	return value
end

local function readF64(): number
	local value = buffer.readf64(readBuffer, readCursor)
	readCursor += 8
	return value
end

local function readVarint(): number
	local result = 0
	local shift = 0
	local byte: number
	repeat
		if shift > 28 then
			error("Malformed varint")
		end
		byte = readU8()
		result = bit32.bor(result, bit32.lshift(bit32.band(byte, 0x7F), shift))
		shift += 7
	until bit32.band(byte, 0x80) == 0
	return result
end

local function readString(): string
	local length = readVarint()
	local value = buffer.readstring(readBuffer, readCursor, length)
	readCursor += length
	return value
end

-- // Strings //

local function registerString(context: Context, value: string)
	if context.stringToId[value] == nil then
		local id = context.nextId
		context.nextId += 1
		context.stringToId[value] = id
		context.idToString[id] = value
	end
end

local function compareKeys(a: any, b: any): boolean
	local typeA, typeB = type(a), type(b)
	if typeA ~= typeB then
		return typeA < typeB
	end
	if typeA == "string" or typeA == "number" then
		return a < b
	end
	return false
end

local function registerStrings(context: Context, value: any)
	if type(value) == "string" then
		registerString(context, value)
	elseif type(value) == "table" then
		local keys = {}
		for key in value do
			table.insert(keys, key)
		end
		table.sort(keys, compareKeys)

		for _, key in keys do
			if type(key) == "string" then
				registerString(context, key)
			end
			registerStrings(context, value[key])
		end
	end
end

-- // Diff //

local function deepDiff(old: any, new: any): any
	if old == new then
		return nil
	end

	if type(old) ~= "table" or type(new) ~= "table" then
		return new
	end

	-- Created on the first change, so unchanged branches cost no allocations.
	local diff: { [any]: any }? = nil

	for key, value in new do
		local subDiff = deepDiff(old[key], value)
		if subDiff ~= nil then
			local target = diff or {}
			target[key] = subDiff
			diff = target
		end
	end

	for key in old do
		if new[key] == nil then
			local target = diff or {}
			target[key] = None
			diff = target
		end
	end

	return diff
end

-- // Serialization //

local function serialize(value: any, context: Context?)
	local valueType = typeof(value)

	if value == None then
		writeU8(TAG_NONE)
	elseif value == nil then
		writeU8(TAG_NIL)
	elseif valueType == "boolean" then
		writeU8(if value then TAG_TRUE else TAG_FALSE)
	elseif valueType == "number" then
		if value % 1 == 0 and value >= 0 and value < VARINT_LIMIT then
			writeU8(TAG_UINT)
			writeVarint(value)
		elseif value % 1 == 0 and value < 0 and value > -VARINT_LIMIT then
			writeU8(TAG_NINT)
			writeVarint(-value)
		else
			writeU8(TAG_NUMBER)
			writeF64(value)
		end
	elseif valueType == "string" then
		local id = context and context.stringToId[value]
		if id then
			writeU8(TAG_STRING_REF)
			writeVarint(id)
		else
			writeU8(TAG_STRING)
			writeString(value)
		end
	elseif valueType == "table" then
		writeU8(TAG_TABLE)
		for key, child in value do
			serialize(key, context)
			serialize(child, context)
		end
		writeU8(TAG_END)
	elseif valueType == "Vector3" then
		writeU8(TAG_VECTOR3)
		writeF64(value.X)
		writeF64(value.Y)
		writeF64(value.Z)
	elseif valueType == "Color3" then
		writeU8(TAG_COLOR3)
		writeF64(value.R)
		writeF64(value.G)
		writeF64(value.B)
	elseif valueType == "CFrame" then
		writeU8(TAG_CFRAME)
		for _, component in { value:GetComponents() } do
			writeF64(component)
		end
	else
		error(`DeltaCompress cannot serialize values of type '{valueType}'`)
	end
end

local function deserialize(context: Context?): any
	local tag = readU8()

	if tag == TAG_NIL then
		return nil
	elseif tag == TAG_NONE then
		return None
	elseif tag == TAG_TRUE then
		return true
	elseif tag == TAG_FALSE then
		return false
	elseif tag == TAG_UINT then
		return readVarint()
	elseif tag == TAG_NINT then
		return -readVarint()
	elseif tag == TAG_NUMBER then
		return readF64()
	elseif tag == TAG_STRING then
		return readString()
	elseif tag == TAG_STRING_REF then
		local id = readVarint()
		local value = context and context.idToString[id]
		if not value then
			error(`Unknown string id {id} (are both sides using the same context?)`)
		end
		return value
	elseif tag == TAG_TABLE then
		local result = {}
		while buffer.readu8(readBuffer, readCursor) ~= TAG_END do
			local key = deserialize(context)
			result[key] = deserialize(context)
		end
		readCursor += 1
		return result
	elseif tag == TAG_VECTOR3 then
		return Vector3.new(readF64(), readF64(), readF64())
	elseif tag == TAG_COLOR3 then
		return Color3.new(readF64(), readF64(), readF64())
	elseif tag == TAG_CFRAME then
		return CFrame.new(
			readF64(),
			readF64(),
			readF64(),
			readF64(),
			readF64(),
			readF64(),
			readF64(),
			readF64(),
			readF64(),
			readF64(),
			readF64(),
			readF64()
		)
	end

	error(`Unknown tag {tag}`)
end

local function apply(old: any, delta: any): any
	if delta == None then
		return nil
	end

	if type(delta) ~= "table" or type(old) ~= "table" then
		return delta
	end

	local result = table.clone(old)
	for key, value in delta do
		result[key] = apply(old[key], value)
	end
	return result
end

local function deepCopy<T>(value: T): T
	-- Through `any`: refining a generic by type() leaves `T & ~table`, not `T`.
	local source: any = value
	if type(source) ~= "table" then
		return source
	end

	local copy = {}
	for key, child in source do
		copy[key] = deepCopy(child)
	end
	return copy :: any
end

-- Like apply, but for the sender's snapshot: tables the diff took from the
-- live data are deep-copied, so later mutations can't reach the snapshot.
local function advance(old: any, diff: any): any
	if diff == None then
		return nil
	end

	if type(diff) ~= "table" then
		return diff
	end

	-- deepDiff only recurses when both sides are tables, so a table diff
	-- under a non-table is a live value rather than a diff node.
	if type(old) ~= "table" then
		return deepCopy(diff)
	end

	local result = table.clone(old)
	for key, value in diff do
		result[key] = advance(old[key], value)
	end
	return result
end

-- // Public API //

local DeltaCompress = {}

DeltaCompress.None = None

-- Creates a context, pre-interning every string key and value found in `state`.
function DeltaCompress.createContext(state: any?): Context
	local context: Context = {
		stringToId = {},
		idToString = {},
		nextId = 1,
	}
	if state ~= nil then
		registerStrings(context, state)
	end
	return context
end

-- Interns every string in `state` into an existing context. Both sides must
-- register the same values in the same order.
function DeltaCompress.registerStrings(context: Context, state: any)
	registerStrings(context, state)
end

-- Returns the serialized difference between `old` and `new` (nil when they
-- are identical) and the snapshot to diff against next time. Tables are
-- compared by reference first, so `old` must be a snapshot rather than the
-- live table that was mutated.
--
-- The new snapshot copies only the changed branches and shares the rest with
-- `old`, so keeping it costs as much as the change, not the whole state.
-- Neither `old` nor the returned snapshot may be mutated.
function DeltaCompress.createDelta<T>(old: T, new: T, context: Context?): (buffer?, T)
	local diff = deepDiff(old, new)
	if diff == nil then
		return nil, old
	end

	writeCursor = 0
	serialize(diff, context)

	local result = buffer.create(writeCursor)
	buffer.copy(result, 0, writeBuffer, 0, writeCursor)
	return result, advance(old, diff)
end

-- Applies a delta produced by createDelta. `old` is not mutated.
function DeltaCompress.applyDelta<T>(old: T, delta: buffer, context: Context?): T
	readBuffer = delta
	readCursor = 0
	return apply(old, deserialize(context))
end

-- Deep copy, for the first `old` of createDelta when it isn't empty.
DeltaCompress.snapshot = deepCopy

return DeltaCompress
