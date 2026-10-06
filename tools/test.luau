--[=[
	Runs every `tests/*.spec.luau` with Lune. A spec returns a table of named
	test functions, and a test fails by erroring. Exits with code 1 if any
	test fails.
]=]

local fs = require("@lune/fs")
local process = require("@lune/process")

local TESTS_DIR = "tests"

local files = {}
for _, name in fs.readDir(TESTS_DIR) do
	if string.match(name, "%.spec%.luau$") then
		table.insert(files, name)
	end
end
table.sort(files)

local passed = 0
local failed = 0

for _, file in files do
	local specName = string.gsub(file, "%.spec%.luau$", "")
	local spec: { [string]: () -> () } = require(`../{TESTS_DIR}/{string.gsub(file, "%.luau$", "")}`)

	local names = {}
	for name in spec do
		table.insert(names, name)
	end
	table.sort(names)

	for _, name in names do
		local ok, err = xpcall(spec[name], debug.traceback)
		if ok then
			passed += 1
			print(`  ✓ {specName} › {name}`)
		else
			failed += 1
			print(`  ✗ {specName} › {name}\n{err}`)
		end
	end
end

print(`{passed} passed, {failed} failed`)
if failed > 0 then
	process.exit(1)
end
