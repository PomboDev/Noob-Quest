local Expect = require("./Expect")
local HeroInput = require("../src/features/heroes/modules/HeroInput")
local HeroInputQueue = require("../src/features/heroes/modules/HeroInputQueue")

-- An input that can be told apart by its aim.
local function tagged(aim: number): HeroInput.Input
	local input = HeroInput.idle()
	input.aim = aim
	return input
end

local function packet(first: number, last: number): { HeroInput.Input }
	local inputs = {}
	for seq = first, last do
		table.insert(inputs, tagged(seq))
	end
	return inputs
end

local function takeAim(queue: HeroInputQueue.Queue): number?
	local input = HeroInputQueue.take(queue)
	return if input then input.aim else nil
end

return {
	["uses inputs in order, one per take"] = function()
		local queue = HeroInputQueue.new()
		Expect.equal(HeroInputQueue.receive(queue, 3, packet(1, 3)), true)
		Expect.equal(takeAim(queue), 1)
		Expect.equal(takeAim(queue), 2)
		Expect.equal(takeAim(queue), 3)
		Expect.equal(takeAim(queue), nil, "empty: the hero waits")
		Expect.equal(HeroInputQueue.lastUsed(queue), 3)
	end,

	["take says which number the input had"] = function()
		local queue = HeroInputQueue.new()
		HeroInputQueue.receive(queue, 9, packet(8, 9))
		local _, seq = HeroInputQueue.take(queue)
		Expect.equal(seq, 8, "starts from the first number it sees")
	end,

	["a repeated input is used once"] = function()
		local queue = HeroInputQueue.new()
		HeroInputQueue.receive(queue, 2, packet(1, 2))
		HeroInputQueue.receive(queue, 3, packet(2, 3))
		HeroInputQueue.receive(queue, 3, packet(2, 3))
		Expect.equal(takeAim(queue), 1)
		Expect.equal(takeAim(queue), 2)
		Expect.equal(takeAim(queue), 3)
		Expect.equal(takeAim(queue), nil)
	end,

	["a lost packet is covered by the next one's copies"] = function()
		local queue = HeroInputQueue.new()
		HeroInputQueue.receive(queue, 3, packet(1, 3))
		-- Packets for 4 and 5 are lost; 6 carries 4 to 6.
		HeroInputQueue.receive(queue, 6, packet(4, 6))
		for seq = 1, 6 do
			Expect.equal(takeAim(queue), seq)
		end
	end,

	["inputs that arrive out of order are used in order"] = function()
		local queue = HeroInputQueue.new()
		HeroInputQueue.receive(queue, 1, packet(1, 1))
		HeroInputQueue.receive(queue, 3, packet(3, 3))
		Expect.equal(takeAim(queue), 1)
		Expect.equal(takeAim(queue), nil, "waits for 2")
		HeroInputQueue.receive(queue, 2, packet(2, 2))
		Expect.equal(takeAim(queue), 2)
		Expect.equal(takeAim(queue), 3)
	end,

	["a gap that never fills becomes an idle input"] = function()
		local queue = HeroInputQueue.new()
		HeroInputQueue.receive(queue, 1, packet(1, 1))
		HeroInputQueue.receive(queue, 3, packet(3, 3))
		Expect.equal(takeAim(queue), 1)
		for _ = 1, HeroInputQueue.HOLE_WAIT do
			Expect.equal(takeAim(queue), nil)
		end
		local filled, seq = HeroInputQueue.take(queue)
		Expect.equal(seq, 2)
		Expect.equal(HeroInput.equal(filled :: HeroInput.Input, HeroInput.idle()), true)
		Expect.equal(takeAim(queue), 3)
	end,

	["sending faster doesn't get inputs used faster"] = function()
		local queue = HeroInputQueue.new()
		-- 40 packets in the time of one tick.
		for last = 1, 40 do
			HeroInputQueue.receive(queue, last, packet(math.max(1, last - 2), last))
		end
		local used = 0
		if HeroInputQueue.take(queue) then
			used += 1
		end
		Expect.equal(used, 1, "one input per take")
	end,

	["a client far ahead has its oldest inputs dropped"] = function()
		local queue = HeroInputQueue.new()
		HeroInputQueue.receive(queue, 1, packet(1, 1))
		Expect.equal(takeAim(queue), 1)
		for last = 2, 40 do
			HeroInputQueue.receive(queue, last, packet(last, last))
		end
		local _, seq = HeroInputQueue.take(queue)
		Expect.equal(seq, 40 - HeroInputQueue.MAX_BACKLOG + 1)
	end,

	["badly formed packets are refused"] = function()
		local queue = HeroInputQueue.new()
		Expect.equal(HeroInputQueue.receive(queue, 0, packet(1, 1)), false)
		Expect.equal(HeroInputQueue.receive(queue, 1.5, packet(1, 1)), false)
		Expect.equal(HeroInputQueue.receive(queue, 1, {}), false)
		Expect.equal(HeroInputQueue.receive(queue, 2, packet(1, 2)), true)
		Expect.equal(HeroInputQueue.receive(queue, 9, packet(1, 5)), false, "too many in one packet")
		Expect.equal(HeroInputQueue.receive(queue, 2, packet(1, 3)), false, "claims inputs before 1")
		Expect.equal(HeroInputQueue.receive(queue, 0 / 0, packet(1, 1)), false)
	end,

	["inputs from the far future are ignored"] = function()
		local queue = HeroInputQueue.new()
		HeroInputQueue.receive(queue, 1, packet(1, 1))
		HeroInputQueue.receive(queue, 100000, packet(99999, 100000))
		Expect.equal(HeroInputQueue.depth(queue), 1)
	end,

	["skipTo drops what the server overruled"] = function()
		local queue = HeroInputQueue.new()
		HeroInputQueue.receive(queue, 5, packet(3, 5))
		HeroInputQueue.skipTo(queue, 4)
		Expect.equal(takeAim(queue), 5)
		Expect.equal(takeAim(queue), nil)
	end,
}
