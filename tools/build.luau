local builder = require("./builder")

local PLACE_FILE = "game.rbxl"

print("🔨 Compiling...")
builder.compile(false)

print("⚙️ Building place...")
builder.run("rojo", { "build", builder.BUILD_PROJECT, "--output", PLACE_FILE })

print(`✅ Built {PLACE_FILE}`)
