local Expect = require("./Expect")
local Targeting = require("../src/features/combat/modules/Targeting")

local function pt(id: number, x: number, z: number)
	return { id = id, x = x, z = z }
end

return {
	["direction and angleOf are inverses"] = function()
		local dx, dz = Targeting.direction(0)
		Expect.equal(math.floor(dx * 1000 + 0.5), 0)
		Expect.equal(dz, 1, "angle 0 faces +Z")
		local ex, ez = Targeting.direction(math.pi / 2)
		Expect.equal(ex, 1, "a quarter turn faces +X")
		Expect.equal(math.floor(ez * 1000 + 0.5), 0)

		for _, angle in { -3, -1.5, 0, 0.7, 2.9 } do
			local x, z = Targeting.direction(angle)
			Expect.equal(math.floor(Targeting.angleOf(x, z) * 1e6 + 0.5), math.floor(angle * 1e6 + 0.5))
		end
	end,

	["inRadius returns the closest first, edge included"] = function()
		local points = { pt(1, 5, 0), pt(2, 0, 3), pt(3, 10, 0), pt(4, 0, -3) }
		Expect.deepEqual(Targeting.inRadius(points, 0, 0, 5), { 2, 4, 1 })
		Expect.deepEqual(Targeting.inRadius(points, 0, 0, 2), {})
	end,

	["equal distances order by id"] = function()
		local points = { pt(9, 3, 0), pt(2, -3, 0), pt(5, 0, 3) }
		Expect.deepEqual(Targeting.inRadius(points, 0, 0, 10), { 2, 5, 9 })
	end,

	["inCone keeps what is ahead, in range and inside the angle"] = function()
		local points = {
			pt(1, 0, 5), -- dead ahead
			pt(2, 0, 20), -- too far
			pt(3, 0, -5), -- behind
			pt(4, 5, 5), -- 45° off
			pt(5, 5, 1), -- ~79° off
		}
		-- A 100° cone is 50° each way: 45° is in, 79° is out.
		Expect.deepEqual(Targeting.inCone(points, 0, 0, 0, 100, 10), { 1, 4 })
		-- Turned to face +X.
		Expect.deepEqual(Targeting.inCone(points, 0, 0, math.pi / 2, 100, 10), { 5, 4 })
		-- A full circle sees everything in range, behind included.
		Expect.deepEqual(Targeting.inCone(points, 0, 0, 0, 360, 10), { 1, 3, 5, 4 })
	end,

	["inCone includes a point on the origin"] = function()
		Expect.deepEqual(Targeting.inCone({ pt(1, 2, 2) }, 2, 2, 1.2, 10, 5), { 1 })
	end,

	["inSegment finds what a dash passes through, in order"] = function()
		local points = { pt(1, 0, 15), pt(2, 1.5, 5), pt(3, 4, 10), pt(4, 0, -5), pt(5, 0, 24) }
		-- A dash from the origin 20 studs along +Z, 3 studs either side.
		Expect.deepEqual(Targeting.inSegment(points, 0, 0, 0, 20, 3), { 2, 1 })
		Expect.deepEqual(Targeting.inSegment(points, 0, 0, 0, 20, 1.5), { 2, 1 })
		Expect.deepEqual(Targeting.inSegment(points, 0, 0, 0, 20, 5), { 4, 2, 3, 1, 5 }, "wider reaches further")
	end,

	["inSegment is rounded at both ends"] = function()
		local points = { pt(1, 0, -2), pt(2, 0, 22) }
		Expect.deepEqual(Targeting.inSegment(points, 0, 0, 0, 20, 3), { 1, 2 })
		Expect.deepEqual(Targeting.inSegment(points, 0, 0, 0, 20, 1.5), {})
	end,

	["a zero-length segment is a circle"] = function()
		Expect.deepEqual(Targeting.inSegment({ pt(1, 1, 1), pt(2, 5, 5) }, 0, 0, 0, 0, 2), { 1 })
	end,

	["nearest honours maxDistance and breaks ties by id"] = function()
		local points = { pt(7, 4, 0), pt(3, -4, 0), pt(8, 9, 0) }
		Expect.equal(Targeting.nearest(points, 0, 0), 3)
		Expect.equal(Targeting.nearest(points, 0, 0, 3), nil)
		Expect.equal(Targeting.nearest(points, 0, 0, 4), 3, "the edge counts")
		Expect.equal(Targeting.nearest({}, 0, 0), nil)
	end,

	["nearestToPoint snaps within the radius only"] = function()
		local points = { pt(1, 10, 10), pt(2, 12, 10) }
		Expect.equal(Targeting.nearestToPoint(points, 11.5, 10, 3), 2)
		Expect.equal(Targeting.nearestToPoint(points, 20, 20, 3), nil)
	end,
}
