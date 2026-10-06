--!strict

--[=[
	Step 4 of act generation: where the enemies stand.

	Camps are packs of enemies placed from the seed, so the server and every
	client agree on them (angles come from core/Angle, not libm). First the points of interest get guards (the
	teleporter always, chests and statues by chance), then the rest are
	scattered over walkable ground. Camps stay a few cells from the spawn and
	from each other. The farther a camp is from the spawn, the bigger and
	nastier its pack (see ActTypes.CampTier).

	An enemy that would stand on a tile nobody can walk on, or that can't be
	reached on foot from the spawn (an island in a pond), is left out.
]=]

local ActTypes = require("@Features/world/modules/ActTypes")
local Angle = require("@Core/Angle")
local Rng = require("@Core/Rng")

type ActDef = ActTypes.ActDef
type Camp = ActTypes.Camp
type CampMember = ActTypes.CampMember
type CampSpec = ActTypes.CampSpec
type CampTier = ActTypes.CampTier
type Poi = ActTypes.Poi

local DX = { 0, 1, 0, -1 }
local DY = { -1, 0, 1, 0 }
local TRIES_PER_CAMP = 30
local GUARD_TRIES = 12
-- Enemies of a camp keep at least this far from its centre.
local MIN_RADIUS = 1.5

local Populate = {}

local function tierFor(spec: CampSpec, distance: number): CampTier
	for _, tier in spec.tiers do
		if distance <= tier.upTo then
			return tier
		end
	end
	return spec.tiers[#spec.tiers]
end

function Populate.camps(
	def: ActDef,
	tileSet: ActTypes.TileSet,
	tiles: { number },
	pois: { Poi },
	rng: Rng.Rng
): { Camp }
	local spec = def.camps
	local camps: { Camp } = {}
	if spec == nil or #spec.tiers == 0 then
		return camps
	end

	local spawn = pois[1]
	local tileSize = def.tileSize

	local function walkable(x: number, y: number): boolean
		if x < 0 or y < 0 or x >= def.width or y >= def.height then
			return false
		end
		local variant = tileSet.variants[tiles[y * def.width + x + 1]]
		return variant ~= nil and variant.walkable
	end

	-- Every tile that can be walked to from the spawn.
	local reached: { [number]: boolean } = {}
	local queue = { spawn.cx, spawn.cy }
	reached[spawn.cy * def.width + spawn.cx + 1] = true
	local head = 1
	while head <= #queue do
		local x, y = queue[head], queue[head + 1]
		head += 2
		for direction = 1, 4 do
			local nx, ny = x + DX[direction], y + DY[direction]
			local index = ny * def.width + nx + 1
			if walkable(nx, ny) and not reached[index] then
				reached[index] = true
				table.insert(queue, nx)
				table.insert(queue, ny)
			end
		end
	end

	-- A tile an enemy may stand on: reachable, and not one of the plazas.
	local function standable(x: number, y: number): boolean
		return walkable(x, y)
			and reached[y * def.width + x + 1] == true
			and tiles[y * def.width + x + 1] ~= tileSet.plaza
	end

	-- Tries to put a camp on the tile (tx, ty). Always uses the same random
	-- numbers for the same inputs, so a failed try doesn't shift later ones.
	local function tryAdd(tx: number, ty: number, bonus: number): boolean
		if not standable(tx, ty) then
			return false
		end

		local centerX, centerY = tx + 0.5, ty + 0.5
		local fromSpawnX, fromSpawnY = centerX - (spawn.x + spawn.w / 2), centerY - (spawn.y + spawn.h / 2)
		local distance = math.sqrt(fromSpawnX * fromSpawnX + fromSpawnY * fromSpawnY)
		if distance < spec.minFromSpawn then
			return false
		end

		for _, other in camps do
			local dx, dy = other.x - centerX, other.y - centerY
			if dx * dx + dy * dy < spec.minApart * spec.minApart then
				return false
			end
		end

		local tier = tierFor(spec, distance)
		local weights: { number } = {}
		for index, entry in tier.entries do
			weights[index] = entry.weight
		end

		local size = Rng.int(rng, tier.minSize, tier.maxSize) + bonus
		local enemies: { CampMember } = {}
		for _ = 1, size do
			local angle = math.floor(Rng.next(rng) * Angle.TURN)
			local radius = MIN_RADIUS + Rng.next(rng) * math.max(0, spec.radius - MIN_RADIUS)
			local sine, cosine = Angle.direction(angle)
			local dx, dz = sine * radius, cosine * radius
			local defId = tier.entries[Rng.weighted(rng, weights)].defId

			if standable(math.floor(centerX + dx / tileSize), math.floor(centerY + dz / tileSize)) then
				table.insert(enemies, { defId = defId, dx = dx, dz = dz })
			end
		end

		if #enemies == 0 then
			return false
		end

		table.insert(camps, { id = `camp_{#camps + 1}`, x = centerX, y = centerY, enemies = enemies })
		return true
	end

	-- Guards: a ring a few cells around a point of interest.
	local chances: { [string]: number } = {}
	for _, guard in spec.guards do
		chances[guard.kind] = guard.chance
	end
	for _, poi in pois do
		local chance = chances[poi.kind]
		if chance and Rng.next(rng) < chance then
			for _ = 1, GUARD_TRIES do
				local angle = math.floor(Rng.next(rng) * Angle.TURN)
				local reach = poi.w / 2 + 2 + Rng.next(rng) * 2
				local sine, cosine = Angle.direction(angle)
				local tx = math.floor(poi.x + poi.w / 2 + sine * reach)
				local ty = math.floor(poi.y + poi.h / 2 + cosine * reach)
				if tryAdd(tx, ty, spec.guardBonus) then
					break
				end
			end
		end
	end

	-- The rest, anywhere there is room.
	local scattered = 0
	for _ = 1, spec.count * TRIES_PER_CAMP do
		if scattered >= spec.count then
			break
		end
		local tx, ty = Rng.int(rng, 0, def.width - 1), Rng.int(rng, 0, def.height - 1)
		if tryAdd(tx, ty, 0) then
			scattered += 1
		end
	end

	return camps
end

return Populate
