--!strict

--[=[
	Enemies, server side: the simulation. Enemies are plain data, not
	Instances: no Humanoids, no physics, no parts. They tick at 20 Hz, follow a
	flow field (see NavGrid, FlowField) towards the nearest hero and attack.
	The clients get a compact snapshot 15 times a second and draw pooled models.

	Every attack has a telegraph: the enemy stands still for a short wind-up
	(the client shows it) and only then does the damage, and only if the hero
	is still in reach.

	Each enemy is also a CombatService entity and shares its id, so damage,
	death and hit effects all go through combat. The run feature spawns enemies
	here and listens for kills.

	The Siege Golem boss is a StateMachine: Chase (it also hits up close),
	Slam (a telegraphed area attack) and Summon.
]=]

local RunService = game:GetService("RunService")

local Aim = require("@Features/heroes/modules/Aim")
local CombatService = require("@Features/combat/CombatServiceServer")
local EnemyDefs = require("@Features/enemies/modules/EnemyDefs")
local EnemySnapshot = require("@Features/enemies/modules/EnemySnapshot")
local FlowField = require("@Features/enemies/modules/FlowField")
local Log = require("@Core/Log")
local NavGrid = require("@Features/enemies/modules/NavGrid")
local Network = require("@Core/Network")
local RateLimit = require("@Core/RateLimit")
local StateMachine = require("@Core/StateMachine")
local Targeting = require("@Features/combat/modules/Targeting")

local Packet = Network.Packet

type EnemyDef = EnemyDefs.EnemyDef

type Enemy = {
	id: number,
	def: EnemyDef,
	x: number,
	z: number,
	angle: number,
	-- os.clock() times.
	stunUntil: number,
	telegraphUntil: number,
	nextAttackAt: number,
	-- The wind-up in progress is the boss's slam.
	slamming: boolean,
	-- What the difficulty was when it spawned.
	damageScale: number,
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
}

type FlowEntry = { cx: number, cy: number, field: FlowField.Field }

local TICK = 1 / 20
local SNAPSHOT_INTERVAL = 1 / 15
-- Enemies alive at once. The boss doesn't count towards it.
local MAX_ALIVE = 40
-- Heroes further away than this are ignored.
local ACQUIRE_RANGE = 90
-- How hard crowding pushes enemies apart, in studs per second.
local SEPARATION_SPEED = 6
-- A telegraphed melee hit still lands if the hero is within this much more than the range.
local MELEE_LENIENCY = 1.3
local BOSS_SLAM_DAMAGE_FACTOR = 2

local EnemyService = {}

local network: Network.ServerNetwork

local enemies: { [number]: Enemy } = {}
local aliveCount = 0
local projectiles: { Projectile } = {}
local bosses: { [number]: BossContext } = {}
local bossId: number? = nil
local bossDirty = false

local navGrid: NavGrid.Grid? = nil
local groundY = 0
-- Applied to enemies as they spawn: the run's difficulty.
local hpScale = 1
local damageScale = 1
local flowFields: { [number]: FlowEntry } = {}

local killedCallbacks: { (enemyId: number, defId: string, x: number, z: number, sourceId: number?) -> () } = {}
local pendingSpawns: { { defId: string, x: number, z: number } } = {}

local requestLimit = RateLimit.new({ burst = 2, perSecond = 0.5 })

-- Set at the start of every tick, for the boss states.
local tickNow = 0
local tickHeroes: { Targeting.Point } = {}

local function sendBossHealth()
	local id = bossId
	local entity = if id then CombatService.get(id) else nil
	if entity then
		network:fireAllClients("onBossHealth", math.clamp(math.floor(entity.hp), 0, 65535), entity.maxHp)
	end
end

local function removeEnemy(enemy: Enemy)
	if enemies[enemy.id] == nil then
		return
	end

	enemies[enemy.id] = nil
	aliveCount -= 1
	bosses[enemy.id] = nil
	if bossId == enemy.id then
		bossId = nil
	end
	CombatService.unregister(enemy.id)
	network:fireAllClients("onDespawn", enemy.id)
end

local function onKilled(enemy: Enemy, sourceId: number?)
	removeEnemy(enemy)
	for _, callback in killedCallbacks do
		task.spawn(callback, enemy.id, enemy.def.id, enemy.x, enemy.z, sourceId)
	end
end

local function flowFor(heroId: number, hx: number, hz: number): FlowField.Field?
	local grid = navGrid
	if grid == nil then
		return nil
	end

	local cx, cy = NavGrid.cellOf(grid, hx, hz)
	if cx == nil or cy == nil then
		return nil
	end

	local entry = flowFields[heroId]
	if entry == nil or entry.cx ~= cx or entry.cy ~= cy then
		entry = { cx = cx, cy = cy, field = FlowField.build(grid, cx, cy) }
		flowFields[heroId] = entry
	end
	return entry.field
end

-- Moves an enemy by (dx, dz), sliding along walls: a step into an unwalkable
-- cell is tried on each axis on its own.
local function move(enemy: Enemy, dx: number, dz: number)
	local grid = navGrid
	if grid == nil then
		enemy.x += dx
		enemy.z += dz
		return
	end

	if NavGrid.walkableAt(grid, enemy.x + dx, enemy.z + dz) then
		enemy.x += dx
		enemy.z += dz
	elseif NavGrid.walkableAt(grid, enemy.x + dx, enemy.z) then
		enemy.x += dx
	elseif NavGrid.walkableAt(grid, enemy.x, enemy.z + dz) then
		enemy.z += dz
	end
end

-- Pushes away from every enemy that is too close, so a crowd spreads out.
local function separation(enemy: Enemy): (number, number)
	local px, pz = 0, 0
	for _, other in enemies do
		if other ~= enemy then
			local dx, dz = enemy.x - other.x, enemy.z - other.z
			local reach = enemy.def.radius + other.def.radius
			local distanceSquared = dx * dx + dz * dz
			if distanceSquared < reach * reach then
				local distance = math.sqrt(distanceSquared)
				if distance < 1e-3 then
					-- On the same spot: any direction will do, but the same one every time.
					px += (enemy.id % 2 == 0 and 1 or -1)
				else
					local push = (reach - distance) / reach
					px += dx / distance * push
					pz += dz / distance * push
				end
			end
		end
	end
	return px, pz
end

-- Steps towards a hero along the flow field (or straight at it without one).
local function walkTowards(enemy: Enemy, hero: Targeting.Point, speed: number, dt: number)
	local dx, dz = 0, 0
	local field = flowFor(hero.id, hero.x, hero.z)
	if field and navGrid then
		dx, dz = FlowField.direction(navGrid, field, enemy.x, enemy.z)
	end
	if dx == 0 and dz == 0 then
		local toX, toZ = hero.x - enemy.x, hero.z - enemy.z
		local length = math.sqrt(toX * toX + toZ * toZ)
		if length > 1e-3 then
			dx, dz = toX / length, toZ / length
		end
	end

	local sx, sz = separation(enemy)
	move(enemy, (dx * speed + sx * SEPARATION_SPEED) * dt, (dz * speed + sz * SEPARATION_SPEED) * dt)
end

-- Steps straight away from a hero.
local function walkAway(enemy: Enemy, hero: Targeting.Point, speed: number, dt: number)
	local awayX, awayZ = enemy.x - hero.x, enemy.z - hero.z
	local length = math.sqrt(awayX * awayX + awayZ * awayZ)
	if length > 1e-3 then
		move(enemy, awayX / length * speed * dt, awayZ / length * speed * dt)
	end
end

local function faceTowards(enemy: Enemy, hero: Targeting.Point)
	local angle = Aim.angleTo(enemy.x, enemy.z, hero.x, hero.z)
	if angle then
		enemy.angle = angle
	end
end

local function startTelegraph(enemy: Enemy, seconds: number, now: number)
	enemy.telegraphUntil = now + seconds
end

local function fireProjectile(enemy: Enemy, hero: Targeting.Point)
	local def = enemy.def
	local angle = Aim.angleTo(enemy.x, enemy.z, hero.x, hero.z) or enemy.angle
	local dx, dz = Targeting.direction(angle)
	local speed, life = def.projectileSpeed or 40, def.projectileLife or 1

	table.insert(projectiles, {
		x = enemy.x,
		z = enemy.z,
		dx = dx,
		dz = dz,
		speed = speed,
		life = life,
		radius = def.projectileRadius or 1.5,
		damage = def.damage * enemy.damageScale,
		ownerId = enemy.id,
	})
	network:fireAllClients(
		"onProjectile",
		Vector3.new(enemy.x, groundY, enemy.z),
		Vector3.new(dx * speed, 0, dz * speed),
		life
	)
end

-- The wind-up is over: the attack happens now.
local function resolveAttack(enemy: Enemy)
	local def = enemy.def
	if def.behaviour == "ranged" then
		local nearest = Targeting.nearest(tickHeroes, enemy.x, enemy.z, def.attackRange * MELEE_LENIENCY)
		for _, hero in tickHeroes do
			if hero.id == nearest then
				fireProjectile(enemy, hero)
			end
		end
	else
		local hit = Targeting.nearest(tickHeroes, enemy.x, enemy.z, def.attackRange * MELEE_LENIENCY)
		if hit then
			CombatService.applyDamage(enemy.id, hit, def.damage * enemy.damageScale, "physical", false)
		end
	end
end

-- What a chaser, a ranged enemy and a boss between special attacks all do.
local function stepFighter(enemy: Enemy, target: Targeting.Point?, dt: number)
	local def = enemy.def
	local now = tickNow

	if enemy.telegraphUntil > 0 then
		if target then
			faceTowards(enemy, target)
		end
		if now >= enemy.telegraphUntil then
			enemy.telegraphUntil = 0
			enemy.nextAttackAt = now + def.attackCooldown
			resolveAttack(enemy)
		end
		return
	end

	if target == nil then
		return
	end

	faceTowards(enemy, target)
	local dx, dz = target.x - enemy.x, target.z - enemy.z
	local distance = math.sqrt(dx * dx + dz * dz)
	local ready = now >= enemy.nextAttackAt

	if def.behaviour == "ranged" then
		local preferred = def.preferredRange or 20
		if ready and distance <= def.attackRange then
			startTelegraph(enemy, def.telegraph, now)
		elseif distance > preferred then
			walkTowards(enemy, target, def.speed, dt)
		elseif distance < preferred * 0.6 then
			walkAway(enemy, target, def.speed, dt)
		end
	else
		if distance <= def.attackRange then
			if ready then
				startTelegraph(enemy, def.telegraph, now)
			end
		else
			walkTowards(enemy, target, def.speed, dt)
		end
	end
end

local function createBossMachine(context: BossContext): StateMachine.Machine<BossContext>
	local Chase: StateMachine.State<BossContext> = StateMachine.state({
		name = "Chase",
		update = function(ctx: BossContext, dt: number)
			local enemy = ctx.enemy
			local def = enemy.def
			local now = tickNow
			local nearest = Targeting.nearest(tickHeroes, enemy.x, enemy.z, ACQUIRE_RANGE)
			local target: Targeting.Point? = nil
			for _, hero in tickHeroes do
				if hero.id == nearest then
					target = hero
				end
			end

			stepFighter(enemy, target, dt)

			-- Never interrupt a melee wind-up already under way.
			if enemy.telegraphUntil > 0 or target == nil or ctx.machine == nil then
				return
			end

			local slamRadius = def.slamRadius or 16
			local dx, dz = target.x - enemy.x, target.z - enemy.z
			if now >= ctx.nextSlamAt and dx * dx + dz * dz <= (slamRadius * 0.9) ^ 2 then
				StateMachine.send(ctx.machine, "Slam")
			elseif now >= ctx.nextSummonAt then
				StateMachine.send(ctx.machine, "Summon")
			end
		end,
	} :: StateMachine.State<BossContext>)

	local Slam: StateMachine.State<BossContext> = StateMachine.state({
		name = "Slam",
		enter = function(ctx: BossContext)
			local enemy = ctx.enemy
			ctx.slamEndsAt = tickNow + (enemy.def.slamTelegraph or 1)
			enemy.telegraphUntil = ctx.slamEndsAt
			enemy.slamming = true
		end,
		update = function(ctx: BossContext, _dt: number)
			if tickNow < ctx.slamEndsAt or ctx.machine == nil then
				return
			end

			local enemy = ctx.enemy
			local def = enemy.def
			local victims = Targeting.inRadius(tickHeroes, enemy.x, enemy.z, def.slamRadius or 16)
			for _, heroId in victims do
				CombatService.applyDamage(
					enemy.id,
					heroId,
					def.damage * BOSS_SLAM_DAMAGE_FACTOR * enemy.damageScale,
					"physical",
					false
				)
			end

			ctx.nextSlamAt = tickNow + (def.slamCooldown or 7)
			StateMachine.send(ctx.machine, "Done")
		end,
		exit = function(ctx: BossContext)
			ctx.enemy.telegraphUntil = 0
			ctx.enemy.slamming = false
			ctx.enemy.nextAttackAt = tickNow + 1
		end,
	} :: StateMachine.State<BossContext>)

	local Summon: StateMachine.State<BossContext> = StateMachine.state({
		name = "Summon",
		enter = function(ctx: BossContext)
			local enemy = ctx.enemy
			local def = enemy.def
			local count = def.summonCount or 3
			for index = 1, count do
				-- A ring around the boss, outside its body.
				local angle = (index / count) * math.pi * 2
				local dx, dz = Targeting.direction(angle)
				local reach = def.radius + 6
				table.insert(pendingSpawns, {
					defId = def.summonDef or "grunt",
					x = enemy.x + dx * reach,
					z = enemy.z + dz * reach,
				})
			end
			ctx.nextSummonAt = tickNow + (def.summonCooldown or 14)
			if ctx.machine then
				StateMachine.send(ctx.machine, "Done")
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

local function stepProjectiles(dt: number)
	local index = 1
	while index <= #projectiles do
		local projectile = projectiles[index]
		projectile.x += projectile.dx * projectile.speed * dt
		projectile.z += projectile.dz * projectile.speed * dt
		projectile.life -= dt

		local gone = projectile.life <= 0
		if not gone then
			local hit = Targeting.nearest(tickHeroes, projectile.x, projectile.z, projectile.radius + 1)
			if hit then
				CombatService.applyDamage(projectile.ownerId, hit, projectile.damage, "physical", false)
				gone = true
			end
		end

		if gone then
			table.remove(projectiles, index)
		else
			index += 1
		end
	end
end

local function tick(dt: number)
	tickNow = os.clock()
	tickHeroes = CombatService.points("hero")

	-- Forget flow fields of heroes that are gone.
	local present: { [number]: boolean } = {}
	for _, hero in tickHeroes do
		present[hero.id] = true
	end
	for heroId in flowFields do
		if not present[heroId] then
			flowFields[heroId] = nil
		end
	end

	for _, enemy in enemies do
		if tickNow < enemy.stunUntil then
			-- A stunned enemy loses its wind-up.
			enemy.telegraphUntil = 0
			continue
		end

		local boss = bosses[enemy.id]
		if boss and boss.machine then
			StateMachine.update(boss.machine, dt)
		else
			local nearest = Targeting.nearest(tickHeroes, enemy.x, enemy.z, ACQUIRE_RANGE)
			local target: Targeting.Point? = nil
			for _, hero in tickHeroes do
				if hero.id == nearest then
					target = hero
				end
			end
			stepFighter(enemy, target, dt)
		end
	end

	stepProjectiles(dt)

	local spawns = pendingSpawns
	pendingSpawns = {}
	for _, request in spawns do
		EnemyService.spawn(request.defId, request.x, request.z)
	end
end

local function sendSnapshot()
	local entries: { EnemySnapshot.Entry } = {}
	local now = os.clock()
	for _, enemy in enemies do
		local flags = 0
		if enemy.telegraphUntil > now then
			flags += EnemySnapshot.TELEGRAPHING
			if enemy.slamming then
				flags += EnemySnapshot.SLAM
			end
		end
		if enemy.stunUntil > now then
			flags += EnemySnapshot.STUNNED
		end
		table.insert(entries, { id = enemy.id, x = enemy.x, z = enemy.z, angle = enemy.angle, flags = flags })
		if #entries >= EnemySnapshot.MAX_ENTRIES then
			break
		end
	end

	if #entries > 0 then
		network:fireAllClientsUnreliable("onSnapshot", EnemySnapshot.encode(entries))
	end

	if bossDirty then
		bossDirty = false
		sendBossHealth()
	end
end

-- Spawns an enemy at a world position and returns its id, or nil at the cap
-- (the boss ignores it) or for an unknown def.
function EnemyService.spawn(defId: string, x: number, z: number): number?
	local def = EnemyDefs.get(defId)
	if def == nil then
		Log.warn(`Unknown enemy {defId}`)
		return nil
	end
	if def.behaviour ~= "boss" and aliveCount >= MAX_ALIVE then
		return nil
	end

	local enemy: Enemy = {
		id = 0,
		def = def,
		x = x,
		z = z,
		angle = 0,
		stunUntil = 0,
		telegraphUntil = 0,
		-- A fresh enemy waits a moment before its first attack.
		nextAttackAt = os.clock() + 0.5,
		slamming = false,
		damageScale = damageScale,
	}

	local id = CombatService.register({
		team = "enemy",
		maxHp = math.floor(def.maxHp * hpScale + 0.5),
		armor = def.armor,
		position = function()
			return Vector3.new(enemy.x, groundY, enemy.z)
		end,
		onDeath = function(_, sourceId)
			onKilled(enemy, sourceId)
		end,
		-- The boss shrugs stuns off.
		onStun = if def.behaviour == "boss"
			then nil
			else function(_, seconds)
				enemy.stunUntil = math.max(enemy.stunUntil, os.clock() + seconds)
			end,
	})
	enemy.id = id
	enemies[id] = enemy
	aliveCount += 1

	if def.behaviour == "boss" then
		local now = os.clock()
		local context: BossContext = {
			enemy = enemy,
			machine = nil,
			nextSlamAt = now + 4,
			nextSummonAt = now + (def.summonCooldown or 14) * 0.5,
			slamEndsAt = 0,
		}
		createBossMachine(context)
		bosses[id] = context
		bossId = id
		bossDirty = true
	end

	network:fireAllClients("onSpawn", id, EnemyDefs.indexOf(def.id) :: number)
	return id
end

-- Removes every enemy and projectile without reporting kills (the act ended).
function EnemyService.despawnAll()
	for _, enemy in enemies do
		removeEnemy(enemy)
	end
	table.clear(projectiles)
	table.clear(pendingSpawns)
	table.clear(flowFields)
end

function EnemyService.aliveCount(): number
	return aliveCount
end

-- Where enemies may walk, and the height they stand at. nil allows walking anywhere.
function EnemyService.setNavGrid(grid: NavGrid.Grid?, newGroundY: number)
	navGrid = grid
	groundY = newGroundY
	table.clear(flowFields)
end

-- How much tougher enemies are from now on. Enemies already alive keep theirs.
function EnemyService.setScaling(newHpScale: number, newDamageScale: number)
	hpScale = math.max(0.1, newHpScale)
	damageScale = math.max(0.1, newDamageScale)
end

-- Runs `callback` for every kill: enemy id, def id, position and the entity that did it.
function EnemyService.observeKilled(
	callback: (enemyId: number, defId: string, x: number, z: number, sourceId: number?) -> ()
): () -> ()
	table.insert(killedCallbacks, callback)
	return function()
		local index = table.find(killedCallbacks, callback)
		if index then
			table.remove(killedCallbacks, index)
		end
	end
end

function EnemyService.init()
	network = Network.server("Enemy", EnemyService, {
		requestEnemies = {}, -- client -> server
		onSpawn = { Packet.NumberU16, Packet.NumberU8 }, -- id, def index
		onDespawn = { Packet.NumberU16 },
		onSnapshot = { Packet.BufferLong },
		-- start, velocity, seconds it lives
		onProjectile = { Packet.Vector3F32, Packet.Vector3F32, Packet.NumberF32 },
		onBossHealth = { Packet.NumberU16, Packet.NumberU16 }, -- hp, max hp
	})

	CombatService.observeDamage(function(targetId)
		if targetId == bossId then
			bossDirty = true
		end
	end)

	local sinceTick, sinceSnapshot = 0, 0
	RunService.Heartbeat:Connect(function(dt)
		sinceTick += dt
		sinceSnapshot += dt

		-- A long frame is simulated in one step of that length, capped, not replayed.
		if sinceTick >= TICK then
			tick(math.min(sinceTick, 0.25))
			sinceTick = 0
		end
		if sinceSnapshot >= SNAPSHOT_INTERVAL then
			sinceSnapshot = 0
			sendSnapshot()
		end
	end)
end

-- Network (client -> server): a client that joined late asks who is alive.
function EnemyService.requestEnemies(player: Player)
	if not RateLimit.take(requestLimit, player) then
		return
	end

	for id, enemy in enemies do
		network:fireClient(player, "onSpawn", id, EnemyDefs.indexOf(enemy.def.id) :: number)
	end
	bossDirty = true
end

return EnemyService
