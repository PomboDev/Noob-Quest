local ActDefs = require("../src/features/world/modules/ActDefs")
local ActTypes = require("../src/features/world/modules/ActTypes")
local Expect = require("./Expect")
local GenerateAct = require("../src/features/world/modules/GenerateAct")
local PoiLayout = require("../src/features/world/modules/PoiLayout")
local Rng = require("../src/core/Rng")
local TileSet = require("../src/features/world/modules/TileSet")

type Act = ActTypes.Act

local DX = { 0, 1, 0, -1 }
local DY = { -1, 0, 1, 0 }

local ACT_1 = ActDefs.forAct(1)
local SEEDS = 40

-- Cells reachable from `startCell` over walkable tiles.
local function flood(act: Act, tileSet: ActTypes.TileSet, startCell: number): { [number]: boolean }
	local reached: { [number]: boolean } = { [startCell] = true }
	local queue = { startCell }
	local head = 1
	while head <= #queue do
		local cell = queue[head]
		head += 1
		local x, y = (cell - 1) % act.width, (cell - 1) // act.width
		for d = 1, 4 do
			local nx, ny = x + DX[d], y + DY[d]
			if nx >= 0 and nx < act.width and ny >= 0 and ny < act.height then
				local neighbor = ny * act.width + nx + 1
				if not reached[neighbor] and tileSet.variants[act.tiles[neighbor]].walkable then
					reached[neighbor] = true
					table.insert(queue, neighbor)
				end
			end
		end
	end
	return reached
end

return {
	["same seed gives an identical act"] = function()
		for seed = 1, 5 do
			local a = GenerateAct.generate(ACT_1, seed)
			local b = GenerateAct.generate(ACT_1, seed)
			Expect.deepEqual(a, b, `seed {seed}`)
			Expect.equal(GenerateAct.hash(a), GenerateAct.hash(b), `seed {seed} hash`)
		end
	end,

	["different seeds give different acts"] = function()
		local hashes: { [number]: boolean } = {}
		local distinct = 0
		for seed = 1, 20 do
			local hash = GenerateAct.hash(GenerateAct.generate(ACT_1, seed))
			if not hashes[hash] then
				hashes[hash] = true
				distinct += 1
			end
		end
		Expect.equal(distinct, 20)
	end,

	["places every point inside the rules"] = function()
		for seed = 1, SEEDS do
			local act = GenerateAct.generate(ACT_1, seed)

			local expected = 1
			for _, request in ACT_1.pois do
				expected += request.count
			end
			Expect.equal(#act.pois, expected, `seed {seed} point count`)

			local spawn = act.pois[1]
			Expect.equal(spawn.kind, "spawn")

			local requests: { [string]: ActTypes.PoiRequest } = {}
			for _, request in ACT_1.pois do
				requests[request.kind] = request
			end

			for index, poi in act.pois do
				Expect.equal(poi.x >= 0 and poi.y >= 0, true, `seed {seed} {poi.id} in bounds`)
				Expect.equal(
					poi.x + poi.w <= act.width and poi.y + poi.h <= act.height,
					true,
					`seed {seed} {poi.id} in bounds`
				)

				if index > 1 then
					local request = requests[poi.kind]
					local dx, dy = poi.cx - spawn.cx, poi.cy - spawn.cy
					local fromSpawn = dx * dx + dy * dy
					Expect.equal(
						fromSpawn >= request.minFromSpawn ^ 2,
						true,
						`seed {seed} {poi.id} not too close to the spawn`
					)
					Expect.equal(
						fromSpawn <= request.maxFromSpawn ^ 2,
						true,
						`seed {seed} {poi.id} not too far from the spawn`
					)
				end

				for other = index + 1, #act.pois do
					local b = act.pois[other]
					local apart = poi.x + poi.w < b.x or b.x + b.w < poi.x or poi.y + poi.h < b.y or b.y + b.h < poi.y
					Expect.equal(apart, true, `seed {seed} {poi.id} and {b.id} keep a gap`)
				end
			end
		end
	end,

	["every point is reachable from the spawn on foot"] = function()
		for seed = 1, SEEDS do
			local act = GenerateAct.generate(ACT_1, seed)
			local spawn = act.pois[1]
			local reached = flood(act, TileSet.DEFAULT, spawn.cy * act.width + spawn.cx + 1)
			for _, poi in act.pois do
				Expect.equal(reached[poi.cy * act.width + poi.cx + 1], true, `seed {seed} reaches {poi.id}`)
			end
		end
	end,

	["generated maps are mostly walkable and not relaxed"] = function()
		for seed = 1, SEEDS do
			local act = GenerateAct.generate(ACT_1, seed)
			Expect.equal(act.relaxed, false, `seed {seed} relaxed`)

			local walkable = 0
			for _, id in act.tiles do
				if TileSet.DEFAULT.variants[id].walkable then
					walkable += 1
				end
			end
			Expect.equal(walkable / #act.tiles > 0.6, true, `seed {seed} walkable share {walkable / #act.tiles}`)
		end
	end,

	["props sit on plain ground inside the map"] = function()
		for seed = 1, 10 do
			local act = GenerateAct.generate(ACT_1, seed)
			Expect.equal(#act.props > 0, true, `seed {seed} has props`)
			for _, prop in act.props do
				Expect.equal(prop.x >= 0 and prop.x < act.width and prop.y >= 0 and prop.y < act.height, true)
				Expect.equal(act.tiles[prop.y * act.width + prop.x + 1], TileSet.DEFAULT.ground)
				Expect.equal(prop.ox >= 0 and prop.ox < 1 and prop.oy >= 0 and prop.oy < 1, true)
			end
		end
	end,

	["falls back to plain ground when WFC keeps failing"] = function()
		-- Path tiles can't touch the only other tile, so every WFC run fails.
		local tileSet = TileSet.build({
			{
				name = "ground",
				prefab = "G",
				sockets = { "x", "x", "x", "x" },
				weight = 1,
				walkable = true,
				rotations = 1,
			},
			{
				name = "path",
				prefab = "P",
				sockets = { "p", "p", "p", "p" },
				weight = 0,
				walkable = true,
				rotations = 1,
			},
			{
				name = "plaza",
				prefab = "Z",
				sockets = { "p", "p", "p", "p" },
				weight = 0,
				walkable = true,
				rotations = 1,
			},
		}, { ground = "ground", path = "path", plaza = "plaza" })

		local act = GenerateAct.generate(ACT_1, 3, { tileSet = tileSet, maxWfcAttempts = 3 })
		Expect.equal(act.relaxed, true)
		Expect.equal(act.wfcAttempts, 3)

		local spawn = act.pois[1]
		local reached = flood(act, tileSet, spawn.cy * act.width + spawn.cx + 1)
		for _, poi in act.pois do
			Expect.equal(reached[poi.cy * act.width + poi.cx + 1], true, `reaches {poi.id}`)
		end
	end,

	["fails clearly when the points can't be placed"] = function()
		local crowded = table.clone(ACT_1)
		crowded.pois =
			{ { kind = "teleporter", count = 1, size = 3, minFromSpawn = 100, maxFromSpawn = 200, minApart = 1 } }
		Expect.errors(function()
			GenerateAct.generate(crowded, 1)
		end, "could not place")
	end,

	["layout honours the requested counts"] = function()
		local pois = PoiLayout.layout(ACT_1, Rng.new(1)) :: { ActTypes.Poi }
		local counts: { [string]: number } = {}
		for _, poi in pois do
			counts[poi.kind] = (counts[poi.kind] or 0) + 1
		end
		Expect.equal(counts.spawn, 1)
		Expect.equal(counts.teleporter, 1)
		Expect.equal(counts.chest, 8)
		Expect.equal(counts.structure, 4)
	end,

	["the act is the size we ask for"] = function()
		local act = GenerateAct.generate(ACT_1, 1)
		Expect.equal(act.width, 48)
		Expect.equal(act.height, 48)
		Expect.equal(#act.tiles, 48 * 48)
	end,

	["camps stand on walkable ground, away from the spawn and each other"] = function()
		local spec = ACT_1.camps :: ActTypes.CampSpec
		for seed = 1, SEEDS do
			local act = GenerateAct.generate(ACT_1, seed)
			Expect.equal(#act.camps >= spec.count, true, `seed {seed} has {#act.camps} camps`)

			local spawn = act.pois[1]
			local spawnX, spawnY = spawn.x + spawn.w / 2, spawn.y + spawn.h / 2
			for index, camp in act.camps do
				Expect.equal(#camp.enemies > 0, true, `seed {seed} {camp.id} is not empty`)

				local dx, dy = camp.x - spawnX, camp.y - spawnY
				Expect.equal(
					dx * dx + dy * dy >= spec.minFromSpawn ^ 2,
					true,
					`seed {seed} {camp.id} is far from the spawn`
				)

				for other = index + 1, #act.camps do
					local b = act.camps[other]
					local apartX, apartY = camp.x - b.x, camp.y - b.y
					Expect.equal(
						apartX * apartX + apartY * apartY >= spec.minApart ^ 2,
						true,
						`seed {seed} camps apart`
					)
				end

				for _, member in camp.enemies do
					local tx = math.floor(camp.x + member.dx / act.tileSize)
					local ty = math.floor(camp.y + member.dz / act.tileSize)
					Expect.equal(
						tx >= 0 and ty >= 0 and tx < act.width and ty < act.height,
						true,
						`seed {seed} in bounds`
					)
					local id = act.tiles[ty * act.width + tx + 1]
					Expect.equal(
						TileSet.DEFAULT.variants[id].walkable,
						true,
						`seed {seed} {camp.id} stands on walkable ground`
					)
					Expect.equal(id ~= TileSet.DEFAULT.plaza, true, `seed {seed} {camp.id} stays off the plazas`)
				end
			end
		end
	end,

	["every camp can be reached from the spawn on foot"] = function()
		for seed = 1, SEEDS do
			local act = GenerateAct.generate(ACT_1, seed)
			local spawn = act.pois[1]
			local reached = flood(act, TileSet.DEFAULT, spawn.cy * act.width + spawn.cx + 1)
			for _, camp in act.camps do
				local cell = math.floor(camp.y) * act.width + math.floor(camp.x) + 1
				Expect.equal(reached[cell], true, `seed {seed} reaches {camp.id}`)
			end
		end
	end,

	["farther camps hold more and tougher enemies"] = function()
		local spec = ACT_1.camps :: ActTypes.CampSpec
		local nearest, farthest = spec.tiers[1], spec.tiers[#spec.tiers]
		local sawSpitterNear, sawSpitterFar = false, false
		for seed = 1, SEEDS do
			local act = GenerateAct.generate(ACT_1, seed)
			local spawn = act.pois[1]
			local spawnX, spawnY = spawn.x + spawn.w / 2, spawn.y + spawn.h / 2
			for _, camp in act.camps do
				local distance = math.sqrt((camp.x - spawnX) ^ 2 + (camp.y - spawnY) ^ 2)
				for _, member in camp.enemies do
					if member.defId == "spitter" then
						if distance <= nearest.upTo then
							sawSpitterNear = true
						elseif distance > spec.tiers[#spec.tiers - 1].upTo then
							sawSpitterFar = true
						end
					end
				end
			end
		end
		Expect.equal(sawSpitterNear, false, "no spitters in the first tier")
		Expect.equal(sawSpitterFar, true, "spitters in the last tier")
		Expect.equal(farthest.maxSize > nearest.maxSize, true)
	end,

	["an act without camps has none"] = function()
		local empty = table.clone(ACT_1)
		empty.camps = nil
		Expect.equal(#GenerateAct.generate(empty, 1).camps, 0)
	end,

	["camps are part of the hash"] = function()
		local a = GenerateAct.generate(ACT_1, 1)
		local b = GenerateAct.generate(ACT_1, 1)
		Expect.equal(GenerateAct.hash(a), GenerateAct.hash(b))
		table.remove(b.camps[1].enemies)
		Expect.equal(GenerateAct.hash(a) ~= GenerateAct.hash(b), true)
	end,
	-- Pinned: generation must give the same act on every platform. If this moves
	-- on purpose, bump GenerateAct.VERSION in the same change.
	["gives the same hash on every platform"] = function()
		Expect.equal(GenerateAct.VERSION, 3)
		Expect.equal(GenerateAct.hash(GenerateAct.generate(ACT_1, 12345)), 3235104388)
	end,
}
