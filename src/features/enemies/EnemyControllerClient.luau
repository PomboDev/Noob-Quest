--!strict

--[=[
	Enemies, client side: draws what the server simulates.

	The server sends a snapshot about 15 times a second. Each enemy keeps its
	last few samples and is drawn 100 ms in the past, between the two samples
	around that time, so movement stays smooth however the snapshots arrive.

	Models are pooled per enemy type, so spawning and killing allocate nothing
	once the pool is warm. A model comes from ReplicatedStorage.Assets.Enemies
	(named after the def id), or is a plain block in the def's colour until the
	art exists. A red glow is the telegraph, a yellow one is a stun, and the
	boss's slam draws the area it will hit.

	The heroes aim at what this module shows (see HeroController.setTargetProvider).
]=]

local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Angle = require("@Core/Angle")
local Charm = require("@Packages/charm")
local CombatController = require("@Features/combat/CombatControllerClient")
local EnemyDefs = require("@Features/enemies/modules/EnemyDefs")
local EnemySnapshot = require("@Features/enemies/modules/EnemySnapshot")
local HeroController = require("@Features/heroes/HeroControllerClient")
local Log = require("@Core/Log")
local Network = require("@Core/Network")
local Targeting = require("@Features/combat/modules/Targeting")

type EnemyDef = EnemyDefs.EnemyDef

type Sample = { t: number, x: number, z: number, angle: number, flags: number }

type View = {
	id: number,
	defIndex: number,
	def: EnemyDef,
	model: Model,
	highlight: Highlight,
	slamDisc: Part?,
	samples: { Sample },
	-- Where it is drawn now.
	x: number,
	z: number,
	shown: boolean,
}

type Shot = { part: Part, vx: number, vz: number, life: number }

export type BossInfo = { name: string, hp: number, maxHp: number }

local EnemyController = {}

EnemyController.state = {
	-- The boss while one is alive, for the HUD's health bar.
	boss = Charm.atom(nil :: BossInfo?),
}

-- Enemies are drawn this far in the past.
local INTERPOLATION_DELAY = 0.1
local MAX_SAMPLES = 6
local TELEGRAPH_COLOR = Color3.fromRGB(255, 60, 60)
local STUN_COLOR = Color3.fromRGB(255, 220, 60)
local SHOT_HEIGHT = 2

local folder: Folder? = nil
local views: { [number]: View } = {}
local pool: { [number]: { Model } } = {}
local shots: { Shot } = {}
local points: { Targeting.Point } = {}
local feetY = 0

local function buildModel(def: EnemyDef): Model
	local assets = ReplicatedStorage:FindFirstChild("Assets")
	local enemies = if assets then assets:FindFirstChild("Enemies") else nil
	local template = if enemies then enemies:FindFirstChild(def.id) else nil
	if template and template:IsA("Model") then
		return template:Clone()
	end

	local model = Instance.new("Model")
	model.Name = def.id

	local body = Instance.new("Part")
	body.Name = "Body"
	body.Size = Vector3.new(def.size.x, def.size.y, def.size.z)
	body.Color = Color3.fromRGB(def.color.r, def.color.g, def.color.b)
	body.Material = Enum.Material.SmoothPlastic
	body.Anchored = true
	body.CanCollide = false
	body.CanQuery = false
	body.CanTouch = false
	body.Parent = model
	model.PrimaryPart = body
	return model
end

local function newView(id: number, defIndex: number, def: EnemyDef): View
	local reused = table.remove(pool[defIndex] or {})
	local model = reused or buildModel(def)
	model.Name = `{def.id}{id}`

	-- A pooled model already has its highlight.
	local highlight: Highlight = model:FindFirstChildOfClass("Highlight") or Instance.new("Highlight")
	if highlight.Parent == nil then
		highlight.FillTransparency = 0.45
		highlight.OutlineTransparency = 1
		highlight.Enabled = false
		highlight.Parent = model
	end

	return {
		id = id,
		defIndex = defIndex,
		def = def,
		model = model,
		highlight = highlight,
		slamDisc = nil,
		samples = {},
		x = 0,
		z = 0,
		shown = false,
	}
end

local function release(view: View)
	view.model.Parent = nil
	view.highlight.Enabled = false
	if view.slamDisc then
		view.slamDisc.Parent = nil
	end

	local stack = pool[view.defIndex]
	if stack == nil then
		stack = {}
		pool[view.defIndex] = stack
	end
	table.insert(stack, view.model)
end

local function lerpAngle(from: number, to: number, alpha: number): number
	local difference = (to - from + Angle.HALF) % Angle.TURN - Angle.HALF
	return from + difference * alpha
end

-- Where an enemy is at `time`, between the two samples around it. Before the
-- first sample it stays at the first; after the last it waits at the last.
local function sampleAt(samples: { Sample }, time: number): Sample?
	local count = #samples
	if count == 0 then
		return nil
	end
	if time <= samples[1].t then
		return samples[1]
	end
	if time >= samples[count].t then
		return samples[count]
	end

	for index = 1, count - 1 do
		local a, b = samples[index], samples[index + 1]
		if time >= a.t and time <= b.t then
			local alpha = (time - a.t) / math.max(b.t - a.t, 1e-6)
			return {
				t = time,
				x = a.x + (b.x - a.x) * alpha,
				z = a.z + (b.z - a.z) * alpha,
				angle = lerpAngle(a.angle, b.angle, alpha),
				flags = b.flags,
			}
		end
	end
	return samples[count]
end

local function getSlamDisc(view: View): Part
	local disc = view.slamDisc
	if disc then
		return disc
	end

	local created = Instance.new("Part")
	created.Name = "SlamWarning"
	created.Shape = Enum.PartType.Cylinder
	created.Anchored = true
	created.CanCollide = false
	created.CanQuery = false
	created.CanTouch = false
	created.CastShadow = false
	created.Material = Enum.Material.Neon
	created.Color = TELEGRAPH_COLOR
	created.Transparency = 0.7
	local diameter = (view.def.slamRadius or 16) * 2
	created.Size = Vector3.new(0.2, diameter, diameter)
	view.slamDisc = created
	return created
end

local function updateFeet()
	local character = Players.LocalPlayer.Character
	local root = if character then character:FindFirstChild("HumanoidRootPart") else nil
	local humanoid = if character then character:FindFirstChildOfClass("Humanoid") else nil
	if root and root:IsA("BasePart") and humanoid then
		feetY = root.Position.Y - (humanoid.HipHeight + root.Size.Y / 2)
	end
end

local function render()
	updateFeet()
	local target = os.clock() - INTERPOLATION_DELAY

	table.clear(points)
	for id, view in views do
		local sample = sampleAt(view.samples, target)
		if sample == nil then
			continue
		end

		view.x, view.z = sample.x, sample.z
		table.insert(points, { id = id, x = sample.x, z = sample.z })

		local def = view.def
		local position = Vector3.new(sample.x, feetY + def.size.y / 2, sample.z)
		local dx, dz = Angle.direction(sample.angle)
		view.model:PivotTo(CFrame.lookAt(position, position + Vector3.new(dx, 0, dz)))

		if not view.shown then
			view.shown = true
			view.model.Parent = folder
		end

		local telegraphing = bit32.band(sample.flags, EnemySnapshot.TELEGRAPHING) ~= 0
		local stunned = bit32.band(sample.flags, EnemySnapshot.STUNNED) ~= 0
		view.highlight.Enabled = telegraphing or stunned
		view.highlight.FillColor = if stunned then STUN_COLOR else TELEGRAPH_COLOR

		local slamming = telegraphing and bit32.band(sample.flags, EnemySnapshot.SLAM) ~= 0
		if slamming then
			local disc = getSlamDisc(view)
			disc.CFrame = CFrame.new(sample.x, feetY + 0.15, sample.z) * CFrame.Angles(0, 0, math.rad(90))
			disc.Parent = workspace
		elseif view.slamDisc then
			view.slamDisc.Parent = nil
		end
	end
end

-- Network (server -> client)
function EnemyController.onSpawn(id: number, defIndex: number)
	local def = EnemyDefs.byIndex(defIndex)
	if def == nil or views[id] then
		return
	end

	views[id] = newView(id, defIndex, def)
	if def.behaviour == "boss" then
		EnemyController.state.boss({ name = def.name, hp = def.maxHp, maxHp = def.maxHp })
	end
end

function EnemyController.onDespawn(id: number)
	local view = views[id]
	if view == nil then
		return
	end

	views[id] = nil
	release(view)
	if view.def.behaviour == "boss" then
		EnemyController.state.boss(nil)
	end
end

function EnemyController.onSnapshot(data: buffer)
	local entries = EnemySnapshot.decode(data)
	if entries == nil then
		Log.warn("Dropped a malformed enemy snapshot")
		return
	end

	local now = os.clock()
	for _, entry in entries do
		local view = views[entry.id]
		if view then
			table.insert(view.samples, { t = now, x = entry.x, z = entry.z, angle = entry.angle, flags = entry.flags })
			if #view.samples > MAX_SAMPLES then
				table.remove(view.samples, 1)
			end
		end
	end
end

function EnemyController.onProjectile(position: Vector3, velocity: Vector3, life: number)
	local part = Instance.new("Part")
	part.Shape = Enum.PartType.Ball
	part.Size = Vector3.new(1.4, 1.4, 1.4)
	part.Color = Color3.fromRGB(190, 110, 255)
	part.Material = Enum.Material.Neon
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Position = Vector3.new(position.X, feetY + SHOT_HEIGHT, position.Z)
	part.Parent = workspace

	table.insert(shots, { part = part, vx = velocity.X, vz = velocity.Z, life = life })
	Debris:AddItem(part, life + 0.1)
end

function EnemyController.onBossHealth(hp: number, maxHp: number)
	local boss = EnemyController.state.boss()
	if boss then
		EnemyController.state.boss({ name = boss.name, hp = hp, maxHp = maxHp })
	end
end

local function stepShots(dt: number)
	local index = 1
	while index <= #shots do
		local shot = shots[index]
		shot.life -= dt
		if shot.life <= 0 or shot.part.Parent == nil then
			table.remove(shots, index)
		else
			local position = shot.part.Position
			shot.part.Position = Vector3.new(position.X + shot.vx * dt, feetY + SHOT_HEIGHT, position.Z + shot.vz * dt)
			index += 1
		end
	end
end

-- Where every enemy is drawn now. Read it, don't change it: it is rebuilt every frame.
function EnemyController.getPoints(): { Targeting.Point }
	return points
end

function EnemyController.start()
	local created = Instance.new("Folder")
	created.Name = "Enemies"
	created.Parent = workspace
	folder = created

	CombatController.observeHit(function(entityId)
		local view = views[entityId]
		if view and view.shown then
			CombatController.flash(view.model)
		end
	end)

	HeroController.setTargetProvider({
		points = function()
			return points
		end,
		model = function(id)
			local view = views[id]
			return if view and view.shown then view.model else nil
		end,
	})

	RunService.RenderStepped:Connect(function(dt)
		render()
		stepShots(dt)
	end)

	-- Yields until the server has registered the service.
	local network = Network.client("Enemy", EnemyController)
	network:fire("requestEnemies")
end

return EnemyController
