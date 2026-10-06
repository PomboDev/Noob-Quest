local Angle = require("../src/core/Angle")
local Expect = require("./Expect")
local HeroInput = require("../src/features/heroes/modules/HeroInput")
local Rng = require("../src/core/Rng")

local function randomInput(rng: Rng.Rng): HeroInput.Input
	local moving = Rng.next(rng) < 0.6
	return {
		moving = moving,
		moveAngle = if moving then Rng.int(rng, 0, 255) else 0,
		aim = Rng.int(rng, 0, 65535),
		attack = Rng.next(rng) < 0.5,
		auto = Rng.next(rng) < 0.3,
		ability = Rng.int(rng, 0, 3),
		interact = if Rng.next(rng) < 0.2 then Rng.int(rng, 1, 65535) else 0,
	}
end

return {
	["an input survives the wire"] = function()
		local rng = Rng.new(5)
		local wire = buffer.create(HeroInput.SIZE * 50)
		local sent = {}
		for index = 0, 49 do
			local input = randomInput(rng)
			sent[index] = input
			HeroInput.write(wire, index * HeroInput.SIZE, input)
		end
		for index = 0, 49 do
			local read = HeroInput.read(wire, index * HeroInput.SIZE)
			Expect.equal(read ~= nil and HeroInput.equal(read :: HeroInput.Input, sent[index]), true, `input {index}`)
		end
	end,

	["the idle input is all zeros on the wire"] = function()
		local wire = buffer.create(HeroInput.SIZE)
		HeroInput.write(wire, 0, HeroInput.idle())
		Expect.equal(buffer.tostring(wire), string.rep("\0", HeroInput.SIZE))
	end,

	["a short buffer holds no input"] = function()
		local wire = buffer.create(HeroInput.SIZE - 1)
		Expect.equal(HeroInput.read(wire, 0), nil)
		Expect.equal(HeroInput.read(buffer.create(HeroInput.SIZE * 2), HeroInput.SIZE + 1), nil)
		Expect.equal(HeroInput.read(buffer.create(HeroInput.SIZE), -1), nil)
	end,

	["any bytes decode to a valid input"] = function()
		local rng = Rng.new(8)
		for _ = 1, 200 do
			local wire = buffer.create(HeroInput.SIZE)
			for byte = 0, HeroInput.SIZE - 1 do
				buffer.writeu8(wire, byte, Rng.int(rng, 0, 255))
			end
			local input = HeroInput.read(wire, 0) :: HeroInput.Input
			Expect.equal(HeroInput.equal(input, HeroInput.normalize(input)), true)
			Expect.equal(input.ability <= HeroInput.MAX_ABILITY, true)
			Expect.equal(input.moving or input.moveAngle == 0, true, "no direction without moving")
		end
	end,

	["normalize repairs a hand-made input"] = function()
		local input = HeroInput.normalize({
			moving = true,
			moveAngle = 300.7,
			aim = -1,
			attack = true,
			auto = false,
			ability = 9,
			interact = 0 / 0,
		})
		Expect.deepEqual(input, {
			moving = true,
			moveAngle = 44,
			aim = 65535,
			attack = true,
			auto = false,
			ability = 3,
			interact = 0,
		})
	end,

	["move directions line up with eight-way keys"] = function()
		Expect.equal(HeroInput.quantizeMove(0), 0)
		Expect.equal(HeroInput.quantizeMove(Angle.QUARTER), 64)
		Expect.equal(HeroInput.quantizeMove(Angle.QUARTER // 2), 32)
		Expect.equal(HeroInput.quantizeMove(Angle.TURN - 1), 0, "rounds up past the last step")
		Expect.equal(HeroInput.moveDirection({ moveAngle = 64 } :: any), Angle.QUARTER)
	end,
}
