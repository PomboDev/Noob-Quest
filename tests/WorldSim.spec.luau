local ActDefs = require("../src/features/world/modules/ActDefs")
local ActSpace = require("../src/features/world/modules/ActSpace")
local Expect = require("./Expect")
local LobbySpace = require("../src/features/world/modules/LobbySpace")
local SimContext = require("../src/features/sim/modules/SimContext")
local WorldSim = require("../src/features/world/modules/WorldSim")

local function eventsOf(ctx: SimContext.Ctx, kind: string): { SimContext.Event }
	local found = {}
	for _, event in ctx.events do
		if event.kind == kind then
			table.insert(found, event)
		end
	end
	return found
end

local function generated(mapSeed: number, lootSeed: number): (WorldSim.State, SimContext.Ctx)
	local state, ctx = WorldSim.new(), SimContext.new()
	Expect.equal(WorldSim.generate(state, ctx, 1, mapSeed, lootSeed), true)
	return state, ctx
end

local function objectOfKind(state: WorldSim.State, kind: string): WorldSim.Object
	for _, object in state.objects do
		if object.kind == kind then
			return object
		end
	end
	error(`no {kind}`)
end

return {
	["the lobby has its portal as object 1, and nothing else"] = function()
		local state = WorldSim.new()
		Expect.equal(#state.objects, 1)
		Expect.equal(state.objects[1].objectId, 1)
		Expect.equal(state.objects[1].kind, "lobbyPortal")
		Expect.equal(state.objects[1].persistent, true)
		Expect.equal(state.grid, nil)
		Expect.equal(#state.camps, 0)
	end,

	["generating an act builds its objects and camps and says so"] = function()
		local state, ctx = generated(7, 8)
		Expect.equal(state.actIndex, 1)
		Expect.equal(state.act ~= nil, true)
		Expect.equal(state.grid ~= nil, true)

		local kinds: { [string]: number } = {}
		for _, object in state.objects do
			kinds[object.kind] = (kinds[object.kind] or 0) + 1
		end
		Expect.equal(kinds.teleporter, 1)
		Expect.equal(kinds.angelStatue, 1)
		Expect.equal(kinds.devilStatue, 1)
		Expect.equal(kinds.chest, 8)
		Expect.equal(
			#eventsOf(ctx, "objectAdded"),
			11,
			"the act's own objects (the lobby portal is built by the adapter)"
		)
		Expect.equal(#eventsOf(ctx, "actGenerated"), 1)
	end,

	["the same seeds give the same act, objects and loot seeds"] = function()
		local function describe(state: WorldSim.State): string
			local lines = {}
			for _, object in state.objects do
				table.insert(
					lines,
					`{object.id} {object.objectId} {object.kind} {object.x} {object.z} {object.lootSeed}`
				)
			end
			for _, camp in state.camps do
				for _, member in camp.enemies do
					table.insert(lines, `{camp.id} {member.defId} {member.x} {member.z} {member.lootSeed}`)
				end
			end
			return table.concat(lines, "\n")
		end

		local a, b = generated(7, 8), generated(7, 8)
		Expect.equal(describe(a), describe(b))
		Expect.equal(describe(a) ~= describe(generated(7, 9)), true, "another loot seed")
		Expect.equal(describe(a) ~= describe(generated(8, 8)), true, "another map seed")
		Expect.equal(generated(7, 8).act.seed, generated(7, 9).act.seed, "the loot seed doesn't change the map")
	end,

	["generating again replaces the objects and numbers them afresh"] = function()
		local state, ctx = generated(7, 8)
		local first = #state.objects
		table.clear(ctx.events)

		Expect.equal(WorldSim.generate(state, ctx, 1, 9, 8), true)
		Expect.equal(#state.objects, first, "the same kinds of objects")
		Expect.equal(#eventsOf(ctx, "objectRemoved"), first - 1, "all but the lobby portal went")
		Expect.equal(state.objects[1].kind, "lobbyPortal")
		Expect.equal(state.objects[2].objectId, 2)
		Expect.equal(state.objects[#state.objects].objectId, first)
		Expect.equal(state.byObject[1], state.objects[1])
	end,

	["reset forgets the act"] = function()
		local state, ctx = generated(7, 8)
		WorldSim.reset(state, ctx)
		Expect.equal(#state.objects, 1)
		Expect.equal(state.act, nil)
		Expect.equal(state.grid, nil)
		Expect.equal(#state.camps, 0)
		Expect.equal(state.nextObjectId, 2)
	end,

	["an object can be used from within reach, and not from further away"] = function()
		local state, ctx = generated(7, 8)
		local teleporter = objectOfKind(state, "teleporter")
		Expect.equal(
			WorldSim.use(state, ctx, teleporter.x + WorldSim.REACH + 0.5, teleporter.z, teleporter.objectId),
			nil
		)
		Expect.equal(
			WorldSim.use(state, ctx, teleporter.x + WorldSim.REACH - 0.5, teleporter.z, teleporter.objectId),
			teleporter
		)
		Expect.equal(WorldSim.use(state, ctx, teleporter.x, teleporter.z, 9999), nil, "no such object")
	end,

	["a one-shot object is used up, a teleporter isn't, and a disabled one can't be used"] = function()
		local state, ctx = generated(7, 8)
		local chest = objectOfKind(state, "chest")
		Expect.equal(WorldSim.use(state, ctx, chest.x, chest.z, chest.objectId), chest)
		Expect.equal(chest.used, true)
		Expect.equal(chest.enabled, false)
		Expect.equal(WorldSim.use(state, ctx, chest.x, chest.z, chest.objectId), nil)
		local told = eventsOf(ctx, "objectEnabled")
		Expect.equal(told[#told].id, chest.id)
		Expect.equal(told[#told].enabled, false)

		local teleporter = objectOfKind(state, "teleporter")
		Expect.equal(WorldSim.use(state, ctx, teleporter.x, teleporter.z, teleporter.objectId), teleporter)
		Expect.equal(WorldSim.use(state, ctx, teleporter.x, teleporter.z, teleporter.objectId), teleporter)
		WorldSim.setEnabled(state, ctx, teleporter.id, false)
		Expect.equal(WorldSim.use(state, ctx, teleporter.x, teleporter.z, teleporter.objectId), nil)
		WorldSim.setEnabled(state, ctx, teleporter.id, true)
		Expect.equal(WorldSim.use(state, ctx, teleporter.x, teleporter.z, teleporter.objectId), teleporter)
	end,

	["the exit portal opens beyond the teleporter once and closes"] = function()
		local state, ctx = generated(7, 8)
		local teleporter = objectOfKind(state, "teleporter")
		table.clear(ctx.events)

		WorldSim.openPortal(state, ctx)
		WorldSim.openPortal(state, ctx)
		local portal = WorldSim.get(state, WorldSim.PORTAL_ID) :: WorldSim.Object
		Expect.equal(portal.kind, "portal")
		Expect.equal(portal.x, teleporter.x)
		Expect.equal(portal.z, teleporter.z + 14)
		Expect.equal(#eventsOf(ctx, "objectAdded"), 1, "opened once")

		WorldSim.closePortal(state, ctx)
		Expect.equal(WorldSim.get(state, WorldSim.PORTAL_ID), nil)
		Expect.equal(state.byObject[portal.objectId], nil)
		Expect.equal(#eventsOf(ctx, "objectRemoved"), 1)
		WorldSim.closePortal(state, ctx)
		Expect.equal(#eventsOf(ctx, "objectRemoved"), 1, "closing twice does nothing")
	end,

	["grids: the lobby's over the lobby, the act's elsewhere"] = function()
		local state, ctx = generated(7, 8)
		Expect.equal(WorldSim.gridAt(state, LobbySpace.X, LobbySpace.Z), LobbySpace.navGrid())
		local x, z = ActSpace.poiCenter(state.act, state.act.pois[1])
		Expect.equal(WorldSim.gridAt(state, x, z), state.grid)

		WorldSim.reset(state, ctx)
		Expect.equal(WorldSim.gridAt(state, x, z), LobbySpace.navGrid(), "no act: the lobby's grid")
	end,

	["heroes start spread over the lobby, or the act's spawn once there is one"] = function()
		local state, ctx = generated(7, 8)
		local spawn = ActSpace.poisOfKind(state.act, "spawn")[1]
		local centerX, centerZ = ActSpace.poiCenter(state.act, spawn)
		local x1, z1 = WorldSim.spawnPoint(state, 1)
		local x2, z2 = WorldSim.spawnPoint(state, 2)
		Expect.equal(math.abs(x1 - centerX) <= 8 and math.abs(z1 - centerZ) <= 8, true)
		Expect.equal(x1 ~= x2 or z1 ~= z2, true)

		WorldSim.reset(state, ctx)
		local lx, lz = WorldSim.spawnPoint(state, 1)
		Expect.equal(LobbySpace.contains(lx, lz), true)
	end,

	["positions of points of interest and objects"] = function()
		local state = generated(7, 8)
		local x, z = WorldSim.positionOf(state, "teleporter")
		local teleporter = objectOfKind(state, "teleporter")
		Expect.equal(x, teleporter.x)
		Expect.equal(z, teleporter.z)
		local ox, oz = WorldSim.positionOfObject(state, teleporter.id)
		Expect.equal(ox, x)
		Expect.equal(oz, z)
		Expect.equal((WorldSim.positionOfObject(state, "nothing")), nil)
		Expect.equal((WorldSim.positionOf(WorldSim.new(), "teleporter")), nil, "no act, no teleporter")
		Expect.equal(ActDefs.forAct(1).id, state.act.id)
	end,
}
