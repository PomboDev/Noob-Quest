--[=[
	Assertions for the specs run by `tools/test.luau`. Each one errors with a
	readable message, pointing at the caller.
]=]

local Expect = {}

local function show(value: any): string
	if type(value) == "string" then
		return string.format("%q", value)
	end
	return tostring(value)
end

local function compare(actual: any, expected: any, path: string): string?
	if actual == expected then
		return nil
	end
	if type(actual) ~= "table" or type(expected) ~= "table" then
		return `{path}: expected {show(expected)}, got {show(actual)}`
	end

	for key, value in expected do
		local problem = compare(actual[key], value, `{path}.{tostring(key)}`)
		if problem then
			return problem
		end
	end
	for key, value in actual do
		if expected[key] == nil then
			return `{path}.{tostring(key)}: unexpected {show(value)}`
		end
	end
	return nil
end

function Expect.equal(actual: any, expected: any, label: string?)
	if actual ~= expected then
		error(`{label or "value"}: expected {show(expected)}, got {show(actual)}`, 2)
	end
end

-- Structural equality: tables match when their keys and values do.
function Expect.deepEqual(actual: any, expected: any, label: string?)
	local problem = compare(actual, expected, label or "value")
	if problem then
		error(problem, 2)
	end
end

-- Expects `fn` to error, with a message containing `contains` if given.
function Expect.errors(fn: () -> (), contains: string?)
	local ok, err = pcall(fn)
	if ok then
		error("expected an error", 2)
	end
	if contains and not string.find(tostring(err), contains, 1, true) then
		error(`expected an error containing {show(contains)}, got: {tostring(err)}`, 2)
	end
end

return Expect
