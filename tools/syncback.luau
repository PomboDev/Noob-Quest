--[=[
    Pulls the Assets folder out of a saved model file into assets/shared/.

    Usage: pesde run syncback [-- [model] [rojo flags]]

    The model defaults to assets/places/Assets.rbxm. In the asset place, right-click
    the Assets folder in ReplicatedStorage and choose Save to File: the Studio
    MCP can't save files. Flags such as `--dry-run`, `--list` and `-y` go to
    `rojo syncback`, which asks before writing unless given `-y`.

    Syncback writes through assets.project.json, which maps only assets/shared/,
    so code is never touched. Before it runs the model is checked, because two
    mistakes would do damage:

    - anything but a single Folder named Assets at the root (a whole place, say)
      is refused: syncback would treat every prefab as deleted and empty
      assets/shared/
    - scripts inside prefabs would skip darklua, selene and luau-lsp
]=]

local fs = require("@lune/fs")
local process = require("@lune/process")
local roblox = require("@lune/roblox")

local builder = require("./builder")

local DEFAULT_MODEL = "assets/places/Assets.rbxm"

local model = DEFAULT_MODEL
local flags = {}
local modelGiven = false
local dryRun = false
for _, argument in process.args do
	if string.sub(argument, 1, 1) == "-" or modelGiven then
		table.insert(flags, argument)
		dryRun = dryRun or argument == "--dry-run"
	else
		model = argument
		modelGiven = true
	end
end

if not fs.isFile(model) then
	error(`{model} not found: right-click the Assets folder in Studio, Save to File, and save it there`, 0)
end

local roots = roblox.deserializeModel(fs.readFile(model))
local assets = roots[1]
if #roots ~= 1 or assets == nil or not assets:IsA("Folder") or assets.Name ~= "Assets" then
	error(
		`{model} must hold exactly one Folder named Assets (save the folder, not the place): syncback would delete everything in {builder.ASSETS_DIR}`,
		0
	)
end

local scripts = {}
for _, descendant in assets:GetDescendants() do
	if descendant:IsA("LuaSourceContainer") then
		table.insert(scripts, descendant:GetFullName())
	end
end
if #scripts > 0 then
	error(`Prefabs must not contain scripts, move the code into src/:\n  {table.concat(scripts, "\n  ")}`, 0)
end

builder.generateAssets()

local arguments = { "syncback", builder.ASSETS_PROJECT, "--input", model }
for _, flag in flags do
	table.insert(arguments, flag)
end
builder.run("rojo", arguments)

-- Keep the generated project canonical, whatever syncback did to it.
builder.generateAssets()
print(if dryRun then "✅ Dry run finished, nothing written" else `✅ Synced {model} into {builder.ASSETS_DIR}/`)
