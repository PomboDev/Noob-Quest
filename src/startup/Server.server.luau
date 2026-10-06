--!strict

local ServerScriptService = game:GetService("ServerScriptService")

local Loader = require("@Core/Loader")

local features = ServerScriptService:FindFirstChild("Features")
if features then
	Loader.load(features, "Server")
end
