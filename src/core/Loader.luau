--!strict

--[=[
	Discovers and boots feature modules.

	Every direct child of a feature folder whose name ends with the given suffix
	("Client" or "Server") is required. Deeper modules (e.g. a feature's
	`modules/` folder) are never auto-loaded.

	Lifecycle, in module-name order:
	1. init()  - called synchronously for every feature. Wire up state, networks
	             and connections here. Must not yield.
	2. start() - spawned once every init() has finished. May yield, and may
	             safely use other features.

	A feature whose init() errors is logged and its start() is skipped.
]=]

local Log = require("@Core/Log")

export type Feature = {
	init: (() -> ())?,
	start: (() -> ())?,
}

type Entry = {
	name: string,
	feature: Feature,
}

local function collect(root: Instance, suffix: string): { Entry }
	local pattern = `{suffix}$`
	local entries: { Entry } = {}

	for _, folder in root:GetChildren() do
		for _, child in folder:GetChildren() do
			if not child:IsA("ModuleScript") or not string.match(child.Name, pattern) then
				continue
			end

			local ok, result = pcall(require, child)
			if ok then
				table.insert(entries, { name = child.Name, feature = result :: Feature })
			else
				Log.warn(`Failed to require {child:GetFullName()}: {result}`)
			end
		end
	end

	table.sort(entries, function(a: Entry, b: Entry)
		return a.name < b.name
	end)

	return entries
end

local function traceback(message: any): string
	return debug.traceback(tostring(message), 2)
end

local function load(root: Instance, suffix: "Client" | "Server")
	local entries = collect(root, suffix)
	local initialized: { Entry } = {}

	for _, entry in entries do
		local init = entry.feature.init
		if init then
			-- `:: any`: strict mode has no type for the error of a call that returns nothing
			local ok, err = xpcall(init :: any, traceback)
			if not ok then
				Log.warn(`{entry.name}.init failed, skipping start:\n{err}`)
				continue
			end
		end
		table.insert(initialized, entry)
	end

	for _, entry in initialized do
		local start = entry.feature.start
		if start then
			task.spawn(start)
		end
	end

	Log.debug(`Started {#initialized}/{#entries} {suffix} features`)
end

return {
	load = load,
}
