--!strict

--[=[
	Heroes, client side: input, aiming and the feel of every hero.

	Two aim modes follow the last input device:
	- aimed (mouse and keyboard): hold the left mouse button to attack towards
	  the cursor. Space dashes, Q or the
	  right mouse button slams.
	- auto (touch and gamepad): the hero hits the nearest enemy and the player
	  only moves. A gamepad's right stick aims while it is pushed.

	Movement is owned by the server (see HeroServiceServer): 20 times a second
	this module samples what the player is doing into a numbered HeroInput,
	runs it through the same HeroSim the server runs (so the hero answers at
	once), and sends the last few inputs. The server says where the hero
	really is (`onHeroAck`); if that differs from the prediction the hero is
	put right (see HeroPrediction).

	The player's Roblox character is a puppet: anchored, and placed here every
	frame, the local one from the prediction and everyone else's from the
	positions the server sends (`onHeroes`), drawn a little in the past.

	Angles in the simulation are core/Angle units. The aiming code and the
	combat events use radians: 0 faces +Z, and the direction of angle a is
	(sin a, cos a).
]=]

local ContextActionService = game:GetService("ContextActionService")
local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local Aim = require("@Features/heroes/modules/Aim")
local Angle = require("@Core/Angle")
local Charm = require("@Packages/charm")
local CombatController = require("@Features/combat/CombatControllerClient")
local HeroAnimator = require("@Features/heroes/modules/HeroAnimator")
local HeroDefs = require("@Features/heroes/modules/HeroDefs")
local HeroInput = require("@Features/heroes/modules/HeroInput")
local HeroMotion = require("@Features/heroes/modules/HeroMotion")
local HeroPrediction = require("@Features/heroes/modules/HeroPrediction")
local HeroSim = require("@Features/heroes/modules/HeroSim")
local HeroSnapshot = require("@Features/heroes/modules/HeroSnapshot")
local LobbySpace = require("@Features/world/modules/LobbySpace")
local Log = require("@Core/Log")
local NavGrid = require("@Features/enemies/modules/NavGrid")
local Network = require("@Core/Network")
local PoseBuffer = require("@Features/heroes/modules/PoseBuffer")
local SimClock = require("@Features/sim/modules/SimClock")
local Targeting = require("@Features/combat/modules/Targeting")
local WorldController = require("@Features/world/WorldControllerClient")

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
local MOVE_DEADZONE = 0.1
-- How long the hero keeps facing a swing it made on its own (auto mode).
local FACE_SWING_TIME = 0.35
local HIGHLIGHT_COLOR = Color3.fromRGB(255, 80, 80)
-- The key shown on each ability's button, in the order of HeroDef.abilities.
local ABILITY_KEYS = { "Space", "Q" }
local ABILITY_INPUTS: { { Enum.KeyCode | Enum.UserInputType } } = {
	{ Enum.KeyCode.Space, Enum.KeyCode.ButtonA },
	{ Enum.KeyCode.Q, Enum.UserInputType.MouseButton2, Enum.KeyCode.ButtonX },
}

local RENDER_NAME = "HeroSim"
-- Other players' heroes are drawn this far in the past, so there is always a pair of snapshots to blend.
local REMOTE_DELAY = 0.12
-- A long frame runs at most this many ticks of input, then carries on from there.
local MAX_TICKS_PER_FRAME = 5
-- Each packet repeats this many of the latest inputs, so a lost packet costs nothing.
local INPUTS_PER_PACKET = 3
-- How quickly a correction fades out, and the size of one that is simply a jump.
local CORRECTION_RATE = 12
local CORRECTION_SNAP = 8
-- Radians a second a hero turns at.
local TURN_RATE = 18
-- Bytes before the inputs in a sendInputs buffer: the last input's number (u32) and the count (u8).
local PACKET_HEADER = 5
local GROUND_Y = 0

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
local aimAngle = 0
local aimTargetId: number? = nil
local stickAngle: number? = nil
local faceUntil = 0
local faceAngle = 0

-- The local hero's prediction, nil until the server has said where it is.
local prediction: HeroPrediction.Prediction? = nil
-- The state before the latest input, to blend between ticks.
local previousMotion: HeroMotion.State? = nil
local accumulator = 0
local lastAckSeq = 0
local held = false
-- What the player pressed since the last tick.
local pendingAbility = 0
local pendingAbilityAngle = 0
local pendingInteract = 0
-- The direction the player is walking, in core/Angle units (nil when not walking).
local moveAngle: number? = nil

-- Drawing.
local renderX, renderZ = 0, 0
local rendered = false
local correctionX, correctionZ = 0, 0
local renderFacing = 0
local remotePoses: { [number]: PoseBuffer.Buffer } = {}
local remoteSpeed: { [number]: { x: number, z: number } } = {}

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

-- The way the hero faces, in radians.
local function facingAngle(): number
	local current = prediction
	if current then
		return Angle.toRadians(current.sim.facing)
	end
	return renderFacing
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
			aimAngle = autoAngle(root) or facingAngle()
		end
	end
end

-- The local hero is standing: its HP, as the server reports it, isn't 0.
local function heroAlive(): boolean
	local health = CombatController.health()[HeroController.state.entityId()]
	return health == nil or health.hp > 0
end

-- The grid the hero walks on where it stands: the lobby's, or the act's once the map is known.
local function gridAt(x: number, z: number): NavGrid.Grid
	if LobbySpace.contains(x, z) then
		return LobbySpace.navGrid()
	end
	return WorldController.state.navGrid() or LobbySpace.navGrid()
end

-- Where the player is pushing, as a core/Angle angle (nil when they aren't).
-- Roblox's own controls (keyboard, thumbstick, gamepad) turn the push into the
-- Humanoid's MoveDirection, already in world space and relative to the camera.
local function readMove(humanoid: Humanoid): number?
	local direction = humanoid.MoveDirection
	if direction.X * direction.X + direction.Z * direction.Z < MOVE_DEADZONE * MOVE_DEADZONE then
		return nil
	end
	return Angle.atan2(direction.X, direction.Z)
end

-- The direction an ability goes: the aim, or in auto mode the nearest enemy,
-- else the way the hero is walking or facing. In core/Angle units.
local function abilityDirection(root: BasePart): number
	if mode == "aimed" then
		return Angle.fromRadians(aimAngle)
	end

	local toEnemy = autoAngle(root)
	if toEnemy then
		return Angle.fromRadians(toEnemy)
	end
	return moveAngle or Angle.fromRadians(facingAngle())
end

local function startCooldown(index: number, ticks: number)
	local updated = table.clone(HeroController.state.cooldownEnds())
	updated[index] = os.clock() + ticks / SimClock.RATE
	HeroController.state.cooldownEnds(updated)
end

-- The input for this tick, from what the player is doing.
local function sampleInput(): HeroInput.Input
	local input = HeroInput.idle()
	-- Held in place while the map loads: the server uses the idle input anyway.
	if held then
		return input
	end

	local alive = heroAlive()
	input.aim = Angle.fromRadians(aimAngle)
	if moveAngle then
		input.moving = true
		input.moveAngle = HeroInput.quantizeMove(moveAngle)
	end
	input.attack = alive and (mode == "auto" or mouseHeld)
	input.auto = mode == "auto" and stickAngle == nil

	if pendingAbility > 0 then
		input.ability = pendingAbility
		input.aim = pendingAbilityAngle
	end
	input.interact = pendingInteract
	pendingAbility = 0
	pendingInteract = 0
	return input
end

local function sendInputs(current: HeroPrediction.Prediction)
	local connected = network
	if connected == nil then
		return
	end

	local count = math.min(INPUTS_PER_PACKET, current.seq)
	local packet = buffer.create(PACKET_HEADER + count * HeroInput.SIZE)
	buffer.writeu32(packet, 0, current.seq)
	buffer.writeu8(packet, 4, count)
	for index = 0, count - 1 do
		local record = current.records[current.seq - count + 1 + index]
		HeroInput.write(
			packet,
			PACKET_HEADER + index * HeroInput.SIZE,
			if record then record.input else HeroInput.idle()
		)
	end
	connected:fireUnreliable("sendInputs", packet)
end

-- Uses one tick of input.
local function tickOnce(current: HeroPrediction.Prediction)
	local sim = current.sim
	previousMotion = HeroMotion.copy(sim.motion)

	local grid = gridAt(sim.motion.x, sim.motion.z)
	local result = HeroPrediction.step(current, sampleInput(), grid, heroAlive())
	if result.used then
		local ability = def.abilities[result.used]
		if ability then
			startCooldown(result.used, SimClock.ticks(ability.cooldown))
		end
	end
	sendInputs(current)
end

local function turnToward(current: number, target: number, dt: number): number
	local difference = (target - current + math.pi) % (2 * math.pi) - math.pi
	local step = TURN_RATE * dt
	if math.abs(difference) <= step then
		return target
	end
	return current + math.sign(difference) * step
end

local function place(character: Model, root: BasePart, humanoid: Humanoid, x: number, z: number, facing: number)
	local height = GROUND_Y + humanoid.HipHeight + root.Size.Y / 2
	local position = Vector3.new(x, height, z)
	character:PivotTo(CFrame.lookAt(position, position + Vector3.new(math.sin(facing), 0, math.cos(facing))))
end

-- Draws the local hero from the prediction.
local function renderLocal(current: HeroPrediction.Prediction, dt: number)
	local character = Players.LocalPlayer.Character
	local root, humanoid = characterParts(Players.LocalPlayer)
	if character == nil or root == nil or humanoid == nil then
		return
	end

	local motion = current.sim.motion
	local before = previousMotion or motion
	local alpha = math.clamp(accumulator / SimClock.TICK, 0, 1)
	local x = before.x + (motion.x - before.x) * alpha
	local z = before.z + (motion.z - before.z) * alpha

	-- After a correction the hero glides from where it was drawn to where it should be.
	if correctionX ~= 0 or correctionZ ~= 0 then
		local fade = math.exp(-CORRECTION_RATE * dt)
		correctionX *= fade
		correctionZ *= fade
		if math.abs(correctionX) < 0.01 and math.abs(correctionZ) < 0.01 then
			correctionX, correctionZ = 0, 0
		end
	end
	local drawnX, drawnZ = x + correctionX, z + correctionZ

	local speed = if rendered
		then math.sqrt((drawnX - renderX) ^ 2 + (drawnZ - renderZ) ^ 2) / math.max(dt, 1e-3)
		else 0
	renderX, renderZ, rendered = drawnX, drawnZ, true

	local now = os.clock()
	local target = if now < faceUntil then faceAngle else Angle.toRadians(current.sim.facing)
	renderFacing = turnToward(renderFacing, target, dt)

	root.Anchored = true
	humanoid.AutoRotate = false
	place(character, root, humanoid, drawnX, drawnZ, renderFacing)
	HeroAnimator.update(character, speed)
end

-- Draws everyone else's hero from the server's snapshots.
local function renderRemotes(dt: number)
	local at = os.clock() - REMOTE_DELAY
	for userId, poses in remotePoses do
		local player = Players:GetPlayerByUserId(userId)
		local x, z, facing = PoseBuffer.sample(poses, at)
		if player == nil or player == Players.LocalPlayer or x == nil or z == nil or facing == nil then
			continue
		end

		local character = player.Character
		local root, humanoid = characterParts(player)
		if character == nil or root == nil or humanoid == nil then
			continue
		end

		local last = remoteSpeed[userId]
		local speed = if last then math.sqrt((x - last.x) ^ 2 + (z - last.z) ^ 2) / math.max(dt, 1e-3) else 0
		remoteSpeed[userId] = { x = x, z = z }

		root.Anchored = true
		humanoid.AutoRotate = false
		place(character, root, humanoid, x, z, Angle.toRadians(facing))
		HeroAnimator.update(character, speed)
	end
end

local function onRender(dt: number)
	local camera = workspace.CurrentCamera
	local root, humanoid = characterParts(Players.LocalPlayer)
	local current = prediction

	if camera and root and humanoid then
		updateAim(root, humanoid, camera)
		moveAngle = readMove(humanoid)
	else
		showAim(nil, nil)
		moveAngle = nil
	end

	if current and root and humanoid then
		accumulator = math.min(accumulator + dt, MAX_TICKS_PER_FRAME * SimClock.TICK)
		while accumulator >= SimClock.TICK do
			accumulator -= SimClock.TICK
			tickOnce(current)
		end
		renderLocal(current, dt)
	end

	renderRemotes(dt)
end

-- Uses the ability at `index` (1-based, the order of HeroDef.abilities). The
-- cooldown starts here at once and the server corrects it if it disagrees.
function HeroController.activate(index: number)
	local ability = def.abilities[index]
	local current = prediction
	local root = characterParts(Players.LocalPlayer)
	if ability == nil or current == nil or root == nil or held or not heroAlive() then
		return
	end

	local now = os.clock()
	local ends = HeroController.state.cooldownEnds()
	if now < (ends[index] or 0) or HeroSim.remaining(current.sim, index) > 0 then
		return
	end

	pendingAbility = index
	pendingAbilityAngle = abilityDirection(root)
	faceUntil = now + SimClock.ticks(ability.cooldown) * 0 + 0.2
	faceAngle = Angle.toRadians(pendingAbilityAngle)
	startCooldown(index, SimClock.ticks(ability.cooldown))
end

-- Uses a world object (a chest, the teleporter): the id comes from the object's prompt.
function HeroController.interact(objectId: number)
	if prediction and not held then
		pendingInteract = objectId
	end
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
function HeroController.onHeroAck(
	seq: number,
	x: number,
	z: number,
	dashLeft: number,
	dashX: number,
	dashZ: number,
	tick: number,
	flags: number,
	ready1: number,
	ready2: number,
	ready3: number
)
	-- Reports can arrive out of order: an older one is stale.
	if seq < lastAckSeq then
		return
	end
	lastAckSeq = seq
	held = bit32.band(flags, 1) ~= 0

	local first = prediction == nil
	local current = prediction or HeroPrediction.new(HeroSim.new(def, x, z))
	prediction = current

	local ack: HeroPrediction.Ack = {
		seq = seq,
		motion = { x = x, z = z, dashLeft = dashLeft, dashX = dashX, dashZ = dashZ },
		tick = tick,
		remaining = { ready1, ready2, ready3 },
	}
	local grid = gridAt(x, z)
	local drawnX, drawnZ = renderX, renderZ
	-- The first word from the server always sets things up, even when the prediction already agrees.
	local corrected = HeroPrediction.acknowledge(current, ack, grid)
	if not corrected and not first then
		return
	end

	-- The prediction was wrong (or this is the first word from the server): the
	-- cooldowns follow the server, and the hero glides to the right place unless it jumped far.
	local ends = table.clone(HeroController.state.cooldownEnds())
	local now = os.clock()
	for index in def.abilities do
		local left = ack.remaining[index] or 0
		ends[index] = if left > 0 then now + left / SimClock.RATE else 0
	end
	HeroController.state.cooldownEnds(ends)

	previousMotion = HeroMotion.copy(current.sim.motion)
	if first or not rendered then
		correctionX, correctionZ = 0, 0
		rendered = false
	else
		local motion = current.sim.motion
		local offsetX, offsetZ = drawnX - motion.x, drawnZ - motion.z
		if offsetX * offsetX + offsetZ * offsetZ > CORRECTION_SNAP * CORRECTION_SNAP then
			correctionX, correctionZ = 0, 0
		else
			correctionX, correctionZ = offsetX, offsetZ
		end
	end
	Log.debug(`Hero corrected at input {seq}`)
end

function HeroController.onHeroes(data: buffer)
	local entries = HeroSnapshot.decode(data)
	if entries == nil then
		return
	end

	local now = os.clock()
	for _, entry in entries do
		local poses = remotePoses[entry.userId]
		if poses == nil then
			poses = PoseBuffer.new()
			remotePoses[entry.userId] = poses
		end
		PoseBuffer.push(poses, now, entry.x, entry.z, entry.facing)
	end
end

function HeroController.onHeroAttack(userId: number, angle: number)
	local player = Players:GetPlayerByUserId(userId)
	if player == nil then
		return
	end

	local root = characterParts(player)
	if root == nil then
		return
	end

	local dx, dz = math.sin(angle), math.cos(angle)
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

-- The server made a hero for this player (or remade it): start again from its word.
function HeroController.onHeroEntity(entityId: number)
	HeroController.state.entityId(entityId)
	prediction = nil
	previousMotion = nil
	lastAckSeq = 0
	held = false
	accumulator = 0
	rendered = false
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
	-- Before the camera (which follows the character) and after the controls.
	RunService:BindToRenderStep(RENDER_NAME, Enum.RenderPriority.Camera.Value - 1, onRender)

	-- The prompts only show and time the hold: using one is an input, so the server can check the distance.
	ProximityPromptService.PromptTriggered:Connect(function(prompt)
		local objectId = prompt:GetAttribute("InteractId")
		if type(objectId) == "number" then
			HeroController.interact(objectId)
		end
	end)

	Players.PlayerRemoving:Connect(function(leaving)
		remotePoses[leaving.UserId] = nil
		remoteSpeed[leaving.UserId] = nil
	end)

	-- Yields until the server has registered the service.
	local connected = Network.client("Hero", HeroController)
	network = connected
	connected:fire("requestHero")
end

return HeroController
