--!strict

--[=[
	What the screen shows when a run is won: what the run collected and a
	button back to the lobby. A death skips it: the player lands in the lobby
	and sees what it cost (see DeathToast).
]=]

local RunController = require("@Features/run/RunControllerClient")
local Vide = require("@Packages/vide")
local VideCharm = require("@Packages/vide-charm")

local create = Vide.create

local function Line(name: string, order: number, text: () -> string, size: number, color: Color3)
	return create("TextLabel")({
		Name = name,
		LayoutOrder = order,
		Size = UDim2.new(1, 0, 0, size + 10),
		BackgroundTransparency = 1,
		Font = Enum.Font.BuilderSansBold,
		TextSize = size,
		TextColor3 = color,
		TextStrokeTransparency = 0.5,
		Text = text,
	})
end

local function ResultsScreen()
	local view = VideCharm.useAtom(RunController.state.view)
	local showResults = VideCharm.useAtom(RunController.state.showResults)

	return create("Frame")({
		Name = "Results",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Color3.new(0, 0, 0),
		BackgroundTransparency = 0.45,
		Visible = showResults,
		ZIndex = 10,

		create("Frame")({
			Name = "Panel",
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromOffset(420, 320),
			BackgroundColor3 = Color3.fromRGB(30, 34, 52),
			ZIndex = 11,

			create("UICorner")({ CornerRadius = UDim.new(0, 20) }),
			create("UIStroke")({ Color = Color3.new(1, 1, 1), Transparency = 0.5, Thickness = 3 }),
			create("UIListLayout")({
				HorizontalAlignment = Enum.HorizontalAlignment.Center,
				VerticalAlignment = Enum.VerticalAlignment.Center,
				Padding = UDim.new(0, 8),
				SortOrder = Enum.SortOrder.LayoutOrder,
			}),

			Line("Title", 1, function()
				return "Victory!"
			end, 44, Color3.fromRGB(255, 225, 120)),
			Line("Coins", 2, function()
				return `Coins  +{view().coins}`
			end, 28, Color3.fromRGB(255, 215, 80)),
			Line("Xp", 3, function()
				return `XP  +{view().xp}`
			end, 28, Color3.fromRGB(140, 210, 255)),

			create("TextButton")({
				Name = "ReturnToLobby",
				LayoutOrder = 4,
				Size = UDim2.fromOffset(240, 64),
				BackgroundColor3 = Color3.fromRGB(70, 180, 90),
				Font = Enum.Font.BuilderSansBold,
				TextSize = 28,
				TextColor3 = Color3.new(1, 1, 1),
				Text = "Return to lobby",
				AutoButtonColor = true,
				ZIndex = 12,
				Activated = function()
					RunController.returnToLobby()
				end,

				create("UICorner")({ CornerRadius = UDim.new(0, 16) }),
			}),
		}),
	})
end

return ResultsScreen
