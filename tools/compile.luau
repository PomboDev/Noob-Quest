local builder = require("./builder")

builder.compile(false)
print(`✅ Compiled {builder.SRC_DIR}/ into {builder.OUT_DIR}/`)
