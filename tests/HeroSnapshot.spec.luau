local Expect = require("./Expect")
local HeroSnapshot = require("../src/features/heroes/modules/HeroSnapshot")
local LobbySpace = require("../src/features/world/modules/LobbySpace")
local NavGrid = require("../src/features/enemies/modules/NavGrid")

return {
	["a snapshot survives the wire"] = function()
		local entries: { HeroSnapshot.Entry } = {
			{ userId = 12345, x = 1500.5, z = -20.25, facing = 40000, flags = 0 },
			{ userId = 4294967295, x = -288, z = 288, facing = 0, flags = HeroSnapshot.DASHING },
		}
		local decoded = HeroSnapshot.decode(HeroSnapshot.encode(entries))
		Expect.deepEqual(decoded, entries)
	end,

	["an empty snapshot is fine"] = function()
		Expect.deepEqual(HeroSnapshot.decode(HeroSnapshot.encode({})), {})
	end,

	["a buffer of the wrong size is refused"] = function()
		local good = HeroSnapshot.encode({ { userId = 1, x = 0, z = 0, facing = 0, flags = 0 } })
		Expect.equal(HeroSnapshot.decode(buffer.create(0)), nil)
		Expect.equal(HeroSnapshot.decode(buffer.create(buffer.len(good) + 1)), nil)
		local truncated = buffer.create(buffer.len(good) - 1)
		buffer.copy(truncated, 0, good, 0, buffer.len(good) - 1)
		Expect.equal(HeroSnapshot.decode(truncated), nil)
	end,

	["too many heroes for one message is an error"] = function()
		local entries = {}
		for index = 1, HeroSnapshot.MAX_ENTRIES + 1 do
			table.insert(entries, { userId = index, x = 0, z = 0, facing = 0, flags = 0 })
		end
		local ok = pcall(HeroSnapshot.encode :: any, entries)
		Expect.equal(ok, false)
	end,

	["the lobby is a walkable platform inside a ring of walls"] = function()
		local grid = LobbySpace.navGrid()
		Expect.equal(NavGrid.walkableAt(grid, LobbySpace.X, LobbySpace.SPAWN_Z), true)
		Expect.equal(NavGrid.walkableAt(grid, LobbySpace.X, LobbySpace.PORTAL_Z), true)
		Expect.equal(NavGrid.walkableAt(grid, LobbySpace.X + 59, LobbySpace.Z), false, "the wall")
		Expect.equal(NavGrid.walkableAt(grid, LobbySpace.X + 70, LobbySpace.Z), false, "off the platform")
		Expect.equal(LobbySpace.navGrid(), grid, "built once")
	end,
}
