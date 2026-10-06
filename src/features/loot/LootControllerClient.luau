--!strict

--[=[
	Loot, client side: draws the coins and XP orbs the server says are on the
	ground for this player.

	Orbs bob in place and fly towards the hero once it comes close, so a
	pickup feels like a pull instead of a pop. The server decides when
	something is picked up (see LootServiceServer); a floating "+N" shows what
	it was worth. Orb parts are pooled, so a busy fight allocates nothing once
	the pool is warm.
]=]

local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local LootTables = require("@Features/loot/modules/LootTables")
local Network = require("@Core/Network")

type Kind = LootTables.Kind

type Orb = {
	part: Part,
	kind: Kind,
	amount: number,
	-- Where it is drawn (it drifts towards the hero) and the height it sits at.
	x: number,
	z: number,
	baseY: number,
	seed: number,
}

local LootController = {}

-- Orbs closer than this to the hero are pulled in.
local MAGNET_RADIUS = 14
local MAGNET_SPEED = 48
local HOVER = 2.2
local BOB = 0.4

local COLORS: { [Kind]: Color3 } = {
	coin = Color3.fromRGB(255, 205, 60),
	xp = Color3.fromRGB(90, 210, 255),
}
local SIZES: { [Kind]: number } = { coin = 1.6, xp = 1.3 }

local folder: Folder? = nil
local orbs: { [number]: Orb } = {}
local pool: { Part } = {}

local function container(): Folder
	if folder == nil or folder.Parent == nil then
		local created = Instance.new("Folder")
		created.Name = "Loot"
		created.Parent = workspace
		folder = created
	end
	return folder :: Folder
end

local function takePart(): Part
	local reused = table.remove(pool)
	if reused then
		return reused
	end

	local part = Instance.new("Part")
	part.Shape = Enum.PartType.Ball
	part.Material = Enum.Material.Neon
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	return part
end

local function releasePart(part: Part)
	part.Parent = nil
	table.insert(pool, part)
end

local function remove(id: number)
	local orb = orbs[id]
	if orb then
		orbs[id] = nil
		releasePart(orb.part)
	end
end

-- A "+N" that floats up from `position` and fades.
local function showAmount(position: Vector3, text: string, color: Color3)
	local anchor = Instance.new("Part")
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.Transparency = 1
	anchor.Size = Vector3.one
	anchor.Position = position

	local gui = Instance.new("BillboardGui")
	gui.Size = UDim2.fromOffset(90, 30)
	gui.AlwaysOnTop = true
	gui.Adornee = anchor
	gui.Parent = anchor

	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.BuilderSansBold
	label.TextSize = 22
	label.TextColor3 = color
	label.TextStrokeTransparency = 0.4
	label.Text = text
	label.Parent = gui

	anchor.Parent = container()

	local info = TweenInfo.new(0.8, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	TweenService:Create(anchor, info, { Position = position + Vector3.new(0, 4, 0) }):Play()
	TweenService:Create(label, info, { TextTransparency = 1, TextStrokeTransparency = 1 }):Play()
	Debris:AddItem(anchor, 1)
end

local function heroPosition(): Vector3?
	local character = Players.LocalPlayer.Character
	local root = if character then character:FindFirstChild("HumanoidRootPart") else nil
	if root and root:IsA("BasePart") then
		return root.Position
	end
	return nil
end

local function step(dt: number)
	local hero = heroPosition()
	local now = os.clock()

	for _, orb in orbs do
		if hero then
			local dx, dz = hero.X - orb.x, hero.Z - orb.z
			local distance = math.sqrt(dx * dx + dz * dz)
			if distance < MAGNET_RADIUS and distance > 1e-3 then
				-- Faster the closer it gets.
				local pull = MAGNET_SPEED * (1.2 - distance / MAGNET_RADIUS) * dt
				local move = math.min(pull, distance)
				orb.x += dx / distance * move
				orb.z += dz / distance * move
			end
		end

		local height = orb.baseY + HOVER + math.sin(now * 3 + orb.seed) * BOB
		orb.part.Position = Vector3.new(orb.x, height, orb.z)
	end
end

-- Network (server -> client)
function LootController.onDrop(id: number, kindIndex: number, amount: number, position: Vector3)
	local kind: Kind? = LootTables.KINDS[kindIndex]
	if kind == nil then
		return
	end

	remove(id)
	local part = takePart()
	local size = SIZES[kind]
	part.Size = Vector3.new(size, size, size)
	part.Color = COLORS[kind]
	part.Position = position + Vector3.new(0, HOVER, 0)
	part.Parent = container()

	orbs[id] = {
		part = part,
		kind = kind,
		amount = amount,
		x = position.X,
		z = position.Z,
		baseY = position.Y,
		seed = id * 0.7,
	}
end

function LootController.onPickup(id: number, collected: boolean)
	local orb = orbs[id]
	if orb and collected then
		local text = if orb.kind == "coin" then `+{orb.amount}` else `+{orb.amount} XP`
		showAmount(orb.part.Position + Vector3.new(0, 1.5, 0), text, COLORS[orb.kind])
	end
	remove(id)
end

function LootController.onClear()
	for id in orbs do
		remove(id)
	end
end

function LootController.start()
	-- Yields until the server has registered the service, then asks for what is already on the ground.
	local network = Network.client("Loot", LootController)
	RunService.Heartbeat:Connect(step)
	network:fire("requestDrops")
end

return LootController
