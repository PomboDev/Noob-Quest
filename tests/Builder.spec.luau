local Expect = require("./Expect")
local builder = require("../tools/builder")

-- Renders the given source paths the way `generate` would.
local function project(paths: { string }, root: string?): any
	local entries = {}
	for _, path in paths do
		table.insert(entries, builder.describe(path))
	end
	return builder.render(entries, root or "src")
end

local function render(paths: { string }, root: string?): any
	return project(paths, root).tree
end

return {
	["Server suffix routes to ServerScriptService"] = function()
		local tree = render({
			"features/combat/CombatServiceServer.luau",
			"features/combat/CombatControllerClient.luau",
		})

		Expect.equal(
			tree.ServerScriptService.Features.Combat.CombatServiceServer["$path"],
			"src/features/combat/CombatServiceServer.luau"
		)
		Expect.equal(
			tree.ReplicatedStorage.Source.Features.Combat.CombatControllerClient["$path"],
			"src/features/combat/CombatControllerClient.luau"
		)
		Expect.equal(
			tree.ReplicatedStorage.Source.Features.Combat.CombatServiceServer,
			nil,
			"server module leaked to clients"
		)
	end,

	["routing matches the suffix only"] = function()
		local tree = render({ "core/ObserverUtils.luau", "core/NetworkServer.luau" })
		Expect.equal(tree.ReplicatedStorage.Source.Core.ObserverUtils["$path"], "src/core/ObserverUtils.luau")
		Expect.equal(tree.ServerScriptService.Core.NetworkServer["$path"], "src/core/NetworkServer.luau")
	end,

	["folders become PascalCase, ui becomes UI"] = function()
		local tree = render({ "features/playerData/modules/Shape.luau", "features/ui/Root.luau" })
		Expect.equal(
			tree.ReplicatedStorage.Source.Features.PlayerData.Modules.Shape["$path"],
			"src/features/playerData/modules/Shape.luau"
		)
		Expect.equal(tree.ReplicatedStorage.Source.Features.UI.Root["$path"], "src/features/ui/Root.luau")
	end,

	["Server, Client, Utils and Types take their folder's name"] = function()
		local tree = render({
			"features/combat/Server.luau",
			"features/combat/Client.luau",
			"features/combat/modules/Utils.luau",
			"features/combat/modules/Types.luau",
		})

		Expect.equal(tree.ServerScriptService.Features.Combat.CombatServer["$path"], "src/features/combat/Server.luau")
		Expect.equal(
			tree.ReplicatedStorage.Source.Features.Combat.CombatClient["$path"],
			"src/features/combat/Client.luau"
		)
		Expect.equal(
			tree.ReplicatedStorage.Source.Features.Combat.Modules.ModulesUtils["$path"],
			"src/features/combat/modules/Utils.luau"
		)
		Expect.equal(
			tree.ReplicatedStorage.Source.Features.Combat.Modules.ModulesTypes["$path"],
			"src/features/combat/modules/Types.luau"
		)
	end,

	["an init folder is mapped as one module"] = function()
		local tree = render({ "core/Network/init.luau", "core/Network/Codec.luau", "core/Network/Types.luau" })

		local network = tree.ReplicatedStorage.Source.Core.Network
		Expect.equal(network["$path"], "src/core/Network")
		Expect.equal(network["$className"], nil, "module should not be a Folder")
		Expect.equal(network.Codec, nil, "children come from Rojo mapping the folder")
		Expect.equal(tree.ServerScriptService.Core, nil)
	end,

	["server files inside an init folder are carved out"] = function()
		local result = project({
			"core/Network/init.luau",
			"core/Network/Codec.luau",
			"core/Network/NetworkServer.luau",
		})

		Expect.deepEqual(result.globIgnorePaths, { "src/core/Network/NetworkServer.luau" })
		Expect.equal(
			result.tree.ServerScriptService.Core.Network.NetworkServer["$path"],
			"src/core/Network/NetworkServer.luau"
		)
		Expect.equal(result.tree.ReplicatedStorage.Source.Core.Network["$path"], "src/core/Network")
	end,

	["carved-out files are found at any depth and under any root"] = function()
		local result = project({
			"core/net/init.luau",
			"core/net/deep/er/Gate.luau",
			"core/net/deep/er/GateServer.luau",
		}, "out")

		Expect.deepEqual(result.globIgnorePaths, { "out/core/net/deep/er/GateServer.luau" })
		Expect.equal(
			result.tree.ServerScriptService.Core.Net.Deep.Er.GateServer["$path"],
			"out/core/net/deep/er/GateServer.luau"
		)
	end,

	["a server init folder moves as a whole"] = function()
		local result = project({
			"features/combat/combatServer/init.luau",
			"features/combat/combatServer/Helper.luau",
		})

		Expect.equal(result.globIgnorePaths, nil)
		Expect.equal(
			result.tree.ServerScriptService.Features.Combat.CombatServer["$path"],
			"src/features/combat/combatServer"
		)
		Expect.equal(result.tree.ReplicatedStorage.Source.Features, nil, "nothing for clients")
	end,

	["a server init folder inside a shared one is an error"] = function()
		Expect.errors(function()
			render({ "core/net/init.luau", "core/net/gateServer/init.luau" })
		end, "a server init folder can't sit inside")
	end,

	["init.luau needs a folder"] = function()
		Expect.errors(function()
			builder.describe("init.luau")
		end, "must be inside a folder")
	end,

	["a module and a folder can't share a name"] = function()
		-- luau-lsp would resolve require("Network") to the folder.
		Expect.errors(function()
			render({ "core/Network.luau", "core/Network/Codec.luau" })
		end, "both map to ReplicatedStorage.Source.Core.Network")
		Expect.errors(function()
			render({ "core/network/Codec.luau", "core/Network.luau" })
		end, "use Network/init.luau instead")
	end,

	["files mapping to the same instance are an error"] = function()
		Expect.errors(function()
			render({ "features/combat/Server.luau", "features/combat/CombatServer.luau" })
		end, "both map to ServerScriptService.Features.Combat.CombatServer")
	end,

	["entry scripts are mapped explicitly"] = function()
		local tree = render({})
		Expect.equal(tree.ReplicatedStorage.Source.StartUp.Client["$path"], "src/startup/Client.client.luau")
		Expect.equal(tree.ServerScriptService.StartUp.Server["$path"], "src/startup/Server.server.luau")
	end,

	["assets map into ReplicatedStorage under any root"] = function()
		Expect.equal(render({}, "src").ReplicatedStorage.Assets["$path"], "assets/shared")
		Expect.equal(render({}, "out").ReplicatedStorage.Assets["$path"], "assets/shared")
	end,

	["the assets project is rooted at the assets folder"] = function()
		-- The syncback input is a model whose root is Assets: a DataModel root would be refused.
		Expect.deepEqual(builder.renderAssets().tree, { ["$path"] = "assets/shared" })
	end,

	["the build project points at the compiled output"] = function()
		local tree = render({ "core/Log.luau" }, "out")
		Expect.equal(tree.ReplicatedStorage.Source.Core.Log["$path"], "out/core/Log.luau")
		Expect.equal(tree.ReplicatedStorage.Packages["$path"], "roblox_packages")
	end,
}
