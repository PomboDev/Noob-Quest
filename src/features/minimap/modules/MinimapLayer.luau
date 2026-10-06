--!strict

--[=[
	The picture inside the minimap: explored tiles, icons for what the hero has
	found, enemy dots and the hero's own dot. Everything is positioned in
	fractions of the content frame, so when the content is resized (the map is
	opened) nothing needs to move.

	The fog of war is the dark background of the minimap itself. A tile is only
	drawn once the hero has seen it, so unexplored ground stays dark. Tiles in
	sight are drawn bright and tiles seen before are dimmed.

	Drawing a Frame per tile would cost thousands of Frames, so tiles are
	merged into rectangles with greedy meshing (GreedyMesh): neighbouring tiles
	of one colour share a Frame. There are two meshes. The base holds everything
	explored, dimmed, and is meshed again only when the hero finds new tiles. The
	sight mesh on top holds the bright tiles in sight, a few dozen, and is meshed
	again whenever they change. Each mesh reuses a pool of Frames.

	State lives in a Layer table that the controller keeps. Each function takes
	the layer first.
]=]

local ActSpace = require("@Features/world/modules/ActSpace")
local ActTypes = require("@Features/world/modules/ActTypes")
local GreedyMesh = require("@Features/minimap/modules/GreedyMesh")
local MinimapMath = require("@Features/minimap/modules/MinimapMath")
local Targeting = require("@Features/combat/modules/Targeting")
local TileSet = require("@Features/world/modules/TileSet")

type Act = ActTypes.Act
type Poi = ActTypes.Poi

type Icon = {
	poi: Poi,
	frame: Frame,
	-- The tile that must be explored before the icon shows.
	tileIndex: number,
}

export type Layer = {
	act: Act,
	content: Frame,
	originX: number,
	originZ: number,
	mapWidth: number,
	mapHeight: number,
	-- Per tile (row by row): its colour kind once explored, 0 before.
	explored: { number },
	-- Per tile: its colour kind while in sight, 0 otherwise.
	sight: { number },
	-- The tiles in sight now, in the order MinimapMath.tilesWithin gave them.
	visible: { number },
	-- The Frames of the two meshes, reused each time they are meshed again.
	basePool: { Frame },
	sightPool: { Frame },
	icons: { Icon },
	portal: Frame,
	dots: { Frame },
	hero: Frame,
}

type IconSpec = {
	color: Color3,
	size: number,
	round: boolean,
	rotation: number,
	-- Dims once the object has been used up (a chest that was opened).
	usable: boolean,
}

local ICONS: { [string]: IconSpec } = {
	spawn = { color = Color3.fromRGB(110, 230, 140), size = 9, round = true, rotation = 0, usable = false },
	teleporter = { color = Color3.fromRGB(80, 210, 240), size = 13, round = false, rotation = 45, usable = false },
	angelStatue = { color = Color3.fromRGB(255, 245, 200), size = 10, round = true, rotation = 0, usable = true },
	devilStatue = { color = Color3.fromRGB(225, 60, 50), size = 10, round = true, rotation = 0, usable = true },
	chest = { color = Color3.fromRGB(255, 200, 60), size = 8, round = false, rotation = 0, usable = true },
	structure = { color = Color3.fromRGB(175, 175, 195), size = 9, round = false, rotation = 0, usable = false },
}
local PORTAL_SPEC: IconSpec =
	{ color = Color3.fromRGB(180, 100, 255), size = 14, round = false, rotation = 45, usable = false }

-- Tile variants that look alike share a kind, and only tiles of one kind merge.
local KIND_COLORS: { Color3 } = {
	Color3.fromRGB(70, 118, 56), -- 1: ground
	Color3.fromRGB(178, 152, 106), -- 2: path
	Color3.fromRGB(150, 150, 162), -- 3: plaza
	Color3.fromRGB(150, 170, 110), -- 4: shore
	Color3.fromRGB(62, 122, 205), -- 5: water
	Color3.fromRGB(110, 110, 110), -- 6: anything else
}
local UNKNOWN_KIND = 6
local KIND_OF_PREFAB: { [string]: number } = {
	Ground = 1,
	Path = 2,
	Plaza = 3,
	Shore = 4,
	ShoreCorner = 4,
	Water = 5,
}

-- Tiles seen before but out of sight are blended this far towards the fog. They
-- are darkened, not made see-through: neighbouring tiles overlap by a pixel, and
-- two see-through tiles would show a grid line where they meet.
local FOG_COLOR = Color3.fromRGB(14, 16, 26)
local DIMMED = 0.55
-- The same kinds, dimmed for the tiles seen before.
local DIM_COLORS: { Color3 } = {}
for kind, color in KIND_COLORS do
	DIM_COLORS[kind] = color:Lerp(FOG_COLOR, DIMMED)
end

local ENEMY_COLOR = Color3.fromRGB(255, 70, 70)
local ENEMY_SIZE = 5
local HERO_SIZE = 10
local MAX_DOTS = 100

local MinimapLayer = {}

-- The dark of the unexplored map: the view uses it as its background.
MinimapLayer.FOG_COLOR = FOG_COLOR

local function makeIcon(spec: IconSpec, name: string): Frame
	local frame = Instance.new("Frame")
	frame.Name = name
	frame.AnchorPoint = Vector2.new(0.5, 0.5)
	frame.Size = UDim2.fromOffset(spec.size, spec.size)
	frame.BackgroundColor3 = spec.color
	frame.BorderSizePixel = 0
	frame.Rotation = spec.rotation
	frame.ZIndex = 3
	frame.Visible = false

	if spec.round then
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0.5, 0)
		corner.Parent = frame
	end

	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(20, 20, 30)
	stroke.Thickness = 1.5
	stroke.Parent = frame
	return frame
end

local function placeAt(layer: Layer, frame: GuiObject, x: number, z: number)
	frame.Position = UDim2.fromScale(
		MinimapMath.fraction(layer.originX, layer.mapWidth, x),
		MinimapMath.fraction(layer.originZ, layer.mapHeight, z)
	)
end

local function makeDot(layer: Layer): Frame
	local dot =
		makeIcon({ color = ENEMY_COLOR, size = ENEMY_SIZE, round = true, rotation = 0, usable = false }, "Enemy")
	dot.ZIndex = 4
	dot.Parent = layer.content
	return dot
end

-- Builds a layer in `content` for a new act, with nothing explored.
function MinimapLayer.create(content: Frame, act: Act): Layer
	content:ClearAllChildren()

	local originX, originZ = ActSpace.origin(act)
	local layer: Layer = {
		act = act,
		content = content,
		originX = originX,
		originZ = originZ,
		mapWidth = act.width * act.tileSize,
		mapHeight = act.height * act.tileSize,
		explored = table.create(act.width * act.height, 0),
		sight = table.create(act.width * act.height, 0),
		visible = {},
		basePool = {},
		sightPool = {},
		icons = {},
		portal = makeIcon(PORTAL_SPEC, "Portal"),
		dots = {},
		hero = makeIcon(
			{ color = Color3.new(1, 1, 1), size = HERO_SIZE, round = true, rotation = 0, usable = false },
			"Hero"
		),
	}

	for _, poi in act.pois do
		local spec = ICONS[poi.kind]
		if spec then
			local frame = makeIcon(spec, poi.id)
			placeAt(layer, frame, ActSpace.poiCenter(act, poi))
			frame.Parent = content
			table.insert(layer.icons, { poi = poi, frame = frame, tileIndex = ActSpace.tileIndex(act, poi.cx, poi.cy) })
		end
	end

	layer.portal.Parent = content
	layer.hero.ZIndex = 6
	layer.hero.Visible = true
	layer.hero.Parent = content
	return layer
end

local function kindOf(act: Act, index: number): number
	local variant = TileSet.DEFAULT.variants[act.tiles[index]]
	return if variant then KIND_OF_PREFAB[variant.prefab] or UNKNOWN_KIND else UNKNOWN_KIND
end

local function newPatch(layer: Layer, zIndex: number): Frame
	local patch = Instance.new("Frame")
	patch.Name = "Patch"
	patch.BorderSizePixel = 0
	patch.ZIndex = zIndex
	patch.Parent = layer.content
	return patch
end

-- Puts a mesh on screen: one Frame per rectangle, taken from `pool` (which
-- grows when it has to) and coloured from `colors` by the rectangle's kind.
local function drawRects(layer: Layer, pool: { Frame }, rects: { GreedyMesh.Rect }, colors: { Color3 }, zIndex: number)
	local act = layer.act
	for index, rect in rects do
		local existing: Frame? = pool[index]
		local patch = existing or newPatch(layer, zIndex)
		pool[index] = patch

		patch.Position = UDim2.fromScale(rect.x / act.width, rect.y / act.height)
		-- A pixel more than its share, so neighbours overlap instead of leaving seams.
		patch.Size = UDim2.new(rect.w / act.width, 1, rect.h / act.height, 1)
		patch.BackgroundColor3 = colors[rect.value]
		patch.Visible = true
	end

	for index = #rects + 1, #pool do
		pool[index].Visible = false
	end
end

local function sameTiles(a: { number }, b: { number }): boolean
	if #a ~= #b then
		return false
	end
	for index, tile in a do
		if b[index] ~= tile then
			return false
		end
	end
	return true
end

-- The hero is at (x, z): tiles in sight are explored and drawn bright, and the
-- ones that just went out of sight stay on the map, dimmed.
function MinimapLayer.reveal(layer: Layer, x: number, z: number)
	local act = layer.act
	local now = MinimapMath.tilesWithin(
		act.width,
		act.height,
		act.tileSize,
		layer.originX,
		layer.originZ,
		x,
		z,
		MinimapMath.VISION_RADIUS
	)

	local found = false
	for _, index in now do
		if layer.explored[index] == 0 then
			layer.explored[index] = kindOf(act, index)
			found = true
		end
	end
	if found then
		drawRects(layer, layer.basePool, GreedyMesh.merge(act.width, act.height, layer.explored), DIM_COLORS, 1)
	end

	if not sameTiles(now, layer.visible) then
		for _, index in layer.visible do
			layer.sight[index] = 0
		end
		for _, index in now do
			layer.sight[index] = layer.explored[index]
		end
		drawRects(layer, layer.sightPool, GreedyMesh.merge(act.width, act.height, layer.sight), KIND_COLORS, 2)
		layer.visible = now
	end
end

-- Shows the icons whose tile has been explored, and dims the ones already used
-- up. `gameplay` is workspace.Gameplay, where the server keeps the objects.
function MinimapLayer.refreshIcons(layer: Layer, gameplay: Instance?)
	for _, icon in layer.icons do
		local explored = layer.explored[icon.tileIndex] ~= 0 or icon.poi.kind == "spawn"
		icon.frame.Visible = explored

		if explored and ICONS[icon.poi.kind].usable then
			local model = if gameplay then gameplay:FindFirstChild(icon.poi.id) else nil
			local prompt = if model then model:FindFirstChildWhichIsA("ProximityPrompt", true) else nil
			icon.frame.BackgroundTransparency = if prompt and not prompt.Enabled then 0.7 else 0
		end
	end

	-- The exit portal exists only once the boss is dead.
	local portal = if gameplay then gameplay:FindFirstChild("portal") else nil
	if portal and portal:IsA("Model") then
		local position = portal:GetPivot().Position
		placeAt(layer, layer.portal, position.X, position.Z)
		layer.portal.Visible = true
	else
		layer.portal.Visible = false
	end
end

-- Draws a dot for every enemy within `radius` of the hero. What is out of sight stays hidden.
function MinimapLayer.setEnemies(
	layer: Layer,
	enemies: { Targeting.Point },
	heroX: number,
	heroZ: number,
	radius: number
)
	local shown = 0
	for _, enemy in enemies do
		local dx, dz = enemy.x - heroX, enemy.z - heroZ
		if dx * dx + dz * dz <= radius * radius and shown < MAX_DOTS then
			shown += 1
			local existing: Frame? = layer.dots[shown]
			local dot = existing or makeDot(layer)
			layer.dots[shown] = dot
			placeAt(layer, dot, enemy.x, enemy.z)
			dot.Visible = true
		end
	end

	for index = shown + 1, #layer.dots do
		layer.dots[index].Visible = false
	end
end

function MinimapLayer.setHero(layer: Layer, x: number, z: number)
	placeAt(layer, layer.hero, x, z)
end

-- Forgets the layer and everything drawn in it.
function MinimapLayer.destroy(layer: Layer)
	layer.content:ClearAllChildren()
end

return MinimapLayer
