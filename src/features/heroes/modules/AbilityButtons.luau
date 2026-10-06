--!strict

--[=[
	The ability buttons: big touch targets with a cooldown fill and a
	countdown. On a keyboard the same buttons show the key that fires them.
	Mount it in the HUD with the hero controller's state.
]=]

local RunService = game:GetService("RunService")

local HeroDefs = require("@Features/heroes/modules/HeroDefs")
local Vide = require("@Packages/vide")
local VideCharm = require("@Packages/vide-charm")

local create = Vide.create
local source = Vide.source

export type Props = {
	abilities: { HeroDefs.Ability },
	-- Per ability index: the os.clock() time it is ready again.
	-- Atoms (read by calling them), typed loosely: Charm's atom type doesn't unify across modules.
	cooldownEnds: () -> { [number]: number },
	inputMode: () -> string,
	-- The key that fires each ability, shown while the mouse and keyboard are in use.
	keys: { string },
	onUse: (index: number) -> (),
}

local BUTTON_SIZE = 88
local GAP = 12
local MARGIN = 24

local function AbilityButton(props: Props, index: number, now: () -> number)
	local ability = props.abilities[index]
	local cooldownEnds: () -> { [number]: number } = VideCharm.useAtom(props.cooldownEnds :: any)
	local inputMode: () -> string = VideCharm.useAtom(props.inputMode :: any)

	local function remaining(): number
		return math.max(0, (cooldownEnds()[index] or 0) - now())
	end

	return create("TextButton")({
		Name = ability.id,
		LayoutOrder = index,
		Size = UDim2.fromOffset(BUTTON_SIZE, BUTTON_SIZE),
		BackgroundColor3 = Color3.fromRGB(46, 52, 74),
		AutoButtonColor = true,
		Text = "",
		ClipsDescendants = true,
		Activated = function()
			props.onUse(index)
		end,

		create("UICorner")({ CornerRadius = UDim.new(0, 16) }),
		create("UIStroke")({ Color = Color3.fromRGB(255, 255, 255), Transparency = 0.5, Thickness = 2 }),

		-- Darkens the part of the button that is still cooling down, from the top.
		create("Frame")({
			Name = "Cooldown",
			AnchorPoint = Vector2.new(0, 1),
			Position = UDim2.fromScale(0, 1),
			Size = function()
				return UDim2.fromScale(1, math.clamp(remaining() / ability.cooldown, 0, 1))
			end,
			BackgroundColor3 = Color3.new(0, 0, 0),
			BackgroundTransparency = 0.35,
			BorderSizePixel = 0,
		}),

		create("TextLabel")({
			Name = "Name",
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromScale(0.9, 0.5),
			BackgroundTransparency = 1,
			Font = Enum.Font.BuilderSansBold,
			TextScaled = true,
			TextColor3 = Color3.new(1, 1, 1),
			TextStrokeTransparency = 0.5,
			Text = function()
				local seconds = remaining()
				if seconds > 0 then
					return if seconds >= 10 then tostring(math.ceil(seconds)) else string.format("%.1f", seconds)
				end
				return ability.name
			end,
		}),

		create("TextLabel")({
			Name = "Key",
			Position = UDim2.fromOffset(8, 4),
			Size = UDim2.fromOffset(40, 18),
			BackgroundTransparency = 1,
			Font = Enum.Font.BuilderSansBold,
			TextSize = 16,
			TextColor3 = Color3.fromRGB(255, 220, 120),
			TextXAlignment = Enum.TextXAlignment.Left,
			Visible = function()
				return inputMode() == "aimed"
			end,
			Text = props.keys[index] or "",
		}),
	})
end

local function AbilityButtons(props: Props)
	-- One shared clock for every cooldown readout, running only while mounted.
	local now = source(os.clock())
	Vide.cleanup(RunService.Heartbeat:Connect(function()
		now(os.clock())
	end))

	local children: { any } = {
		create("UIListLayout")({
			FillDirection = Enum.FillDirection.Horizontal,
			HorizontalAlignment = Enum.HorizontalAlignment.Right,
			VerticalAlignment = Enum.VerticalAlignment.Bottom,
			Padding = UDim.new(0, GAP),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
	}
	for index in props.abilities do
		table.insert(children, AbilityButton(props, index, now))
	end

	local container: { [any]: any } = {
		Name = "AbilityButtons",
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.new(1, -MARGIN, 1, -MARGIN),
		Size = UDim2.fromOffset(#props.abilities * (BUTTON_SIZE + GAP), BUTTON_SIZE),
		BackgroundTransparency = 1,
	}
	for _, child in children do
		table.insert(container, child)
	end
	return create("Frame")(container)
end

return AbilityButtons
