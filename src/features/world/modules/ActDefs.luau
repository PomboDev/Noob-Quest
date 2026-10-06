--!strict

--[=[
	What each act asks the generator for. Act 1 is a 48 x 48 tile map
	(576 studs across) with one teleporter far from the spawn, and camps of
	enemies standing around it.
]=]

local ActTypes = require("@Features/world/modules/ActTypes")

type ActDef = ActTypes.ActDef

local ACT_1: ActDef = {
	id = "act1",
	width = 48,
	height = 48,
	tileSize = 12,
	spawnSize = 3,
	spawnMargin = 2,
	pois = {
		{ kind = "teleporter", count = 1, size = 3, minFromSpawn = 30, maxFromSpawn = 58, minApart = 12 },
		{ kind = "angelStatue", count = 1, size = 2, minFromSpawn = 12, maxFromSpawn = 44, minApart = 10 },
		{ kind = "devilStatue", count = 1, size = 2, minFromSpawn = 12, maxFromSpawn = 44, minApart = 10 },
		{ kind = "structure", count = 4, size = 3, minFromSpawn = 14, maxFromSpawn = 58, minApart = 8 },
		{ kind = "chest", count = 8, size = 1, minFromSpawn = 8, maxFromSpawn = 58, minApart = 6 },
	},
	props = {
		{ kind = "tree", weight = 6 },
		{ kind = "rock", weight = 3 },
		{ kind = "bush", weight = 4 },
	},
	propDensity = 0.3,
	wobble = 2,
	camps = {
		count = 22,
		minFromSpawn = 12,
		minApart = 6,
		radius = 6,
		tiers = {
			{ upTo = 24, minSize = 3, maxSize = 4, entries = { { defId = "grunt", weight = 1 } } },
			{
				upTo = 42,
				minSize = 4,
				maxSize = 6,
				entries = { { defId = "grunt", weight = 4 }, { defId = "runner", weight = 3 } },
			},
			{
				upTo = 999,
				minSize = 5,
				maxSize = 7,
				entries = {
					{ defId = "grunt", weight = 3 },
					{ defId = "runner", weight = 3 },
					{ defId = "spitter", weight = 2 },
				},
			},
		},
		guards = {
			{ kind = "teleporter", chance = 1 },
			{ kind = "structure", chance = 1 },
			{ kind = "angelStatue", chance = 0.5 },
			{ kind = "devilStatue", chance = 0.5 },
			{ kind = "chest", chance = 0.6 },
		},
		guardBonus = 2,
	},
}

local ACTS: { ActDef } = { ACT_1 }

local ActDefs = {}

-- The definition for a 1-based act number; acts past the last repeat it.
function ActDefs.forAct(actIndex: number): ActDef
	return ACTS[math.min(math.max(actIndex, 1), #ACTS)]
end

return ActDefs
