--!strict

--[=[
	Combat, as part of the simulation: the entity registry and the one place
	damage is dealt. Every hero and enemy is an entity with a position, hit
	points and armor. All damage goes through `applyDamage`, which applies armor
	and crits (CombatMath), keeps the hit points and reports what happened as
	events. Hero HP lives here: a hero at 0 HP is downed, and the run decides
	what that means.

	Pure: no Instances, no clock (i-frames count in ticks) and no random
	numbers (the caller rolls the crit). Entities are kept in the order they
	were registered, so every loop runs in the same order. A death is queued
	and handled by whoever steps the sim, after the current step's actions.
]=]

local Checksum = require("@Features/sim/modules/Checksum")
local CombatMath = require("@Features/combat/modules/CombatMath")
local SimContext = require("@Features/sim/modules/SimContext")
local Targeting = require("@Features/combat/modules/Targeting")

export type Team = "hero" | "enemy"

export type Entity = {
	id: number,
	team: Team,
	hp: number,
	maxHp: number,
	armor: number,
	dead: boolean,
	-- Until this tick no damage lands (dash i-frames).
	invulnerableUntil: number,
	x: number,
	z: number,
}

export type Death = { id: number, sourceId: number? }

export type State = {
	-- In the order they were registered.
	entities: { Entity },
	byId: { [number]: Entity },
	lastId: number,
	-- Entities that reached 0 HP and haven't been handled yet.
	deaths: { Death },
}

-- Ids travel as NumberU16.
local MAX_ID = 65535
-- Packets carry HP and damage as NumberU16.
local MAX_VALUE = 65535

local CombatSim = {}

function CombatSim.new(): State
	return { entities = {}, byId = {}, lastId = 0, deaths = {} }
end

local function clampValue(value: number): number
	return math.clamp(math.floor(value + 0.5), 0, MAX_VALUE)
end

local function isFinitePositive(value: any): boolean
	return type(value) == "number" and value == value and value > 0 and value < math.huge
end

local function nextId(state: State): number
	for _ = 1, MAX_ID do
		state.lastId = if state.lastId >= MAX_ID then 1 else state.lastId + 1
		if state.byId[state.lastId] == nil then
			return state.lastId
		end
	end
	error("Too many combat entities", 0)
end

local function sendHealth(ctx: SimContext.Ctx, entity: Entity)
	if entity.team == "hero" then
		SimContext.emit(ctx, {
			kind = "heroHealth",
			id = entity.id,
			hp = clampValue(entity.hp),
			maxHp = clampValue(entity.maxHp),
		})
	end
end

-- Registers an entity and returns it.
function CombatSim.register(
	state: State,
	ctx: SimContext.Ctx,
	team: Team,
	maxHp: number,
	armor: number,
	x: number,
	z: number
): Entity
	local id = nextId(state)
	local entity: Entity = {
		id = id,
		team = team,
		hp = maxHp,
		maxHp = maxHp,
		armor = armor,
		dead = false,
		invulnerableUntil = 0,
		x = x,
		z = z,
	}
	state.byId[id] = entity
	table.insert(state.entities, entity)
	sendHealth(ctx, entity)
	return entity
end

function CombatSim.unregister(state: State, id: number)
	local entity = state.byId[id]
	if entity == nil then
		return
	end
	state.byId[id] = nil
	local index = table.find(state.entities, entity)
	if index then
		table.remove(state.entities, index)
	end
end

function CombatSim.get(state: State, id: number): Entity?
	return state.byId[id]
end

function CombatSim.isAlive(state: State, id: number): boolean
	local entity = state.byId[id]
	return entity ~= nil and not entity.dead
end

-- The living entities of a team as points, for Targeting.
function CombatSim.points(state: State, team: Team): { Targeting.Point }
	local points = {}
	for _, entity in state.entities do
		if entity.team == team and not entity.dead then
			table.insert(points, { id = entity.id, x = entity.x, z = entity.z })
		end
	end
	return points
end

-- Deals a hit and returns the damage done: 0 when the target is gone, dead,
-- invulnerable or the amount is not a positive number.
function CombatSim.applyDamage(
	state: State,
	ctx: SimContext.Ctx,
	sourceId: number?,
	targetId: number,
	amount: number,
	kind: CombatMath.DamageKind,
	crit: boolean?
): number
	local target = state.byId[targetId]
	if target == nil or target.dead or ctx.tick < target.invulnerableUntil or not isFinitePositive(amount) then
		return 0
	end

	local isCrit = crit == true
	local damage = math.min(CombatMath.finalDamage(amount, target.armor, kind, isCrit), target.hp)
	target.hp -= damage

	SimContext.emit(ctx, {
		kind = "damage",
		id = targetId,
		x = target.x,
		z = target.z,
		damage = clampValue(damage),
		crit = isCrit,
	})
	sendHealth(ctx, target)

	if target.hp <= 0 then
		target.dead = true
		SimContext.emit(ctx, {
			kind = "died",
			id = targetId,
			x = target.x,
			z = target.z,
			hero = target.team == "hero",
		})
		table.insert(state.deaths, { id = targetId, sourceId = sourceId })
	end

	return damage
end

-- The entities that died since the last call, in the order they died.
function CombatSim.popDeaths(state: State): { Death }
	local deaths = state.deaths
	state.deaths = {}
	return deaths
end

-- Nothing damages the entity for the next `ticks` (never shortens an earlier one).
function CombatSim.setInvulnerable(state: State, ctx: SimContext.Ctx, id: number, ticks: number)
	local entity = state.byId[id]
	if entity and isFinitePositive(ticks) then
		entity.invulnerableUntil = math.max(entity.invulnerableUntil, ctx.tick + ticks)
	end
end

-- Restores HP, never above the maximum or on a dead entity (see revive).
function CombatSim.heal(state: State, ctx: SimContext.Ctx, id: number, amount: number)
	local entity = state.byId[id]
	if entity == nil or entity.dead or not isFinitePositive(amount) then
		return
	end

	entity.hp = math.min(entity.maxHp, entity.hp + amount)
	sendHealth(ctx, entity)
end

-- Brings a dead entity back with `hp` (all of it by default).
function CombatSim.revive(state: State, ctx: SimContext.Ctx, id: number, hp: number?)
	local entity = state.byId[id]
	if entity == nil then
		return
	end

	entity.dead = false
	entity.hp = math.clamp(hp or entity.maxHp, 1, entity.maxHp)
	sendHealth(ctx, entity)
end

function CombatSim.checksum(hash: Checksum.Hash, state: State)
	Checksum.section(hash, "combat")
	Checksum.number(hash, state.lastId)
	for _, entity in state.entities do
		Checksum.number(hash, entity.id)
		Checksum.number(hash, entity.hp)
		Checksum.number(hash, entity.maxHp)
		Checksum.bool(hash, entity.dead)
		Checksum.number(hash, entity.invulnerableUntil)
		Checksum.number(hash, entity.x)
		Checksum.number(hash, entity.z)
	end
	for _, death in state.deaths do
		Checksum.number(hash, death.id)
	end
end

return CombatSim
