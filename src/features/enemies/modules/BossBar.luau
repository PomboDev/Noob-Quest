--!strict

--[=[
	The boss's name and health bar, shown while a boss is alive.
]=]

local Bar = require("@Features/app/modules/Bar")
local EnemyController = require("@Features/enemies/EnemyControllerClient")
local VideCharm = require("@Packages/vide-charm")

local function BossBar()
	local boss = VideCharm.useAtom(EnemyController.state.boss)

	return Bar({
		name = "BossHealth",
		anchor = Vector2.new(0.5, 0),
		position = UDim2.new(0.5, 0, 0, 96),
		size = UDim2.fromOffset(460, 34),
		color = Color3.fromRGB(210, 60, 60),
		visible = function()
			return boss() ~= nil
		end,
		fraction = function()
			local current = boss()
			return if current and current.maxHp > 0 then current.hp / current.maxHp else 0
		end,
		label = function()
			local current = boss()
			return if current then current.name else ""
		end,
	})
end

return BossBar
