local AttackInput = require("../src/features/heroes/modules/AttackInput")
local Expect = require("./Expect")

return {
	["a fresh state doesn't attack"] = function()
		local state = AttackInput.new()
		Expect.equal(AttackInput.due(state, 100), false)
	end,

	["rejects angles that aren't whole units in a turn and keeps the state"] = function()
		local state = AttackInput.new()
		Expect.equal(AttackInput.setAttack(state, true, 1, false), true)

		for _, bad in { 0 / 0, math.huge, -math.huge, 1e9, -1, 65536, 1.5, "1", true, {}, false } do
			Expect.equal(AttackInput.setAttack(state, true, bad, false), false)
			Expect.equal(AttackInput.setAim(state, bad), false)
		end
		Expect.equal(state.angle, 1, "angle is unchanged")
		Expect.equal(state.active, true)
	end,

	["rejects flags that aren't booleans"] = function()
		local state = AttackInput.new()
		Expect.equal(AttackInput.setAttack(state, 1, 0, false), false)
		Expect.equal(AttackInput.setAttack(state, true, 0, "yes"), false)
		Expect.equal(AttackInput.setAttack(state, nil, 0, false), false)
		Expect.equal(state.active, false)
	end,

	["repeats while held, at the cooldown, however often it is asked"] = function()
		local state = AttackInput.new()
		AttackInput.setAttack(state, true, 0, false)

		local swings = 0
		-- 5 seconds checked every 0.05 s, with a 0.5 s cooldown.
		for step = 0, 100 do
			local now = step * 0.05
			if AttackInput.due(state, now) then
				swings += 1
				AttackInput.swung(state, now, 0.5)
			end
		end
		Expect.equal(swings, 11, "one at 0 s, then every 0.5 s up to 5 s")
	end,

	["stops when the button is released"] = function()
		local state = AttackInput.new()
		AttackInput.setAttack(state, true, 0, false)
		Expect.equal(AttackInput.due(state, 0), true)
		AttackInput.setAttack(state, false, 0, false)
		Expect.equal(AttackInput.due(state, 10), false)
	end,

	["mashing the button doesn't swing faster"] = function()
		local state = AttackInput.new()
		AttackInput.setAttack(state, true, 0, false)
		AttackInput.swung(state, 0, 0.5)

		-- Release and press again straight away: the timer still holds.
		AttackInput.setAttack(state, false, 0, false)
		AttackInput.setAttack(state, true, 0, false)
		Expect.equal(AttackInput.due(state, 0.1), false)
		Expect.equal(AttackInput.due(state, 0.5), true)
	end,

	["a late loop doesn't build up a burst of swings"] = function()
		local state = AttackInput.new()
		AttackInput.setAttack(state, true, 0, false)
		AttackInput.swung(state, 0, 0.5)

		-- Nothing checked for 10 seconds, then one swing: the next isn't due at once.
		AttackInput.swung(state, 10, 0.5)
		Expect.equal(AttackInput.due(state, 10.1), false)
		Expect.equal(AttackInput.due(state, 10.5), true)
	end,

	["auto mode ignores the client's angle"] = function()
		local state = AttackInput.new()
		AttackInput.setAttack(state, true, 40000, true)
		Expect.equal(AttackInput.swingAngle(state, 1000), 1000)
		Expect.equal(AttackInput.swingAngle(state, nil), nil, "nothing in range: no swing")

		AttackInput.setAttack(state, true, 40000, false)
		Expect.equal(AttackInput.swingAngle(state, 1000), 40000)
	end,

	["stop ends attacking without losing the timer"] = function()
		local state = AttackInput.new()
		AttackInput.setAttack(state, true, 0, false)
		AttackInput.swung(state, 0, 0.5)
		AttackInput.stop(state)
		Expect.equal(AttackInput.due(state, 5), false)
	end,
}
