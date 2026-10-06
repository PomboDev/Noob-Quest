--!strict

--[=[
	A filled bar with an optional label, for health, charge and boss bars.
	`fraction` and `label` are functions so the bar follows state by itself.
]=]

local Vide = require("@Packages/vide")

local create = Vide.create

export type Props = {
	name: string,
	size: UDim2,
	position: UDim2?,
	anchor: Vector2?,
	color: Color3,
	-- 0 to 1.
	fraction: () -> number,
	label: (() -> string)?,
	visible: (() -> boolean)?,
}

local function Bar(props: Props)
	local children: { any } = {
		create("UICorner")({ CornerRadius = UDim.new(0, 8) }),
		create("UIStroke")({ Color = Color3.new(1, 1, 1), Transparency = 0.6, Thickness = 2 }),
		create("Frame")({
			Name = "Fill",
			Size = function()
				return UDim2.fromScale(math.clamp(props.fraction(), 0, 1), 1)
			end,
			BackgroundColor3 = props.color,
			BorderSizePixel = 0,

			create("UICorner")({ CornerRadius = UDim.new(0, 8) }),
		}),
	}

	local label = props.label
	if label then
		table.insert(
			children,
			create("TextLabel")({
				Name = "Label",
				Size = UDim2.fromScale(1, 1),
				BackgroundTransparency = 1,
				Font = Enum.Font.BuilderSansBold,
				TextSize = 18,
				TextColor3 = Color3.new(1, 1, 1),
				TextStrokeTransparency = 0.5,
				Text = label,
			})
		)
	end

	local container: { [any]: any } = {
		Name = props.name,
		AnchorPoint = props.anchor or Vector2.zero,
		Position = props.position or UDim2.new(),
		Size = props.size,
		BackgroundColor3 = Color3.fromRGB(20, 22, 34),
		BackgroundTransparency = 0.25,
		BorderSizePixel = 0,
		Visible = props.visible or true,
	}
	for _, child in children do
		table.insert(container, child)
	end
	return create("Frame")(container)
end

return Bar
