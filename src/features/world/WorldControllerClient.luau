--!strict

--[=[
	World, client side: builds the map from the seed.

	The server says which act and seed are running; this generates the same
	grid (GenerateAct is pure and deterministic) and builds the tiles and props
	into workspace.Map a few at a time, nearest to the player first, so the
	ground around the hero exists at once and the rest follows without a hitch.
	Once the ground around the spawn is there it tells the server, which was
	holding the hero still until then.

	The map is destroyed and rebuilt for every act, and dropped when the
	players go back to the lobby, so nothing piles up.
]=]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local ActDefs = require("@Features/world/modules/ActDefs")
local ActSpace = require("@Features/world/modules/ActSpace")
local ActTypes = require("@Features/world/modules/ActTypes")
local Charm = require("@Packages/charm")
local GenerateAct = require("@Features/world/modules/GenerateAct")
local Log = require("@Core/Log")
local MapBuilder = require("@Features/world/modules/MapBuilder")
local NavGrid = require("@Features/enemies/modules/NavGrid")
local Network = require("@Core/Network")
local TileSet = require("@Features/world/modules/TileSet")

type Act = ActTypes.Act

local WorldController = {}

WorldController.state = {
	-- The act being played, for the minimap. nil in the lobby.
	act = Charm.atom(nil :: Act?),
	-- Where heroes can walk in the act (see HeroController), nil in the lobby.
	navGrid = Charm.atom(nil :: NavGrid.Grid?),
}

-- Tiles built per frame.
local TILES_PER_FRAME = 24
-- The nearest tiles that must exist before the hero is let go: 7 x 7 around it.
local READY_TILES = 49

local network: Network.ClientNetwork? = nil
local mapFolder: Folder? = nil
local building: RBXScriptConnection? = nil

local function stopBuilding()
	if building then
		building:Disconnect()
		building = nil
	end
end

-- Props grouped by the tile they stand on, so a tile brings its props with it.
local function propsByTile(act: Act): { [number]: { ActTypes.Prop } }
	local grouped: { [number]: { ActTypes.Prop } } = {}
	for _, prop in act.props do
		local index = ActSpace.tileIndex(act, prop.x, prop.y)
		local list = grouped[index]
		if list == nil then
			list = {}
			grouped[index] = list
		end
		table.insert(list, prop)
	end
	return grouped
end

local function focusPoint(act: Act): (number, number)
	local character = Players.LocalPlayer.Character
	local root = if character then character:FindFirstChild("HumanoidRootPart") else nil
	if root and root:IsA("BasePart") then
		return root.Position.X, root.Position.Z
	end

	local spawnPoi = ActSpace.poisOfKind(act, "spawn")[1]
	if spawnPoi then
		return ActSpace.poiCenter(act, spawnPoi)
	end
	return 0, 0
end

local function buildMap(act: Act, actIndex: number)
	stopBuilding()
	if mapFolder then
		mapFolder:Destroy()
	end

	local folder = Instance.new("Folder")
	folder.Name = "Map"
	folder.Parent = workspace
	mapFolder = folder

	local grouped = propsByTile(act)
	-- Around the spawn first: that is where the hero is about to appear.
	local spawnPoi = ActSpace.poisOfKind(act, "spawn")[1]
	local focusX, focusZ = focusPoint(act)
	if spawnPoi then
		focusX, focusZ = ActSpace.poiCenter(act, spawnPoi)
	end
	local order = ActSpace.streamOrder(act, focusX, focusZ)

	local started = os.clock()
	local next = 1
	local reported = false

	building = RunService.Heartbeat:Connect(function()
		for _ = 1, TILES_PER_FRAME do
			local index = order[next]
			if index == nil then
				break
			end
			next += 1

			local x, y = (index - 1) % act.width, (index - 1) // act.width
			MapBuilder.tile(act, TileSet.DEFAULT, x, y, folder)
			local props = grouped[index]
			if props then
				for _, prop in props do
					MapBuilder.prop(act, prop, folder)
				end
			end
		end

		if not reported and (next > READY_TILES or order[next] == nil) then
			reported = true
			if network then
				network:fire("mapReady", actIndex)
			end
		end

		if order[next] == nil then
			stopBuilding()
			Log.debug(
				`Built the map ({#order} tiles, {#act.props} props) in {math.floor((os.clock() - started) * 1000)} ms`
			)
		end
	end)
end

-- Network (server -> client)
function WorldController.onAct(seed: number, actIndex: number, version: number)
	if version ~= GenerateAct.VERSION then
		Log.warn(`The server generates maps with version {version}, this client with {GenerateAct.VERSION}`)
	end

	local act = GenerateAct.generate(ActDefs.forAct(actIndex), seed)
	WorldController.state.act(act)
	WorldController.state.navGrid(ActSpace.navGrid(act, TileSet.DEFAULT))
	buildMap(act, actIndex)

	if network then
		network:fire("reportHash", GenerateAct.hash(act))
	end
end

-- The run is over: the map is not needed in the lobby.
function WorldController.onLobby()
	WorldController.state.act(nil)
	WorldController.state.navGrid(nil)
	stopBuilding()
	if mapFolder then
		mapFolder:Destroy()
		mapFolder = nil
	end
end

function WorldController.start()
	-- Yields until the server has registered the service.
	local connected = Network.client("World", WorldController)
	network = connected
	connected:fire("requestAct")
end

return WorldController
