--!strict

--[=[
	Enemies, as part of the simulation. Enemies are plain data, not Instances:
	they follow a flow field (see NavGrid, FlowField) towards the nearest hero
	and attack. Time counts in ticks and positions only change through `step`.

	Every attack has a telegraph: the enemy stands still for a short wind-up
	(the client shows it) and only then does the damage, and only if the hero
	is still in reach.

	Each enemy is also a CombatSim entity (its `body`) and shares its id, so
	damage, death and hit effects all go through combat. A kill is handled by
	whoever steps the sim, which asks `onDeath` to take the enemy out.

	Enemies placed at generation come in groups (a camp). A group stands idle
	until a hero comes close or something hurts one of its members, and then
	the whole group wakes up at once.

	A SpatialHash of the enemies' positions keeps crowd separation and the
	heroes' area attacks from checking every pair (`near`).

	The Siege Golem boss is a StateMachine: Chase (it also hits up close),
	Slam (a telegraphed area attack) and Summon.
]=]

local Angle = require("@Core/Angle")
local Checksum = require("@Features/sim/modules/Checksum")
local CombatSim = require("@Features/combat/modules/CombatSim")
local EnemyDefs = require("@Features/enemies/modules/EnemyDefs")
local EnemySnapshot = require("@Features/enemies/modules/EnemySnapshot")
local FlowField = require("@Features/enemies/modules/FlowField")
local Log = require("@Core/Log")
local NavGrid = require("@Features/enemies/modules/NavGrid")
local SimClock = require("@Features/sim/modules/SimClock")
local SimContext = require("@Features/sim/modules/SimContext")
local SpatialHash = require("@Core/SpatialHash")
local StateMachine = require("@Core/StateMachine")
local Targeting = require("@Features/combat/modules/Targeting")

type EnemyDef = EnemyDefs.EnemyDef

export type Enemy = {
	body: CombatSim.Entity,
	def: EnemyDef,
	-- Which way it faces, in Angle units.
	angle: number,
	-- Ticks: the enemy is stunned until stunUntil, winding up until telegraphUntil (0: not).
	stunUntil: number,
	telegraphUntil: number,
	nextAttackAt: number,
	-- The wind-up in progress is the boss's slam.
	slamming: boolean,
	-- What the difficulty was when it spawned.
	damageScale: number,
	-- The camp it belongs to: idle until the group wakes. Nil for enemies that always hunt.
	group: string?,
	-- Fixes what it drops (see LootSim).
	lootSeed: number,
}

type Projectile = {
	x: number,
	z: number,
	dx: number,
	dz: number,
	speed: number,
	life: number,
	radius: number,
	damage: number,
	ownerId: number,
}

type BossContext = {
	enemy: Enemy,
	machine: StateMachine.Machine<BossContext>?,
	nextSlamAt: number,
	nextSummonAt: number,
	slamEndsAt: number,
	-- What the boss states work on: set at the start of every step.
	sim: State?,
	combat: CombatSim.State?,
	ctx: SimContext.Ctx?,
	heroes: { Targeting.Point },
}

type FlowEntry = { cx: number, cy: number, field: FlowField.Field }

export type State = {
	-- In spawn order.
	enemies: { Enemy },
	byId: { [number]: Enemy },
	aliveCount: number,
	projectiles: { Projectile },
	-- By enemy id; only looked up.
	bosses: { [number]: BossContext },
	bossId: number?,
	-- The boss HP last reported, so a change is reported once.
	bossHp: number?,
	-- Groups that have woken up. Only looked up.
	wokenGroups: { [string]: boolean },
	grid: NavGrid.Grid?,
	-- Applied to enemies as they spawn: the run's difficulty.
	hpScale: number,
	damageScale: number,
	-- By hero entity id: derived from the grid, not part of the state proper.
	flowFields: { [number]: FlowEntry },
	pendingSpawns: { { defId: string, x: number, z: number } },
	hash: SpatialHash.Hash,
	-- The hash lists an enemy that was removed: rebuild before using it.
	hashStale: boolean,
}

-- Enemies alive at once. The boss doesn't count towards it.
local MAX_ALIVE = 80
-- Heroes further away than this are ignored.
local ACQUIRE_RANGE = 90
-- How far along a path a hero's flow field reaches, in studs. An enemy further
-- than that walks straight at the hero until it is within reach.
local PATH_RANGE = 2 * ACQUIRE_RANGE
-- An idle group wakes when a hero comes this close to one of its members.
local WAKE_RANGE = 30
-- How hard crowding pushes enemies apart, in studs per second.
local SEPARATION_SPEED = 6
-- A ranged enemy still fires if the hero is within this much more than its range
-- when the wind-up ends (the shot can be dodged). A melee hit needs the hero in
-- range: anything more lands hits the player sees from a distance.
local RANGED_LENIENCY = 1.3
local BOSS_SLAM_DAMAGE_FACTOR = 2
-- The biggest enemy radius, so a separation query reaches every enemy that can touch.
local MAX_RADIUS = 4
-- Two radii: one cell is that big, so a query only looks at a few cells.
local CELL_SIZE = 2 * MAX_RADIUS

local DT = SimClock.TICK

local EnemySim = {}

EnemySim.MAX_ALIVE = MAX_ALIVE

function EnemySim.new(): State
	return {
		enemies = {},
		byId = {},
		aliveCount = 0,
		projectiles = {},
		bosses = {},
		bossId = nil,
		bossHp = nil,
		wokenGroups = {},
		grid = nil,
		hpScale = 1,
		damageScale = 1,
		flowFields = {},
		pendingSpawns = {},
		hash = SpatialHash.new(CELL_SIZE),
		hashStale = false,
	}
end

-- Scratch lists for queries: emptied before every use, never kept.
local nearIds: { number } = {}

local function rebuildHash(sim: State)
	SpatialHash.clear(sim.hash)
	for _, enemy in sim.enemies do
		SpatialHash.insert(sim.hash, enemy.body.id, enemy.body.x, enemy.body.z)
	end
	sim.hashStale = false
end

local function isIdle(sim: State, enemy: Enemy): boolean
	local group = enemy.group
	return group ~= nil and not sim.wokenGroups[group]
end

-- The living enemies within `radius` of (x, z), as points for Targeting.
function EnemySim.near(sim: State, x: number, z: number, radius: number): { Targeting.Point }
	if sim.hashStale then
		rebuildHash(sim)
	end
	table.clear(nearIds)
	SpatialHash.query(sim.hash, x, z, radius, nearIds)

	local points: { Targeting.Point } = {}
	for _, id in nearIds do
		local enemy = sim.byId[id]
		if enemy and not enemy.body.dead then
			table.insert(points, { id = id, x = enemy.body.x, z = enemy.body.z })
		end
	end
	return points
end

local function flowFor(sim: State, heroId: number, hx: number, hz: number): FlowField.Field?
	local grid = sim.grid
	if grid == nil then
		return nil
	end

	local cx, cy = NavGrid.cellOf(grid, hx, hz)
	if cx == nil or cy == nil then
		return nil
	end

	local entry = sim.flowFields[heroId]
	local maxSteps = math.ceil(PATH_RANGE / grid.cellSize)
	if entry == nil then
		entry = { cx = cx, cy = cy, field = FlowField.build(grid, cx, cy, maxSteps) }
		sim.flowFields[heroId] = entry
	elseif entry.cx ~= cx or entry.cy ~= cy then
		-- Rebuilt in place: only the area the last build reached is reset.
		entry.cx, entry.cy = cx, cy
		FlowField.build(grid, cx, cy, maxSteps, entry.field)
	end
	return entry.field
end

-- Moves an enemy by (dx, dz), sliding along walls: a step into an unwalkable
-- cell is tried on each axis on its own.
local function move(sim: State, enemy: Enemy, dx: number, dz: number)
	local body = enemy.body
	local grid = sim.grid
	if grid == nil then
		body.x += dx
		body.z += dz
		return
	end

	if NavGrid.walkableAt(grid, body.x + dx, body.z + dz) then
		body.x += dx
		body.z += dz
	elseif NavGrid.walkableAt(grid, body.x + dx, body.z) then
		body.x += dx
	elseif NavGrid.walkableAt(grid, body.x, body.z + dz) then
		body.z += dz
	end
end

-- Pushes away from every enemy that is too close, so a crowd spreads out.
-- Others are read where they were at the start of the step, so the order
-- enemies are stepped in doesn't matter.
local function separation(sim: State, enemy: Enemy): (number, number)
	local body = enemy.body
	local px, pz = 0, 0
	table.clear(nearIds)
	SpatialHash.query(sim.hash, body.x, body.z, enemy.def.radius + MAX_RADIUS, nearIds)

	for _, otherId in nearIds do
		local other = sim.byId[otherId]
		if other == nil or other == enemy then
			continue
		end

		local dx, dz = body.x - sim.hash.xs[otherId], body.z - sim.hash.zs[otherId]
		local reach = enemy.def.radius + other.def.radius
		local distanceSquared = dx * dx + dz * dz
		if distanceSquared < reach * reach then
			local distance = math.sqrt(distanceSquared)
			if distance < 1e-3 then
				-- On the same spot: any direction will do, but the same one every time.
				px += (body.id % 2 == 0 and 1 or -1)
			else
				local push = (reach - distance) / reach
				px += dx / distance * push
				pz += dz / distance * push
			end
		end
	end
	return px, pz
end

-- Steps towards a hero along the flow field (or straight at it without one).
local function walkTowards(sim: State, enemy: Enemy, hero: Targeting.Point, speed: number)
	local body = enemy.body
	local dx, dz = 0, 0
	local field = flowFor(sim, hero.id, hero.x, hero.z)
	if field and sim.grid then
		dx, dz = FlowField.direction(sim.grid, field, body.x, body.z)
	end
	if dx == 0 and dz == 0 then
		local toX, toZ = hero.x - body.x, hero.z - body.z
		local length = math.sqrt(toX * toX + toZ * toZ)
		if length > 1e-3 then
			dx, dz = toX / length, toZ / length
		end
	end

	local sx, sz = separation(sim, enemy)
	move(sim, enemy, (dx * speed + sx * SEPARATION_SPEED) * DT, (dz * speed + sz * SEPARATION_SPEED) * DT)
end

-- Steps straight away from a hero.
local function walkAway(sim: State, enemy: Enemy, hero: Targeting.Point, speed: number)
	local body = enemy.body
	local awayX, awayZ = body.x - hero.x, body.z - hero.z
	local length = math.sqrt(awayX * awayX + awayZ * awayZ)
	if length > 1e-3 then
		move(sim, enemy, awayX / length * speed * DT, awayZ / length * speed * DT)
	end
end

local function faceTowards(enemy: Enemy, hero: Targeting.Point)
	local angle = Angle.between(enemy.body.x, enemy.body.z, hero.x, hero.z)
	if angle then
		enemy.angle = angle
	end
end

local function pointOf(heroes: { Targeting.Point }, id: number?): Targeting.Point?
	for _, hero in heroes do
		if hero.id == id then
			return hero
		end
	end
	return nil
end

local function fireProjectile(sim: State, ctx: SimContext.Ctx, enemy: Enemy, hero: Targeting.Point)
	local def = enemy.def
	local body = enemy.body
	local angle = Angle.between(body.x, body.z, hero.x, hero.z) or enemy.angle
	local dx, dz = Angle.direction(angle)
	local speed, life = def.projectileSpeed or 40, def.projectileLife or 1

	table.insert(sim.projectiles, {
		x = body.x,
		z = body.z,
		dx = dx,
		dz = dz,
		speed = speed,
		life = life,
		radius = def.projectileRadius or 1.5,
		damage = def.damage * enemy.damageScale,
		ownerId = body.id,
	})
	SimContext.emit(ctx, {
		kind = "projectile",
		x = body.x,
		z = body.z,
		vx = dx * speed,
		vz = dz * speed,
		life = life,
	})
end

-- The wind-up is over: the attack happens now.
local function resolveAttack(
	sim: State,
	combat: CombatSim.State,
	ctx: SimContext.Ctx,
	enemy: Enemy,
	heroes: { Targeting.Point }
)
	local def = enemy.def
	local body = enemy.body
	local reach = if def.behaviour == "ranged" then def.attackRange * RANGED_LENIENCY else def.attackRange
	local nearest = Targeting.nearest(heroes, body.x, body.z, reach)
	if nearest == nil then
		return
	end

	if def.behaviour == "ranged" then
		local hero = pointOf(heroes, nearest)
		if hero then
			fireProjectile(sim, ctx, enemy, hero)
		end
	else
		CombatSim.applyDamage(combat, ctx, body.id, nearest, def.damage * enemy.damageScale, "physical", false)
	end
end

-- What a chaser, a ranged enemy and a boss between special attacks all do.
local function stepFighter(
	sim: State,
	combat: CombatSim.State,
	ctx: SimContext.Ctx,
	enemy: Enemy,
	target: Targeting.Point?,
	heroes: { Targeting.Point }
)
	local def = enemy.def
	local body = enemy.body
	local now = ctx.tick

	if enemy.telegraphUntil > 0 then
		if target then
			faceTowards(enemy, target)
		end
		if now >= enemy.telegraphUntil then
			enemy.telegraphUntil = 0
			enemy.nextAttackAt = now + SimClock.ticks(def.attackCooldown)
			resolveAttack(sim, combat, ctx, enemy, heroes)
		end
		return
	end

	if target == nil then
		return
	end

	faceTowards(enemy, target)
	local dx, dz = target.x - body.x, target.z - body.z
	local distance = math.sqrt(dx * dx + dz * dz)
	local ready = now >= enemy.nextAttackAt

	if def.behaviour == "ranged" then
		local preferred = def.preferredRange or 20
		if ready and distance <= def.attackRange then
			enemy.telegraphUntil = now + SimClock.ticks(def.telegraph)
		elseif distance > preferred then
			walkTowards(sim, enemy, target, def.speed)
		elseif distance < preferred * 0.6 then
			walkAway(sim, enemy, target, def.speed)
		end
	else
		if distance <= def.attackRange then
			if ready then
				enemy.telegraphUntil = now + SimClock.ticks(def.telegraph)
			end
		else
			walkTowards(sim, enemy, target, def.speed)
		end
	end
end

local function createBossMachine(context: BossContext): StateMachine.Machine<BossContext>
	local Chase: StateMachine.State<BossContext> = StateMachine.state({
		name = "Chase",
		update = function(boss: BossContext, _dt: number)
			local sim, combat, ctx = boss.sim :: State, boss.combat :: CombatSim.State, boss.ctx :: SimContext.Ctx
			local enemy = boss.enemy
			local def = enemy.def
			local body = enemy.body
			local nearest = Targeting.nearest(boss.heroes, body.x, body.z, ACQUIRE_RANGE)
			local target = pointOf(boss.heroes, nearest)

			stepFighter(sim, combat, ctx, enemy, target, boss.heroes)

			-- Never interrupt a melee wind-up already under way.
			if enemy.telegraphUntil > 0 or target == nil or boss.machine == nil then
				return
			end

			local slamRadius = def.slamRadius or 16
			local dx, dz = target.x - body.x, target.z - body.z
			if ctx.tick >= boss.nextSlamAt and dx * dx + dz * dz <= slamRadius * slamRadius * 0.81 then
				StateMachine.send(boss.machine, "Slam")
			elseif ctx.tick >= boss.nextSummonAt then
				StateMachine.send(boss.machine, "Summon")
			end
		end,
	} :: StateMachine.State<BossContext>)

	local Slam: StateMachine.State<BossContext> = StateMachine.state({
		name = "Slam",
		enter = function(boss: BossContext)
			local enemy = boss.enemy
			local ctx = boss.ctx :: SimContext.Ctx
			boss.slamEndsAt = ctx.tick + SimClock.ticks(enemy.def.slamTelegraph or 1)
			enemy.telegraphUntil = boss.slamEndsAt
			enemy.slamming = true
		end,
		update = function(boss: BossContext, _dt: number)
			local combat, ctx = boss.combat :: CombatSim.State, boss.ctx :: SimContext.Ctx
			if ctx.tick < boss.slamEndsAt or boss.machine == nil then
				return
			end

			local enemy = boss.enemy
			local def = enemy.def
			local victims = Targeting.inRadius(boss.heroes, enemy.body.x, enemy.body.z, def.slamRadius or 16)
			for _, heroId in victims do
				CombatSim.applyDamage(
					combat,
					ctx,
					enemy.body.id,
					heroId,
					def.damage * BOSS_SLAM_DAMAGE_FACTOR * enemy.damageScale,
					"physical",
					false
				)
			end

			boss.nextSlamAt = ctx.tick + SimClock.ticks(def.slamCooldown or 7)
			StateMachine.send(boss.machine, "Done")
		end,
		exit = function(boss: BossContext)
			local ctx = boss.ctx :: SimContext.Ctx
			boss.enemy.telegraphUntil = 0
			boss.enemy.slamming = false
			boss.enemy.nextAttackAt = ctx.tick + SimClock.ticks(1)
		end,
	} :: StateMachine.State<BossContext>)

	local Summon: StateMachine.State<BossContext> = StateMachine.state({
		name = "Summon",
		enter = function(boss: BossContext)
			local sim, ctx = boss.sim :: State, boss.ctx :: SimContext.Ctx
			local enemy = boss.enemy
			local def = enemy.def
			local count = def.summonCount or 3
			for index = 1, count do
				-- A ring around the boss, outside its body.
				local angle = (index - 1) * Angle.TURN // count
				local dx, dz = Angle.direction(angle)
				local reach = def.radius + 6
				table.insert(sim.pendingSpawns, {
					defId = def.summonDef or "grunt",
					x = enemy.body.x + dx * reach,
					z = enemy.body.z + dz * reach,
				})
			end
			boss.nextSummonAt = ctx.tick + SimClock.ticks(def.summonCooldown or 14)
			if boss.machine then
				StateMachine.send(boss.machine, "Done")
			end
		end,
	} :: StateMachine.State<BossContext>)

	local machine = StateMachine.create({
		initial = Chase,
		states = { Chase, Slam, Summon },
		transitions = {
			{ from = Chase, to = Slam, event = "Slam" },
			{ from = Chase, to = Summon, event = "Summon" },
			{ from = Slam, to = Chase, event = "Done" },
			{ from = Summon, to = Chase, event = "Done" },
		},
		context = context,
	})
	context.machine = machine
	return machine
end

local function stepProjectiles(sim: State, combat: CombatSim.State, ctx: SimContext.Ctx, heroes: { Targeting.Point })
	local kept: { Projectile } = {}
	for _, projectile in sim.projectiles do
		projectile.x += projectile.dx * projectile.speed * DT
		projectile.z += projectile.dz * projectile.speed * DT
		projectile.life -= DT

		local gone = projectile.life <= 0
		if not gone then
			local hit = Targeting.nearest(heroes, projectile.x, projectile.z, projectile.radius + 1)
			if hit then
				CombatSim.applyDamage(combat, ctx, projectile.ownerId, hit, projectile.damage, "physical", false)
				gone = true
			end
		end

		if not gone then
			table.insert(kept, projectile)
		end
	end
	sim.projectiles = kept
end

-- Spawns an enemy at a world position and returns it, or nil at the cap (the
-- boss ignores it) or for an unknown def. An enemy with a `group` stands idle
-- until that group wakes (see wakeGroup). Without a `lootSeed` it takes the
-- next one of the run's loot stream.
function EnemySim.spawn(
	sim: State,
	combat: CombatSim.State,
	ctx: SimContext.Ctx,
	defId: string,
	x: number,
	z: number,
	group: string?,
	lootSeed: number?
): Enemy?
	local def = EnemyDefs.get(defId)
	if def == nil then
		Log.warn(`Unknown enemy {defId}`)
		return nil
	end
	if def.behaviour ~= "boss" and sim.aliveCount >= MAX_ALIVE then
		return nil
	end

	local body = CombatSim.register(combat, ctx, "enemy", math.floor(def.maxHp * sim.hpScale + 0.5), def.armor, x, z)
	local enemy: Enemy = {
		body = body,
		def = def,
		angle = 0,
		stunUntil = 0,
		telegraphUntil = 0,
		-- A fresh enemy waits a moment before its first attack.
		nextAttackAt = ctx.tick + SimClock.ticks(0.5),
		slamming = false,
		damageScale = sim.damageScale,
		group = group,
		lootSeed = lootSeed or SimContext.nextSeed(ctx),
	}
	sim.enemies[#sim.enemies + 1] = enemy
	sim.byId[body.id] = enemy
	sim.aliveCount += 1
	if sim.hashStale then
		rebuildHash(sim)
	end
	SpatialHash.insert(sim.hash, body.id, x, z)

	if def.behaviour == "boss" then
		local context: BossContext = {
			enemy = enemy,
			machine = nil,
			nextSlamAt = ctx.tick + SimClock.ticks(4),
			nextSummonAt = ctx.tick + SimClock.ticks((def.summonCooldown or 14) * 0.5),
			slamEndsAt = 0,
			sim = nil,
			combat = nil,
			ctx = nil,
			heroes = {},
		}
		createBossMachine(context)
		sim.bosses[body.id] = context
		sim.bossId = body.id
		sim.bossHp = nil
	end

	SimContext.emit(ctx, { kind = "spawn", id = body.id, def = EnemyDefs.indexOf(def.id) :: number })
	return enemy
end

local function removeEnemy(sim: State, combat: CombatSim.State, ctx: SimContext.Ctx, enemy: Enemy)
	local id = enemy.body.id
	if sim.byId[id] == nil then
		return
	end

	sim.byId[id] = nil
	local index = table.find(sim.enemies, enemy)
	if index then
		table.remove(sim.enemies, index)
	end
	sim.aliveCount -= 1
	sim.bosses[id] = nil
	if sim.bossId == id then
		sim.bossId = nil
		sim.bossHp = nil
	end
	sim.hashStale = true
	CombatSim.unregister(combat, id)
	SimContext.emit(ctx, { kind = "despawn", id = id })
end

-- Takes a killed enemy out and returns it (for its loot and the run), or nil
-- when the entity wasn't an enemy of this sim.
function EnemySim.onDeath(sim: State, combat: CombatSim.State, ctx: SimContext.Ctx, id: number): Enemy?
	local enemy = sim.byId[id]
	if enemy then
		removeEnemy(sim, combat, ctx, enemy)
	end
	return enemy
end

function EnemySim.get(sim: State, id: number): Enemy?
	return sim.byId[id]
end

-- Removes every enemy and projectile without reporting kills (the act ended).
function EnemySim.despawnAll(sim: State, combat: CombatSim.State, ctx: SimContext.Ctx)
	local all = table.clone(sim.enemies)
	for _, enemy in all do
		removeEnemy(sim, combat, ctx, enemy)
	end
	table.clear(sim.projectiles)
	table.clear(sim.pendingSpawns)
	table.clear(sim.flowFields)
	table.clear(sim.wokenGroups)
end

-- Wakes every enemy of a group: they start hunting.
function EnemySim.wakeGroup(sim: State, group: string)
	sim.wokenGroups[group] = true
end

-- Stuns an enemy for `ticks` (never shortens an earlier stun). The boss shrugs it off.
function EnemySim.stun(sim: State, ctx: SimContext.Ctx, id: number, ticks: number)
	local enemy = sim.byId[id]
	if enemy == nil or enemy.body.dead or enemy.def.behaviour == "boss" then
		return
	end
	enemy.stunUntil = math.max(enemy.stunUntil, ctx.tick + ticks)
end

-- How many more enemies fit under the cap.
function EnemySim.capacity(sim: State): number
	return math.max(0, MAX_ALIVE - sim.aliveCount)
end

-- Where enemies may walk. nil allows walking anywhere.
function EnemySim.setNavGrid(sim: State, grid: NavGrid.Grid?)
	sim.grid = grid
	table.clear(sim.flowFields)
end

-- How much tougher enemies are from now on. Enemies already alive keep theirs.
function EnemySim.setScaling(sim: State, hpScale: number, damageScale: number)
	sim.hpScale = math.max(0.1, hpScale)
	sim.damageScale = math.max(0.1, damageScale)
end

-- Advances every enemy by one tick.
function EnemySim.step(sim: State, combat: CombatSim.State, ctx: SimContext.Ctx)
	local heroes = CombatSim.points(combat, "hero")
	local now = ctx.tick

	-- Forget flow fields of heroes that are gone.
	for heroId in sim.flowFields do
		if pointOf(heroes, heroId) == nil then
			sim.flowFields[heroId] = nil
		end
	end

	if sim.hashStale then
		rebuildHash(sim)
	end

	-- Idle groups wake when a hero comes close, or when one of them is hurt.
	for _, hero in heroes do
		table.clear(nearIds)
		SpatialHash.query(sim.hash, hero.x, hero.z, WAKE_RANGE, nearIds)
		for _, id in nearIds do
			local enemy = sim.byId[id]
			if enemy and enemy.group then
				sim.wokenGroups[enemy.group] = true
			end
		end
	end
	for _, enemy in sim.enemies do
		if enemy.group and enemy.body.hp < enemy.body.maxHp then
			sim.wokenGroups[enemy.group] = true
		end
	end

	for _, enemy in sim.enemies do
		if enemy.body.dead or isIdle(sim, enemy) then
			continue
		end

		if now < enemy.stunUntil then
			-- A stunned enemy loses its wind-up.
			enemy.telegraphUntil = 0
			continue
		end

		local boss = sim.bosses[enemy.body.id]
		if boss and boss.machine then
			boss.sim, boss.combat, boss.ctx, boss.heroes = sim, combat, ctx, heroes
			StateMachine.update(boss.machine, DT)
		else
			local body = enemy.body
			local nearest = Targeting.nearest(heroes, body.x, body.z, ACQUIRE_RANGE)
			stepFighter(sim, combat, ctx, enemy, pointOf(heroes, nearest), heroes)
		end
	end

	stepProjectiles(sim, combat, ctx, heroes)

	local spawns = sim.pendingSpawns
	sim.pendingSpawns = {}
	for _, request in spawns do
		EnemySim.spawn(sim, combat, ctx, request.defId, request.x, request.z)
	end

	-- Everything has moved: the hash is what the heroes' attacks see next step.
	rebuildHash(sim)

	local bossId = sim.bossId
	local boss = if bossId then CombatSim.get(combat, bossId) else nil
	if boss and boss.hp ~= sim.bossHp then
		sim.bossHp = boss.hp
		SimContext.emit(ctx, {
			kind = "bossHealth",
			hp = math.clamp(math.floor(boss.hp), 0, 65535),
			maxHp = math.clamp(math.floor(boss.maxHp), 0, 65535),
		})
	end
end

-- The snapshot entries for the clients: every enemy, in spawn order.
function EnemySim.snapshot(sim: State, ctx: SimContext.Ctx): { EnemySnapshot.Entry }
	local entries: { EnemySnapshot.Entry } = {}
	for _, enemy in sim.enemies do
		local flags = 0
		if enemy.telegraphUntil > ctx.tick then
			flags += EnemySnapshot.TELEGRAPHING
			if enemy.slamming then
				flags += EnemySnapshot.SLAM
			end
		end
		if enemy.stunUntil > ctx.tick then
			flags += EnemySnapshot.STUNNED
		end
		table.insert(
			entries,
			{ id = enemy.body.id, x = enemy.body.x, z = enemy.body.z, angle = enemy.angle, flags = flags }
		)
		if #entries >= EnemySnapshot.MAX_ENTRIES then
			break
		end
	end
	return entries
end

function EnemySim.checksum(hash: Checksum.Hash, sim: State)
	Checksum.section(hash, "enemies")
	for _, enemy in sim.enemies do
		Checksum.number(hash, enemy.body.id)
		Checksum.number(hash, EnemyDefs.indexOf(enemy.def.id) :: number)
		Checksum.number(hash, enemy.angle)
		Checksum.number(hash, enemy.stunUntil)
		Checksum.number(hash, enemy.telegraphUntil)
		Checksum.number(hash, enemy.nextAttackAt)
		Checksum.bool(hash, enemy.slamming)
		Checksum.number(hash, enemy.damageScale)
		Checksum.number(hash, enemy.lootSeed)
		Checksum.string(hash, enemy.group or "")
		local boss = sim.bosses[enemy.body.id]
		if boss then
			Checksum.number(hash, boss.nextSlamAt)
			Checksum.number(hash, boss.nextSummonAt)
			Checksum.number(hash, boss.slamEndsAt)
			Checksum.string(hash, if boss.machine then StateMachine.getState(boss.machine) else "")
		end
	end

	for _, projectile in sim.projectiles do
		Checksum.number(hash, projectile.x)
		Checksum.number(hash, projectile.z)
		Checksum.number(hash, projectile.life)
		Checksum.number(hash, projectile.ownerId)
	end

	local woken: { string } = {}
	for group in sim.wokenGroups do
		table.insert(woken, group)
	end
	table.sort(woken)
	for _, group in woken do
		Checksum.string(hash, group)
	end

	for _, request in sim.pendingSpawns do
		Checksum.string(hash, request.defId)
		Checksum.number(hash, request.x)
		Checksum.number(hash, request.z)
	end
	Checksum.number(hash, sim.hpScale)
	Checksum.number(hash, sim.damageScale)
end

return EnemySim
