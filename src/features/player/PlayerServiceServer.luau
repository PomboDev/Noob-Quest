--!strict

--[=[
	Server-authoritative player data.

	Loads each player's profile with ProfileStore, upgrading data saved by
	older versions (see PlayerMigrations), lets other server features read and
	change it through getData/updateData, and replicates every change to the
	owning client as a binary delta (see PlayerControllerClient).

	A full sync is one Packet.BufferLong, so the serialized data must stay
	under 64 KB. In Studio without API access, ProfileStore falls back to a
	mock store.
]=]

local Players = game:GetService("Players")

local DeltaCompress = require("@Core/DeltaCompress")
local Log = require("@Core/Log")
local Network = require("@Core/Network")
local PlayerData = require("@Features/player/modules/PlayerData")
local PlayerMigrations = require("@Features/player/modules/PlayerMigrations")
local ProfileStore = require("@ServerPackages/profile-store")

type Data = PlayerData.Data

local STORE_NAME = "PlayerData"

-- `:: any`: Data's optional fields (nil) aren't in ProfileStore's
-- JSONAcceptable, so the template is typed through the annotation instead.
local store: ProfileStore.ProfileStore<Data> = ProfileStore.New(STORE_NAME, PlayerData.TEMPLATE :: any)

local network: Network.ServerNetwork
-- Derived from the store, as ProfileStore recommends: its generic Profile<T>
-- can't be spelled out without type errors.
local profiles: { [Player]: typeof(store:StartSessionAsync("", {})) } = {}
-- Snapshot of what each client last received. Absent until the client asks.
local lastSent: { [Player]: any } = {}
local dirty: { [Player]: true } = {}
local flushScheduled = false
local loadedCallbacks: { (player: Player) -> () } = {}

local PlayerService = {}

local function sync(player: Player, data: Data, previous: any)
	local delta, snapshot = DeltaCompress.createDelta(previous, data, PlayerData.CONTEXT)
	if delta then
		network:fireClient(player, "onDataDelta", delta)
		lastSent[player] = snapshot
	end
end

-- Sends every pending change at most once per frame, however many
-- updateData calls happened in between. One player's failure (data that
-- can't be serialized, a sync over the size limit) never blocks the others.
local function flush()
	flushScheduled = false

	for player in dirty do
		local profile = profiles[player]
		local previous = lastSent[player]
		if profile and previous then
			-- `:: any`: strict mode has no type for the error of a call that returns nothing
			local ok, err = pcall(sync :: any, player, profile.Data, previous)
			if not ok then
				Log.warn(`Failed to replicate {player.Name}'s data: {err}`)
			end
		end
	end

	table.clear(dirty)
end

local function markDirty(player: Player)
	dirty[player] = true

	if not flushScheduled then
		flushScheduled = true
		task.defer(flush)
	end
end

local function onPlayerAdded(player: Player)
	-- ProfileStore's exported type only declares `Steal`, hence the cast.
	local profile = store:StartSessionAsync(
		`Player_{player.UserId}`,
		{
			Cancel = function()
				return player.Parent ~= Players
			end,
		} :: any
	)

	if not profile then
		-- Cancelled because the player left, or the session could not be started.
		if player.Parent == Players then
			player:Kick("Your data could not be loaded. Please rejoin.")
		end
		return
	end

	-- Before Reconcile, which would otherwise give old data the current
	-- schemaVersion if it had none. On failure the session ends with the data
	-- unchanged, so it stays loadable by a fixed or newer server.
	local migrated, result = pcall(PlayerMigrations.migrate, profile.Data)
	if not migrated then
		Log.warn(`Could not load {player.Name}'s data: {result}`)
		profile:EndSession()
		if player.Parent == Players then
			player:Kick("Your data could not be loaded. Please rejoin.")
		end
		return
	end
	profile.Data = result

	profile:AddUserId(player.UserId)
	profile:Reconcile()

	profile.OnSessionEnd:Connect(function()
		profiles[player] = nil
		lastSent[player] = nil
		dirty[player] = nil
		player:Kick("Your data session ended. Please rejoin.")
	end)

	if player.Parent ~= Players then
		profile:EndSession()
		return
	end

	profiles[player] = profile
	Log.debug(`Loaded data for {player.Name}`)

	for _, callback in loadedCallbacks do
		task.spawn(callback, player)
	end

	-- The client may have asked for its data before loading finished.
	if lastSent[player] then
		markDirty(player)
	end
end

local function onPlayerRemoving(player: Player)
	local profile = profiles[player]
	if profile then
		profile:EndSession()
	end

	lastSent[player] = nil
	dirty[player] = nil
end

-- The player's live data, or nil while it is loading. Treat it as read-only
-- and go through updateData so the client stays in sync.
function PlayerService.getData(player: Player): Data?
	local profile = profiles[player]
	return if profile then profile.Data else nil
end

-- Mutates a loaded player's data and replicates the change. Returns false if
-- the data is not loaded (yet). `mutate` must not yield: the change is
-- replicated once it returns.
function PlayerService.updateData(player: Player, mutate: (data: Data) -> ()): boolean
	local profile = profiles[player]
	if not profile then
		return false
	end

	mutate(profile.Data)
	markDirty(player)
	return true
end

-- Calls `callback` (in its own thread) for every player whose data is loaded
-- now or loads later.
function PlayerService.observeLoaded(callback: (player: Player) -> ())
	table.insert(loadedCallbacks, callback)
	for player in profiles do
		task.spawn(callback, player)
	end
end

-- Saves the player's profile now and yields until a save whose data passes
-- `isSaved` reaches the DataStore. Returns false instead if the data isn't
-- loaded, the session ends or `timeout` seconds pass first.
function PlayerService.saveAsync(player: Player, isSaved: (saved: Data) -> boolean, timeout: number): boolean
	local profile = profiles[player]
	if not profile or not profile:IsActive() then
		return false
	end

	local thread = coroutine.running()
	local result: boolean? = nil
	local waiting = false
	local connections: { { Disconnect: (self: any) -> () } } = {}

	local function finish(value: boolean)
		if result ~= nil then
			return
		end
		result = value
		for _, connection in connections do
			connection:Disconnect()
		end
		if waiting then
			task.spawn(thread)
		end
	end

	table.insert(
		connections,
		profile.OnAfterSave:Connect(function(saved)
			if isSaved(saved) then
				finish(true)
			end
		end)
	)
	table.insert(
		connections,
		profile.OnSessionEnd:Connect(function()
			finish(false)
		end)
	)
	task.delay(timeout, finish, false)

	profile:Save()
	if result == nil then
		waiting = true
		coroutine.yield()
	end
	return result == true
end

-- Network: the client is listening; start it from a full sync. Only the
-- first request counts, so a client can't force repeated full syncs.
function PlayerService.requestData(player: Player)
	if player.Parent ~= Players or lastSent[player] ~= nil then
		return
	end

	lastSent[player] = {}
	markDirty(player)
end

function PlayerService.init()
	network = Network.server("Player", PlayerService, {
		requestData = {}, -- client -> server
		onDataDelta = { Network.Packet.BufferLong }, -- server -> client
	})

	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(onPlayerRemoving)

	-- Players who joined before this feature initialized (common in Studio).
	for _, player in Players:GetPlayers() do
		task.spawn(onPlayerAdded, player)
	end
end

return PlayerService
