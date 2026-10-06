--!strict

--[=[
	Minimap, client side: a corner map with fog of war.

	The map starts dark. Tiles within the hero's sight are drawn as it walks
	(MinimapLayer), so what it has explored stays on the map and the rest stays
	fogged. Clicking or tapping the map (or pressing M) opens it: it grows to
	the middle of the screen and shows the whole act instead of following the
	hero.

	The view (MinimapView) hands over the frame to draw in with `attach`. Every
	frame this slides the frame so the hero stays in the middle of the view;
	the fog is revealed ten times a second. A new act builds a new map, and the
	lobby has none.
]=]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local StarterGui = game:GetService("StarterGui")
local UserInputService = game:GetService("UserInputService")

local Charm = require("@Packages/charm")
local EnemyController = require("@Features/enemies/EnemyControllerClient")
local MinimapLayer = require("@Features/minimap/modules/MinimapLayer")
local MinimapMath = require("@Features/minimap/modules/MinimapMath")
local WorldController = require("@Features/world/WorldControllerClient")

local MinimapController = {}

MinimapController.state = {
	-- The whole act is shown, large, in the middle of the screen.
	expanded = Charm.atom(false),
}

-- Seconds between fog updates.
local REVEAL_INTERVAL = 0.1
local TOGGLE_KEY = Enum.KeyCode.M

local content: Frame? = nil
local layer: MinimapLayer.Layer? = nil
local sinceReveal = REVEAL_INTERVAL

-- The frame the map is drawn in. Called by the view when it is built.
function MinimapController.attach(frame: Frame)
	content = frame
	layer = nil
end

function MinimapController.toggle()
	MinimapController.state.expanded(not MinimapController.state.expanded())
end

local function heroPosition(): (number?, number?)
	local character = Players.LocalPlayer.Character
	local root = if character then character:FindFirstChild("HumanoidRootPart") else nil
	if root and root:IsA("BasePart") then
		return root.Position.X, root.Position.Z
	end
	return nil, nil
end

-- Builds the map for the current act, or clears it when there is none.
local function syncLayer(frame: Frame)
	local act = WorldController.state.act()
	local current = layer

	if act == nil then
		if current then
			MinimapLayer.destroy(current)
			layer = nil
		end
	elseif current == nil or current.act ~= act then
		layer = MinimapLayer.create(frame, act)
		sinceReveal = REVEAL_INTERVAL
	end
end

local function step(dt: number)
	local frame = content
	if frame == nil then
		return
	end

	syncLayer(frame)
	local current = layer
	local heroX, heroZ = heroPosition()
	if current == nil or heroX == nil or heroZ == nil then
		return
	end

	local expanded = MinimapController.state.expanded()
	local viewSize = if expanded then MinimapMath.SIZE_EXPANDED else MinimapMath.SIZE_NORMAL
	local pxPerStud = if expanded
		then MinimapMath.fitScale(viewSize, current.mapWidth, current.mapHeight)
		else MinimapMath.NORMAL_PX_PER_STUD

	-- The open map stays on the middle of the act (the world origin); the small one follows the hero.
	local focusX = if expanded then current.originX + current.mapWidth / 2 else heroX
	local focusZ = if expanded then current.originZ + current.mapHeight / 2 else heroZ
	local offsetX, offsetZ =
		MinimapMath.contentOffset(viewSize, pxPerStud, current.originX, current.originZ, focusX, focusZ)
	frame.Size = UDim2.fromOffset(current.mapWidth * pxPerStud, current.mapHeight * pxPerStud)
	frame.Position = UDim2.fromOffset(offsetX, offsetZ)

	MinimapLayer.setHero(current, heroX, heroZ)

	sinceReveal += dt
	if sinceReveal >= REVEAL_INTERVAL then
		sinceReveal = 0
		MinimapLayer.reveal(current, heroX, heroZ)
		MinimapLayer.refreshIcons(current, workspace:FindFirstChild("Gameplay"))
		MinimapLayer.setEnemies(current, EnemyController.getPoints(), heroX, heroZ, MinimapMath.VISION_RADIUS)
	end
end

-- Roblox's player list sits in the same corner and draws over the map. The core
-- UI may not be ready yet, so it takes a few tries.
local function hidePlayerList()
	for _ = 1, 10 do
		if pcall(StarterGui.SetCoreGuiEnabled, StarterGui, Enum.CoreGuiType.PlayerList, false) then
			return
		end
		task.wait(0.5)
	end
end

function MinimapController.start()
	task.spawn(hidePlayerList)
	RunService.Heartbeat:Connect(step)

	UserInputService.InputBegan:Connect(function(input, processed)
		if not processed and input.KeyCode == TOGGLE_KEY then
			MinimapController.toggle()
		end
	end)
end

return MinimapController
