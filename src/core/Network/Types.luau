--!strict

--[=[
	Types shared by the Network modules. Only types are exported; requiring
	this module at runtime returns nil.
]=]

-- Ordered list of Packet data types, one per argument.
export type MethodSchema = { string }
export type Schemas = { [string]: MethodSchema }

export type MethodHandler = (player: Player, ...any) -> ...any

-- One encoded message: a bare buffer, or a buffer plus the Instances it
-- references (false stands in for a nil Instance so the array has no gaps).
export type BatchEntry = buffer | {
	buf: buffer,
	inst: { Instance | false },
}

-- What the server publishes to clients for each registered service.
export type ServiceManifest = {
	id: number,
	methods: { [string]: number },
	schemas: Schemas,
}

export type Manifest = { [string]: ServiceManifest }

export type ServerNetwork = {
	id: number,
	name: string,
	service: { [string]: any },
	schemas: Schemas,
	methodIds: { [string]: number },
	methodNames: { string },
	fireClient: (self: ServerNetwork, player: Player, methodName: string, ...any) -> (),
	fireClientImmediate: (self: ServerNetwork, player: Player, methodName: string, ...any) -> (),
	fireClientUnreliable: (self: ServerNetwork, player: Player, methodName: string, ...any) -> (),
	fireAllClients: (self: ServerNetwork, methodName: string, ...any) -> (),
	fireAllClientsImmediate: (self: ServerNetwork, methodName: string, ...any) -> (),
	fireAllClientsUnreliable: (self: ServerNetwork, methodName: string, ...any) -> (),
}

export type ClientNetwork = {
	id: number,
	name: string,
	schemas: Schemas,
	methodIds: { [string]: number },
	methodNames: { string },
	callbacks: { [number]: { (...any) -> () } },
	fire: (self: ClientNetwork, methodName: string, ...any) -> (),
	fireUnreliable: (self: ClientNetwork, methodName: string, ...any) -> (),
	fireImmediate: (self: ClientNetwork, methodName: string, ...any) -> (),
	invoke: (self: ClientNetwork, methodName: string, ...any) -> ...any,
	on: (self: ClientNetwork, methodName: string, callback: (...any) -> ()) -> () -> (),
}

return nil
