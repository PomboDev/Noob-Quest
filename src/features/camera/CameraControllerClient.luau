--!strict

--[=[
	Camera feature: a fixed top-down camera that follows the character.

	The camera is Scriptable and bound just after Roblox's own camera, so it
	wins every frame. Pitch and yaw are fixed, so movement keys always mean the
	same screen direction. There is no zoom or rotation, and the Scriptable camera
	ignores mouse lock.
]=]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local CameraMath = require("@Features/camera/modules/CameraMath")

local CameraController = {}

local BIND_NAME = "HeroCamera"
local PITCH = 57 -- degrees above the horizon
local YAW = 0 -- degrees, see CameraMath.offset
local DISTANCE = 50 -- studs from the character
local SMOOTH_RATE = 12 -- per second, higher follows tighter
-- A jump this big (a new act's spawn) is a teleport, not something to glide across.
local SNAP_DISTANCE = 100

local focus: Vector3? = nil

local function step(dt: number)
	local camera = workspace.CurrentCamera
	local character = Players.LocalPlayer.Character
	local root = if character then character:FindFirstChild("HumanoidRootPart") else nil
	if camera == nil or root == nil or not root:IsA("BasePart") then
		focus = nil
		return
	end

	-- Roblox resets this when the character spawns.
	if camera.CameraType ~= Enum.CameraType.Scriptable then
		camera.CameraType = Enum.CameraType.Scriptable
	end

	local target = root.Position
	local previous = focus
	local current: Vector3 = target
	if previous and (target - previous).Magnitude <= SNAP_DISTANCE then
		current = previous:Lerp(target, CameraMath.smoothAlpha(dt, SMOOTH_RATE))
	end
	focus = current

	local x, y, z = CameraMath.offset(PITCH, YAW, DISTANCE)
	camera.CFrame = CFrame.lookAt(current + Vector3.new(x, y, z), current)
end

function CameraController.start()
	local player = Players.LocalPlayer
	player.CameraMinZoomDistance = DISTANCE
	player.CameraMaxZoomDistance = DISTANCE

	RunService:BindToRenderStep(BIND_NAME, Enum.RenderPriority.Camera.Value + 1, step)
end

return CameraController
