--!strict

--[=[
	The world, as part of the simulation: the act's walkable grid, the objects
	heroes use (the lobby portal, the teleporter, statues, chests, the exit
	portal) and the camps of enemies.

	It holds data only. The adapter turns the `objectAdded`, `objectRemoved`
	and `objectEnabled` events into Instances with prompts, and an `actGenerated`
	event into the message that makes every client build the map from the seed.

	Everything an enemy or a chest will drop is fixed here, when the act is
	generated: each camp member and object gets a `lootSeed` from the run's
	loot seed (which clients never see), so the loot doesn't depend on what
	happens during the run (see LootSim).

	Pure and deterministic: the same (mapSeed, lootSeed, act) always gives the
	same act, objects, camps and seeds.
]=]

local ActDefs = require("@Features/world/modules/ActDefs")
local ActSpace = require("@Features/world/modules/ActSpace")
local ActTypes = require("@Features/world/modules/ActTypes")
local Checksum = require("@Features/sim/modules/Checksum")
local GenerateAct = require("@Features/world/modules/GenerateAct")
local LobbySpace = require("@Features/world/modules/LobbySpace")
local Log = require("@Core/Log")
local NavGrid = require("@Features/enemies/modules/NavGrid")
local Rng = require("@Core/Rng")
local SimContext = require("@Features/sim/modules/SimContext")
local TileSet = require("@Features/world/modules/TileSet")

type Act = ActTypes.Act

export type Object = {
	id: string,
	-- What a hero's input carries to use it (also its prompt's "InteractId").
	objectId: number,
	kind: string,
	x: number,
	z: number,
	-- Used up by the first use (statues, chests).
	oneShot: boolean,
	used: boolean,
	enabled: boolean,
	-- Survives a new act (the lobby portal).
	persistent: boolean,
	-- Fixes what a chest pays and what a statue's guards drop.
	lootSeed: number,
}

export type CampMember = { defId: string, x: number, z: number, lootSeed: number }

-- A camp in world coordinates: its centre and where each enemy stands.
export type Camp = { id: string, x: number, z: number, enemies: { CampMember } }

export type State = {
	act: Act?,
	actIndex: number,
	-- The act's walkable cells, nil in the lobby.
	grid: NavGrid.Grid?,
	-- In the order they were added.
	objects: { Object },
	byId: { [string]: Object },
	byObject: { [number]: Object },
	nextObjectId: number,
	camps: { Camp },
}

local WorldSim = {}

-- The lobby portal is always object 1.
WorldSim.LOBBY_PORTAL = "lobbyPortal"
WorldSim.LOBBY_PORTAL_OBJECT = 1
-- A hero may use an object this close: its prompt's reach (12) and a little
-- more, since the hero keeps walking while the input is on its way.
WorldSim.REACH = 12 + 6
WorldSim.PORTAL_ID = "portal"
-- The exit portal opens this far beyond the teleporter (or the spawn).
local PORTAL_OFFSET = 14
-- Generation is tried this many times with new seeds before giving up.
local MAX_ATTEMPTS = 3

-- Which objects are used up by one use.
local ONE_SHOT: { [string]: boolean } = {
	teleporter = false,
	portal = false,
	lobbyPortal = false,
	angelStatue = true,
	devilStatue = true,
	chest = true,
}

local OBJECT_KINDS = { "teleporter", "angelStatue", "devilStatue", "chest" }

-- `ctx` is nil for an object nobody needs to hear about (the lobby portal).
local function addObject(
	state: State,
	ctx: SimContext.Ctx?,
	id: string,
	kind: string,
	x: number,
	z: number,
	persistent: boolean,
	lootSeed: number
): Object
	local object: Object = {
		id = id,
		objectId = state.nextObjectId,
		kind = kind,
		x = x,
		z = z,
		oneShot = ONE_SHOT[kind] == true,
		used = false,
		enabled = true,
		persistent = persistent,
		lootSeed = lootSeed,
	}
	state.nextObjectId += 1
	table.insert(state.objects, object)
	state.byId[id] = object
	state.byObject[object.objectId] = object
	if ctx then
		SimContext.emit(ctx, { kind = "objectAdded", id = id, objectId = object.objectId, object = kind, x = x, z = z })
	end
	return object
end

function WorldSim.new(): State
	local state: State = {
		act = nil,
		actIndex = 0,
		grid = nil,
		objects = {},
		byId = {},
		byObject = {},
		nextObjectId = 1,
		camps = {},
	}
	-- Not announced: the adapter builds the lobby and its portal itself.
	addObject(state, nil, WorldSim.LOBBY_PORTAL, "lobbyPortal", LobbySpace.X, LobbySpace.PORTAL_Z, true, 0)
	return state
end

-- Removes the act's objects (the lobby's stay) and numbers new ones from 2.
local function clear(state: State, ctx: SimContext.Ctx)
	local kept: { Object } = {}
	for _, object in state.objects do
		if object.persistent then
			table.insert(kept, object)
		else
			state.byId[object.id] = nil
			state.byObject[object.objectId] = nil
			SimContext.emit(ctx, { kind = "objectRemoved", id = object.id })
		end
	end
	state.objects = kept
	state.nextObjectId = 1 + #kept
end

-- Forgets the act and its objects (the run ended).
function WorldSim.reset(state: State, ctx: SimContext.Ctx)
	clear(state, ctx)
	state.act = nil
	state.actIndex = 0
	state.grid = nil
	state.camps = {}
end

-- Generates act `actIndex` for a run and builds its objects and camps. Tries
-- up to three seeds derived from `mapSeed`; false if none works. Clients are
-- told the seed and build the map themselves.
function WorldSim.generate(
	state: State,
	ctx: SimContext.Ctx,
	actIndex: number,
	mapSeed: number,
	lootSeed: number
): boolean
	local def = ActDefs.forAct(actIndex)
	local actSeed = Rng.derive(mapSeed, actIndex)

	local generated: Act? = nil
	local seed = 0
	for attempt = 1, MAX_ATTEMPTS do
		seed = Rng.derive(actSeed, attempt)
		local ok, result = pcall(GenerateAct.generate, def, seed)
		if ok then
			generated = result :: Act
			break
		end
		Log.warn(`Act {actIndex} failed to generate (attempt {attempt}): {result}`)
	end
	if generated == nil then
		return false
	end

	clear(state, ctx)
	state.act = generated
	state.actIndex = actIndex
	state.grid = ActSpace.navGrid(generated, TileSet.DEFAULT)
	state.camps = {}

	-- Every loot seed of the act, in the order things are made.
	local actLoot = Rng.derive(lootSeed, actIndex)
	local serial = 0
	local function nextLootSeed(): number
		serial += 1
		return Rng.derive(actLoot, serial)
	end

	for _, camp in generated.camps do
		local centerX, centerZ = ActSpace.campPosition(generated, camp)
		local members: { CampMember } = {}
		for _, member in camp.enemies do
			table.insert(members, {
				defId = member.defId,
				x = centerX + member.dx,
				z = centerZ + member.dz,
				lootSeed = nextLootSeed(),
			})
		end
		table.insert(state.camps, { id = camp.id, x = centerX, z = centerZ, enemies = members })
	end

	for _, kind in OBJECT_KINDS do
		for _, poi in ActSpace.poisOfKind(generated, kind :: ActTypes.PoiKind) do
			local x, z = ActSpace.poiCenter(generated, poi)
			addObject(state, ctx, poi.id, kind, x, z, false, nextLootSeed())
		end
	end

	SimContext.emit(ctx, { kind = "actGenerated", seed = seed, act = actIndex })
	return true
end

-- The centre of the act's first point of interest of a kind, or nil.
function WorldSim.positionOf(state: State, kind: ActTypes.PoiKind): (number?, number?)
	local act = state.act
	local poi = if act then ActSpace.poisOfKind(act, kind)[1] else nil
	if act and poi then
		return ActSpace.poiCenter(act, poi)
	end
	return nil, nil
end

-- Where an object is, by the id it was created with.
function WorldSim.positionOfObject(state: State, id: string): (number?, number?)
	local object = state.byId[id]
	if object then
		return object.x, object.z
	end
	return nil, nil
end

function WorldSim.get(state: State, id: string): Object?
	return state.byId[id]
end

-- Opens the exit portal beyond the teleporter (or the spawn without one).
function WorldSim.openPortal(state: State, ctx: SimContext.Ctx)
	if state.byId[WorldSim.PORTAL_ID] then
		return
	end
	local x, z = WorldSim.positionOf(state, "teleporter")
	if x == nil or z == nil then
		x, z = WorldSim.positionOf(state, "spawn")
	end
	if x and z then
		addObject(state, ctx, WorldSim.PORTAL_ID, "portal", x, z + PORTAL_OFFSET, false, 0)
	end
end

function WorldSim.closePortal(state: State, ctx: SimContext.Ctx)
	local portal = state.byId[WorldSim.PORTAL_ID]
	if portal == nil then
		return
	end
	state.byId[portal.id] = nil
	state.byObject[portal.objectId] = nil
	local index = table.find(state.objects, portal)
	if index then
		table.remove(state.objects, index)
	end
	SimContext.emit(ctx, { kind = "objectRemoved", id = portal.id })
end

-- Turns an object on or off, e.g. the teleporter while it is charging.
function WorldSim.setEnabled(state: State, ctx: SimContext.Ctx, id: string, enabled: boolean)
	local object = state.byId[id]
	if object and not object.used and object.enabled ~= enabled then
		object.enabled = enabled
		SimContext.emit(ctx, { kind = "objectEnabled", id = id, enabled = enabled })
	end
end

-- A hero's input used an object: the object if it can be used from (x, z)
-- (it exists, is on, isn't used up and is within reach), else nil. A one-shot
-- object is used up.
function WorldSim.use(state: State, ctx: SimContext.Ctx, x: number, z: number, objectId: number): Object?
	local object = state.byObject[objectId]
	if object == nil or object.used or not object.enabled then
		return nil
	end

	local dx, dz = object.x - x, object.z - z
	if dx * dx + dz * dz > WorldSim.REACH * WorldSim.REACH then
		return nil
	end

	if object.oneShot then
		object.used = true
		object.enabled = false
		SimContext.emit(ctx, { kind = "objectEnabled", id = object.id, enabled = false })
	end
	return object
end

-- The grid a hero standing at (x, z) walks on: the lobby's over the lobby, else the act's.
function WorldSim.gridAt(state: State, x: number, z: number): NavGrid.Grid
	if LobbySpace.contains(x, z) then
		return LobbySpace.navGrid()
	end
	return state.grid or LobbySpace.navGrid()
end

-- Where the hero in `slot` starts: spread over the act's spawn plaza, or the lobby.
function WorldSim.spawnPoint(state: State, slot: number): (number, number)
	local centerX, centerZ = LobbySpace.X, LobbySpace.SPAWN_Z
	local act = state.act
	local spawn = if act then ActSpace.poisOfKind(act, "spawn")[1] else nil
	if act and spawn then
		centerX, centerZ = ActSpace.poiCenter(act, spawn)
	end

	local index = slot - 1
	return centerX + (index % 4 - 1.5) * 4, centerZ + (index // 4) * 4
end

function WorldSim.checksum(hash: Checksum.Hash, state: State)
	Checksum.section(hash, "world")
	Checksum.number(hash, state.actIndex)
	Checksum.number(hash, state.nextObjectId)
	local act = state.act
	if act then
		Checksum.number(hash, act.seed)
	end
	for _, object in state.objects do
		Checksum.string(hash, object.id)
		Checksum.number(hash, object.objectId)
		Checksum.bool(hash, object.used)
		Checksum.bool(hash, object.enabled)
		Checksum.number(hash, object.lootSeed)
	end
	for _, camp in state.camps do
		for _, member in camp.enemies do
			Checksum.number(hash, member.lootSeed)
		end
	end
end

return WorldSim
