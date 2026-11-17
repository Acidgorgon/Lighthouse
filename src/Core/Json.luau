--!strict
-- JSON for exports (no HttpService, so it runs in tests and on either side).
--
-- encode: nil -> null; NaN and +-inf -> null; integers print without a fraction; strings are
-- escaped (quotes, backslash, control characters); a table with keys 1..n is an array, an empty
-- table is [] (the Snapshot's empty lists stay lists); other tables are objects with keys sorted.
-- Non JSON values (functions, buffers, userdata) become null; nesting deeper than 64 and cycles
-- become null too. decode: a small strict parser (returns nil, err on bad input, never throws).

local Json = {}

local MAX_DEPTH = 64

local ESC: { [string]: string } = {
	['"'] = '\\"',
	["\\"] = "\\\\",
	["\b"] = "\\b",
	["\f"] = "\\f",
	["\n"] = "\\n",
	["\r"] = "\\r",
	["\t"] = "\\t",
}
for c = 0, 31 do
	local ch = string.char(c)
	if ESC[ch] == nil then
		ESC[ch] = string.format("\\u%04x", c)
	end
end
ESC["\127"] = "\\u007f"

local function str(s: string): string
	return '"' .. string.gsub(s, '[%c"\\]', ESC) .. '"'
end

local function num(n: number): string
	if n ~= n or n == math.huge or n == -math.huge then
		return "null"
	end
	if n == math.floor(n) and math.abs(n) < 2 ^ 53 then
		return string.format("%d", n)
	end
	return string.format("%.10g", n)
end

local function isArray(t: { [any]: any }): (boolean, number)
	local n = #t
	local k = 0
	for key in t do
		if type(key) ~= "number" or key < 1 or key > n or key ~= math.floor(key) then
			return false, 0
		end
		k += 1
	end
	return k == n, n
end

local encodeValue: (v: any, out: { string }, depth: number, seen: { [any]: boolean }) -> ()

function encodeValue(v: any, out: { string }, depth: number, seen: { [any]: boolean })
	local tv = type(v)
	if tv == "number" then
		table.insert(out, num(v))
	elseif tv == "string" then
		table.insert(out, str(v))
	elseif tv == "boolean" then
		table.insert(out, if v then "true" else "false")
	elseif tv == "table" then
		if depth >= MAX_DEPTH or seen[v] then
			table.insert(out, "null")
			return
		end
		seen[v] = true
		local array, n = isArray(v)
		if array then
			table.insert(out, "[")
			for i = 1, n do
				if i > 1 then
					table.insert(out, ",")
				end
				encodeValue(v[i], out, depth + 1, seen)
			end
			table.insert(out, "]")
		else
			local keys = {}
			for key in v do
				local tk = type(key)
				if tk == "string" or tk == "number" then
					table.insert(keys, key)
				end
			end
			table.sort(keys, function(a, b)
				return tostring(a) < tostring(b)
			end)
			table.insert(out, "{")
			for i, key in keys do
				if i > 1 then
					table.insert(out, ",")
				end
				table.insert(out, str(tostring(key)))
				table.insert(out, ":")
				encodeValue(v[key], out, depth + 1, seen)
			end
			table.insert(out, "}")
		end
		seen[v] = nil
	else
		table.insert(out, "null")
	end
end

function Json.encode(value: any): string
	local out = {}
	encodeValue(value, out, 0, {})
	return table.concat(out)
end

--------------------------------------------------------------------------------
-- decode
--------------------------------------------------------------------------------

local UNESC: { [string]: string } = { ['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }

local function utf8char(cp: number): string
	if cp < 0x80 then
		return string.char(cp)
	elseif cp < 0x800 then
		return string.char(0xC0 + bit32.rshift(cp, 6), 0x80 + bit32.band(cp, 0x3F))
	elseif cp < 0x10000 then
		return string.char(0xE0 + bit32.rshift(cp, 12), 0x80 + bit32.band(bit32.rshift(cp, 6), 0x3F), 0x80 + bit32.band(cp, 0x3F))
	end
	return string.char(
		0xF0 + bit32.rshift(cp, 18),
		0x80 + bit32.band(bit32.rshift(cp, 12), 0x3F),
		0x80 + bit32.band(bit32.rshift(cp, 6), 0x3F),
		0x80 + bit32.band(cp, 0x3F)
	)
end

-- Returns the decoded value, or nil and an error message. JSON null decodes to nil.
function Json.decode(s: string): (any, string?)
	if type(s) ~= "string" then
		return nil, "not a string"
	end
	local pos = 1
	local len = #s

	local function fail(msg: string): any
		error({ msg = msg .. " at " .. pos }, 0)
	end
	local function skip()
		pos = string.find(s, "[^ \t\r\n]", pos) or len + 1
	end

	local parse: (depth: number) -> any
	local function parseString(): string
		pos += 1
		local parts = {}
		while true do
			local a, b = string.find(s, '[%c"\\]', pos)
			if a == nil then
				return fail("unterminated string")
			end
			table.insert(parts, string.sub(s, pos, a - 1))
			local c = string.sub(s, a, b)
			if c == '"' then
				pos = a + 1
				return table.concat(parts)
			elseif c == "\\" then
				local e = string.sub(s, a + 1, a + 1)
				if e == "u" then
					local hex = string.sub(s, a + 2, a + 5)
					local cp = if string.match(hex, "^%x%x%x%x$") then tonumber(hex, 16) else nil
					if cp == nil then
						return fail("bad \\u escape")
					end
					local nextPos = a + 6
					if cp >= 0xD800 and cp <= 0xDBFF and string.sub(s, nextPos, nextPos + 1) == "\\u" then
						local lo = tonumber(string.sub(s, nextPos + 2, nextPos + 5), 16)
						if lo and lo >= 0xDC00 and lo <= 0xDFFF then
							cp = 0x10000 + (cp - 0xD800) * 0x400 + (lo - 0xDC00)
							nextPos += 6
						end
					end
					table.insert(parts, utf8char(cp))
					pos = nextPos
				else
					local u = UNESC[e]
					if u == nil then
						return fail("bad escape")
					end
					table.insert(parts, u)
					pos = a + 2
				end
			else
				return fail("control character in string")
			end
		end
	end

	function parse(depth: number): any
		if depth > 512 then
			return fail("too deep")
		end
		skip()
		local c = string.sub(s, pos, pos)
		if c == "{" then
			pos += 1
			local obj = {}
			skip()
			if string.sub(s, pos, pos) == "}" then
				pos += 1
				return obj
			end
			while true do
				skip()
				if string.sub(s, pos, pos) ~= '"' then
					return fail("expected key")
				end
				local key = parseString()
				skip()
				if string.sub(s, pos, pos) ~= ":" then
					return fail("expected ':'")
				end
				pos += 1
				obj[key] = parse(depth + 1)
				skip()
				local d = string.sub(s, pos, pos)
				pos += 1
				if d == "}" then
					return obj
				elseif d ~= "," then
					return fail("expected ',' or '}'")
				end
			end
		elseif c == "[" then
			pos += 1
			local arr = {}
			local n = 0
			skip()
			if string.sub(s, pos, pos) == "]" then
				pos += 1
				return arr
			end
			while true do
				n += 1
				arr[n] = parse(depth + 1)
				skip()
				local d = string.sub(s, pos, pos)
				pos += 1
				if d == "]" then
					return arr
				elseif d ~= "," then
					return fail("expected ',' or ']'")
				end
			end
		elseif c == '"' then
			return parseString()
		elseif c == "t" and string.sub(s, pos, pos + 3) == "true" then
			pos += 4
			return true
		elseif c == "f" and string.sub(s, pos, pos + 4) == "false" then
			pos += 5
			return false
		elseif c == "n" and string.sub(s, pos, pos + 3) == "null" then
			pos += 4
			return nil
		else
			local a, b = string.find(s, "^-?%d+%.?%d*[eE]?[-+]?%d*", pos)
			if a == nil then
				return fail("unexpected character")
			end
			local v = tonumber(string.sub(s, a, b))
			if v == nil then
				return fail("bad number")
			end
			pos = b + 1
			return v
		end
	end

	local ok, result = pcall(function()
		local v = parse(0)
		skip()
		if pos <= len then
			fail("trailing characters")
		end
		return v
	end)
	if ok then
		return result, nil
	end
	return nil, if type(result) == "table" then result.msg else tostring(result)
end

return Json
