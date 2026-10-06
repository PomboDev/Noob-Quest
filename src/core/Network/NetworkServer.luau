--!strict

--[=[
	Server half of Network (use it through `Network.server`).

	Owns the remotes and the manifest of registered services that clients
	fetch. Outgoing messages are queued per player and flushed once per
	frame; incoming ones are decoded defensively and dispatched to the
	service's handler with the calling Player first.
]=]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Codec = require("@Core/Network/Codec")
local Log = require("@Core/Log")
local Types = require("@Core/Network/Types")

type BatchEntry = Types.BatchEntry
type Manifest = Types.Manifest
type MethodHandler = Types.MethodHandler
type Schemas = Types.Schemas
type ServerNetwork = Types.ServerNetwork

local MAX_IDS = 255

local function getOrCreate(parent: Instance, className: string, name: string): Instance
	local existing = parent:FindFirstChild(name)
	if existing then
		return existing
	end

	local instance = Instance.new(className)
	instance.Name = name
	instance.Parent = parent
	return instance
end

local folder = getOrCreate(ReplicatedStorage, "Folder", Codec.FOLDER)
local reliableEvent = getOrCreate(folder, "RemoteEvent", Codec.RELIABLE) :: RemoteEvent
local unreliableEvent = getOrCreate(folder, "UnreliableRemoteEvent", Codec.UNRELIABLE) :: UnreliableRemoteEvent
local remoteFunction = getOrCreate(folder, "RemoteFunction", Codec.FUNCTION) :: RemoteFunction

local manifest: Manifest = {}
local networksById: { [number]: ServerNetwork } = {}
local nextServiceId = 0

local reliableQueue: { [Player]: { BatchEntry } } = {}
local unreliableQueue: { [Player]: { BatchEntry } } = {}
local flushScheduled = false

-- // Outgoing //

local function flush()
	flushScheduled = false

	for player, batch in reliableQueue do
		if player.Parent then
			reliableEvent:FireClient(player, batch)
		end
	end

	for player, batch in unreliableQueue do
		if player.Parent then
			for _, chunk in Codec.chunk(batch) do
				unreliableEvent:FireClient(player, chunk)
			end
		end
	end

	table.clear(reliableQueue)
	table.clear(unreliableQueue)
end

local function enqueue(queue: { [Player]: { BatchEntry } }, player: Player, entry: BatchEntry)
	local batch = queue[player]
	if batch then
		table.insert(batch, entry)
	else
		queue[player] = { entry }
	end

	if not flushScheduled then
		flushScheduled = true
		RunService.Heartbeat:Once(flush)
	end
end

local function encode(self: ServerNetwork, methodName: string, ...: any): BatchEntry?
	local methodId = self.methodIds[methodName]
	if not methodId then
		Log.warn(`Unknown method '{methodName}' in service '{self.name}'`)
		return nil
	end
	return Codec.encode(self.id, methodId, self.schemas[methodName], ...)
end

-- Bot proxies and other non-Player stand-ins are silently skipped.
local function isPlayer(player: any): boolean
	return typeof(player) == "Instance" and (player :: Instance):IsA("Player")
end

local function fireClient(self: ServerNetwork, player: Player, methodName: string, ...: any)
	if not isPlayer(player) then
		return
	end
	local entry = encode(self, methodName, ...)
	if entry then
		enqueue(reliableQueue, player, entry)
	end
end

local function fireClientUnreliable(self: ServerNetwork, player: Player, methodName: string, ...: any)
	if not isPlayer(player) then
		return
	end
	local entry = encode(self, methodName, ...)
	if entry then
		enqueue(unreliableQueue, player, entry)
	end
end

local function fireClientImmediate(self: ServerNetwork, player: Player, methodName: string, ...: any)
	if not isPlayer(player) then
		return
	end
	local entry = encode(self, methodName, ...)
	if entry then
		reliableEvent:FireClient(player, { entry })
	end
end

local function fireAllClients(self: ServerNetwork, methodName: string, ...: any)
	local entry = encode(self, methodName, ...)
	if entry then
		for _, player in Players:GetPlayers() do
			enqueue(reliableQueue, player, entry)
		end
	end
end

local function fireAllClientsUnreliable(self: ServerNetwork, methodName: string, ...: any)
	local entry = encode(self, methodName, ...)
	if entry then
		for _, player in Players:GetPlayers() do
			enqueue(unreliableQueue, player, entry)
		end
	end
end

local function fireAllClientsImmediate(self: ServerNetwork, methodName: string, ...: any)
	local entry = encode(self, methodName, ...)
	if entry then
		reliableEvent:FireAllClients({ entry })
	end
end

-- // Incoming //

-- Resolves an incoming message to its handler and decoded arguments.
-- Everything here is client-controlled, so unknown ids and malformed
-- payloads are dropped instead of raising.
local function resolve(buf: buffer, inst: { any }?): (MethodHandler?, { any }, number)
	local network = networksById[buffer.readu8(buf, 0)]
	if not network then
		return nil, {}, 0
	end

	local methodName: string? = network.methodNames[buffer.readu8(buf, 1)]
	if not methodName then
		return nil, {}, 0
	end

	local handler = network.service[methodName]
	if type(handler) ~= "function" then
		return nil, {}, 0
	end

	local schema = network.schemas[methodName]
	local ok, args = pcall(Codec.decode, schema, buf, inst)
	if not ok then
		Log.debug(`Dropped malformed '{network.name}.{methodName}' payload: {args}`)
		return nil, {}, 0
	end

	return handler, args, #schema
end

local function onEvent(player: Player, batch: any)
	if type(batch) ~= "table" then
		return
	end

	for _, entry in batch do
		local buf, inst = Codec.unpack(entry)
		if not buf then
			continue
		end

		local handler, args, count = resolve(buf, inst)
		if handler then
			task.spawn(handler, player, table.unpack(args, 1, count))
		end
	end
end

local function onInvoke(player: Player, request: any): ...any
	if request == Codec.REGISTRY_REQUEST then
		return manifest
	end

	local buf, inst = Codec.unpack(request)
	if not buf then
		return nil
	end

	local handler, args, count = resolve(buf, inst)
	if handler then
		return handler(player, table.unpack(args, 1, count))
	end
	return nil
end

reliableEvent.OnServerEvent:Connect(onEvent)
unreliableEvent.OnServerEvent:Connect(onEvent)
remoteFunction.OnServerInvoke = onInvoke

-- // Registration //

local NetworkServer = {}

--[=[
	Registers a service. Only methods listed in `schemas` exist on the wire:

	- a schema key that is also a function on `service` is callable by clients
	  (the handler receives the calling Player first)
	- every schema key can be sent to clients with the fire* functions
]=]
function NetworkServer.new(name: string, service: { [string]: any }, schemas: Schemas): ServerNetwork
	assert(manifest[name] == nil, `[Network] Service '{name}' is already registered`)
	assert(nextServiceId < MAX_IDS, `[Network] Cannot register more than {MAX_IDS} services`)

	local methodNames: { string } = {}
	for methodName, schema in schemas do
		Codec.validateSchema(schema, `[Network] {name}.{methodName}`)
		table.insert(methodNames, methodName)
	end
	assert(#methodNames <= MAX_IDS, `[Network] Service '{name}' has more than {MAX_IDS} methods`)
	table.sort(methodNames)

	local methodIds: { [string]: number } = {}
	for methodId, methodName in methodNames do
		methodIds[methodName] = methodId
	end

	nextServiceId += 1

	local network: ServerNetwork = {
		id = nextServiceId,
		name = name,
		service = service,
		schemas = schemas,
		methodIds = methodIds,
		methodNames = methodNames,
		fireClient = fireClient,
		fireClientImmediate = fireClientImmediate,
		fireClientUnreliable = fireClientUnreliable,
		fireAllClients = fireAllClients,
		fireAllClientsImmediate = fireAllClientsImmediate,
		fireAllClientsUnreliable = fireAllClientsUnreliable,
	}

	networksById[network.id] = network
	manifest[name] = {
		id = network.id,
		methods = methodIds,
		schemas = schemas,
	}

	return network
end

return NetworkServer
