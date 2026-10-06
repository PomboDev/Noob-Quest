--[=[
	Everything CI should run, in order:

	1. regenerate the project files and sourcemap (luau-lsp reads the sourcemap)
	2. formatting with StyLua (`pesde run format` fixes it)
	3. lints with selene; the first run generates its Roblox standard library
	4. type checking of src/ with luau-lsp, against the Roblox API definitions
	   (downloaded once into DEFINITIONS)
	5. the unit tests
]=]

local fs = require("@lune/fs")
local net = require("@lune/net")

local builder = require("./builder")

local SELENE_STD = "roblox.yml"
local DEFINITIONS = "globalTypes.d.luau"
-- The documented /type-definitions/ path redirects here, and Lune can't follow
-- that redirect.
local DEFINITIONS_URL = "https://luau-lsp.pages.dev/globalTypes.None.d.luau"

local function step(label: string, fn: () -> ())
	print(`▶ {label}`)
	fn()
end

step("Project files", builder.generate)

step("Formatting", function()
	builder.run("stylua", { "--check", table.unpack(builder.FORMAT_PATHS) })
end)

step("Lints", function()
	if not fs.isFile(SELENE_STD) then
		builder.run("selene", { "generate-roblox-std" })
	end
	builder.run("selene", { builder.SRC_DIR })
end)

step("Types", function()
	if not fs.isFile(DEFINITIONS) then
		local response = net.request(DEFINITIONS_URL)
		if not response.ok then
			error(`Failed to download {DEFINITIONS_URL}: {response.statusCode} {response.statusMessage}`, 0)
		end
		fs.writeFile(DEFINITIONS, response.body)
	end

	builder.run("luau-lsp", {
		"analyze",
		`--definitions=@roblox={DEFINITIONS}`,
		`--sourcemap={builder.SOURCEMAP}`,
		-- Installed packages are typed (and linted) by their authors, not us.
		"--ignore=**/roblox_packages/**",
		"--ignore=**/roblox_server_packages/**",
		builder.SRC_DIR,
	})
end)

step("Tests", function()
	builder.run("lune", { "run", "tools/test" })
end)

print("✅ All checks passed")
