--[=[
	Development loop:

	1. clean dev build of src/ into out/
	2. `darklua process --watch` recompiles edited files
	3. `rojo serve` syncs out/ into Studio
	4. every POLL_INTERVAL the src/ layout is compared; when files are added,
	   removed or renamed, the generated files are brought up to date (see
	   regenerate) and darklua restarts on the new sourcemap
]=]

local builder = require("./builder")
local process = require("@lune/process")
local task = require("@lune/task")

local POLL_INTERVAL = 0.5
local RETRY_INTERVAL = 2
local DEV_ENV = { ROBLOX_DEV = "true" }

-- Prints a child stream line by line with a prefix. Each stream gets its own
-- reader so no pipe is ever left full (which would stall the child).
local function pipe(label: string, stream: any)
	task.spawn(function()
		local pending = ""
		while true do
			local chunk = stream:read()
			if chunk == nil then
				break
			end

			pending ..= chunk
			while true do
				local line, rest = string.match(pending, "^([^\n]*)\n(.*)$")
				if line == nil then
					break
				end
				if line ~= "" then
					print(`[{label}] {line}`)
				end
				pending = rest
			end
		end

		if pending ~= "" then
			print(`[{label}] {pending}`)
		end
	end)
end

local function spawn(label: string, program: string, args: { string }, env: { [string]: string }?)
	local child = process.create(program, args, { env = env })
	pipe(label, child.stdout)
	pipe(label, child.stderr)
	return child
end

-- kill() can error if the child already exited on its own.
local function stop(child: any)
	pcall(child.kill, child)
end

local function startDarklua()
	return spawn("Darklua", "darklua", {
		"process",
		"--config",
		builder.DARKLUA_CONFIG,
		"--watch",
		builder.SRC_DIR,
		builder.OUT_DIR,
	}, DEV_ENV)
end

print("🚀 Starting development environment...")
builder.compile(true)

local darklua = startDarklua()
local rojo = spawn("Rojo", "rojo", { "serve", builder.BUILD_PROJECT })

-- Rojo reloads build.project.json by itself, but if the file points at an
-- out/ file darklua hasn't written yet it fails to load the project and never
-- recovers. So the project is written last: after darklua has processed the
-- new layout, and before stale output (which nothing references any more) is
-- pruned. An invalid layout fails in generateSource, before anything stops.
local function regenerate()
	builder.generateSource()

	stop(darklua)
	local ok, err = pcall(builder.processSources, true)
	darklua = startDarklua()
	if not ok then
		error(err, 0)
	end

	builder.generateBuild()
	builder.pruneOut()
end

-- Without Rojo there is nothing to sync to, so stop the whole loop.
task.spawn(function()
	local status = rojo:status()
	print(`[Rojo] exited with code {status.code}`)
	stop(darklua)
	process.exit(status.code)
end)

print("👀 Watching for changes...")

local layout = builder.snapshot()
local retryAt = 0
local lastError: string? = nil

while true do
	task.wait(POLL_INTERVAL)

	local current = builder.snapshot()
	if current ~= layout and os.clock() >= retryAt then
		if lastError == nil then
			print("[Structure] Change detected, regenerating project files")
		end

		local ok, err = pcall(regenerate)
		if ok then
			layout = current
			lastError = nil
			print("[Structure] Project files updated ✅")
		else
			-- Keep the old layout so this is retried, but only report a problem once.
			retryAt = os.clock() + RETRY_INTERVAL
			if tostring(err) ~= lastError then
				lastError = tostring(err)
				print(`[Structure] Failed to update, fix the problem and it retries: {err} ❌`)
			end
		end
	end
end
