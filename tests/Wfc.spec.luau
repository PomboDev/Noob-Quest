local ActTypes = require("../src/features/world/modules/ActTypes")
local Expect = require("./Expect")
local Rng = require("../src/core/Rng")
local TileSet = require("../src/features/world/modules/TileSet")
local Wfc = require("../src/features/world/modules/Wfc")

type TileSet = ActTypes.TileSet

local DX = { 0, 1, 0, -1 }
local DY = { -1, 0, 1, 0 }

-- Every touching pair of cells must show equal sockets.
local function socketMismatches(width: number, height: number, tileSet: TileSet, tiles: { number }): number
	local mismatches = 0
	for y = 0, height - 1 do
		for x = 0, width - 1 do
			local here = tileSet.variants[tiles[y * width + x + 1]]
			for d = 1, 4 do
				local nx, ny = x + DX[d], y + DY[d]
				if nx >= 0 and nx < width and ny >= 0 and ny < height then
					local there = tileSet.variants[tiles[ny * width + nx + 1]]
					if here.sockets[d] ~= there.sockets[(d + 1) % 4 + 1] then
						mismatches += 1
					end
				end
			end
		end
	end
	return mismatches
end

return {
	["rotating a base tile turns its sockets clockwise"] = function()
		local shore: { number } = {}
		for _, variant in TileSet.DEFAULT.variants do
			if variant.name == "shore" then
				table.insert(shore, variant.id)
			end
		end
		Expect.equal(#shore, 4)

		local expected =
			{ { "w", "g", "g", "g" }, { "g", "w", "g", "g" }, { "g", "g", "w", "g" }, { "g", "g", "g", "w" } }
		for rotation = 0, 3 do
			Expect.deepEqual(
				TileSet.DEFAULT.variants[shore[rotation + 1]].sockets,
				expected[rotation + 1],
				`rotation {rotation}`
			)
		end
	end,

	["solves with matching sockets for many seeds"] = function()
		for seed = 1, 25 do
			local tiles = Wfc.solve(16, 16, TileSet.DEFAULT, {}, Rng.new(seed))
			Expect.equal(tiles ~= nil, true, `seed {seed} solves`)
			Expect.equal(socketMismatches(16, 16, TileSet.DEFAULT, tiles :: { number }), 0, `seed {seed} mismatches`)
		end
	end,

	["is deterministic and varies with the seed"] = function()
		local a = Wfc.solve(16, 16, TileSet.DEFAULT, {}, Rng.new(5))
		local b = Wfc.solve(16, 16, TileSet.DEFAULT, {}, Rng.new(5))
		Expect.deepEqual(a, b)

		local differs = false
		for seed = 6, 12 do
			local other = Wfc.solve(16, 16, TileSet.DEFAULT, {}, Rng.new(seed))
			if table.concat(other :: { number }, ",") ~= table.concat(a :: { number }, ",") then
				differs = true
			end
		end
		Expect.equal(differs, true)
	end,

	["keeps fixed cells and never picks weight-0 tiles elsewhere"] = function()
		local tileSet = TileSet.DEFAULT
		local fixed = { [1] = tileSet.path, [20] = tileSet.plaza, [100] = tileSet.path }
		for seed = 1, 10 do
			local tiles = Wfc.solve(12, 12, tileSet, fixed, Rng.new(seed)) :: { number }
			Expect.equal(tiles[1], tileSet.path)
			Expect.equal(tiles[20], tileSet.plaza)
			Expect.equal(tiles[100], tileSet.path)
			for cell, id in tiles do
				if not fixed[cell] then
					Expect.equal(tileSet.variants[id].weight > 0, true, `cell {cell}`)
				end
			end
		end
	end,

	["returns nil on a contradiction"] = function()
		-- Two tiles that can never touch, fixed at both ends of a row.
		local tileSet = TileSet.build({
			{ name = "a", prefab = "A", sockets = { "a", "a", "a", "a" }, weight = 1, walkable = true, rotations = 1 },
			{ name = "b", prefab = "B", sockets = { "b", "b", "b", "b" }, weight = 1, walkable = true, rotations = 1 },
		}, { ground = "a", path = "a", plaza = "b" })

		local fixed = { [1] = tileSet.ground, [6] = tileSet.plaza }
		Expect.equal(Wfc.solve(6, 1, tileSet, fixed, Rng.new(1)), nil)
		Expect.equal(
			Wfc.solve(6, 1, tileSet, { [1] = tileSet.ground }, Rng.new(1)) ~= nil,
			true,
			"one side alone is fine"
		)
	end,
}
