local builder = require("./builder")

builder.run("stylua", builder.FORMAT_PATHS)
print(`✅ Formatted {table.concat(builder.FORMAT_PATHS, ", ")}`)
