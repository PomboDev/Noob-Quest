--!strict

--[=[
	Combat feature, server side: the entity registry and the one place damage
	is dealt.

	Every hero and enemy registers as an entity. All damage goes through
	applyDamage, which applies armor and crits (CombatMath), keeps the hit
	points and tells the clients. Hero HP lives here, not on the Humanoid,
	which is never damaged: a hero at 0 HP is downed, and the run feature
	decides what that means.

	Other server features register their entities and call applyDamage. They
	read an entity through `get` and never change it.
]=]

local CombatMath = require("@Features/combat/modules/CombatMath")
local Log = require("@Core/Log")
local Network = require("@Core/Network")
local RateLimit = require("@Core/RateLimit")
local Targeting = require("@Features/combat/modules/Targeting")

local Packet = Network.Packet

export type Team = "hero" | "enemy"

export type Entity = {
	id: number,
	team: Team,
	hp: number,
	maxHp: number,
	armor: number,
	dead: boolean,
	-- Until this os.clock() time no damage lands (dash i-frames).
	invulnerableUntil: number,
	position: () -> Vector3,
	-- Runs once when the entity's HP reaches 0. `sourceId` is nil for damage with no entity behind it.
	onDeath: ((entity: Entity, sourceId: number?) -> ())?,
	-- Runs when something stuns the entity: the owner decides what that means.
	onStun: ((entity: Entity, seconds: number) -> ())?,
}

export type Definition = {
	team: Team,
	maxHp: number,
	armor: number?,
	position: () -> Vector3,
	onDeath: ((entity: Entity, sourceId: number?) -> ())?,
	onStun: ((entity: Entity, seconds: number) -> ())?,
}

-- Ids travel as NumberU16.
local MAX_ID = 65535
-- Packets carry HP and damage as NumberU16.
local MAX_VALUE = 65535

local CombatService = {}

local network: Network.ServerNetwork

local entities: { [number]: Entity } = {}
local lastId = 0
local requestLimit = RateLimit.new({ burst = 2, perSecond = 0.5 })
local damageCallbacks: { (targetId: number, damage: number) -> () } = {}

local function clampValue(value: number): number
	return math.clamp(math.floor(value + 0.5), 0, MAX_VALUE)
end

local function isFinitePositive(value: any): boolean
	return type(value) == "number" and value == value and value > 0 and value < math.huge
end

local function nextId(): number
	for _ = 1, MAX_ID do
		lastId = if lastId >= MAX_ID then 1 else lastId + 1
		if entities[lastId] == nil then
			return lastId
		end
	end
	error("Too many combat entities", 0)
end

local function sendHealth(entity: Entity)
	if entity.team == "hero" then
		network:fireAllClients("onHeroHealth", entity.id, clampValue(entity.hp), clampValue(entity.maxHp))
	end
end

function CombatService.init()
	-- All server -> client.
	network = Network.server("Combat", CombatService, {
		requestHealth = {}, -- client -> server
		-- entity id, position, damage dealt, crit
		onDamage = { Packet.NumberU16, Packet.Vector3S16, Packet.NumberU16, Packet.Boolean },
		-- hero entity id, hp, max hp
		onHeroHealth = { Packet.NumberU16, Packet.NumberU16, Packet.NumberU16 },
		-- entity id, position, whether it was a hero
		onEntityDied = { Packet.NumberU16, Packet.Vector3S16, Packet.Boolean },
	})
end

-- Runs `callback(targetId, damage)` after every hit that lands. Returns a function that stops it.
function CombatService.observeDamage(callback: (targetId: number, damage: number) -> ()): () -> ()
	table.insert(damageCallbacks, callback)
	return function()
		local index = table.find(damageCallbacks, callback)
		if index then
			table.remove(damageCallbacks, index)
		end
	end
end

-- Registers an entity and returns its id.
function CombatService.register(definition: Definition): number
	local id = nextId()
	local entity: Entity = {
		id = id,
		team = definition.team,
		hp = definition.maxHp,
		maxHp = definition.maxHp,
		armor = definition.armor or 0,
		dead = false,
		invulnerableUntil = 0,
		position = definition.position,
		onDeath = definition.onDeath,
		onStun = definition.onStun,
	}
	entities[id] = entity
	sendHealth(entity)
	return id
end

function CombatService.unregister(id: number)
	entities[id] = nil
end

function CombatService.get(id: number): Entity?
	return entities[id]
end

function CombatService.isAlive(id: number): boolean
	local entity = entities[id]
	return entity ~= nil and not entity.dead
end

-- The living entities of a team as points, for Targeting.
function CombatService.points(team: Team): { Targeting.Point }
	local points = {}
	for id, entity in entities do
		if entity.team == team and not entity.dead then
			local position = entity.position()
			table.insert(points, { id = id, x = position.X, z = position.Z })
		end
	end
	return points
end

-- Deals a hit and returns the damage done: 0 when the target is gone, dead,
-- invulnerable or the amount is not a positive number.
function CombatService.applyDamage(
	sourceId: number?,
	targetId: number,
	amount: number,
	kind: CombatMath.DamageKind,
	crit: boolean?
): number
	local target = entities[targetId]
	if target == nil or target.dead or os.clock() < target.invulnerableUntil or not isFinitePositive(amount) then
		return 0
	end

	local isCrit = crit == true
	local damage = math.min(CombatMath.finalDamage(amount, target.armor, kind, isCrit), target.hp)
	target.hp -= damage

	network:fireAllClientsUnreliable("onDamage", targetId, target.position(), clampValue(damage), isCrit)
	sendHealth(target)
	for _, callback in damageCallbacks do
		task.spawn(callback, targetId, damage)
	end

	if target.hp <= 0 then
		target.dead = true
		network:fireAllClients("onEntityDied", targetId, target.position(), target.team == "hero")

		local onDeath = target.onDeath
		if onDeath then
			local ok, err = pcall(onDeath :: any, target, sourceId)
			if not ok then
				Log.warn(`onDeath of entity {targetId} failed: {err}`)
			end
		end
	end

	return damage
end

-- Nothing damages the entity for the next `seconds` (never shortens an earlier one).
function CombatService.setInvulnerable(id: number, seconds: number)
	local entity = entities[id]
	if entity and isFinitePositive(seconds) then
		entity.invulnerableUntil = math.max(entity.invulnerableUntil, os.clock() + seconds)
	end
end

-- Stuns the entity, if its owner handles stuns.
function CombatService.stun(id: number, seconds: number)
	local entity = entities[id]
	if entity == nil or entity.dead or entity.onStun == nil or not isFinitePositive(seconds) then
		return
	end

	local onStun = entity.onStun
	local ok, err = pcall(onStun :: any, entity, seconds)
	if not ok then
		Log.warn(`onStun of entity {id} failed: {err}`)
	end
end

-- Restores HP, never above the maximum or on a dead entity (see revive).
function CombatService.heal(id: number, amount: number)
	local entity = entities[id]
	if entity == nil or entity.dead or not isFinitePositive(amount) then
		return
	end

	entity.hp = math.min(entity.maxHp, entity.hp + amount)
	sendHealth(entity)
end

-- Brings a dead entity back with `hp` (all of it by default).
function CombatService.revive(id: number, hp: number?)
	local entity = entities[id]
	if entity == nil then
		return
	end

	entity.dead = false
	entity.hp = math.clamp(hp or entity.maxHp, 1, entity.maxHp)
	sendHealth(entity)
end

-- Network (client -> server): a client that joined late asks for every hero's health.
function CombatService.requestHealth(player: Player)
	if not RateLimit.take(requestLimit, player) then
		return
	end

	for _, entity in entities do
		if entity.team == "hero" then
			network:fireClient(player, "onHeroHealth", entity.id, clampValue(entity.hp), clampValue(entity.maxHp))
		end
	end
end

return CombatService
