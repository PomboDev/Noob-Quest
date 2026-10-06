--!strict

--[=[
	Client half of Network (use it through `Network.client`).

	Requiring it waits for the server's remotes. Each service handle encodes
	outgoing calls with the schemas the server published, batches them once
	per frame, and dispatches incoming messages to the callbacks bound with
	`on` (or auto-bound from a controller).
]=]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Codec = require("@Core/Network/Codec")
local Log = require("@Core/Log")
local Types = require("@Core/Network/Types")

type BatchEntry = Types.BatchEntry
type ClientNetwork = Types.ClientNetwork
type Manifest = Types.Manifest
type ServiceManifest = Types.ServiceManifest

local REMOTE_TIMEOUT = 10
local MANIFEST_TIMEOUT = 5
local MANIFEST_RETRY_INTERVAL = 0.5

local function waitForRemote(parent: Instance, name: string): Instance
	local instance = parent:WaitForChild(name, REMOTE_TIMEOUT)
	if not instance then
		error(`[Network] Timed out waiting for {parent:GetFullName()}.{name}`)
	end
	return instance
end

local folder = waitForRemote(ReplicatedStorage, Codec.FOLDER)
local reliableEvent = waitForRemote(folder, Codec.RELIABLE) :: RemoteEvent
local unreliableEvent = waitForRemote(folder, Codec.UNRELIABLE) :: UnreliableRemoteEvent
local remoteFunction = waitForRemote(folder, Codec.FUNCTION) :: RemoteFunction

local manifest: Manifest = {}
local networksById: { [number]: ClientNetwork } = {}

local reliableQueue: { BatchEntry } = {}
local unreliableQueue: { BatchEntry } = {}
local flushScheduled = false

-- // Outgoing //

local function flush()
	flushScheduled = false

	if #reliableQueue > 0 then
		reliableEvent:FireServer(reliableQueue)
		table.clear(reliableQueue)
	end

	if #unreliableQueue > 0 then
		for _, chunk in Codec.chunk(unreliableQueue) do
			unreliableEvent:FireServer(chunk)
		end
		table.clear(unreliableQueue)
	end
end

local function enqueue(queue: { BatchEntry }, entry: BatchEntry)
	table.insert(queue, entry)

	if not flushScheduled then
		flushScheduled = true
		RunService.Heartbeat:Once(flush)
	end
end

local function encode(self: ClientNetwork, methodName: string, ...: any): BatchEntry?
	local methodId = self.methodIds[methodName]
	if not methodId then
		Log.warn(`Unknown method '{methodName}' in service '{self.name}'`)
		return nil
	end
	return Codec.encode(self.id, methodId, self.schemas[methodName], ...)
end

local function fire(self: ClientNetwork, methodName: string, ...: any)
	local entry = encode(self, methodName, ...)
	if entry then
		enqueue(reliableQueue, entry)
	end
end

local function fireUnreliable(self: ClientNetwork, methodName: string, ...: any)
	local entry = encode(self, methodName, ...)
	if entry then
		enqueue(unreliableQueue, entry)
	end
end

local function fireImmediate(self: ClientNetwork, methodName: string, ...: any)
	local entry = encode(self, methodName, ...)
	if entry then
		reliableEvent:FireServer({ entry })
	end
end

local function invoke(self: ClientNetwork, methodName: string, ...: any): ...any
	local entry = encode(self, methodName, ...)
	if entry then
		return remoteFunction:InvokeServer(entry)
	end
	return nil
end

local function on(self: ClientNetwork, methodName: string, callback: (...any) -> ()): () -> ()
	local methodId = self.methodIds[methodName]
	if not methodId then
		Log.warn(`Cannot bind to unknown method '{methodName}' in service '{self.name}'`)
		return function() end
	end

	-- Lists are replaced rather than edited, so a callback that connects or
	-- disconnects during a dispatch doesn't shift the list being iterated.
	local callbacks = table.clone(self.callbacks[methodId] or {})
	table.insert(callbacks, callback)
	self.callbacks[methodId] = callbacks

	return function()
		local current = self.callbacks[methodId]
		local index = current and table.find(current, callback)
		if current and index then
			local remaining = table.clone(current)
			table.remove(remaining, index)
			self.callbacks[methodId] = remaining
		end
	end
end

-- // Incoming //

local function onEvent(batch: { BatchEntry })
	for _, entry in batch do
		local buf, inst = Codec.unpack(entry)
		if not buf then
			continue
		end

		local network = networksById[buffer.readu8(buf, 0)]
		if not network then
			continue
		end

		local methodId = buffer.readu8(buf, 1)
		local callbacks = network.callbacks[methodId]
		if not callbacks or #callbacks == 0 then
			continue
		end

		local schema = network.schemas[network.methodNames[methodId]]
		local args = Codec.decode(schema, buf, inst)
		local count = #schema
		for _, callback in callbacks do
			task.spawn(callback, table.unpack(args, 1, count))
		end
	end
end

reliableEvent.OnClientEvent:Connect(onEvent)
unreliableEvent.OnClientEvent:Connect(onEvent)

-- // Registration //

local function refreshManifest()
	local ok, result = pcall(remoteFunction.InvokeServer, remoteFunction, Codec.REGISTRY_REQUEST)
	if ok and type(result) == "table" then
		manifest = result
	else
		Log.warn(`Failed to fetch the service registry: {result}`)
	end
end

-- The server may still be registering services when the client boots, so
-- retry for a short while before giving up.
local function waitForService(name: string): ServiceManifest
	local deadline = os.clock() + MANIFEST_TIMEOUT
	if not manifest[name] then
		refreshManifest()
	end

	while not manifest[name] and os.clock() < deadline do
		task.wait(MANIFEST_RETRY_INTERVAL)
		refreshManifest()
	end

	local service = manifest[name]
	if not service then
		error(`[Network] Service '{name}' is not registered on the server`)
	end
	return service
end

local function createNetwork(name: string, service: ServiceManifest): ClientNetwork
	local methodNames: { string } = {}
	for methodName, methodId in service.methods do
		methodNames[methodId] = methodName
	end

	local network: ClientNetwork = {
		id = service.id,
		name = name,
		schemas = service.schemas,
		methodIds = service.methods,
		methodNames = methodNames,
		callbacks = {},
		fire = fire,
		fireUnreliable = fireUnreliable,
		fireImmediate = fireImmediate,
		invoke = invoke,
		on = on,
	}

	networksById[service.id] = network
	return network
end

local NetworkClient = {}

--[=[
	Connects to a server service by name. Yields until the server has
	registered it.

	If `controller` is given, any of its functions named after a method in
	the service's schemas are bound as receivers for that method. Name
	server -> client methods `on*` (e.g. `onDataDelta`) so a controller's
	other functions never collide with client -> server method names.
]=]
function NetworkClient.new(name: string, controller: { [string]: any }?): ClientNetwork
	local service = waitForService(name)

	-- Several controllers may talk to the same service; they share one handle.
	local network = networksById[service.id] or createNetwork(name, service)

	if controller then
		for methodName in service.methods do
			local callback = controller[methodName]
			if type(callback) == "function" then
				network:on(methodName, callback)
			end
		end
	end

	return network
end

return NetworkClient
