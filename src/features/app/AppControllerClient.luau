--!strict

--[=[
	App feature: mounts the root ScreenGui. Add other features' UI components
	as children of App().

	The coins label is a minimal example of using another feature's state: a
	Charm atom from PlayerController, bound into Vide through vide-charm.
]=]

local Players = game:GetService("Players")

local AbilityButtons = require("@Features/heroes/modules/AbilityButtons")
local BossBar = require("@Features/enemies/modules/BossBar")
local DeathToast = require("@Features/run/modules/DeathToast")
local HeroBar = require("@Features/heroes/modules/HeroBar")
local HeroController = require("@Features/heroes/HeroControllerClient")
local Log = require("@Core/Log")
local MinimapView = require("@Features/minimap/modules/MinimapView")
local PlayerController = require("@Features/player/PlayerControllerClient")
local ResultsScreen = require("@Features/run/modules/ResultsScreen")
local RunHud = require("@Features/run/modules/RunHud")
local Vide = require("@Packages/vide")
local VideCharm = require("@Packages/vide-charm")

local create = Vide.create

local function CoinsLabel()
	local coins = VideCharm.useAtom(PlayerController.state.coins)

	return create("TextLabel")({
		Name = "Coins",
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 16, 1, -16),
		Size = UDim2.fromOffset(240, 32),
		BackgroundTransparency = 1,
		Font = Enum.Font.BuilderSansBold,
		TextSize = 22,
		TextColor3 = Color3.new(1, 1, 1),
		TextStrokeTransparency = 0.6,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = function()
			return `Coins: {coins()}`
		end,
	})
end

local function App()
	return create("ScreenGui")({
		Name = "App",
		IgnoreGuiInset = true,
		ResetOnSpawn = false,

		CoinsLabel(),
		HeroBar(),
		RunHud(),
		BossBar(),
		AbilityButtons({
			abilities = HeroController.getDef().abilities,
			cooldownEnds = HeroController.state.cooldownEnds,
			inputMode = HeroController.state.inputMode,
			keys = HeroController.getAbilityKeys(),
			onUse = HeroController.activate,
		}),
		MinimapView(),
		ResultsScreen(),
		DeathToast(),
	})
end

local AppController = {}

function AppController.start()
	Vide.mount(App, Players.LocalPlayer:WaitForChild("PlayerGui"))
	Log.debug("App mounted")
end

return AppController
