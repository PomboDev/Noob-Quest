--!strict

--[=[
	Heroes, client side: input, aiming and the local feel of the hero.

	Two aim modes follow the last input device:
	- aimed (mouse and keyboard): hold the left mouse button to attack towards
	  the cursor, Shift to stand still while doing it. Space dashes, Q or the
	  right mouse button slams.
	- auto (touch and gamepad): the hero hits the nearest enemy and the player
	  only moves. A gamepad's right stick aims while it is pushed.

	The server owns the swings, cooldowns and damage. This module tells it
	what the player wants (setAttack while the state changes, setAim while the
	angle moves) and does what only the client can: aiming from the cursor,
	moving the local character for the dash and turning it to face its target.

	Angles follow Targeting: 0 faces +Z, and the direction of angle a is (sin a, cos a).
]=]

local ContextActionService = game:GetService("ContextActionService")
local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local Aim = require("@Features/heroes/modules/Aim")
local Charm = require("@Packages/charm")
local CombatController = require("@Features/combat/CombatControllerClient")
local HeroDefs = require("@Features/heroes/modules/HeroDefs")
local Log = require("@Core/Log")
local Network = require("@Core/Network")
local Targeting = require("@Features/combat/modules/Targeting")

local HeroController = {}

export type Mode = "aimed" | "auto"

-- What the heroes need to know about enemies, supplied by the enemies feature.
export type TargetProvider = {
	points: () -> { Targeting.Point },
	model: (id: number) -> Instance?,
}

-- A click this close to an enemy aims at it.
local SNAP_RADIUS = 3
local STICK_DEADZONE = 0.3
-- The most often setAim is sent, and the smallest turn worth sending.
local AIM_SEND_INTERVAL = 0.05
local AIM_SEND_DELTA = 0.02
-- How long the hero keeps facing a swing it made on its own (auto mode).
local FACE_SWING_TIME = 0.35
local HIGHLIGHT_COLOR = Color3.fromRGB(255, 80, 80)
-- The key shown on each ability's button, in the order of HeroDef.abilities.
local ABILITY_KEYS = { "Space", "Q" }
local ABILITY_INPUTS: { { Enum.KeyCode | Enum.UserInputType } } = {
	{ Enum.KeyCode.Space, Enum.KeyCode.ButtonA },
	{ Enum.KeyCode.Q, Enum.UserInputType.MouseButton2, Enum.KeyCode.ButtonX },
}

local def: HeroDefs.HeroDef = HeroDefs.get(HeroDefs.DEFAULT) :: HeroDefs.HeroDef

HeroController.state = {
	-- The combat entity of the local hero (see CombatController.health), 0 until the server says.
	entityId = Charm.atom(0),
	inputMode = Charm.atom("aimed" :: Mode),
	-- Per ability index: the os.clock() time it is ready again.
	cooldownEnds = Charm.atom({} :: { [number]: number }),
}

local network: Network.ClientNetwork? = nil
local provider: TargetProvider? = nil

local mode: Mode = "aimed"
local mouseHeld = false
local shiftHeld = false
local aimAngle = 0
local aimTargetId: number? = nil
local stickAngle: number? = nil
-- What the server was last told.
local sentActive = false
local sentAuto = false
local sentAngle = 0
local sentAt = 0
local faceUntil = 0
local faceAngle = 0

local aimRing: Part? = nil
local targetHighlight: Highlight? = nil

local function setMode(newMode: Mode)
	if newMode ~= mode then
		mode = newMode
		HeroController.state.inputMode(newMode)
		Log.debug(`Aim mode: {newMode}`)
	end
end

-- Touch and gamepad play in auto mode, mouse and keyboard aim. Other devices change nothing.
local function onInputType(inputType: Enum.UserInputType)
	if inputType == Enum.UserInputType.Touch or string.find(inputType.Name, "^Gamepad") then
		setMode("auto")
	elseif inputType == Enum.UserInputType.Keyboard or string.find(inputType.Name, "^Mouse") then
		setMode("aimed")
	end
end

-- A flat disc on the ground that fades out: the placeholder for swing and slam effects.
local function disc(position: Vector3, diameter: number, color: Color3, duration: number)
	local part = Instance.new("Part")
	part.Shape = Enum.PartType.Cylinder
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Material = Enum.Material.Neon
	part.Color = color
	part.Transparency = 0.4
	part.Size = Vector3.new(0.2, diameter * 0.4, diameter * 0.4)
	part.CFrame = CFrame.new(position) * CFrame.Angles(0, 0, math.rad(90))
	part.Parent = workspace

	local info = TweenInfo.new(duration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	TweenService:Create(part, info, {
		Size = Vector3.new(0.2, diameter, diameter),
		Transparency = 1,
	}):Play()
	Debris:AddItem(part, duration)
end

local function characterParts(player: Player): (BasePart?, Humanoid?)
	local character = player.Character
	if character == nil then
		return nil, nil
	end
	local root = character:FindFirstChild("HumanoidRootPart")
	return if root and root:IsA("BasePart") then root else nil, character:FindFirstChildOfClass("Humanoid")
end

local function getAimRing(): Part
	local ring = aimRing
	if ring then
		return ring
	end

	local created = Instance.new("Part")
	created.Name = "AimRing"
	created.Shape = Enum.PartType.Cylinder
	created.Anchored = true
	created.CanCollide = false
	created.CanQuery = false
	created.CanTouch = false
	created.CastShadow = false
	created.Material = Enum.Material.Neon
	created.Color = HIGHLIGHT_COLOR
	created.Transparency = 0.5
	created.Size = Vector3.new(0.15, 3, 3)
	aimRing = created
	return created
end

local function getHighlight(): Highlight
	local highlight = targetHighlight
	if highlight then
		return highlight
	end

	local created = Instance.new("Highlight")
	created.Name = "AimTarget"
	created.FillTransparency = 1
	created.OutlineColor = HIGHLIGHT_COLOR
	created.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	targetHighlight = created
	return created
end

-- Shows the aim ring at `point` and outlines the enemy the aim snapped to, or hides both.
local function showAim(point: Vector3?, targetId: number?)
	if point then
		local ring = getAimRing()
		ring.CFrame = CFrame.new(point + Vector3.new(0, 0.2, 0)) * CFrame.Angles(0, 0, math.rad(90))
		ring.Parent = workspace
	elseif aimRing then
		aimRing.Parent = nil
	end

	local model = if targetId and provider then provider.model(targetId) else nil
	if model then
		local highlight = getHighlight()
		highlight.Adornee = model
		highlight.Parent = model
	elseif targetHighlight then
		targetHighlight.Adornee = nil
		targetHighlight.Parent = nil
	end
end

local function stickDirection(camera: Camera): number?
	for _, input in UserInputService:GetGamepadState(Enum.UserInputType.Gamepad1) do
		if input.KeyCode == Enum.KeyCode.Thumbstick2 then
			local stick = input.Position
			if Vector2.new(stick.X, stick.Y).Magnitude < STICK_DEADZONE then
				return nil
			end

			-- Stick up is away from the camera, right is to its right.
			local look = camera.CFrame.LookVector
			local right = camera.CFrame.RightVector
			local dx = right.X * stick.X + look.X * stick.Y
			local dz = right.Z * stick.X + look.Z * stick.Y
			return Aim.angleTo(0, 0, dx, dz)
		end
	end
	return nil
end

-- The angle to the nearest enemy within the hero's auto range, if any.
local function autoAngle(root: BasePart): number?
	if provider == nil then
		return nil
	end

	local position = root.Position
	local nearest = Targeting.nearest(provider.points(), position.X, position.Z, def.attack.autoRange)
	if nearest == nil then
		return nil
	end
	for _, point in provider.points() do
		if point.id == nearest then
			return Aim.angleTo(position.X, position.Z, point.x, point.z)
		end
	end
	return nil
end

local function facingAngle(root: BasePart): number
	local look = root.CFrame.LookVector
	return Targeting.angleOf(look.X, look.Z)
end

-- Works out what the hero is aiming at this frame.
local function updateAim(root: BasePart, humanoid: Humanoid, camera: Camera)
	stickAngle = if mode == "auto" then stickDirection(camera) else nil

	if mode == "aimed" then
		local mouse = UserInputService:GetMouseLocation()
		local ray = camera:ViewportPointToRay(mouse.X, mouse.Y)
		local feetY = root.Position.Y - (humanoid.HipHeight + root.Size.Y / 2)
		local x, z = Aim.groundPoint(
			ray.Origin.X,
			ray.Origin.Y,
			ray.Origin.Z,
			ray.Direction.X,
			ray.Direction.Y,
			ray.Direction.Z,
			feetY
		)

		if x and z then
			local points = if provider then provider.points() else {}
			local resolved = Aim.resolve(points, root.Position.X, root.Position.Z, x, z, SNAP_RADIUS)
			if resolved then
				aimAngle = resolved.angle
				aimTargetId = resolved.targetId
			end
			showAim(Vector3.new(x, feetY, z), aimTargetId)
		else
			showAim(nil, nil)
		end
	else
		showAim(nil, nil)
		aimTargetId = nil
		local stick = stickAngle
		if stick then
			aimAngle = stick
		else
			aimAngle = autoAngle(root) or facingAngle(root)
		end
	end
end

-- Tells the server about changes to what the player wants.
local function syncAttack(alive: boolean)
	local connected = network
	if connected == nil then
		return
	end

	local active = alive and (mode == "auto" or mouseHeld)
	local auto = mode == "auto" and stickAngle == nil
	local now = os.clock()

	if active ~= sentActive or auto ~= sentAuto then
		sentActive, sentAuto, sentAngle, sentAt = active, auto, aimAngle, now
		connected:fire("setAttack", active, aimAngle, auto)
	elseif
		active
		and not auto
		and now - sentAt >= AIM_SEND_INTERVAL
		and math.abs(aimAngle - sentAngle) > AIM_SEND_DELTA
	then
		sentAngle, sentAt = aimAngle, now
		connected:fireUnreliable("setAim", aimAngle)
	end
end

-- The local hero is standing: its HP, as the server reports it, isn't 0.
local function heroAlive(): boolean
	local health = CombatController.health()[HeroController.state.entityId()]
	return health == nil or health.hp > 0
end

local function step()
	local player = Players.LocalPlayer
	local root, humanoid = characterParts(player)
	local camera = workspace.CurrentCamera
	if root == nil or humanoid == nil or camera == nil then
		showAim(nil, nil)
		syncAttack(false)
		return
	end

	updateAim(root, humanoid, camera)
	syncAttack(heroAlive())

	local now = os.clock()
	local attacking = (mode == "aimed" and mouseHeld) or stickAngle ~= nil
	if attacking then
		faceUntil = now + 0.1
		faceAngle = aimAngle
	end

	-- Hold Shift while attacking to stand your ground.
	humanoid.WalkSpeed = if shiftHeld and attacking then 0 else def.walkSpeed

	if now < faceUntil then
		humanoid.AutoRotate = false
		local dx, dz = Targeting.direction(faceAngle)
		local position = root.Position
		root.CFrame = CFrame.lookAt(position, position + Vector3.new(dx, 0, dz))
	else
		humanoid.AutoRotate = true
	end
end

-- Moves the local character along `angle` for the length of the dash.
local function startDash(root: BasePart, ability: HeroDefs.Dash, angle: number)
	local dx, dz = Targeting.direction(angle)

	local attachment = Instance.new("Attachment")
	attachment.Parent = root

	local velocity = Instance.new("LinearVelocity")
	velocity.Attachment0 = attachment
	velocity.MaxForce = math.huge
	velocity.RelativeTo = Enum.ActuatorRelativeTo.World
	velocity.VelocityConstraintMode = Enum.VelocityConstraintMode.Vector
	velocity.VectorVelocity = Vector3.new(dx, 0, dz) * (ability.distance / ability.duration)
	velocity.Parent = root

	Debris:AddItem(velocity, ability.duration)
	Debris:AddItem(attachment, ability.duration)

	faceUntil = os.clock() + ability.duration
	faceAngle = angle
end

-- Where the hero is headed when an ability is used: the aim, or in auto mode
-- the nearest enemy, else the way it is moving or facing.
local function abilityAngle(root: BasePart, humanoid: Humanoid): number
	if mode == "aimed" then
		return aimAngle
	end

	local toEnemy = autoAngle(root)
	if toEnemy then
		return toEnemy
	end

	local move = humanoid.MoveDirection
	if move.Magnitude > 0.1 then
		return Targeting.angleOf(move.X, move.Z)
	end
	return facingAngle(root)
end

-- Uses the ability at `index` (1-based, the order of HeroDef.abilities). The
-- cooldown starts here at once and the server corrects it if it disagrees.
function HeroController.activate(index: number)
	local ability = def.abilities[index]
	local connected = network
	if ability == nil or connected == nil then
		return
	end

	local now = os.clock()
	local ends = HeroController.state.cooldownEnds()
	if now < (ends[index] or 0) then
		return
	end

	local root, humanoid = characterParts(Players.LocalPlayer)
	if root == nil or humanoid == nil or not heroAlive() then
		return
	end

	local updated = table.clone(ends)
	updated[index] = now + ability.cooldown
	HeroController.state.cooldownEnds(updated)

	local angle = abilityAngle(root, humanoid)
	if ability.kind == "dash" then
		startDash(root, ability, angle)
	end
	connected:fire("useAbility", index, angle)
end

function HeroController.getDef(): HeroDefs.HeroDef
	return def
end

function HeroController.getAbilityKeys(): { string }
	return ABILITY_KEYS
end

-- The enemies feature says where enemies are and which model is whose.
function HeroController.setTargetProvider(newProvider: TargetProvider?)
	provider = newProvider
end

-- Network (server -> client)
function HeroController.onHeroAttack(userId: number, angle: number)
	local player = Players:GetPlayerByUserId(userId)
	if player == nil then
		return
	end

	local root = characterParts(player)
	if root == nil then
		return
	end

	local dx, dz = Targeting.direction(angle)
	local ahead = root.Position + Vector3.new(dx, 0, dz) * (def.attack.range * 0.5)
	disc(Vector3.new(ahead.X, root.Position.Y - 2.5, ahead.Z), def.attack.range, Color3.new(1, 1, 1), 0.15)

	if player == Players.LocalPlayer then
		faceUntil = os.clock() + FACE_SWING_TIME
		faceAngle = angle
	end
end

function HeroController.onAbilityUsed(userId: number, index: number, _angle: number)
	local ability = def.abilities[index]
	local player = Players:GetPlayerByUserId(userId)
	if ability == nil or player == nil or ability.kind ~= "slam" then
		return
	end

	local root = characterParts(player)
	if root then
		disc(root.Position - Vector3.new(0, 2.5, 0), ability.radius * 2, Color3.fromRGB(255, 180, 60), 0.4)
	end
end

function HeroController.onHeroEntity(entityId: number)
	HeroController.state.entityId(entityId)
end

function HeroController.onAbilityRejected(index: number, remaining: number)
	local updated = table.clone(HeroController.state.cooldownEnds())
	updated[index] = os.clock() + remaining
	HeroController.state.cooldownEnds(updated)
end

local function bindInput()
	ContextActionService:BindActionAtPriority("HeroAttack", function(_, inputState)
		mouseHeld = inputState == Enum.UserInputState.Begin
		return Enum.ContextActionResult.Sink
	end, false, Enum.ContextActionPriority.High.Value, Enum.UserInputType.MouseButton1)

	ContextActionService:BindActionAtPriority("HeroStandStill", function(_, inputState)
		shiftHeld = inputState == Enum.UserInputState.Begin
		return Enum.ContextActionResult.Pass
	end, false, Enum.ContextActionPriority.High.Value, Enum.KeyCode.LeftShift, Enum.KeyCode.RightShift)

	for index in def.abilities do
		local inputs = ABILITY_INPUTS[index]
		if inputs == nil then
			continue
		end

		ContextActionService:BindActionAtPriority(`HeroAbility{index}`, function(_, inputState)
			if inputState == Enum.UserInputState.Begin then
				HeroController.activate(index)
			end
			return Enum.ContextActionResult.Sink
		end, false, Enum.ContextActionPriority.High.Value, table.unpack(inputs))
	end
end

function HeroController.start()
	onInputType(UserInputService:GetLastInputType())
	UserInputService.LastInputTypeChanged:Connect(onInputType)

	bindInput()
	RunService.RenderStepped:Connect(step)

	-- Yields until the server has registered the service.
	local connected = Network.client("Hero", HeroController)
	network = connected
	connected:fire("requestHero")
end

return HeroController
