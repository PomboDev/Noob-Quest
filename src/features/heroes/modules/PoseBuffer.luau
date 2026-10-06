--!strict

--[=[
	A short history of where a hero was, so another player's hero can be
	drawn smoothly a little in the past (the snapshots arrive 15 times a
	second). Plain numbers, so Lune can test it.

	Facing is a core/Angle angle and is blended the short way round.
]=]

local PoseBuffer = {}

type Sample = { t: number, x: number, z: number, facing: number }

export type Buffer = { samples: { Sample } }

local MAX_SAMPLES = 10

function PoseBuffer.new(): Buffer
	return { samples = {} }
end

-- Adds a sample taken at time `t`. Samples older than the newest are dropped
-- (unreliable messages can arrive out of order).
function PoseBuffer.push(buf: Buffer, t: number, x: number, z: number, facing: number)
	local samples = buf.samples
	local last = samples[#samples]
	if last and t <= last.t then
		return
	end
	table.insert(samples, { t = t, x = x, z = z, facing = facing })
	if #samples > MAX_SAMPLES then
		table.remove(samples, 1)
	end
end

local function turn(from: number, to: number, alpha: number): number
	local difference = (to - from + 32768) % 65536 - 32768
	return (from + difference * alpha) % 65536
end

-- Where the hero was at time `t`: blended between the samples either side of
-- it, or the nearest sample if `t` is outside them. nil with no samples.
function PoseBuffer.sample(buf: Buffer, t: number): (number?, number?, number?)
	local samples = buf.samples
	local count = #samples
	if count == 0 then
		return nil, nil, nil
	end

	local first, last = samples[1], samples[count]
	if t <= first.t then
		return first.x, first.z, first.facing
	elseif t >= last.t then
		return last.x, last.z, last.facing
	end

	for index = 2, count do
		local after = samples[index]
		if t <= after.t then
			local before = samples[index - 1]
			local alpha = (t - before.t) / (after.t - before.t)
			return before.x + (after.x - before.x) * alpha,
				before.z + (after.z - before.z) * alpha,
				turn(before.facing, after.facing, alpha)
		end
	end
	return last.x, last.z, last.facing
end

return PoseBuffer
