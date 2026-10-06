--!strict

--[=[
	The server's queue of one player's inputs. Each input has a number (the
	client's own tick count) and the server uses them strictly in order, one
	per server tick. That is what keeps a client honest:
	- sending inputs faster doesn't move the hero faster: the queue is read once per tick;
	- a late input doesn't make the server invent one: the hero waits (a stall)
	  and its state after input N is the same as the client predicted;
	- the client repeats its last few inputs in every packet, so a lost packet
	  costs nothing, and a gap that never fills is taken as "did nothing".
]=]

local HeroInput = require("@Features/heroes/modules/HeroInput")

local HeroInputQueue = {}

export type Queue = {
	-- The number of the next input to use, nil until the first packet.
	nextSeq: number?,
	pending: { [number]: HeroInput.Input },
	-- The highest number received.
	newest: number,
	-- Ticks spent waiting for a number that hasn't come while later ones have.
	waited: number,
}

-- More inputs than this waiting means the client is far ahead of the server
-- (a long hitch, or a client sending too fast): the oldest are dropped.
HeroInputQueue.MAX_BACKLOG = 13
-- Ticks a gap is waited for before it is filled with "did nothing".
HeroInputQueue.HOLE_WAIT = 5
-- The most inputs one packet may carry.
HeroInputQueue.MAX_PER_PACKET = 4
-- Inputs further ahead than this are ignored when they arrive.
local MAX_AHEAD = 64

function HeroInputQueue.new(): Queue
	return { nextSeq = nil, pending = {}, newest = 0, waited = 0 }
end

-- A packet: `inputs` are the inputs numbered `last - #inputs + 1` to `last`,
-- oldest first. Returns false for a packet that isn't well formed.
function HeroInputQueue.receive(queue: Queue, last: number, inputs: { HeroInput.Input }): boolean
	local count = #inputs
	if
		type(last) ~= "number"
		or last % 1 ~= 0
		or last < 1
		or count < 1
		or count > HeroInputQueue.MAX_PER_PACKET
		or last - count + 1 < 1
	then
		return false
	end

	-- The first packet sets where the numbering starts.
	local nextSeq: number = queue.nextSeq or (last - count + 1)
	queue.nextSeq = nextSeq

	for index, input in inputs do
		local seq = last - count + index
		if seq >= nextSeq and seq <= nextSeq + MAX_AHEAD and queue.pending[seq] == nil then
			queue.pending[seq] = input
		end
	end
	queue.newest = math.max(queue.newest, math.min(last, nextSeq + MAX_AHEAD))
	return true
end

-- The input numbered `queue.nextSeq`, as (input, number), and moves on. nil
-- when there is nothing to use yet.
function HeroInputQueue.take(queue: Queue): (HeroInput.Input?, number?)
	local nextSeq = queue.nextSeq
	if nextSeq == nil then
		return nil, nil
	end

	-- Too far behind: skip the oldest ones.
	if queue.newest - nextSeq >= HeroInputQueue.MAX_BACKLOG then
		for seq = nextSeq, queue.newest - HeroInputQueue.MAX_BACKLOG do
			queue.pending[seq] = nil
		end
		nextSeq = queue.newest - HeroInputQueue.MAX_BACKLOG + 1
		queue.nextSeq = nextSeq
	end

	local input = queue.pending[nextSeq]
	if input == nil then
		if queue.newest > nextSeq then
			-- Later inputs are here but this one isn't: give it a few ticks to arrive.
			queue.waited += 1
			if queue.waited > HeroInputQueue.HOLE_WAIT then
				queue.waited = 0
				queue.nextSeq = nextSeq + 1
				return HeroInput.idle(), nextSeq
			end
		end
		return nil, nil
	end

	queue.pending[nextSeq] = nil
	queue.nextSeq = nextSeq + 1
	queue.waited = 0
	return input, nextSeq
end

-- The server moved the hero by its own decision (a teleport): everything up
-- to and including `seq` is dropped and the next input used is `seq + 1`.
function HeroInputQueue.skipTo(queue: Queue, seq: number)
	-- Before the first packet nothing is numbered yet: the client starts from here.
	if queue.nextSeq == nil then
		return
	end
	for key in queue.pending do
		if key <= seq then
			queue.pending[key] = nil
		end
	end
	queue.nextSeq = seq + 1
	queue.newest = math.max(queue.newest, seq)
	queue.waited = 0
end

-- The highest input number used so far (0 before any).
function HeroInputQueue.lastUsed(queue: Queue): number
	return if queue.nextSeq then queue.nextSeq - 1 else 0
end

-- How many inputs are waiting.
function HeroInputQueue.depth(queue: Queue): number
	local depth = 0
	for _ in queue.pending do
		depth += 1
	end
	return depth
end

return HeroInputQueue
