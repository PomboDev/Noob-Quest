--!strict

--[=[
	Builds the visible, solid parts of an act: tiles and props.

	A tile comes from ReplicatedStorage.Assets.Tiles under its variant's
	prefab name, placed with its pivot on the walking surface at the tile's
	centre and turned by its rotation. A prop comes from Assets.Props under its
	kind. When a prefab is missing a plain block in the right colour stands in,
	so the map works before any art exists.

	Clients build the map from the seed (see WorldControllerClient); the server
	could run the same code if that ever has to move.
]=]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ActSpace = require("@Features/world/modules/ActSpace")
local ActTypes = require("@Features/world/modules/ActTypes")

type Act = ActTypes.Act

local MapBuilder = {}

type Block = {
	color: Color3,
	-- Height of the top above the walking surface, and how thick the block is.
	top: number,
	thickness: number,
	material: Enum.Material,
	transparency: number,
}

local TILE_BLOCKS: { [string]: Block } = {
	Ground = {
		color = Color3.fromRGB(86, 140, 62),
		top = 0,
		thickness = 1,
		material = Enum.Material.Grass,
		transparency = 0,
	},
	Path = {
		color = Color3.fromRGB(176, 150, 104),
		top = 0,
		thickness = 1,
		material = Enum.Material.Ground,
		transparency = 0,
	},
	Plaza = {
		color = Color3.fromRGB(150, 150, 160),
		top = 0,
		thickness = 1,
		material = Enum.Material.Slate,
		transparency = 0,
	},
	Shore = {
		color = Color3.fromRGB(150, 170, 110),
		top = 0,
		thickness = 1,
		material = Enum.Material.Sand,
		transparency = 0,
	},
	ShoreCorner = {
		color = Color3.fromRGB(150, 170, 110),
		top = 0,
		thickness = 1,
		material = Enum.Material.Sand,
		transparency = 0,
	},
	-- Water is the one thing nobody can walk through: a solid pond.
	Water = {
		color = Color3.fromRGB(60, 120, 200),
		top = 3,
		thickness = 4,
		material = Enum.Material.Glass,
		transparency = 0.25,
	},
}

local FALLBACK_BLOCK: Block = {
	color = Color3.fromRGB(255, 0, 255),
	top = 0,
	thickness = 1,
	material = Enum.Material.SmoothPlastic,
	transparency = 0,
}

local function assetFolder(name: string): Instance?
	local assets = ReplicatedStorage:FindFirstChild("Assets")
	return if assets then assets:FindFirstChild(name) else nil
end

local function block(name: string, size: Vector3, cframe: CFrame, color: Color3, material: Enum.Material): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.CFrame = cframe
	part.Color = color
	part.Material = material
	part.Anchored = true
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	return part
end

-- Builds the tile at column x, row y and parents it. Returns what it made.
function MapBuilder.tile(act: Act, tileSet: ActTypes.TileSet, x: number, y: number, parent: Instance): Instance
	local variant = tileSet.variants[act.tiles[ActSpace.tileIndex(act, x, y)]]
	local centerX, centerZ = ActSpace.tileCenter(act, x, y)
	local prefabName = if variant then variant.prefab else "?"
	local rotation = if variant then ActSpace.rotationRadians(variant.rotation) else 0

	local folder = assetFolder("Tiles")
	local prefab = if folder then folder:FindFirstChild(prefabName) else nil
	if prefab and prefab:IsA("Model") then
		local model = prefab:Clone()
		model.Name = `Tile_{x}_{y}`
		model:PivotTo(CFrame.new(centerX, ActSpace.GROUND_Y, centerZ) * CFrame.Angles(0, rotation, 0))
		model.Parent = parent
		return model
	end

	local spec = TILE_BLOCKS[prefabName] or FALLBACK_BLOCK
	local center = ActSpace.GROUND_Y + spec.top - spec.thickness / 2
	local part = block(
		`Tile_{x}_{y}`,
		Vector3.new(act.tileSize, spec.thickness, act.tileSize),
		CFrame.new(centerX, center, centerZ) * CFrame.Angles(0, rotation, 0),
		spec.color,
		spec.material
	)
	part.Transparency = spec.transparency
	part.Parent = parent
	return part
end

local function greyboxProp(kind: string, x: number, z: number, rotation: number): Model
	local model = Instance.new("Model")
	model.Name = kind
	local ground = ActSpace.GROUND_Y
	local turn = CFrame.Angles(0, rotation, 0)

	if kind == "tree" then
		local trunk = block(
			"Trunk",
			Vector3.new(1.2, 5, 1.2),
			CFrame.new(x, ground + 2.5, z) * turn,
			Color3.fromRGB(110, 78, 50),
			Enum.Material.Wood
		)
		local crown = block(
			"Crown",
			Vector3.new(6, 6, 6),
			CFrame.new(x, ground + 7, z) * turn,
			Color3.fromRGB(52, 110, 50),
			Enum.Material.Grass
		)
		crown.Shape = Enum.PartType.Ball
		trunk.Parent, crown.Parent = model, model
		model.PrimaryPart = trunk
	elseif kind == "rock" then
		local rock = block(
			"Rock",
			Vector3.new(3.5, 2.2, 3),
			CFrame.new(x, ground + 0.8, z) * turn,
			Color3.fromRGB(125, 125, 130),
			Enum.Material.Slate
		)
		rock.Shape = Enum.PartType.Ball
		rock.Parent = model
		model.PrimaryPart = rock
	else
		local bush = block(
			"Bush",
			Vector3.new(3, 2, 3),
			CFrame.new(x, ground + 0.8, z) * turn,
			Color3.fromRGB(70, 130, 60),
			Enum.Material.Grass
		)
		bush.Shape = Enum.PartType.Ball
		bush.Parent = model
		model.PrimaryPart = bush
	end

	-- Props are for looks: they never block anyone.
	for _, part in model:GetDescendants() do
		if part:IsA("BasePart") then
			part.CanCollide = false
			part.CanQuery = false
			part.CanTouch = false
		end
	end
	return model
end

-- Builds a prop and parents it.
function MapBuilder.prop(act: Act, prop: ActTypes.Prop, parent: Instance): Instance
	local x, z = ActSpace.propPosition(act, prop)
	local rotation = ActSpace.rotationRadians(prop.rotation)

	local folder = assetFolder("Props")
	local prefab = if folder then folder:FindFirstChild(prop.kind) else nil
	local model: Model
	if prefab and prefab:IsA("Model") then
		model = prefab:Clone()
		model:PivotTo(CFrame.new(x, ActSpace.GROUND_Y, z) * CFrame.Angles(0, rotation, 0))
		for _, part in model:GetDescendants() do
			if part:IsA("BasePart") then
				part.CanCollide = false
			end
		end
	else
		model = greyboxProp(prop.kind, x, z, rotation)
	end

	model.Name = `{prop.kind}_{prop.x}_{prop.y}`
	model.Parent = parent
	return model
end

return MapBuilder
