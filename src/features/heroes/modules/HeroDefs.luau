--!strict

--[=[
	Hero definitions: base stats, the basic attack and the abilities. The
	Warrior is the first; ranged heroes add projectile fields later.
]=]

local HeroDefs = {}

export type Attack = {
	damage: number,
	cooldown: number, -- seconds between swings
	coneDegrees: number, -- total width of the cleave
	range: number, -- studs
	autoRange: number, -- how far auto-target looks for something to hit
	critChance: number, -- 0 to 1
}

export type Dash = {
	kind: "dash",
	id: string,
	name: string,
	cooldown: number,
	distance: number, -- studs travelled
	duration: number, -- seconds the dash takes
	halfWidth: number, -- studs either side of the path that get hit
	damage: number,
	invulnerable: number, -- seconds of i-frames from the start
}

export type Slam = {
	kind: "slam",
	id: string,
	name: string,
	cooldown: number,
	radius: number,
	damage: number,
	stun: number, -- seconds
}

export type Ability = Dash | Slam

export type HeroDef = {
	id: string,
	name: string,
	maxHp: number,
	armor: number,
	walkSpeed: number,
	attack: Attack,
	-- The order buttons are drawn in and the index sent over the network.
	abilities: { Ability },
}

local WARRIOR: HeroDef = {
	id = "warrior",
	name = "Warrior",
	maxHp = 220,
	armor = 20,
	walkSpeed = 18,
	attack = {
		damage = 16,
		cooldown = 0.55,
		coneDegrees = 100,
		range = 8,
		autoRange = 12,
		critChance = 0.08,
	},
	abilities = {
		{
			kind = "dash",
			id = "charge",
			name = "Charge",
			cooldown = 4,
			distance = 20,
			duration = 0.2,
			halfWidth = 3,
			damage = 30,
			invulnerable = 0.3,
		},
		{
			kind = "slam",
			id = "slam",
			name = "Ground Slam",
			cooldown = 8,
			radius = 14,
			damage = 45,
			stun = 1.2,
		},
	},
}

local DEFS: { [string]: HeroDef } = {
	[WARRIOR.id] = WARRIOR,
}

HeroDefs.DEFAULT = WARRIOR.id

function HeroDefs.get(id: string): HeroDef?
	return DEFS[id]
end

-- The ability at a network index (1-based), or nil for anything that isn't one.
function HeroDefs.ability(def: HeroDef, index: any): Ability?
	if type(index) ~= "number" or index % 1 ~= 0 then
		return nil
	end
	return def.abilities[index]
end

return HeroDefs
