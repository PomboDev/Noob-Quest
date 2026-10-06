--!strict

--[=[
	World, server side: the act's logical grid and the gameplay objects.

	The server holds only what gameplay needs: the generated act (tile ids and
	points of interest), the nav grid for enemies, and a few Instances players
	touch (teleporter, statues, chests, the exit portal) with their prompts.
	It never builds the thousands of tiles and props: every client builds those
	from the same seed (see WorldControllerClient), so switching acts is just
	forgetting the grid and generating the next one.

	The run feature calls `generate`, then listens to `observeInteract`.

	Heroes are placed at the spawn and held in place until the client says the
	ground under it is built (`mapReady`), so nobody falls through a map that
	is still streaming in. A hero who falls off the world is put back at the spawn.
]=]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local ActDefs = require("@Features/world/modules/ActDefs")
local ActSpace = require("@Features/world/modules/ActSpace")
local ActTypes = require("@Features/world/modules/ActTypes")
local GenerateAct = require("@Features/world/modules/GenerateAct")
local Log = require("@Core/Log")
local NavGrid = require("@Features/enemies/modules/NavGrid")
local Network = require("@Core/Network")
local RateLimit = require("@Core/RateLimit")
local TileSet = require("@Features/world/modules/TileSet")

local Packet = Network.Packet

type Act = ActTypes.Act

export type InteractCallback = (kind: string, id: string, player: Player) -> ()

type Interactable = {
	id: string,
	kind: string,
	model: Instance,
	prompt: ProximityPrompt,
	-- Used up by the first use (statues, chests).
	oneShot: boolean,
	used: boolean,
}

local WorldService = {}

-- A hero this far below the walking surface has fallen off the map.
local KILL_DEPTH = 40
-- How long a hero is held while the client builds the ground under it.
local HOLD_TIMEOUT = 15
local PORTAL_ID = "portal"

local network: Network.ServerNetwork

local act: Act? = nil
local actIndex = 0
local navGrid: NavGrid.Grid? = nil
local gameplay: Folder? = nil
local interactables: { [string]: Interactable } = {}
local interactCallbacks: { InteractCallback } = {}
-- Heroes held until their client has built the ground, with the act they wait for.
local held: { [Player]: number } = {}

local requestLimit = RateLimit.new({ burst = 3, perSecond = 0.5 })
local readyLimit = RateLimit.new({ burst = 3, perSecond = 0.5 })
local hashLimit = RateLimit.new({ burst = 3, perSecond = 0.5 })

local function rootOf(player: Player): BasePart?
	local character = player.Character
	local root = if character then character:FindFirstChild("HumanoidRootPart") else nil
	if root and root:IsA("BasePart") then
		return root
	end
	return nil
end

local function groundPoint(x: number, z: number): Vector3
	return Vector3.new(x, ActSpace.GROUND_Y, z)
end

local function release(player: Player)
	held[player] = nil
	local root = rootOf(player)
	if root then
		root.Anchored = false
	end
end

-- Puts a hero at the spawn. `hold` keeps it still until the client has built the ground.
local function placeHero(player: Player, hold: boolean)
	local current = act
	local character = player.Character
	local root = rootOf(player)
	if current == nil or character == nil or root == nil then
		return
	end

	local spawnPoi = ActSpace.poisOfKind(current, "spawn")[1]
	if spawnPoi == nil then
		return
	end

	-- Spread players over the spawn plaza.
	local centerX, centerZ = ActSpace.poiCenter(current, spawnPoi)
	local slot = 0
	for _, other in Players:GetPlayers() do
		if other == player then
			break
		end
		slot += 1
	end
	local offsetX = (slot % 4 - 1.5) * 4
	local offsetZ = (slot // 4) * 4

	root.AssemblyLinearVelocity = Vector3.zero
	root.AssemblyAngularVelocity = Vector3.zero
	character:PivotTo(CFrame.new(centerX + offsetX, ActSpace.GROUND_Y + 5, centerZ + offsetZ))

	if hold then
		root.Anchored = true
		held[player] = actIndex
		local waitingFor = actIndex
		task.delay(HOLD_TIMEOUT, function()
			if held[player] == waitingFor then
				Log.warn(`{player.Name}'s client never built the map, releasing`)
				release(player)
			end
		end)
	end
end

local function clear()
	for _, interactable in interactables do
		interactable.model:Destroy()
	end
	table.clear(interactables)
	if gameplay then
		gameplay:ClearAllChildren()
	end
end

local function structureModel(kind: string): Model?
	local assets = game:GetService("ReplicatedStorage"):FindFirstChild("Assets")
	local folder = if assets then assets:FindFirstChild("Structures") else nil
	local prefab = if folder then folder:FindFirstChild(kind) else nil
	return if prefab and prefab:IsA("Model") then prefab:Clone() else nil
end

local function anchoredPart(name: string, size: Vector3, position: Vector3, color: Color3, parent: Instance): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.Position = position
	part.Color = color
	part.Anchored = true
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Parent = parent
	return part
end

-- The stand-in for a structure with no prefab: a coloured block or pad.
local function greyboxStructure(kind: string, position: Vector3): (Model, BasePart)
	local model = Instance.new("Model")
	model.Name = kind
	local ground = position.Y
	local main: Part

	if kind == "teleporter" then
		main = anchoredPart(
			"Pad",
			Vector3.new(0.6, 12, 12),
			position + Vector3.new(0, 0.3, 0),
			Color3.fromRGB(70, 200, 230),
			model
		)
		main.Shape = Enum.PartType.Cylinder
		main.CFrame = CFrame.new(position + Vector3.new(0, 0.3, 0)) * CFrame.Angles(0, 0, math.rad(90))
		main.Material = Enum.Material.Neon
		anchoredPart(
			"Beacon",
			Vector3.new(2, 14, 2),
			Vector3.new(position.X, ground + 7, position.Z),
			Color3.fromRGB(190, 250, 255),
			model
		).Material =
			Enum.Material.Neon
	elseif kind == "portal" then
		main = anchoredPart(
			"Portal",
			Vector3.new(10, 14, 1.5),
			position + Vector3.new(0, 7, 0),
			Color3.fromRGB(170, 90, 255),
			model
		)
		main.Material = Enum.Material.Neon
		main.Transparency = 0.2
	elseif kind == "angelStatue" then
		main = anchoredPart(
			"Statue",
			Vector3.new(3, 8, 3),
			position + Vector3.new(0, 4, 0),
			Color3.fromRGB(245, 245, 235),
			model
		)
		main.Material = Enum.Material.Marble
		anchoredPart(
			"Halo",
			Vector3.new(4, 0.4, 4),
			position + Vector3.new(0, 8.6, 0),
			Color3.fromRGB(255, 230, 120),
			model
		).Material =
			Enum.Material.Neon
	elseif kind == "devilStatue" then
		main = anchoredPart(
			"Statue",
			Vector3.new(3, 8, 3),
			position + Vector3.new(0, 4, 0),
			Color3.fromRGB(120, 30, 30),
			model
		)
		main.Material = Enum.Material.Basalt
		anchoredPart(
			"Horns",
			Vector3.new(4, 1, 1),
			position + Vector3.new(0, 8.5, 0),
			Color3.fromRGB(255, 80, 40),
			model
		).Material =
			Enum.Material.Neon
	else
		-- chest
		main = anchoredPart(
			"Chest",
			Vector3.new(3.5, 2.2, 2.4),
			position + Vector3.new(0, 1.1, 0),
			Color3.fromRGB(150, 100, 50),
			model
		)
		main.Material = Enum.Material.Wood
		anchoredPart(
			"Lock",
			Vector3.new(0.8, 0.8, 0.3),
			position + Vector3.new(0, 1.3, 1.25),
			Color3.fromRGB(255, 210, 70),
			model
		)
	end

	model.PrimaryPart = main
	return model, main
end

local PROMPTS: { [string]: { action: string, object: string, hold: number, oneShot: boolean } } = {
	teleporter = { action = "Charge", object = "Teleporter", hold = 1, oneShot = false },
	portal = { action = "Enter", object = "Exit Portal", hold = 0.5, oneShot = false },
	angelStatue = { action = "Pray", object = "Angel Statue", hold = 0.8, oneShot = true },
	devilStatue = { action = "Bargain", object = "Devil Statue", hold = 0.8, oneShot = true },
	chest = { action = "Open", object = "Chest", hold = 0.5, oneShot = true },
}

local function addInteractable(id: string, kind: string, position: Vector3)
	local spec = PROMPTS[kind]
	local folder = gameplay
	if spec == nil or folder == nil then
		return
	end

	local model: Model
	local anchor: BasePart
	local prefab = structureModel(kind)
	local prefabAnchor = if prefab then prefab.PrimaryPart or prefab:FindFirstChildWhichIsA("BasePart", true) else nil
	if prefab and prefabAnchor then
		prefab:PivotTo(CFrame.new(position))
		model, anchor = prefab, prefabAnchor
	else
		model, anchor = greyboxStructure(kind, position)
	end
	model.Name = id
	model.Parent = folder

	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText = spec.action
	prompt.ObjectText = spec.object
	prompt.HoldDuration = spec.hold
	prompt.MaxActivationDistance = 12
	prompt.RequiresLineOfSight = false
	prompt.Parent = anchor

	local interactable: Interactable = {
		id = id,
		kind = kind,
		model = model,
		prompt = prompt,
		oneShot = spec.oneShot,
		used = false,
	}
	interactables[id] = interactable

	prompt.Triggered:Connect(function(player)
		if interactable.used or not prompt.Enabled then
			return
		end
		if interactable.oneShot then
			interactable.used = true
			prompt.Enabled = false
		end
		for _, callback in interactCallbacks do
			task.spawn(callback, kind, id, player)
		end
	end)
end

-- Generates an act and builds its gameplay objects. Clients are told the seed and
-- build the map themselves. Errors if the points of interest can't be placed.
function WorldService.generate(newActIndex: number, seed: number): Act
	local started = os.clock()
	local def = ActDefs.forAct(newActIndex)
	local generated = GenerateAct.generate(def, seed)

	clear()
	act = generated
	actIndex = newActIndex
	navGrid = ActSpace.navGrid(generated, TileSet.DEFAULT)

	for _, kind in { "teleporter", "angelStatue", "devilStatue", "chest" } do
		for _, poi in ActSpace.poisOfKind(generated, kind :: ActTypes.PoiKind) do
			local x, z = ActSpace.poiCenter(generated, poi)
			addInteractable(poi.id, kind, groundPoint(x, z))
		end
	end

	Log.debug(
		`Generated {def.id} (seed {seed}) in {math.floor((os.clock() - started) * 1000)} ms: {generated.layoutAttempts} layouts, {generated.wfcAttempts} WFC runs{if generated.relaxed
			then ", relaxed"
			else ""}`
	)

	network:fireAllClients("onAct", seed, newActIndex, GenerateAct.VERSION)
	for _, player in Players:GetPlayers() do
		placeHero(player, true)
	end
	return generated
end

-- Forgets the act and its objects (the run ended).
function WorldService.reset()
	clear()
	act = nil
	navGrid = nil
	actIndex = 0
	table.clear(held)
end

function WorldService.getAct(): Act?
	return act
end

function WorldService.getActIndex(): number
	return actIndex
end

function WorldService.getNavGrid(): NavGrid.Grid?
	return navGrid
end

function WorldService.getGroundY(): number
	return ActSpace.GROUND_Y
end

-- The centre of the act's first point of interest of a kind, or nil.
function WorldService.positionOf(kind: ActTypes.PoiKind): Vector3?
	local current = act
	local poi = if current then ActSpace.poisOfKind(current, kind)[1] else nil
	if current and poi then
		local x, z = ActSpace.poiCenter(current, poi)
		return groundPoint(x, z)
	end
	return nil
end

-- Every point of interest of a kind, as ground positions.
function WorldService.positionsOf(kind: ActTypes.PoiKind): { Vector3 }
	local positions = {}
	local current = act
	if current then
		for _, poi in ActSpace.poisOfKind(current, kind) do
			local x, z = ActSpace.poiCenter(current, poi)
			table.insert(positions, groundPoint(x, z))
		end
	end
	return positions
end

-- Opens the exit portal where the teleporter is (or at the spawn without one).
function WorldService.openPortal()
	if interactables[PORTAL_ID] then
		return
	end
	local position = WorldService.positionOf("teleporter") or WorldService.positionOf("spawn")
	if position then
		addInteractable(PORTAL_ID, "portal", position + Vector3.new(0, 0, 14))
	end
end

function WorldService.closePortal()
	local portal = interactables[PORTAL_ID]
	if portal then
		portal.model:Destroy()
		interactables[PORTAL_ID] = nil
	end
end

-- Turns an object's prompt on or off, e.g. the teleporter while it is charging.
function WorldService.setInteractable(id: string, enabled: boolean)
	local interactable = interactables[id]
	if interactable and not interactable.used then
		interactable.prompt.Enabled = enabled
	end
end

-- Puts every hero back at the spawn (a new act, or a run starting again).
function WorldService.sendToSpawn(player: Player)
	placeHero(player, true)
end

-- Runs `callback(kind, id, player)` whenever a player uses an object.
function WorldService.observeInteract(callback: InteractCallback): () -> ()
	table.insert(interactCallbacks, callback)
	return function()
		local index = table.find(interactCallbacks, callback)
		if index then
			table.remove(interactCallbacks, index)
		end
	end
end

local function watchPlayer(player: Player)
	player.CharacterAdded:Connect(function()
		-- Wait for the character to be whole before moving it.
		task.defer(function()
			if rootOf(player) == nil and player.Character then
				player.Character:WaitForChild("HumanoidRootPart", 5)
			end
			placeHero(player, true)
		end)
	end)
	if player.Character then
		placeHero(player, true)
	end
end

function WorldService.init()
	network = Network.server("World", WorldService, {
		requestAct = {}, -- client -> server
		mapReady = { Packet.NumberU8 }, -- client -> server: act index
		reportHash = { Packet.NumberU32 }, -- client -> server: GenerateAct.hash of its map
		onAct = { Packet.NumberU32, Packet.NumberU8, Packet.NumberU8 }, -- seed, act index, generator version
	})

	local folder = Instance.new("Folder")
	folder.Name = "Gameplay"
	folder.Parent = workspace
	gameplay = folder

	for _, player in Players:GetPlayers() do
		watchPlayer(player)
	end
	Players.PlayerAdded:Connect(watchPlayer)
	Players.PlayerRemoving:Connect(function(player)
		held[player] = nil
	end)

	-- The kill plane: anyone who has fallen off the world goes back to the spawn.
	local sinceCheck = 0
	RunService.Heartbeat:Connect(function(dt)
		sinceCheck += dt
		if sinceCheck < 0.25 or act == nil then
			return
		end
		sinceCheck = 0

		for _, player in Players:GetPlayers() do
			local root = rootOf(player)
			if root and root.Position.Y < ActSpace.GROUND_Y - KILL_DEPTH and held[player] == nil then
				placeHero(player, false)
			end
		end
	end)
end

-- Network (client -> server)
function WorldService.requestAct(player: Player)
	if not RateLimit.take(requestLimit, player) then
		return
	end
	local current = act
	if current then
		network:fireClient(player, "onAct", current.seed, actIndex, GenerateAct.VERSION)
	end
end

function WorldService.mapReady(player: Player, readyIndex: number)
	if not RateLimit.take(readyLimit, player) then
		return
	end
	if held[player] ~= nil and held[player] == readyIndex then
		release(player)
	end
end

-- A dev check: a client whose map differs from the server's has a generator that
-- has drifted, and its map doesn't match the nav grid.
function WorldService.reportHash(player: Player, hash: number)
	local current = act
	if current == nil or not RateLimit.take(hashLimit, player) then
		return
	end

	if hash ~= GenerateAct.hash(current) then
		Log.warn(`{player.Name}'s map differs from the server's (act {actIndex}, seed {current.seed})`)
	else
		Log.debug(`{player.Name}'s map matches the server's`)
	end
end

return WorldService
