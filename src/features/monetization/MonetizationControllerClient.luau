--!strict

--[=[
	Client side of monetization: the game passes the local player owns, as a
	Charm atom for UI, and purchase prompts. The server decides what a
	purchase grants (MonetizationService); prompting only opens Roblox's
	purchase dialog.
]=]

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")

local Charm = require("@Packages/charm")
local Network = require("@Core/Network")

local passes = Charm.atom({} :: { [number]: true })

local MonetizationController = {}

MonetizationController.state = {
	-- Registered passes the local player owns: passId -> true
	passes = passes,
}

-- Reads the atom, so it's reactive inside Charm.computed and Vide effects.
function MonetizationController.ownsPass(passId: number): boolean
	return passes()[passId] == true
end

function MonetizationController.promptProduct(productId: number)
	MarketplaceService:PromptProductPurchase(Players.LocalPlayer, productId)
end

function MonetizationController.promptPass(passId: number)
	MarketplaceService:PromptGamePassPurchase(Players.LocalPlayer, passId)
end

-- Network: the server found (or saw us buy) a pass we own.
function MonetizationController.onPassOwned(passId: number)
	local current = table.clone(passes())
	current[passId] = true
	passes(current)
end

function MonetizationController.start()
	local network = Network.client("Monetization", MonetizationController)
	network:fire("requestPasses")
end

return MonetizationController
