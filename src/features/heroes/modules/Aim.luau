--!strict

--[=[
	Aiming maths on plain numbers, so Lune can test it. This is for the client,
	which turns the cursor into an aim: angles are radians, 0 faces +Z and the
	direction of angle a is (sin a, cos a). The aim travels to the server as
	an `Angle` unit in the hero's input, so nothing here has to be deterministic.
	The server finds angles with `Angle.between`.
]=]

local Targeting = require("@Features/combat/modules/Targeting")

local Aim = {}

export type Resolved = {
	angle: number,
	-- The enemy the aim snapped to, if any.
	targetId: number?,
}

-- A ray that only meets the plane this far away (in ray lengths) is as good as level.
local MAX_REACH = 10000

-- Where a ray hits the horizontal plane at height `planeY`: the point under
-- the cursor. nil when the ray doesn't reach it (pointing level or upwards, the
-- plane is behind the origin, or it is further than MAX_REACH ray lengths away).
function Aim.groundPoint(
	originX: number,
	originY: number,
	originZ: number,
	directionX: number,
	directionY: number,
	directionZ: number,
	planeY: number
): (number?, number?)
	if directionY == 0 or directionY ~= directionY then
		return nil, nil
	end

	local t = (planeY - originY) / directionY
	if t ~= t or t < 0 or t > MAX_REACH then
		return nil, nil
	end
	return originX + directionX * t, originZ + directionZ * t
end

-- The angle from one point to another, or nil when they are the same point.
function Aim.angleTo(fromX: number, fromZ: number, toX: number, toZ: number): number?
	local dx, dz = toX - fromX, toZ - fromZ
	if dx == 0 and dz == 0 then
		return nil
	end
	return math.atan2(dx, dz)
end

-- Turns the point under the cursor into an aim: if an enemy is within
-- `snapRadius` of the point the hero aims at it, so a click close to an enemy
-- doesn't miss because of perspective. nil when the hero is standing on the point.
function Aim.resolve(
	enemies: { Targeting.Point },
	heroX: number,
	heroZ: number,
	pointX: number,
	pointZ: number,
	snapRadius: number
): Resolved?
	local targetId = Targeting.nearestToPoint(enemies, pointX, pointZ, snapRadius)
	if targetId then
		for _, enemy in enemies do
			if enemy.id == targetId then
				local snapped = Aim.angleTo(heroX, heroZ, enemy.x, enemy.z)
				if snapped then
					return { angle = snapped, targetId = targetId }
				end
			end
		end
	end

	local angle = Aim.angleTo(heroX, heroZ, pointX, pointZ)
	if angle == nil then
		return nil
	end
	return { angle = angle, targetId = nil }
end

return Aim
