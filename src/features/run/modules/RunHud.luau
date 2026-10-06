--!strict

--[=[
	The run's HUD: act, timer and difficulty at the top, what to do next
	under them, and the teleporter's charge while it charges.
]=]

local Bar = require("@Features/app/modules/Bar")
local RunController = require("@Features/run/RunControllerClient")
local Vide = require("@Packages/vide")
local VideCharm = require("@Packages/vide-charm")

local create = Vide.create

local HINTS: { [string]: string } = {
	Generating = "Building the map...",
	Exploring = "Find the teleporter, and look for chests and statues!",
	Charging = "Stay close to the teleporter!",
	Boss = "Defeat the Siege Golem!",
	ExitOpen = "Step into the portal to finish!",
}

local function formatTime(seconds: number): string
	return string.format("%02d:%02d", seconds // 60, seconds % 60)
end

local function RunHud()
	local view = VideCharm.useAtom(RunController.state.view)

	local function active(): boolean
		local phase = view().phase
		return phase ~= "Waiting" and phase ~= "Victory" and phase ~= "Defeat"
	end

	return create("Frame")({
		Name = "RunHud",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 12),
		Size = UDim2.fromOffset(460, 76),
		BackgroundTransparency = 1,
		Visible = active,

		create("TextLabel")({
			Name = "Status",
			Size = UDim2.new(1, 0, 0, 30),
			BackgroundTransparency = 1,
			Font = Enum.Font.BuilderSansBold,
			TextSize = 24,
			TextColor3 = Color3.new(1, 1, 1),
			TextStrokeTransparency = 0.4,
			Text = function()
				local current = view()
				return `Act {current.act}   {formatTime(current.elapsed)}   Danger x{string.format(
					"%.2f",
					current.coefficient
				)}`
			end,
		}),

		create("TextLabel")({
			Name = "Hint",
			Position = UDim2.fromOffset(0, 32),
			Size = UDim2.new(1, 0, 0, 24),
			BackgroundTransparency = 1,
			Font = Enum.Font.BuilderSans,
			TextSize = 18,
			TextColor3 = Color3.fromRGB(255, 235, 170),
			TextStrokeTransparency = 0.5,
			Text = function()
				return HINTS[view().phase] or ""
			end,
		}),

		Bar({
			name = "TeleporterCharge",
			position = UDim2.fromOffset(80, 58),
			size = UDim2.fromOffset(300, 16),
			color = Color3.fromRGB(70, 200, 230),
			visible = function()
				return view().phase == "Charging"
			end,
			fraction = function()
				return view().charge
			end,
		}),
	})
end

return RunHud
