--[=[
	Shared build steps for the pesde scripts in this folder.

	Rojo project files are generated from the layout of `src/`:

	- `*Server.luau` modules go to ServerScriptService, everything else to
	  ReplicatedStorage.Source (folders mirror `src/`, renamed to PascalCase)
	- `Server`, `Client`, `Utils` and `Types` files take their folder's name as
	  a prefix: `combat/Server.luau` becomes `CombatServer`
	- a folder with an `init.luau` becomes that module and Rojo maps the rest of
	  the folder as its children, keeping their file names (no prefixes). Files
	  ending in `Server` inside it are carved out into ServerScriptService, at
	  the same path, so they never replicate to clients
	- two files that map to the same instance are an error, and so is a module
	  that shares its name with a sibling folder (`Foo.luau` next to `foo/`):
	  luau-lsp resolves `require("Foo")` to the folder, so use `foo/init.luau`
	- `src/startup/` holds the two entry scripts and is mapped explicitly

	`default.project.json` points at `src/` and only feeds the sourcemap
	(luau-lsp + darklua's require conversion). `build.project.json` points at
	darklua's output in `out/` and is what Rojo serves and builds.

	Both map ReplicatedStorage.Assets to `assets/shared/`, the prefabs pulled
	from the asset place. `assets.project.json` maps only that folder: it is
	what `rojo syncback` writes through, so syncback never touches code. Its
	root is the Assets folder itself, matching the model file syncback reads.
]=]

local fs = require("@lune/fs")
local process = require("@lune/process")
local serde = require("@lune/serde")

local SRC_DIR = "src"
local OUT_DIR = "out"
local STARTUP_DIR = "startup"
local DARKLUA_CONFIG = ".darklua.json"
local SOURCE_PROJECT = "default.project.json"
local BUILD_PROJECT = "build.project.json"
local SOURCEMAP = "sourcemap.json"
local ASSETS_DIR = "assets/shared"
local ASSETS_PROJECT = "assets.project.json"
-- Everything StyLua formats and checks.
local FORMAT_PATHS = { "src", "tools", "tests" }

-- File names prefixed with their folder's name, e.g. combat/Server.luau -> CombatServer.
local PREFIXED_NAMES = { server = true, client = true, utils = true, types = true }

type Entry = {
	path: string, -- relative to the source root, e.g. "core/Network/Packet.luau"
	folders: { string }, -- instance names of the containing folders
	name: string, -- instance name of the module
	isInit: boolean, -- an init.luau: the module is its folder
	isServer: boolean,
}

type Node = { [string]: any }

local function run(program: string, args: { string }, env: { [string]: string }?)
	local result = process.exec(program, args, { stdio = "forward", env = env })
	if not result.ok then
		error(`'{program} {table.concat(args, " ")}' failed with exit code {result.code}`, 0)
	end
end

-- Sorted paths of every .luau file under `root`, relative to it. Dotfiles
-- (editor swap files and the like) are ignored.
local function listFiles(root: string): { string }
	local files = {}

	local function walk(relative: string)
		local directory = if relative == "" then root else `{root}/{relative}`
		for _, name in fs.readDir(directory) do
			if string.sub(name, 1, 1) == "." then
				continue
			end

			local path = if relative == "" then name else `{relative}/{name}`
			if fs.isDir(`{root}/{path}`) then
				walk(path)
			elseif string.match(name, "%.luau$") then
				table.insert(files, path)
			end
		end
	end

	walk("")
	table.sort(files)
	return files
end

local function toPascalCase(name: string): string
	if string.lower(name) == "ui" then
		return "UI"
	end
	return (string.gsub(name, "^%l", string.upper))
end

local function describe(path: string): Entry
	local parts = string.split(path, "/")
	local fileName = string.gsub(table.remove(parts) :: string, "%.luau$", "")

	local folders = {}
	for _, part in parts do
		table.insert(folders, toPascalCase(part))
	end

	local isInit = fileName == "init"
	local name = fileName
	if isInit then
		if #folders == 0 then
			error(`{SRC_DIR}/{path}: init.luau must be inside a folder`, 0)
		end
		name = table.remove(folders) :: string
	elseif PREFIXED_NAMES[string.lower(fileName)] then
		name = (folders[#folders] or "") .. toPascalCase(fileName)
	end

	return {
		path = path,
		folders = folders,
		name = name,
		isInit = isInit,
		isServer = string.match(name, "Server$") ~= nil,
	}
end

local function collectEntries(): { Entry }
	local entries = {}
	for _, path in listFiles(SRC_DIR) do
		if not string.match(path, `^{STARTUP_DIR}/`) then
			table.insert(entries, describe(path))
		end
	end
	return entries
end

-- The folder a path lives in, e.g. "core/Network/Codec.luau" -> "core/Network".
local function directoryOf(path: string): string?
	return string.match(path, "^(.*)/[^/]+$")
end

local function render(entries: { Entry }, root: string): Node
	local shared: Node = { ["$className"] = "Folder" }
	local server: Node = {}
	local ignored: { string } = {}

	local initFolders: { [string]: Entry } = {}
	for _, entry in entries do
		if entry.isInit then
			initFolders[directoryOf(entry.path) :: string] = entry
		end
	end

	-- The nearest init folder above `path`: Rojo maps everything inside it.
	local function enclosingInit(path: string): Entry?
		local directory = directoryOf(path)
		while directory do
			local init = initFolders[directory]
			if init then
				return init
			end
			directory = directoryOf(directory)
		end
		return nil
	end

	local function place(entry: Entry)
		local node = if entry.isServer then server else shared
		local location = if entry.isServer then "ServerScriptService" else "ReplicatedStorage.Source"
		for _, folder in entry.folders do
			local child = node[folder]
			if child == nil then
				child = { ["$className"] = "Folder" }
				node[folder] = child
			elseif child["$path"] then
				error(`{child["$path"]} and the folder of {root}/{entry.path} both map to {location}.{folder}`, 0)
			end
			node = child
			location ..= "." .. folder
		end

		local module = node[entry.name]
		if module and module["$path"] then
			error(`{module["$path"]} and {root}/{entry.path} both map to {location}.{entry.name}`, 0)
		elseif module then
			error(`{root}/{entry.path} shares its name with a folder: use {entry.name}/init.luau instead`, 0)
		end

		local target = if entry.isInit then directoryOf(entry.path) :: string else entry.path
		node[entry.name] = { ["$path"] = `{root}/{target}` }
	end

	for _, entry in entries do
		local enclosing = enclosingInit(if entry.isInit then directoryOf(entry.path) :: string else entry.path)
		if enclosing == nil then
			place(entry)
		elseif entry.isServer and not enclosing.isServer then
			-- Mapped by Rojo with the rest of the init folder unless ignored,
			-- which would replicate it to every client.
			if entry.isInit then
				error(`{root}/{entry.path}: a server init folder can't sit inside {enclosing.path}`, 0)
			end
			table.insert(ignored, `{root}/{entry.path}`)
			place(entry)
		end
	end

	shared.StartUp = {
		["$className"] = "Folder",
		Client = { ["$path"] = `{root}/{STARTUP_DIR}/Client.client.luau` },
	}
	server.StartUp = {
		["$className"] = "Folder",
		Server = { ["$path"] = `{root}/{STARTUP_DIR}/Server.server.luau` },
	}

	return {
		name = "game",
		emitLegacyScripts = false,
		globIgnorePaths = if #ignored > 0 then ignored else nil,
		tree = {
			["$className"] = "DataModel",
			ReplicatedStorage = {
				-- darklua never processes assets, so this is the same under any root.
				Assets = { ["$path"] = ASSETS_DIR },
				Packages = { ["$path"] = "roblox_packages" },
				Source = shared,
			},
			ServerScriptService = server,
			ServerStorage = {
				Packages = { ["$path"] = "roblox_server_packages" },
			},
		},
	}
end

-- The project syncback writes through. The input is a model file whose root is
-- the Assets folder, so that folder is the root of the project too.
local function renderAssets(): Node
	return {
		name = "assets",
		tree = { ["$path"] = ASSETS_DIR },
	}
end

local function writeJson(path: string, value: any)
	fs.writeFile(path, serde.encode("json", value, true) .. "\n")
end

-- Writes default.project.json and regenerates the sourcemap darklua and
-- luau-lsp read.
local function generateSource()
	writeJson(SOURCE_PROJECT, render(collectEntries(), SRC_DIR))
	run("rojo", { "sourcemap", SOURCE_PROJECT, "--output", SOURCEMAP })
end

-- Writes build.project.json, which points Rojo at darklua's output.
local function generateBuild()
	writeJson(BUILD_PROJECT, render(collectEntries(), OUT_DIR))
end

-- Writes assets.project.json. Creates the assets folder on a fresh clone, so
-- every project's Assets $path exists.
local function generateAssets()
	if not fs.isDir(ASSETS_DIR) then
		fs.writeDir(ASSETS_DIR)
	end
	writeJson(ASSETS_PROJECT, renderAssets())
end

-- Writes every project file and regenerates the sourcemap.
local function generate()
	generateAssets()
	generateSource()
	generateBuild()
end

-- Runs darklua once over src/, writing into out/.
local function processSources(dev: boolean)
	run("darklua", { "process", "--config", DARKLUA_CONFIG, SRC_DIR, OUT_DIR }, { ROBLOX_DEV = tostring(dev) })
end

-- Clean build of `src/` into `out/`.
local function compile(dev: boolean)
	generate()

	if fs.isDir(OUT_DIR) then
		fs.removeDir(OUT_DIR)
	end
	fs.writeDir(OUT_DIR)

	processSources(dev)
end

-- Removes the directories under `directory` that no longer hold anything.
local function removeEmptyDirectories(directory: string)
	for _, name in fs.readDir(directory) do
		local path = `{directory}/{name}`
		if fs.isDir(path) then
			removeEmptyDirectories(path)
			if #fs.readDir(path) == 0 then
				fs.removeDir(path)
			end
		end
	end
end

-- Deletes compiled files (and the folders they leave empty) whose source was
-- renamed or removed.
local function pruneOut()
	if not fs.isDir(OUT_DIR) then
		return
	end

	local sources = {}
	for _, path in listFiles(SRC_DIR) do
		sources[path] = true
	end

	for _, path in listFiles(OUT_DIR) do
		if not sources[path] then
			fs.removeFile(`{OUT_DIR}/{path}`)
		end
	end

	removeEmptyDirectories(OUT_DIR)
end

-- A cheap signature of the source layout, for detecting added/removed/renamed files.
local function snapshot(): string
	return table.concat(listFiles(SRC_DIR), "\n")
end

return {
	SRC_DIR = SRC_DIR,
	OUT_DIR = OUT_DIR,
	DARKLUA_CONFIG = DARKLUA_CONFIG,
	BUILD_PROJECT = BUILD_PROJECT,
	SOURCEMAP = SOURCEMAP,
	ASSETS_DIR = ASSETS_DIR,
	ASSETS_PROJECT = ASSETS_PROJECT,
	FORMAT_PATHS = FORMAT_PATHS,

	run = run,
	generate = generate,
	generateAssets = generateAssets,
	generateSource = generateSource,
	generateBuild = generateBuild,
	processSources = processSources,
	compile = compile,
	pruneOut = pruneOut,
	snapshot = snapshot,

	-- Exposed for tests.
	describe = describe,
	render = render,
	renderAssets = renderAssets,
}
