--!strict

--[=[
	The enemy snapshot the server sends about 15 times a second: where every
	enemy is. Packed into a buffer so 40 enemies stay well under the ~900 bytes
	an unreliable message can carry.

	Per enemy, 8 bytes: id (u16), x and z in eighths of a stud (s16, so up to
	4095 studs from the origin), angle (u8, a 256th of a turn) and flags (u8).
]=]

local EnemySnapshot = {}

export type Entry = {
	id: number,
	x: number,
	z: number,
	-- Radians, as in Targeting. Stored in 256 steps, so it comes back within half a step.
	angle: number,
	flags: number,
}

local ENTRY_SIZE = 8
local COORD_SCALE = 8
local MAX_ENTRIES = 100
local TURN = math.pi * 2

-- Flag bits.
EnemySnapshot.TELEGRAPHING = 1
EnemySnapshot.STUNNED = 2
-- The wind-up is the boss's slam: the client draws the area it will hit.
EnemySnapshot.SLAM = 4

EnemySnapshot.MAX_ENTRIES = MAX_ENTRIES

local function packAngle(angle: number): number
	return math.floor((angle % TURN) / TURN * 256 + 0.5) % 256
end

function EnemySnapshot.encode(entries: { Entry }): buffer
	if #entries > MAX_ENTRIES then
		error(`EnemySnapshot: {#entries} enemies is more than the {MAX_ENTRIES} one message holds`, 2)
	end

	local out = buffer.create(1 + #entries * ENTRY_SIZE)
	buffer.writeu8(out, 0, #entries)
	for index, entry in entries do
		local offset = 1 + (index - 1) * ENTRY_SIZE
		buffer.writeu16(out, offset, entry.id)
		buffer.writei16(out, offset + 2, math.clamp(math.floor(entry.x * COORD_SCALE + 0.5), -32768, 32767))
		buffer.writei16(out, offset + 4, math.clamp(math.floor(entry.z * COORD_SCALE + 0.5), -32768, 32767))
		buffer.writeu8(out, offset + 6, packAngle(entry.angle))
		buffer.writeu8(out, offset + 7, entry.flags % 256)
	end
	return out
end

-- nil for a buffer that doesn't hold the number of enemies it says.
function EnemySnapshot.decode(data: buffer): { Entry }?
	local length = buffer.len(data)
	if length < 1 then
		return nil
	end

	local count = buffer.readu8(data, 0)
	if length ~= 1 + count * ENTRY_SIZE then
		return nil
	end

	local entries = {}
	for index = 1, count do
		local offset = 1 + (index - 1) * ENTRY_SIZE
		table.insert(entries, {
			id = buffer.readu16(data, offset),
			x = buffer.readi16(data, offset + 2) / COORD_SCALE,
			z = buffer.readi16(data, offset + 4) / COORD_SCALE,
			angle = buffer.readu8(data, offset + 6) / 256 * TURN,
			flags = buffer.readu8(data, offset + 7),
		})
	end
	return entries
end

return EnemySnapshot
