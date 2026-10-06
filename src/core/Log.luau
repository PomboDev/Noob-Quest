--!strict

--[=[
	Leveled logging, prefixed with the calling module's name.

	- debug: dev builds only (ROBLOX_DEV=true, injected by darklua)
	- info / warn: always
]=]

local __DEV__ = _G.__DEV__ == "true"

local Log = {}

local function createLogFunction(levelName: string, logFn: (...any) -> (), devOnly: boolean): (...any) -> ()
	if devOnly and not __DEV__ then
		return function() end
	end

	return function(...: any)
		local modulePath = debug.info(2, "s")
		local moduleName = modulePath:match("[^.]+$") or modulePath

		logFn(`[{moduleName}] {levelName}:`, ...)
	end
end

Log.debug = createLogFunction("DEBUG", print, true)
Log.info = createLogFunction("INFO", print, false)
Log.warn = createLogFunction("WARN", warn, false)

return Log
