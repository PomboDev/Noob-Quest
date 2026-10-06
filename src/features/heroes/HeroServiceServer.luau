--!strict

--[=[
	Heroes, server side: each player's hero entity, its attack loop and its
	abilities.

	A hero is registered with CombatService when the character spawns, with
	the stats of its HeroDef. Attacking is a held state (see AttackInput): the
	client says when the button goes down or up and where it aims, and the
	loop here swings on its own timer. Abilities are one request each, checked
	for rate, a living hero and the cooldown, which only the server keeps.

	The client moves its own character for the dash, since it owns its physics.
	The server only deals the damage and the i-frames.
]=]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Aim = require("@Features/heroes/modules/Aim")
local AttackInput = require("@Features/heroes/modules/AttackInput")
local CombatMath = require("@Features/combat/modules/CombatMath")
local CombatService = require("@Features/combat/CombatServiceServer")
local HeroDefs = require("@Features/heroes/modules/HeroDefs")
local Log = require("@Core/Log")
local Network = require("@Core/Network")
local RateLimit = require("@Core/RateLimit")
local Targeting = require("@Features/combat/modules/Targeting")

local Packet = Network.Packet

type HeroDef = HeroDefs.HeroDef

type Hero = {
	player: Player,
	entityId: number,
	def: HeroDef,
	input: AttackInput.State,
	-- Per ability index: the os.clock() time it can be used again.
	readyAt: { [number]: number },
}

local HeroService = {}

local network: Network.ServerNetwork

local heroes: { [Player]: Hero } = {}
local downedCallbacks: { (player: Player) -> () } = {}

local attackLimit = RateLimit.new({ burst = 10, perSecond = 5 })
-- setAim arrives unreliably at up to 20 Hz.
local aimLimit = RateLimit.new({ burst = 40, perSecond = 25 })
local abilityLimit = RateLimit.new({ burst = 4, perSecond = 3 })
local heroLimit = RateLimit.new({ burst = 2, perSecond = 0.5 })

local function rootOf(player: Player): BasePart?
	local character = player.Character
	local root = if character then character:FindFirstChild("HumanoidRootPart") else nil
	if root and root:IsA("BasePart") then
		return root
	end
	return nil
end

local function removeHero(player: Player)
	local hero = heroes[player]
	if hero then
		CombatService.unregister(hero.entityId)
		heroes[player] = nil
	end
end

local function addHero(player: Player, character: Model)
	removeHero(player)

	local def = HeroDefs.get(HeroDefs.DEFAULT)
	if def == nil then
		return
	end

	local lastPosition = Vector3.zero
	local entityId = CombatService.register({
		team = "hero",
		maxHp = def.maxHp,
		armor = def.armor,
		position = function()
			local root = if player.Character == character then rootOf(player) else nil
			if root then
				lastPosition = root.Position
			end
			return lastPosition
		end,
		onDeath = function()
			local hero = heroes[player]
			if hero then
				AttackInput.stop(hero.input)
			end
			for _, callback in downedCallbacks do
				task.spawn(callback, player)
			end
		end,
	})

	heroes[player] = {
		player = player,
		entityId = entityId,
		def = def,
		input = AttackInput.new(),
		readyAt = {},
	}

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.WalkSpeed = def.walkSpeed
	end

	-- Dropped if the client hasn't connected yet: it asks again with requestHero.
	network:fireClient(player, "onHeroEntity", entityId)
end

local function watch(player: Player)
	local function onCharacter(character: Model)
		-- The character may still be loading: its position function waits for the root part.
		addHero(player, character)
	end

	player.CharacterAdded:Connect(onCharacter)
	player.CharacterRemoving:Connect(function()
		removeHero(player)
	end)
	if player.Character then
		onCharacter(player.Character)
	end
end

-- Runs `callback(player)` whenever a hero is downed (HP at 0).
function HeroService.observeDowned(callback: (player: Player) -> ()): () -> ()
	table.insert(downedCallbacks, callback)
	return function()
		local index = table.find(downedCallbacks, callback)
		if index then
			table.remove(downedCallbacks, index)
		end
	end
end

-- The player's hero entity in CombatService, if it has one.
function HeroService.getEntityId(player: Player): number?
	local hero = heroes[player]
	return if hero then hero.entityId else nil
end

-- One swing of the basic attack from the hero's position at `angle`.
local function swing(hero: Hero, position: Vector3, angle: number)
	local attack = hero.def.attack
	local targets =
		Targeting.inCone(CombatService.points("enemy"), position.X, position.Z, angle, attack.coneDegrees, attack.range)

	for _, targetId in targets do
		local crit = CombatMath.isCrit(attack.critChance, math.random())
		CombatService.applyDamage(hero.entityId, targetId, attack.damage, "physical", crit)
	end

	network:fireAllClients("onHeroAttack", hero.player.UserId, angle)
end

local function attackLoop()
	local now = os.clock()
	for player, hero in heroes do
		local input = hero.input
		if not AttackInput.due(input, now) or not CombatService.isAlive(hero.entityId) then
			continue
		end

		local root = rootOf(player)
		if root == nil then
			continue
		end
		local position = root.Position

		local autoAngle: number? = nil
		if input.auto then
			local nearest =
				Targeting.nearest(CombatService.points("enemy"), position.X, position.Z, hero.def.attack.autoRange)
			local entity = if nearest then CombatService.get(nearest) else nil
			if entity then
				local at = entity.position()
				autoAngle = Aim.angleTo(position.X, position.Z, at.X, at.Z)
			end
		end

		-- Nothing in auto range: no swing, and the timer is left alone.
		local angle = AttackInput.swingAngle(input, autoAngle)
		if angle then
			swing(hero, position, angle)
			AttackInput.swung(input, now, hero.def.attack.cooldown)
		end
	end
end

local function useDash(hero: Hero, ability: HeroDefs.Dash, position: Vector3, angle: number)
	local dx, dz = Targeting.direction(angle)
	local targets = Targeting.inSegment(
		CombatService.points("enemy"),
		position.X,
		position.Z,
		position.X + dx * ability.distance,
		position.Z + dz * ability.distance,
		ability.halfWidth
	)

	CombatService.setInvulnerable(hero.entityId, ability.invulnerable)
	for _, targetId in targets do
		CombatService.applyDamage(hero.entityId, targetId, ability.damage, "physical", false)
	end
end

local function useSlam(hero: Hero, ability: HeroDefs.Slam, position: Vector3)
	local targets = Targeting.inRadius(CombatService.points("enemy"), position.X, position.Z, ability.radius)
	for _, targetId in targets do
		CombatService.applyDamage(hero.entityId, targetId, ability.damage, "physical", false)
		CombatService.stun(targetId, ability.stun)
	end
end

function HeroService.init()
	network = Network.server("Hero", HeroService, {
		setAttack = { Packet.Boolean, Packet.NumberF32, Packet.Boolean }, -- client -> server
		requestHero = {}, -- client -> server
		onHeroEntity = { Packet.NumberU16 }, -- the combat entity of the player's hero
		setAim = { Packet.NumberF32 }, -- client -> server
		useAbility = { Packet.NumberU8, Packet.NumberF32 }, -- client -> server
		onHeroAttack = { Packet.NumberU32, Packet.NumberF32 }, -- user id, angle
		onAbilityUsed = { Packet.NumberU32, Packet.NumberU8, Packet.NumberF32 }, -- user id, ability, angle
		onAbilityRejected = { Packet.NumberU8, Packet.NumberF32 }, -- ability, seconds until ready
	})

	for _, player in Players:GetPlayers() do
		watch(player)
	end
	Players.PlayerAdded:Connect(watch)
	Players.PlayerRemoving:Connect(removeHero)

	RunService.Heartbeat:Connect(attackLoop)
end

-- Network (client -> server)
function HeroService.requestHero(player: Player)
	local hero = heroes[player]
	if hero and RateLimit.take(heroLimit, player) then
		network:fireClient(player, "onHeroEntity", hero.entityId)
	end
end

function HeroService.setAttack(player: Player, active: boolean, angle: number, auto: boolean)
	local hero = heroes[player]
	if hero == nil or not RateLimit.take(attackLimit, player) then
		return
	end
	if not CombatService.isAlive(hero.entityId) then
		AttackInput.stop(hero.input)
		return
	end

	-- A bad message changes nothing, so the hero keeps doing what it was doing.
	if not AttackInput.setAttack(hero.input, active, angle, auto) then
		Log.debug(`{player.Name} sent a bad setAttack`)
	end
end

function HeroService.setAim(player: Player, angle: number)
	local hero = heroes[player]
	if hero == nil or not RateLimit.take(aimLimit, player) then
		return
	end
	AttackInput.setAim(hero.input, angle)
end

function HeroService.useAbility(player: Player, index: number, angle: number)
	local hero = heroes[player]
	if hero == nil or not RateLimit.take(abilityLimit, player) then
		return
	end

	local ability = HeroDefs.ability(hero.def, index)
	if ability == nil or not AttackInput.isAngle(angle) or not CombatService.isAlive(hero.entityId) then
		return
	end

	local root = rootOf(player)
	if root == nil then
		return
	end

	local now = os.clock()
	local readyAt = hero.readyAt[index] or 0
	if now < readyAt then
		network:fireClient(player, "onAbilityRejected", index, readyAt - now)
		return
	end
	hero.readyAt[index] = now + ability.cooldown

	if ability.kind == "dash" then
		useDash(hero, ability, root.Position, angle)
	else
		useSlam(hero, ability, root.Position)
	end

	network:fireAllClients("onAbilityUsed", player.UserId, index, angle)
end

return HeroService
