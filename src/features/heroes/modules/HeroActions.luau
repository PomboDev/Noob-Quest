--!strict

--[=[
	What a hero does in the simulation, one input at a time: HeroSim moves it
	and counts its cooldowns, and this turns the result into hits. A swing, a
	dash and a slam are decided here, from the hero's simulated position, the
	enemies' (EnemySim.near) and the damage rules (CombatSim).

	Pure: crits roll from the run's combat stream and every duration is in
	ticks. Reports with events (`heroAttack`, `abilityUsed`, `abilityRejected`,
	`teleport`).
]=]

local Angle = require("@Core/Angle")
local AttackInput = require("@Features/heroes/modules/AttackInput")
local Checksum = require("@Features/sim/modules/Checksum")
local CombatMath = require("@Features/combat/modules/CombatMath")
local CombatSim = require("@Features/combat/modules/CombatSim")
local EnemySim = require("@Features/enemies/modules/EnemySim")
local HeroDefs = require("@Features/heroes/modules/HeroDefs")
local HeroInput = require("@Features/heroes/modules/HeroInput")
local HeroSim = require("@Features/heroes/modules/HeroSim")
local Rng = require("@Core/Rng")
local SimClock = require("@Features/sim/modules/SimClock")
local SimContext = require("@Features/sim/modules/SimContext")
local Targeting = require("@Features/combat/modules/Targeting")
local WorldSim = require("@Features/world/modules/WorldSim")

export type Hero = {
	-- 1, 2, ...: fixed while the hero is in the sim, never a Player.
	slot: number,
	userId: number,
	def: HeroDefs.HeroDef,
	sim: HeroSim.Sim,
	-- The hero's body in combat. Its position follows `sim.motion`.
	entity: CombatSim.Entity,
}

-- What the actions work on.
export type Deps = {
	combat: CombatSim.State,
	enemies: EnemySim.State,
	world: WorldSim.State,
}

local HeroActions = {}

-- Adds a hero at (x, z), or nil for an unknown hero def.
function HeroActions.new(
	combat: CombatSim.State,
	ctx: SimContext.Ctx,
	slot: number,
	userId: number,
	defId: string,
	x: number,
	z: number
): Hero?
	local def = HeroDefs.get(defId)
	if def == nil then
		return nil
	end

	return {
		slot = slot,
		userId = userId,
		def = def,
		sim = HeroSim.new(def, x, z),
		entity = CombatSim.register(combat, ctx, "hero", def.maxHp, def.armor, x, z),
	}
end

-- Puts a hero somewhere (a spawn, the lobby): whatever it was doing stops, and
-- the adapter is told.
function HeroActions.place(ctx: SimContext.Ctx, hero: Hero, x: number, z: number)
	HeroSim.place(hero.sim, x, z)
	hero.entity.x, hero.entity.z = x, z
	SimContext.emit(ctx, { kind = "teleport", slot = hero.slot, x = x, z = z })
end

-- The hero went down: it stops attacking.
function HeroActions.onDowned(hero: Hero)
	AttackInput.stop(hero.sim.attack)
end

-- One swing of the basic attack from (x, z) at `angle` (Angle units).
local function swing(deps: Deps, ctx: SimContext.Ctx, hero: Hero, x: number, z: number, angle: number)
	local attack = hero.def.attack
	local candidates = EnemySim.near(deps.enemies, x, z, attack.range)
	local cone = Angle.fromDegrees(attack.coneDegrees)

	for _, targetId in Targeting.inCone(candidates, x, z, angle, cone, attack.range) do
		local crit = CombatMath.isCrit(attack.critChance, Rng.next(ctx.rng.combat))
		CombatSim.applyDamage(deps.combat, ctx, hero.entity.id, targetId, attack.damage, "physical", crit)
	end

	hero.sim.facing = angle
	SimContext.emit(ctx, { kind = "heroAttack", userId = hero.userId, angle = angle })
end

local function useDash(
	deps: Deps,
	ctx: SimContext.Ctx,
	hero: Hero,
	dash: HeroDefs.Dash,
	x: number,
	z: number,
	angle: number
)
	local dx, dz = Angle.direction(angle)
	local endX, endZ = x + dx * dash.distance, z + dz * dash.distance
	local half = dash.distance / 2
	local candidates = EnemySim.near(deps.enemies, x + dx * half, z + dz * half, half + dash.halfWidth)

	CombatSim.setInvulnerable(deps.combat, ctx, hero.entity.id, SimClock.ticks(dash.invulnerable))
	for _, targetId in Targeting.inSegment(candidates, x, z, endX, endZ, dash.halfWidth) do
		CombatSim.applyDamage(deps.combat, ctx, hero.entity.id, targetId, dash.damage, "physical", false)
	end
end

local function useSlam(deps: Deps, ctx: SimContext.Ctx, hero: Hero, slam: HeroDefs.Slam, x: number, z: number)
	local candidates = EnemySim.near(deps.enemies, x, z, slam.radius)
	for _, targetId in Targeting.inRadius(candidates, x, z, slam.radius) do
		CombatSim.applyDamage(deps.combat, ctx, hero.entity.id, targetId, slam.damage, "physical", false)
		EnemySim.stun(deps.enemies, ctx, targetId, SimClock.ticks(slam.stun))
	end
end

-- Uses one input of a hero. Returns the id of the world object the input
-- uses, if any: the caller checks it (see WorldSim.use).
function HeroActions.step(deps: Deps, ctx: SimContext.Ctx, hero: Hero, input: HeroInput.Input): number?
	local sim = hero.sim
	local entity = hero.entity
	local alive = CombatSim.isAlive(deps.combat, entity.id)

	-- Where the hero stood when it acted.
	local x, z = sim.motion.x, sim.motion.z
	local result = HeroSim.step(sim, input, WorldSim.gridAt(deps.world, x, z), alive)
	entity.x, entity.z = sim.motion.x, sim.motion.z

	local usedIndex = result.used
	if usedIndex then
		local ability = HeroDefs.ability(hero.def, usedIndex)
		if ability and ability.kind == "dash" then
			useDash(deps, ctx, hero, ability, x, z, input.aim)
		elseif ability and ability.kind == "slam" then
			useSlam(deps, ctx, hero, ability, x, z)
		end
		SimContext.emit(ctx, { kind = "abilityUsed", userId = hero.userId, index = usedIndex, angle = input.aim })
	elseif result.rejected then
		SimContext.emit(ctx, {
			kind = "abilityRejected",
			slot = hero.slot,
			index = result.rejected,
			ticks = result.rejectedTicks,
		})
	end

	-- The basic attack swings on the hero's own clock, so a client can't swing faster.
	local attack = sim.attack
	if alive and AttackInput.due(attack, sim.tick) then
		local px, pz = sim.motion.x, sim.motion.z
		local autoAngle: number? = nil
		if attack.auto then
			local range = hero.def.attack.autoRange
			local nearest = Targeting.nearest(EnemySim.near(deps.enemies, px, pz, range), px, pz, range)
			local enemy = if nearest then EnemySim.get(deps.enemies, nearest) else nil
			if enemy then
				autoAngle = Angle.atan2(enemy.body.x - px, enemy.body.z - pz)
			end
		end

		-- Nothing in auto range: no swing, and the timer is left alone.
		local angle = AttackInput.swingAngle(attack, autoAngle)
		if angle then
			swing(deps, ctx, hero, px, pz, angle)
			AttackInput.swung(attack, sim.tick, SimClock.ticks(hero.def.attack.cooldown))
		end
	end

	if input.interact > 0 then
		return input.interact
	end
	return nil
end

function HeroActions.checksum(hash: Checksum.Hash, hero: Hero)
	local sim = hero.sim
	Checksum.number(hash, hero.slot)
	Checksum.number(hash, hero.userId)
	Checksum.number(hash, sim.motion.x)
	Checksum.number(hash, sim.motion.z)
	Checksum.number(hash, sim.motion.dashLeft)
	Checksum.number(hash, sim.motion.dashX)
	Checksum.number(hash, sim.motion.dashZ)
	Checksum.number(hash, sim.tick)
	Checksum.number(hash, sim.facing)
	for index in hero.def.abilities do
		Checksum.number(hash, sim.readyAt[index] or 0)
	end
	Checksum.bool(hash, sim.attack.active)
	Checksum.bool(hash, sim.attack.auto)
	Checksum.number(hash, sim.attack.angle)
	Checksum.number(hash, sim.attack.nextSwing)
end

return HeroActions
