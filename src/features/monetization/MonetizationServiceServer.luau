--!strict

--[=[
	Developer products and game passes.

	Products: the feature that sells one registers what it grants, in init():

		MonetizationService.registerProduct(COINS_PRODUCT_ID, function(player, data, receipt)
			data.coins += 500
		end)

	ProcessReceipt then grants every purchase exactly once:

	1. Wait until the buyer is on this server with their data loaded. If they
	   aren't, answer NotProcessedYet: Roblox asks again when they rejoin.
	2. Grant: the grant and the record of the PurchaseId change the data
	   together, in one updateData (PurchaseReceipts). A purchase that's
	   already recorded isn't granted again.
	3. Persist: save the profile and wait until the saved copy holds the
	   record. Only then answer PurchaseGranted. If the save fails or times
	   out, or the session ends, answer NotProcessedYet: the retry finds the
	   record if it reached the DataStore after all, and otherwise starts over.

	A grant changes `data` and must not yield. If it errors, its changes are
	undone and the purchase is retried later. Effects outside the data (a
	server-wide boost) aren't undone, so make them last.

	Passes: features register the passes they use, in init(), with an
	optional callback that runs (in its own thread) once a player is known to
	own one, when they join or after they buy it here:

		MonetizationService.registerPass(VIP_PASS_ID, function(player)
			-- give the VIP perks
		end)

	Ownership is checked when a player joins and cached for their session,
	and a purchase made in this server is added right away. If Roblox can't
	be reached, the pass counts as not owned until they rejoin. Clients learn
	which registered passes they own (MonetizationController).
]=]

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")

local Log = require("@Core/Log")
local Network = require("@Core/Network")
local PlayerData = require("@Features/player/modules/PlayerData")
local PlayerService = require("@Features/player/PlayerServiceServer")
local PurchaseReceipts = require("@Features/monetization/modules/PurchaseReceipts")

type Data = PlayerData.Data

-- The receipt Roblox passes to ProcessReceipt.
export type Receipt = {
	PlayerId: number,
	PlaceIdWherePurchased: number,
	PurchaseId: string,
	ProductId: number,
	CurrencyType: Enum.CurrencyType,
	CurrencySpent: number,
}

export type Grant = (player: Player, data: Data, receipt: Receipt) -> ()

-- Seconds a purchase waits for the buyer's data to load.
local LOAD_TIMEOUT = 30
-- Seconds a purchase waits for its save. ProfileStore queues writes to one
-- key about 6 s apart, so leave room for that.
local SAVE_TIMEOUT = 30
-- Tries per ownership check while the Roblox API fails.
local OWNERSHIP_ATTEMPTS = 3

local network: Network.ServerNetwork

local products: { [number]: Grant } = {}
-- Pass id -> callbacks for players who own it.
local passes: { [number]: { (player: Player) -> () } } = {}
local started = false
-- The registered passes each player in the server owns.
local owned: { [Player]: { [number]: true } } = {}
-- Players whose client asked for its passes and gets new ones as they come.
local listening: { [Player]: true } = {}

local MonetizationService = {}

-- // Passes //

local function markOwned(player: Player, passId: number)
	local playerPasses = owned[player]
	if not playerPasses or playerPasses[passId] then
		return
	end

	playerPasses[passId] = true
	Log.debug(`{player.Name} owns pass {passId}`)
	if listening[player] then
		network:fireClient(player, "onPassOwned", passId)
	end
	for _, callback in passes[passId] do
		task.spawn(callback, player)
	end
end

local function checkPassAsync(player: Player, passId: number)
	for attempt = 1, OWNERSHIP_ATTEMPTS do
		local ok, result = pcall(function()
			return MarketplaceService:UserOwnsGamePassAsync(player.UserId, passId)
		end)
		if ok then
			if result then
				markOwned(player, passId)
			end
			return
		elseif player.Parent ~= Players then
			return
		end

		Log.warn(`Checking pass {passId} for {player.Name} failed (attempt {attempt}/{OWNERSHIP_ATTEMPTS}): {result}`)
		if attempt < OWNERSHIP_ATTEMPTS then
			task.wait(2 ^ attempt)
		end
	end
end

local function onPlayerAdded(player: Player)
	if owned[player] then
		return
	end
	owned[player] = {}
	for passId in passes do
		task.spawn(checkPassAsync, player, passId)
	end
end

local function onPlayerRemoving(player: Player)
	owned[player] = nil
	listening[player] = nil
end

local function onPassPurchaseFinished(player: Player, passId: number, wasPurchased: boolean)
	if wasPurchased and passes[passId] then
		markOwned(player, passId)
	end
end

-- // Products //

-- Whether the player's data is loaded, waiting up to LOAD_TIMEOUT for it.
local function waitForData(player: Player): boolean
	local deadline = os.clock() + LOAD_TIMEOUT
	while not PlayerService.getData(player) do
		if player.Parent ~= Players or os.clock() > deadline then
			return false
		end
		task.wait(0.5)
	end
	return true
end

local function processReceiptAsync(receipt: Receipt): Enum.ProductPurchaseDecision
	local purchaseId = receipt.PurchaseId
	local grant = products[receipt.ProductId]
	if not grant then
		Log.warn(`No grant registered for product {receipt.ProductId} (purchase {purchaseId})`)
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	local player = Players:GetPlayerByUserId(receipt.PlayerId)
	if not player or not waitForData(player) then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	local status: PurchaseReceipts.Status? = nil
	local reason: string? = nil
	PlayerService.updateData(player, function(data)
		status, reason = PurchaseReceipts.grant(data, purchaseId, os.time(), function(granting)
			grant(player, granting, receipt)
		end)
	end)

	if status == nil then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	elseif status == "failed" then
		Log.warn(`Granting product {receipt.ProductId} to {player.Name} (purchase {purchaseId}) failed: {reason}`)
		return Enum.ProductPurchaseDecision.NotProcessedYet
	elseif status == "granted" then
		Log.info(`Granted product {receipt.ProductId} to {player.Name} (purchase {purchaseId})`)
	end

	local saved = PlayerService.saveAsync(player, function(savedData)
		return PurchaseReceipts.isRecorded(savedData, purchaseId)
	end, SAVE_TIMEOUT)
	if not saved then
		Log.warn(`Purchase {purchaseId} by {player.Name} wasn't saved yet; Roblox will retry it`)
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	return Enum.ProductPurchaseDecision.PurchaseGranted
end

local function processReceipt(receipt: Receipt): Enum.ProductPurchaseDecision
	local ok, decision = pcall(processReceiptAsync, receipt)
	if ok then
		return decision
	end
	Log.warn(`ProcessReceipt for purchase {receipt.PurchaseId} errored: {decision}`)
	return Enum.ProductPurchaseDecision.NotProcessedYet
end

-- // Public API (server features) //

-- Sets what buying `productId` grants. Call from init(); one grant per product.
function MonetizationService.registerProduct(productId: number, grant: Grant)
	assert(not started, "register products in init()")
	assert(products[productId] == nil, `product {productId} is already registered`)
	products[productId] = grant
end

-- Tracks `passId`, calling `onOwned` (if given) for each player who owns it.
-- Call from init(). Several features may register the same pass.
function MonetizationService.registerPass(passId: number, onOwned: ((player: Player) -> ())?)
	assert(not started, "register passes in init()")
	local callbacks = passes[passId] or {}
	passes[passId] = callbacks
	if onOwned then
		table.insert(callbacks, onOwned)
	end
end

-- Whether `player` is known to own the registered pass. False while the
-- join check is still running: use registerPass's callback to react to it.
function MonetizationService.ownsPass(player: Player, passId: number): boolean
	local playerPasses = owned[player]
	return playerPasses ~= nil and playerPasses[passId] == true
end

-- // Network handlers (client input is untrusted) //

-- The client is listening: send the passes found so far, then each new one.
function MonetizationService.requestPasses(player: Player)
	local playerPasses = owned[player]
	if not playerPasses or listening[player] then
		return
	end

	listening[player] = true
	for passId in playerPasses do
		network:fireClient(player, "onPassOwned", passId)
	end
end

function MonetizationService.init()
	network = Network.server("Monetization", MonetizationService, {
		requestPasses = {}, -- client -> server
		onPassOwned = { Network.Packet.NumberF64 }, -- server -> client
	})
end

-- In start(), so every feature's init() has registered its products and
-- passes before the first receipt or join check.
function MonetizationService.start()
	started = true
	MarketplaceService.ProcessReceipt = processReceipt
	MarketplaceService.PromptGamePassPurchaseFinished:Connect(onPassPurchaseFinished)

	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(onPlayerRemoving)
	for _, player in Players:GetPlayers() do
		onPlayerAdded(player)
	end
end

return MonetizationService
