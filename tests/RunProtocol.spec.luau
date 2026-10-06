local Expect = require("./Expect")
local RunProtocol = require("../src/features/run/modules/RunProtocol")

return {
	["a view survives the trip"] = function()
		local view: RunProtocol.View = {
			phase = "Charging",
			act = 2,
			totalActs = 3,
			elapsed = 187,
			coefficient = 1.43,
			charge = 0.37,
			coins = 120,
			xp = 640,
			alive = 2,
		}
		Expect.deepEqual(RunProtocol.decode(RunProtocol.encode(view)), view)
	end,

	["every phase can be sent"] = function()
		for _, phase in { "Waiting", "Generating", "Exploring", "Charging", "Boss", "ExitOpen", "Victory", "Defeat" } do
			local view = table.clone(RunProtocol.TEMPLATE)
			view.phase = phase :: any
			Expect.equal(RunProtocol.decode(RunProtocol.encode(view)).phase, phase)
		end
	end,

	["a view is a few dozen bytes"] = function()
		local size = buffer.len(RunProtocol.encode(RunProtocol.TEMPLATE))
		Expect.equal(size < 80, true, `{size} bytes`)
	end,
}
