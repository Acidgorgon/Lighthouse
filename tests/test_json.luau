-- Export JSON: valid output, escapes, NaN / inf -> null, round trip of a real snapshot.
return function(T)
	local function deepEq(a: any, b: any, path: string)
		if type(a) == "number" and type(b) == "number" then
			if math.abs(a - b) > 1e-9 * math.max(1, math.abs(a)) then
				error(`{path}: {a} vs {b}`)
			end
			return
		end
		if type(a) ~= type(b) then
			error(`{path}: type {type(a)} vs {type(b)}`)
		end
		if type(a) == "table" then
			for k, v in a do
				deepEq(v, b[k], path .. "." .. tostring(k))
			end
			for k in b do
				if a[k] == nil then
					error(`{path}.{k}: missing`)
				end
			end
		elseif a ~= b then
			error(`{path}: {tostring(a)} vs {tostring(b)}`)
		end
	end

	T.test("scalars, escapes, NaN and inf", function()
		local Json = T.core().Json
		T.eq(Json.encode(nil), "null")
		T.eq(Json.encode(true), "true")
		T.eq(Json.encode(42), "42")
		T.eq(Json.encode(-3), "-3")
		T.eq(Json.encode(0.5), "0.5")
		T.eq(Json.encode(1e-7), "1e-07")
		T.eq(Json.encode(0 / 0), "null")
		T.eq(Json.encode(math.huge), "null")
		T.eq(Json.encode(-math.huge), "null")
		T.eq(Json.encode('a"b\\c'), '"a\\"b\\\\c"')
		T.eq(Json.encode("line\nnext\ttab\r\b\f"), '"line\\nnext\\ttab\\r\\b\\f"')
		T.eq(Json.encode("\1\31\127"), '"\\u0001\\u001f\\u007f"')
		T.eq(Json.encode("héllo"), '"héllo"', "UTF-8 passes through")
		T.eq(Json.encode({ 0 / 0, 1, math.huge }), "[null,1,null]")
		T.eq(Json.encode({}), "[]", "empty table is a list")
		T.eq(Json.encode({ b = 1, a = { 1, 2 }, c = "x" }), '{"a":[1,2],"b":1,"c":"x"}', "sorted keys")
		T.eq(Json.encode({ [1] = "a", [3] = "c" }), '{"1":"a","3":"c"}', "sparse array is an object")
		T.eq(Json.encode({ f = function() end, b = buffer.create(1) }), '{"b":null,"f":null}')
		local cyc = {}
		cyc.self = cyc
		T.eq(Json.encode(cyc), '{"self":null}', "cycles become null")
		local shared = { 1 }
		T.eq(Json.encode({ shared, shared }), "[[1],[1]]", "shared (non cyclic) tables are fine")
	end)

	T.test("decode: values, escapes, errors never throw", function()
		local Json = T.core().Json
		local v = Json.decode('{"a":[1,2.5,-3e2,true,false,null],"s":"x\\"\\\\\\n\\u00e9\\ud83d\\ude00"}')
		T.eq(v.a[1], 1)
		T.eq(v.a[2], 2.5)
		T.eq(v.a[3], -300)
		T.eq(v.a[4], true)
		T.eq(v.a[5], false)
		T.eq(v.s, 'x"\\\né😀')
		for _, bad in { "", "{", "[1,", '{"a" 1}', '"abc', "nul", "[1] 2", '"\1"', "{1:2}", '"\\x"' } do
			local r, err = Json.decode(bad)
			T.check(r == nil and type(err) == "string", "rejects " .. bad)
		end
		T.eq(select(2, Json.decode(nil :: any)), "not a string")
	end)

	T.test("a full snapshot and recording round trip as valid JSON", function()
		local h = T.harness({ budget = 1 / 60 })
		local Core = h.Core
		local ps = {}
		for i = 1, 12 do
			ps[i] = Core.probe('Sys."quoted"\n' .. i)
		end
		Core.setEngine({ ping = 0 / 0, heartbeatMs = 2 }, { totalMb = 1, tags = {} }, { device = "Mobile" })
		h.seconds(3, 1 / 60, function()
			for i = 1, 12 do
				ps[i]:begin()
				h.spend(0.0001 * i)
				ps[i]:finish()
			end
			Core.count("C")
			Core.net("L", "c", "out", 10)
		end)
		h.frame(0.2)
		h.seconds(1, 1 / 60)
		local doc = { lighthouse = 1, client = Core.snapshot("client"), recording = Core.recording(1) }
		local text = Core.Json.encode(doc)
		local back, err = Core.Json.decode(text)
		T.check(back ~= nil, "valid JSON: " .. tostring(err))
		T.eq(back.client.engine.ping, nil, "NaN became null")
		doc.client.engine.ping = nil
		deepEq(doc, back, "doc")
		T.eq(back.client.probes[1].name, 'Sys."quoted"\n12')
	end)
end
