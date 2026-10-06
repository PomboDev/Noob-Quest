local EnemyDefs = require("../src/features/enemies/modules/EnemyDefs")
local EnemySnapshot = require("../src/features/enemies/modules/EnemySnapshot")
local Expect = require("./Expect")

local function near(actual: number, expected: number, tolerance: number, label: string)
	if math.abs(actual - expected) > tolerance then
		error(`{label}: expected {expected} ± {tolerance}, got {actual}`, 2)
	end
end

return {
	["round-trips ids, positions, angles and flags"] = function()
		local entries = {
			{ id = 1, x = 12.34, z = 250.9, angle = 0, flags = 0 },
			{ id = 65535, x = -4.5, z = 0, angle = math.pi, flags = EnemySnapshot.TELEGRAPHING },
			{
				id = 300,
				x = 287.99,
				z = 143.2,
				angle = 5.5,
				flags = EnemySnapshot.TELEGRAPHING + EnemySnapshot.STUNNED,
			},
		}
		local decoded = EnemySnapshot.decode(EnemySnapshot.encode(entries))
		Expect.equal(decoded ~= nil, true)
		local result = decoded :: { EnemySnapshot.Entry }
		Expect.equal(#result, 3)
		for index, entry in entries do
			Expect.equal(result[index].id, entry.id)
			Expect.equal(result[index].flags, entry.flags)
			near(result[index].x, entry.x, 1 / 16, "x")
			near(result[index].z, entry.z, 1 / 16, "z")
			near(result[index].angle, entry.angle, math.pi / 256 + 1e-9, "angle")
		end
	end,

	["negative and wrapped angles come back as the same direction"] = function()
		local decoded = EnemySnapshot.decode(EnemySnapshot.encode({
			{ id = 1, x = 0, z = 0, angle = -math.pi / 2, flags = 0 },
			{ id = 2, x = 0, z = 0, angle = math.pi * 2 + 1, flags = 0 },
		})) :: { EnemySnapshot.Entry }
		near(decoded[1].angle, math.pi * 1.5, math.pi / 256 + 1e-9, "-90 degrees")
		near(decoded[2].angle, 1, math.pi / 256 + 1e-9, "a turn and a bit")
	end,

	["each enemy takes 8 bytes and 40 fit an unreliable message"] = function()
		local entries = {}
		for id = 1, 40 do
			table.insert(entries, { id = id, x = id, z = id, angle = 0, flags = 0 })
		end
		local size = buffer.len(EnemySnapshot.encode(entries))
		Expect.equal(size, 1 + 40 * 8)
		Expect.equal(size < 900, true)
		Expect.equal(1 + EnemySnapshot.MAX_ENTRIES * 8 < 900, true, "even a full snapshot fits")
	end,

	["an empty snapshot is valid"] = function()
		local decoded = EnemySnapshot.decode(EnemySnapshot.encode({}))
		Expect.deepEqual(decoded, {})
	end,

	["too many enemies is an error"] = function()
		local entries = {}
		for id = 1, EnemySnapshot.MAX_ENTRIES + 1 do
			table.insert(entries, { id = id, x = 0, z = 0, angle = 0, flags = 0 })
		end
		Expect.errors(function()
			EnemySnapshot.encode(entries)
		end, "more than")
	end,

	["truncated or padded buffers decode to nil"] = function()
		local good = EnemySnapshot.encode({ { id = 1, x = 1, z = 1, angle = 0, flags = 0 } })
		Expect.equal(EnemySnapshot.decode(buffer.create(0)), nil)

		local short = buffer.create(buffer.len(good) - 1)
		buffer.copy(short, 0, good, 0, buffer.len(good) - 1)
		Expect.equal(EnemySnapshot.decode(short), nil)

		local long = buffer.create(buffer.len(good) + 3)
		buffer.copy(long, 0, good)
		Expect.equal(EnemySnapshot.decode(long), nil)
	end,

	["positions outside the range are clamped, not wrapped"] = function()
		local decoded = EnemySnapshot.decode(EnemySnapshot.encode({
			{ id = 1, x = 99999, z = -99999, angle = 0, flags = 0 },
		})) :: { EnemySnapshot.Entry }
		Expect.equal(decoded[1].x > 4000, true)
		Expect.equal(decoded[1].z < -4000, true)
	end,

	["EnemyDefs ids and indexes agree"] = function()
		for index, def in EnemyDefs.list do
			Expect.equal(EnemyDefs.indexOf(def.id), index)
			Expect.equal(EnemyDefs.byIndex(index), def)
			Expect.equal(EnemyDefs.get(def.id), def)
		end
		Expect.equal(EnemyDefs.get("nope"), nil)
		Expect.equal(EnemyDefs.byIndex(0), nil)
		Expect.equal(EnemyDefs.byIndex(99), nil)
	end,

	["every ranged and boss def has the fields its behaviour needs"] = function()
		for _, def in EnemyDefs.list do
			if def.behaviour == "ranged" then
				Expect.equal(def.preferredRange ~= nil and def.projectileSpeed ~= nil, true, def.id)
				Expect.equal(def.projectileLife ~= nil and def.projectileRadius ~= nil, true, def.id)
			elseif def.behaviour == "boss" then
				Expect.equal(
					def.slamRadius ~= nil and def.slamTelegraph ~= nil and def.slamCooldown ~= nil,
					true,
					def.id
				)
				Expect.equal(def.summonCooldown ~= nil and def.summonCount ~= nil, true, def.id)
				Expect.equal(EnemyDefs.get(def.summonDef or "") ~= nil, true, "the summon exists")
			end
			Expect.equal(def.telegraph > 0, true, `{def.id} must telegraph`)
		end
	end,
}
