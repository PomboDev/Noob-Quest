--!strict

--[=[
	A short notice of what the last death cost, shown in the lobby. It is not
	the old "Defeated" screen: it only appears when something was lost, and it
	goes away by itself.
]=]

local RunController = require("@Features/run/RunControllerClient")
local Vide = require("@Packages/vide")
local VideCharm = require("@Packages/vide-charm")

local create = Vide.create

local function DeathToast()
	local penalty = VideCharm.useAtom(RunController.state.penalty)

	return create("TextLabel")({
		Name = "DeathToast",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 120),
		Size = UDim2.fromOffset(460, 44),
		BackgroundColor3 = Color3.fromRGB(60, 24, 30),
		BackgroundTransparency = 0.2,
		Font = Enum.Font.BuilderSansBold,
		TextSize = 22,
		TextColor3 = Color3.fromRGB(255, 190, 190),
		Visible = function()
			return penalty() ~= nil
		end,
		Text = function()
			local lost = penalty()
			if lost == nil then
				return ""
			end

			local parts = {}
			if lost.coins > 0 then
				table.insert(parts, `{lost.coins} coins`)
			end
			if lost.xp > 0 then
				table.insert(parts, `{lost.xp} XP`)
			end
			return `You died and lost {table.concat(parts, " and ")}`
		end,

		create("UICorner")({ CornerRadius = UDim.new(0, 12) }),
		create("UIStroke")({ Color = Color3.fromRGB(255, 120, 120), Transparency = 0.5, Thickness = 2 }),
	})
end

return DeathToast
