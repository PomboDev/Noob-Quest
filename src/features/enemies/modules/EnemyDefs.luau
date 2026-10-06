--!strict

--[=[
	Enemy definitions: stats and behaviour. The order of `EnemyDefs.list` is
	the index sent over the network, so only ever append to it.

	- chaser: follows the flow field to the nearest hero and hits it up close
	- ranged: keeps its distance and shoots projectiles
	- boss: chaser with a slam and a summon (see EnemyServiceServer)

	Every attack has a telegraph: a short wind-up the client shows, so a hit
	is never a surprise.
]=]

local EnemyDefs = {}

export type Behaviour = "chaser" | "ranged" | "boss"

export type EnemyDef = {
	id: string,
	name: string,
	behaviour: Behaviour,
	maxHp: number,
	armor: number,
	speed: number, -- studs per second
	radius: number, -- how much room it takes, for separation
	damage: number,
	attackRange: number, -- studs
	attackCooldown: number, -- seconds between attacks
	telegraph: number, -- seconds of wind-up
	-- Coins and XP for the run director.
	reward: number,
	-- The greybox the client builds when there is no model in Assets.Enemies.
	size: { x: number, y: number, z: number }, -- studs
	color: { r: number, g: number, b: number }, -- 0 to 255

	-- Ranged only.
	preferredRange: number?,
	projectileSpeed: number?,
	projectileLife: number?,
	projectileRadius: number?,

	-- Boss only.
	slamRadius: number?,
	slamTelegraph: number?,
	slamCooldown: number?,
	summonCooldown: number?,
	summonCount: number?,
	summonDef: string?,
}

local DEFS: { EnemyDef } = {
	{
		id = "grunt",
		name = "Grunt",
		behaviour = "chaser",
		maxHp = 40,
		armor = 0,
		speed = 9,
		radius = 1.8,
		damage = 8,
		attackRange = 4,
		attackCooldown = 1.2,
		telegraph = 0.4,
		reward = 1,
		size = { x = 3, y = 4, z = 3 },
		color = { r = 120, g = 170, b = 80 },
	},
	{
		id = "runner",
		name = "Runner",
		behaviour = "chaser",
		maxHp = 25,
		armor = 0,
		speed = 16,
		radius = 1.5,
		damage = 6,
		attackRange = 3.5,
		attackCooldown = 0.9,
		telegraph = 0.25,
		reward = 1,
		size = { x = 2.5, y = 3.5, z = 2.5 },
		color = { r = 220, g = 160, b = 60 },
	},
	{
		id = "spitter",
		name = "Spitter",
		behaviour = "ranged",
		maxHp = 30,
		armor = 0,
		speed = 7,
		radius = 1.6,
		damage = 10,
		attackRange = 32,
		attackCooldown = 2.2,
		telegraph = 0.6,
		reward = 2,
		size = { x = 3, y = 3.5, z = 3 },
		color = { r = 150, g = 90, b = 200 },
		preferredRange = 22,
		projectileSpeed = 40,
		projectileLife = 1.2,
		projectileRadius = 1.5,
	},
	{
		id = "golem",
		name = "Siege Golem",
		behaviour = "boss",
		maxHp = 1500,
		armor = 30,
		speed = 6,
		radius = 4,
		damage = 35,
		attackRange = 8,
		attackCooldown = 2,
		telegraph = 0.8,
		reward = 25,
		size = { x = 9, y = 12, z = 9 },
		color = { r = 120, g = 110, b = 100 },
		slamRadius = 16,
		slamTelegraph = 1.1,
		slamCooldown = 7,
		summonCooldown = 14,
		summonCount = 4,
		summonDef = "grunt",
	},
}

EnemyDefs.list = DEFS

local indexById: { [string]: number } = {}
for index, def in DEFS do
	indexById[def.id] = index
end

function EnemyDefs.get(id: string): EnemyDef?
	local index = indexById[id]
	return if index then DEFS[index] else nil
end

-- The number sent over the network for a def, or nil for an unknown id.
function EnemyDefs.indexOf(id: string): number?
	return indexById[id]
end

function EnemyDefs.byIndex(index: number): EnemyDef?
	return DEFS[index]
end

return EnemyDefs
