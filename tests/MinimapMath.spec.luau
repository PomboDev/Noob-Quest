local Expect = require("./Expect")
local MinimapMath = require("../src/features/minimap/modules/MinimapMath")

-- A 10 x 10 grid of 12-stud tiles whose corner is at (-60, -60).
local function within(x: number, z: number, radius: number): { number }
	return MinimapMath.tilesWithin(10, 10, 12, -60, -60, x, z, radius)
end

local function contains(list: { number }, value: number): boolean
	return table.find(list, value) ~= nil
end

return {
	["the tile under the hero is always found"] = function()
		for _, spot in { { 0, 0 }, { -59, -59 }, { 59, 59 }, { 5.5, -23 } } do
			local tx = math.floor((spot[1] + 60) / 12)
			local ty = math.floor((spot[2] + 60) / 12)
			Expect.equal(contains(within(spot[1], spot[2], 20), ty * 10 + tx + 1), true, `{spot[1]}, {spot[2]}`)
		end
	end,

	["only tiles whose centre is inside the radius count"] = function()
		for _, index in within(0, 0, 30) do
			local tx, ty = (index - 1) % 10, (index - 1) // 10
			local dx, dz = -60 + (tx + 0.5) * 12, -60 + (ty + 0.5) * 12
			Expect.equal(dx * dx + dz * dz <= 30 * 30, true, `tile {index}`)
		end
	end,

	["every tile inside the radius is found"] = function()
		local found = within(7, -13, 35)
		for ty = 0, 9 do
			for tx = 0, 9 do
				local dx, dz = -60 + (tx + 0.5) * 12 - 7, -60 + (ty + 0.5) * 12 + 13
				local inside = dx * dx + dz * dz <= 35 * 35
				Expect.equal(contains(found, ty * 10 + tx + 1), inside, `tile {tx},{ty}`)
			end
		end
	end,

	["it never goes outside the grid"] = function()
		for _, spot in { { -200, -200 }, { 500, 0 }, { -60, 60 }, { 60, 60 } } do
			for _, index in within(spot[1], spot[2], 80) do
				Expect.equal(index >= 1 and index <= 100, true, `{spot[1]}, {spot[2]}`)
			end
		end
	end,

	["far from the map nothing is found"] = function()
		Expect.deepEqual(within(1000, 1000, 55), {})
	end,

	["the radius grows the set"] = function()
		Expect.equal(#within(0, 0, 60) > #within(0, 0, 30), true)
		Expect.equal(#within(0, 0, 30) > #within(0, 0, 10), true)
	end,

	["fraction runs from 0 to 1 along the act"] = function()
		Expect.equal(MinimapMath.fraction(-60, 120, -60), 0)
		Expect.equal(MinimapMath.fraction(-60, 120, 0), 0.5)
		Expect.equal(MinimapMath.fraction(-60, 120, 60), 1)
	end,

	["the open map fits the whole act in the view"] = function()
		local scale = MinimapMath.fitScale(400, 576, 576)
		Expect.equal(576 * scale <= 400, true)
		Expect.equal(576 * scale > 380, true, "it fills most of the view")

		local tall = MinimapMath.fitScale(400, 100, 500)
		Expect.equal(500 * tall <= 400, true, "the longer side decides")
	end,

	["the content slides so the focus is in the middle of the view"] = function()
		-- Focus on the act's corner: the corner is in the middle.
		local x, z = MinimapMath.contentOffset(200, 1, -60, -60, -60, -60)
		Expect.equal(x, 100)
		Expect.equal(z, 100)

		-- Focus on a point 30 studs in: the content has moved 30 px to the left of that.
		x, z = MinimapMath.contentOffset(200, 2, -60, -60, -30, -30)
		Expect.equal(x, 100 - 60)
		Expect.equal(z, 100 - 60)

		-- The focus lands in the middle whatever the numbers are.
		local scale = 0.8
		local focusX, focusZ = 123.4, -87.6
		x, z = MinimapMath.contentOffset(190, scale, -288, -288, focusX, focusZ)
		Expect.equal(math.abs(x + (focusX + 288) * scale - 95) < 1e-9, true)
		Expect.equal(math.abs(z + (focusZ + 288) * scale - 95) < 1e-9, true)
	end,
}
