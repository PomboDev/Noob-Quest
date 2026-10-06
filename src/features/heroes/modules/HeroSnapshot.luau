--!strict

--[=[
	Where every hero is, as the server sends it to all clients about 15 times
	a second (unreliable). The clients draw the other players' heroes from it.

	Per hero, 15 bytes: user id (u32), x and z (f32), facing (u16, in
	core/Angle units) and flags (u8).
]=]

local HeroSnapshot = {}

export type Entry = {
	userId: number,
	x: number,
	z: number,
	facing: number,
	flags: number,
}

local ENTRY_SIZE = 15
local MAX_ENTRIES = 16

-- Flag bits.
HeroSnapshot.DASHING = 1
HeroSnapshot.MAX_ENTRIES = MAX_ENTRIES

function HeroSnapshot.encode(entries: { Entry }): buffer
	if #entries > MAX_ENTRIES then
		error(`HeroSnapshot: {#entries} heroes is more than the {MAX_ENTRIES} one message holds`, 2)
	end

	local out = buffer.create(1 + #entries * ENTRY_SIZE)
	buffer.writeu8(out, 0, #entries)
	for index, entry in entries do
		local offset = 1 + (index - 1) * ENTRY_SIZE
		buffer.writeu32(out, offset, entry.userId)
		buffer.writef32(out, offset + 4, entry.x)
		buffer.writef32(out, offset + 8, entry.z)
		buffer.writeu16(out, offset + 12, entry.facing % 65536)
		buffer.writeu8(out, offset + 14, entry.flags % 256)
	end
	return out
end

-- nil for a buffer that doesn't hold the number of heroes it says.
function HeroSnapshot.decode(data: buffer): { Entry }?
	local length = buffer.len(data)
	if length < 1 then
		return nil
	end
	local count = buffer.readu8(data, 0)
	if count > MAX_ENTRIES or length ~= 1 + count * ENTRY_SIZE then
		return nil
	end

	local entries: { Entry } = {}
	for index = 1, count do
		local offset = 1 + (index - 1) * ENTRY_SIZE
		table.insert(entries, {
			userId = buffer.readu32(data, offset),
			x = buffer.readf32(data, offset + 4),
			z = buffer.readf32(data, offset + 8),
			facing = buffer.readu16(data, offset + 12),
			flags = buffer.readu8(data, offset + 14),
		})
	end
	return entries
end

return HeroSnapshot
