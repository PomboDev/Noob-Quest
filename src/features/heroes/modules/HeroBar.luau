--!strict

--[=[
	The local hero's health bar, from the HP the server reports through combat.
]=]

local Bar = require("@Features/app/modules/Bar")
local CombatController = require("@Features/combat/CombatControllerClient")
local HeroController = require("@Features/heroes/HeroControllerClient")
local VideCharm = require("@Packages/vide-charm")

local function HeroBar()
	local health = VideCharm.useAtom(CombatController.health)
	local entityId = VideCharm.useAtom(HeroController.state.entityId)

	local function mine(): CombatController.Health?
		return health()[entityId()]
	end

	return Bar({
		name = "HeroHealth",
		position = UDim2.fromOffset(16, 16),
		size = UDim2.fromOffset(280, 30),
		color = Color3.fromRGB(80, 200, 100),
		fraction = function()
			local current = mine()
			return if current and current.maxHp > 0 then current.hp / current.maxHp else 1
		end,
		label = function()
			local current = mine()
			return if current then `{math.ceil(current.hp)} / {current.maxHp}` else ""
		end,
	})
end

return HeroBar
