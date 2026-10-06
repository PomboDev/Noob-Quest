--!strict

--[=[
	World, server side: builds what players see and touch for the world in the
	simulation (see WorldSim), and tells every client which act to build.

	The server holds only a few Instances players touch (the lobby, and the
	act's teleporter, statues, chests and exit portal) with their prompts. It
	never builds the thousands of tiles and props: every client builds those
	from the same seed (see WorldControllerClient), so switching acts is just
	forgetting the grid and generating the next one. The sim decides what
	exists; this reacts to its events (`actGenerated`, `objectAdded`,
	`objectRemoved`, `objectEnabled`, `lobby`).

	Between runs everyone is in the lobby: a plain platform far from the act,
	with a portal that starts the next run.

	Heroes are held in place when an act is generated, until the client says
	the ground under it is built (`mapReady`), so nobody walks around a map
	that is still streaming in. Holding only changes the inputs given to the
	sim, so it is part of what a replay records.

	Objects are used through the hero's input, not through ProximityPrompt's
	own server event: the player's character stays at the spawn on the server,
	and the sim checks the distance against the hero's simulated position. The
	prompts only show the object and time the hold.
]=]

local Players = game:GetService("Players")

local ActSpace = require("@Features/world/modules/ActSpace")
local GenerateAct = require("@Features/world/modules/GenerateAct")
local HeroService = require("@Features/heroes/HeroServiceServer")
local LobbySpace = require("@Features/world/modules/LobbySpace")
local Log = require("@Core/Log")
local Network = require("@Core/Network")
local RateLimit = require("@Core/RateLimit")
local SimContext = require("@Features/sim/modules/SimContext")
local SimService = require("@Features/sim/SimServiceServer")
local WorldSim = require("@Features/world/modules/WorldSim")

local Packet = Network.Packet

type Interactable = {
	model: Instance,
	prompt: ProximityPrompt,
}

local WorldService = {}

-- How long a hero is held while the client builds the ground under it.
local HOLD_TIMEOUT = 15
-- The lobby: a square platform this far along X, so it never overlaps an act.
local LOBBY_X = LobbySpace.X
local LOBBY_Z = LobbySpace.Z
local LOBBY_SIZE = LobbySpace.SIZE
local LOBBY_PORTAL_Z = LobbySpace.PORTAL_Z

local network: Network.ServerNetwork

local gameplay: Folder? = nil
-- The Instances of the objects in the sim, by object id.
local interactables: { [string]: Interactable } = {}
-- Heroes held until their client has built the ground, with the act they wait for.
local held: { [Player]: number } = {}

local requestLimit = RateLimit.new({ burst = 3, perSecond = 0.5 })
local readyLimit = RateLimit.new({ burst = 3, perSecond = 0.5 })
local hashLimit = RateLimit.new({ burst = 3, perSecond = 0.5 })

local function groundPoint(x: number, z: number): Vector3
	return Vector3.new(x, ActSpace.GROUND_Y, z)
end

local function release(player: Player)
	held[player] = nil
	HeroService.setFrozen(player, false)
end

-- Keeps a hero still until its client has built the ground of act `forAct`.
local function hold(player: Player, forAct: number)
	HeroService.setFrozen(player, true)
	held[player] = forAct
	task.delay(HOLD_TIMEOUT, function()
		if held[player] == forAct then
			Log.warn(`{player.Name}'s client never built the map, releasing`)
			release(player)
		end
	end)
end

-- Destroys the act's objects. The lobby's stay.
local function destroy(id: string)
	local interactable = interactables[id]
	if interactable then
		interactable.model:Destroy()
		interactables[id] = nil
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
	elseif kind == "portal" or kind == "lobbyPortal" then
		main = anchoredPart(
			"Portal",
			Vector3.new(10, 14, 1.5),
			position + Vector3.new(0, 7, 0),
			if kind == "lobbyPortal" then Color3.fromRGB(80, 220, 120) else Color3.fromRGB(170, 90, 255),
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
	lobbyPortal = { action = "Start run", object = "Run Portal", hold = 0.8, oneShot = false },
	angelStatue = { action = "Pray", object = "Angel Statue", hold = 0.8, oneShot = true },
	devilStatue = { action = "Bargain", object = "Devil Statue", hold = 0.8, oneShot = true },
	chest = { action = "Open", object = "Chest", hold = 0.5, oneShot = true },
}

-- Builds an object and its prompt. A hero uses it by sending `objectId` in its input.
local function addInteractable(id: string, objectId: number, kind: string, position: Vector3)
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
	prompt:SetAttribute("InteractId", objectId)
	prompt.Parent = anchor

	destroy(id)
	interactables[id] = { model = model, prompt = prompt }
end

-- Builds the lobby platform, its walls and the portal that starts a run.
local function buildLobby()
	local folder = Instance.new("Folder")
	folder.Name = "Lobby"
	folder.Parent = workspace

	local floor = anchoredPart(
		"Floor",
		Vector3.new(LOBBY_SIZE, 2, LOBBY_SIZE),
		Vector3.new(LOBBY_X, ActSpace.GROUND_Y - 1, LOBBY_Z),
		Color3.fromRGB(150, 150, 160),
		folder
	)
	floor.Material = Enum.Material.Slate

	-- Low glass walls keep everyone on the platform.
	local half = LOBBY_SIZE / 2
	for _, side in { { 0, -1 }, { 0, 1 }, { -1, 0 }, { 1, 0 } } do
		local alongX = side[1] == 0
		local wall = anchoredPart(
			"Wall",
			if alongX then Vector3.new(LOBBY_SIZE, 12, 2) else Vector3.new(2, 12, LOBBY_SIZE),
			Vector3.new(LOBBY_X + side[1] * half, ActSpace.GROUND_Y + 6, LOBBY_Z + side[2] * half),
			Color3.fromRGB(190, 220, 255),
			folder
		)
		wall.Material = Enum.Material.Glass
		wall.Transparency = 0.7
	end

	local sign = anchoredPart(
		"Sign",
		Vector3.one,
		Vector3.new(LOBBY_X, ActSpace.GROUND_Y + 18, LOBBY_PORTAL_Z),
		Color3.new(1, 1, 1),
		folder
	)
	sign.Transparency = 1
	sign.CanCollide = false
	local gui = Instance.new("BillboardGui")
	gui.Size = UDim2.fromOffset(420, 60)
	gui.AlwaysOnTop = true
	gui.Adornee = sign
	gui.Parent = sign
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.BuilderSansBold
	label.TextSize = 30
	label.TextColor3 = Color3.new(1, 1, 1)
	label.TextStrokeTransparency = 0.4
	label.Text = "Step into the portal to start a run"
	label.Parent = gui

	addInteractable(
		WorldSim.LOBBY_PORTAL,
		WorldSim.LOBBY_PORTAL_OBJECT,
		"lobbyPortal",
		groundPoint(LOBBY_X, LOBBY_PORTAL_Z)
	)
end

function WorldService.init()
	network = Network.server("World", WorldService, {
		requestAct = {}, -- client -> server
		mapReady = { Packet.NumberU8 }, -- client -> server: act index
		reportHash = { Packet.NumberU32 }, -- client -> server: GenerateAct.hash of its map
		onAct = { Packet.NumberU32, Packet.NumberU8, Packet.NumberU8 }, -- seed, act index, generator version
		onLobby = {}, -- the run is over: drop the map
	})

	local folder = Instance.new("Folder")
	folder.Name = "Gameplay"
	folder.Parent = workspace
	gameplay = folder
	buildLobby()

	-- A new act: every client builds the map from the seed, and heroes wait for it.
	SimService.observe("actGenerated", function(event: SimContext.Event)
		network:fireAllClients("onAct", event.seed, event.act, GenerateAct.VERSION)
		for _, player in Players:GetPlayers() do
			if HeroService.slotOf(player) then
				hold(player, event.act)
			end
		end
	end)

	-- A hero that joins in the middle of a run waits for the map too.
	SimService.observe("heroJoined", function(event: SimContext.Event)
		local player = HeroService.playerOfSlot(event.slot)
		if player and event.inAct then
			hold(player, SimService.state().world.actIndex)
		end
	end)

	SimService.observe("lobby", function()
		network:fireAllClients("onLobby")
		for player in held do
			release(player)
		end
		table.clear(held)
	end)

	SimService.observe("objectAdded", function(event: SimContext.Event)
		addInteractable(event.id, event.objectId, event.object, groundPoint(event.x, event.z))
	end)

	SimService.observe("objectRemoved", function(event: SimContext.Event)
		destroy(event.id)
	end)

	SimService.observe("objectEnabled", function(event: SimContext.Event)
		local interactable = interactables[event.id]
		if interactable then
			interactable.prompt.Enabled = event.enabled
		end
	end)

	Players.PlayerRemoving:Connect(function(player)
		held[player] = nil
	end)
end

-- Network (client -> server)
function WorldService.requestAct(player: Player)
	if not RateLimit.take(requestLimit, player) then
		return
	end
	local world = SimService.state().world
	local current = world.act
	if current then
		network:fireClient(player, "onAct", current.seed, world.actIndex, GenerateAct.VERSION)
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
	local world = SimService.state().world
	local current = world.act
	if current == nil or not RateLimit.take(hashLimit, player) then
		return
	end

	if hash ~= GenerateAct.hash(current) then
		Log.warn(`{player.Name}'s map differs from the server's (act {world.actIndex}, seed {current.seed})`)
	else
		Log.debug(`{player.Name}'s map matches the server's`)
	end
end

return WorldService
