--!strict

--[=[
	What each act asks the generator for. Act 1 is a 24 x 24 tile arena
	(288 studs across) with one teleporter far from the spawn.
]=]

local ActTypes = require("@Features/world/modules/ActTypes")

type ActDef = ActTypes.ActDef

local ACT_1: ActDef = {
	id = "act1",
	width = 24,
	height = 24,
	tileSize = 12,
	spawnSize = 3,
	spawnMargin = 2,
	pois = {
		{ kind = "teleporter", count = 1, size = 3, minFromSpawn = 14, maxFromSpawn = 30, minApart = 6 },
		{ kind = "angelStatue", count = 1, size = 2, minFromSpawn = 6, maxFromSpawn = 22, minApart = 5 },
		{ kind = "devilStatue", count = 1, size = 2, minFromSpawn = 6, maxFromSpawn = 22, minApart = 5 },
		{ kind = "structure", count = 2, size = 3, minFromSpawn = 7, maxFromSpawn = 30, minApart = 5 },
		{ kind = "chest", count = 3, size = 1, minFromSpawn = 4, maxFromSpawn = 30, minApart = 4 },
	},
	props = {
		{ kind = "tree", weight = 6 },
		{ kind = "rock", weight = 3 },
		{ kind = "bush", weight = 4 },
	},
	propDensity = 0.3,
	wobble = 2,
}

local ACTS: { ActDef } = { ACT_1 }

local ActDefs = {}

-- The definition for a 1-based act number; acts past the last repeat it.
function ActDefs.forAct(actIndex: number): ActDef
	return ACTS[math.min(math.max(actIndex, 1), #ACTS)]
end

return ActDefs
