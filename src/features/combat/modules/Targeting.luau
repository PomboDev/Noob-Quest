--!strict

--[=[
	Target selection on the XZ plane, over plain lists of points.

	Angles are whole `Angle` units (see core/Angle): 0 faces +Z and a quarter
	turn faces +X, the direction of angle a is (sin a, cos a), which matches the
	camera's yaw 0. Nothing here calls libm trigonometry, so the sim can use it.
	Every function returns ids closest first (equal distances: lower id first),
	so the result is the same on every machine.
]=]

local Angle = require("@Core/Angle")

local Targeting = {}

export type Point = { id: number, x: number, z: number }

local function distanceSquared(point: Point, x: number, z: number): number
	local dx, dz = point.x - x, point.z - z
	return dx * dx + dz * dz
end

local function sorted(found: { { id: number, distance: number } }): { number }
	table.sort(found, function(a, b)
		if a.distance ~= b.distance then
			return a.distance < b.distance
		end
		return a.id < b.id
	end)

	local ids = {}
	for _, entry in found do
		table.insert(ids, entry.id)
	end
	return ids
end

-- Everything within `radius` of (x, z).
function Targeting.inRadius(points: { Point }, x: number, z: number, radius: number): { number }
	local found = {}
	local limit = radius * radius
	for _, point in points do
		local distance = distanceSquared(point, x, z)
		if distance <= limit then
			table.insert(found, { id = point.id, distance = distance })
		end
	end
	return sorted(found)
end

-- Everything within `range` of the origin that lies inside a cone facing
-- `angle`, `cone` wide in total (both in Angle units). A point on the origin counts.
function Targeting.inCone(
	points: { Point },
	originX: number,
	originZ: number,
	angle: number,
	cone: number,
	range: number
): { number }
	local facingX, facingZ = Angle.direction(angle)
	local minimumDot = Angle.cos(cone // 2)
	local limit = range * range

	local found = {}
	for _, point in points do
		local distance = distanceSquared(point, originX, originZ)
		if distance > limit then
			continue
		end

		if distance > 0 then
			local length = math.sqrt(distance)
			local dot = ((point.x - originX) * facingX + (point.z - originZ) * facingZ) / length
			if dot < minimumDot then
				continue
			end
		end
		table.insert(found, { id = point.id, distance = distance })
	end
	return sorted(found)
end

-- Everything within `halfWidth` of the segment from (ax, az) to (bx, bz): the
-- path of a dash. Closest to the start first.
function Targeting.inSegment(
	points: { Point },
	ax: number,
	az: number,
	bx: number,
	bz: number,
	halfWidth: number
): { number }
	local sx, sz = bx - ax, bz - az
	local lengthSquared = sx * sx + sz * sz
	local limit = halfWidth * halfWidth

	local found = {}
	for _, point in points do
		local t = 0
		if lengthSquared > 0 then
			t = math.clamp(((point.x - ax) * sx + (point.z - az) * sz) / lengthSquared, 0, 1)
		end
		local dx, dz = point.x - (ax + sx * t), point.z - (az + sz * t)
		if dx * dx + dz * dz <= limit then
			table.insert(found, { id = point.id, distance = distanceSquared(point, ax, az) })
		end
	end
	return sorted(found)
end

-- The closest point to (x, z), within `maxDistance` when given.
function Targeting.nearest(points: { Point }, x: number, z: number, maxDistance: number?): number?
	local limit = if maxDistance then maxDistance * maxDistance else math.huge

	local best: Point? = nil
	local bestDistance = limit
	for _, point in points do
		local distance = distanceSquared(point, x, z)
		if distance <= bestDistance and (best == nil or distance < bestDistance or point.id < best.id) then
			best = point
			bestDistance = distance
		end
	end
	return if best then best.id else nil
end

-- The aim snap: the closest point to where the cursor is, within `snapRadius`.
function Targeting.nearestToPoint(points: { Point }, pointX: number, pointZ: number, snapRadius: number): number?
	return Targeting.nearest(points, pointX, pointZ, snapRadius)
end

return Targeting
