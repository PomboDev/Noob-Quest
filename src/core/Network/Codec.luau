--!strict
--!native
--!optimize 2

--[=[
	Wire format shared by NetworkServer and NetworkClient.

	A message is a buffer laid out as [u8 serviceId][u8 methodId][args...], with
	args encoded in schema order (see Packet for the data types). Messages that
	reference Instances travel as { buf, inst } because Instances cannot live
	inside a buffer.

	RemoteEvents always carry a batch ({ BatchEntry }); the RemoteFunction
	carries a single BatchEntry (or REGISTRY_REQUEST).
]=]

local Packet = require("@Core/Network/Packet")
local Types = require("@Core/Network/Types")

type BatchEntry = Types.BatchEntry
type MethodSchema = Types.MethodSchema

local MAX_UNRELIABLE_BYTES = 900
local ENTRY_OVERHEAD = 50
local INSTANCE_OVERHEAD = 100

local reads = Packet.reads
local writes = Packet.writes
local readU8 = reads[Packet.NumberU8]
local writeU8 = writes[Packet.NumberU8]

local Codec = {}

Codec.FOLDER = "Network"
Codec.RELIABLE = "Event"
Codec.UNRELIABLE = "Unreliable"
Codec.FUNCTION = "Function"
Codec.REGISTRY_REQUEST = "_getRegistry"

-- Errors when a schema references a data type Packet does not know about.
function Codec.validateSchema(schema: MethodSchema, label: string)
	for index, dataType in schema do
		assert(writes[dataType] ~= nil, `{label}: argument {index} has unknown data type '{dataType}'`)
	end
end

function Codec.encode(serviceId: number, methodId: number, schema: MethodSchema, ...: any): BatchEntry
	Packet.beginWrite()
	writeU8(serviceId)
	writeU8(methodId)

	for index, dataType in schema do
		writes[dataType]((select(index, ...)))
	end

	local buf, inst = Packet.finishWrite()
	if inst then
		return { buf = buf, inst = inst }
	end
	return buf
end

-- Decodes the arguments of a message whose ids have already been read.
-- Errors on malformed buffers; callers handling untrusted input should pcall.
function Codec.decode(schema: MethodSchema, buf: buffer, inst: { any }?): { any }
	Packet.beginRead(buf, inst)
	readU8()
	readU8()

	local args = table.create(#schema)
	for index, dataType in schema do
		args[index] = reads[dataType]()
	end
	return args
end

-- Splits an entry into its buffer and Instances. Returns nil for anything
-- malformed, so it is safe to call on data received from a client.
function Codec.unpack(entry: any): (buffer?, { any }?)
	if typeof(entry) == "buffer" then
		if buffer.len(entry) >= 2 then
			return entry, nil
		end
	elseif typeof(entry) == "table" then
		local buf, inst = entry.buf, entry.inst
		if typeof(buf) == "buffer" and buffer.len(buf) >= 2 and (inst == nil or typeof(inst) == "table") then
			return buf, inst
		end
	end
	return nil, nil
end

-- Splits a batch into chunks small enough for an UnreliableRemoteEvent.
function Codec.chunk(batch: { BatchEntry }): { { BatchEntry } }
	local chunks = {}
	local current = {}
	local size = 0

	for _, entry in batch do
		local entrySize = ENTRY_OVERHEAD
		if typeof(entry) == "buffer" then
			entrySize += buffer.len(entry)
		else
			entrySize += buffer.len(entry.buf) + INSTANCE_OVERHEAD
		end

		if size + entrySize > MAX_UNRELIABLE_BYTES and #current > 0 then
			table.insert(chunks, current)
			current = {}
			size = 0
		end

		table.insert(current, entry)
		size += entrySize
	end

	if #current > 0 then
		table.insert(chunks, current)
	end

	return chunks
end

return Codec
