--!strict

--[=[
	Combat feature, client side: damage numbers, hit flashes and the poof.

	Damage numbers are pooled BillboardGuis pinned to pooled attachments, so a
	busy fight allocates nothing. Other client features use `observeHit` (an
	enemy flashes when it is hit), `flash` and `poof`. `health` holds the
	hit points of every hero entity, for the HUD.
]=]

local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")

local Charm = require("@Packages/charm")
local Network = require("@Core/Network")

local CombatController = {}

export type Health = { hp: number, maxHp: number }
type HitCallback = (entityId: number, position: Vector3, damage: number, crit: boolean) -> ()

type Number = {
	attachment: Attachment,
	gui: BillboardGui,
	label: TextLabel,
}

local MAX_NUMBERS = 40
local NUMBER_LIFETIME = 0.8
local NUMBER_RISE = 4 -- studs
local FLASH_TIME = 0.1
local NORMAL_COLOR = Color3.fromRGB(255, 255, 255)
local CRIT_COLOR = Color3.fromRGB(255, 205, 40)

local numberTween = TweenInfo.new(NUMBER_LIFETIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

CombatController.health = Charm.atom({} :: { [number]: Health })

local free: { Number } = {}
local created = 0
local hitCallbacks: { HitCallback } = {}
local poofEmitter: ParticleEmitter? = nil

local function createNumber(): Number?
	local player = Players.LocalPlayer
	local playerGui = player:FindFirstChildOfClass("PlayerGui")
	if playerGui == nil then
		return nil
	end

	local attachment = Instance.new("Attachment")
	attachment.Name = "DamageNumber"
	attachment.Parent = workspace.Terrain

	local gui = Instance.new("BillboardGui")
	gui.Name = "DamageNumber"
	gui.Adornee = attachment
	gui.Size = UDim2.fromOffset(120, 40)
	gui.AlwaysOnTop = true
	gui.Enabled = false
	gui.ResetOnSpawn = false
	gui.Parent = playerGui

	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.Font = Enum.Font.BuilderSansBold
	label.TextScaled = true
	label.TextStrokeTransparency = 0.3
	label.Parent = gui

	created += 1
	return { attachment = attachment, gui = gui, label = label }
end

local function takeNumber(): Number?
	local number = table.remove(free)
	if number then
		return number
	end
	if created < MAX_NUMBERS then
		return createNumber()
	end
	return nil
end

local function showNumber(position: Vector3, damage: number, crit: boolean)
	local number = takeNumber()
	if number == nil then
		return
	end

	-- Spread repeated hits a little so they don't stack on one spot.
	local jitter = Vector3.new((math.random() - 0.5) * 2, 0, (math.random() - 0.5) * 2)
	number.attachment.WorldPosition = position + Vector3.new(0, 3, 0) + jitter
	number.gui.StudsOffsetWorldSpace = Vector3.zero
	number.gui.Size = if crit then UDim2.fromOffset(160, 54) else UDim2.fromOffset(110, 36)
	number.label.Text = if crit then `{damage}!` else tostring(damage)
	number.label.TextColor3 = if crit then CRIT_COLOR else NORMAL_COLOR
	number.label.TextTransparency = 0
	number.label.TextStrokeTransparency = 0.3
	number.gui.Enabled = true

	TweenService:Create(number.gui, numberTween, { StudsOffsetWorldSpace = Vector3.new(0, NUMBER_RISE, 0) }):Play()
	local fade = TweenService:Create(number.label, numberTween, { TextTransparency = 1, TextStrokeTransparency = 1 })
	fade.Completed:Once(function()
		number.gui.Enabled = false
		table.insert(free, number)
	end)
	fade:Play()
end

local function getPoofEmitter(): ParticleEmitter
	local emitter = poofEmitter
	if emitter then
		return emitter
	end

	local built = Instance.new("ParticleEmitter")
	built.Enabled = false
	built.Texture = "rbxasset://textures/particles/smoke_main.dds"
	built.Color = ColorSequence.new(Color3.fromRGB(235, 235, 235))
	built.Lifetime = NumberRange.new(0.4, 0.7)
	built.Speed = NumberRange.new(6, 12)
	built.SpreadAngle = Vector2.new(180, 180)
	built.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1.5),
		NumberSequenceKeypoint.new(1, 3.5),
	})
	built.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.2),
		NumberSequenceKeypoint.new(1, 1),
	})
	built.Drag = 4
	poofEmitter = built
	return built
end

-- A cartoon puff of smoke at `position`.
function CombatController.poof(position: Vector3)
	local attachment = Instance.new("Attachment")
	attachment.WorldPosition = position + Vector3.new(0, 2, 0)
	attachment.Parent = workspace.Terrain

	local emitter = getPoofEmitter():Clone()
	emitter.Parent = attachment
	emitter:Emit(14)
	Debris:AddItem(attachment, 1.5)
end

-- Briefly lights `model` up white.
function CombatController.flash(model: Instance)
	local highlight = Instance.new("Highlight")
	highlight.FillColor = Color3.new(1, 1, 1)
	highlight.FillTransparency = 0.35
	highlight.OutlineTransparency = 1
	highlight.DepthMode = Enum.HighlightDepthMode.Occluded
	highlight.Adornee = model
	highlight.Parent = model
	Debris:AddItem(highlight, FLASH_TIME)
end

-- Calls `callback` for every hit a client hears about. Returns a function that stops it.
function CombatController.observeHit(callback: HitCallback): () -> ()
	table.insert(hitCallbacks, callback)
	return function()
		local index = table.find(hitCallbacks, callback)
		if index then
			table.remove(hitCallbacks, index)
		end
	end
end

-- Network (server -> client)
function CombatController.onDamage(entityId: number, position: Vector3, damage: number, crit: boolean)
	showNumber(position, damage, crit)
	for _, callback in hitCallbacks do
		callback(entityId, position, damage, crit)
	end
end

function CombatController.onHeroHealth(entityId: number, hp: number, maxHp: number)
	local current = CombatController.health()
	local updated = table.clone(current)
	updated[entityId] = { hp = hp, maxHp = maxHp }
	CombatController.health(updated)
end

function CombatController.onEntityDied(_entityId: number, position: Vector3, wasHero: boolean)
	if not wasHero then
		CombatController.poof(position)
	end
end

function CombatController.start()
	-- Yields until the server has registered the service, then asks for what was sent before.
	local network = Network.client("Combat", CombatController)
	network:fire("requestHealth")
end

return CombatController
