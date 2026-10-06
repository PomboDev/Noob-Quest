--!strict

--[=[
	The minimap's frame. The map is drawn inside a CanvasGroup: a CanvasGroup
	renders its children as one image, so the rounded corners clip the whole
	map into a circle (a rounded square when the map is open). The dark
	background of the CanvasGroup is the fog of war, and the map is drawn on top
	of it by MinimapController.

	Top right, and in the middle of the screen when the map is open. Hidden in
	the lobby, where there is no act.
]=]

local MinimapController = require("@Features/minimap/MinimapControllerClient")
local MinimapLayer = require("@Features/minimap/modules/MinimapLayer")
local MinimapMath = require("@Features/minimap/modules/MinimapMath")
local Vide = require("@Packages/vide")
local VideCharm = require("@Packages/vide-charm")
local WorldController = require("@Features/world/WorldControllerClient")

local create = Vide.create

local MARGIN = 16

local function MinimapView()
	local expanded = VideCharm.useAtom(MinimapController.state.expanded)
	local act = VideCharm.useAtom(WorldController.state.act)

	local function corner(): UDim
		return if expanded() then UDim.new(0, 18) else UDim.new(0.5, 0)
	end

	return create("Frame")({
		Name = "Minimap",
		AnchorPoint = function()
			return if expanded() then Vector2.new(0.5, 0.5) else Vector2.new(1, 0)
		end,
		Position = function()
			return if expanded() then UDim2.fromScale(0.5, 0.5) else UDim2.new(1, -MARGIN, 0, MARGIN)
		end,
		Size = function()
			local size = if expanded() then MinimapMath.SIZE_EXPANDED else MinimapMath.SIZE_NORMAL
			return UDim2.fromOffset(size, size)
		end,
		BackgroundTransparency = 1,
		Visible = function()
			return act() ~= nil
		end,
		ZIndex = 4,

		create("CanvasGroup")({
			Name = "Canvas",
			Size = UDim2.fromScale(1, 1),
			BackgroundColor3 = MinimapLayer.FOG_COLOR,
			BackgroundTransparency = 0.08,

			create("UICorner")({ CornerRadius = corner }),

			-- The map itself: bigger than the view, slid around by the controller.
			create("Frame")({
				Name = "Content",
				BackgroundTransparency = 1,
				Size = UDim2.fromOffset(0, 0),

				Vide.action(function(frame)
					MinimapController.attach(frame :: Frame)
				end),
			}),
		}),

		create("Frame")({
			Name = "Ring",
			Size = UDim2.fromScale(1, 1),
			BackgroundTransparency = 1,
			ZIndex = 5,

			create("UICorner")({ CornerRadius = corner }),
			create("UIStroke")({ Color = Color3.new(1, 1, 1), Transparency = 0.45, Thickness = 3 }),
		}),

		-- Click or tap to open and close the whole map.
		create("TextButton")({
			Name = "Toggle",
			Size = UDim2.fromScale(1, 1),
			BackgroundTransparency = 1,
			Text = "",
			ZIndex = 6,
			Activated = function()
				MinimapController.toggle()
			end,
		}),
	})
end

return MinimapView
