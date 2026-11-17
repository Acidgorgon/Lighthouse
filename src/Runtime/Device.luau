--!strict
-- Device class of this client: "Desktop" | "Mobile" | "Tablet" | "Console" | "VR".
--   VRService.VREnabled               -> VR
--   GuiService:IsTenFootInterface()   -> Console
--   touch and no keyboard             -> Tablet if the short side of the screen is >= 600 px, else Mobile
--   anything else                     -> Desktop
-- Every engine read is pcall'd; the answer is cached after the first call.

local Device = {}

local TABLET_SHORT_SIDE = 600

local cached: string? = nil

local function getService(name: string): any
	local ok, s = pcall(function()
		return game:GetService(name)
	end)
	return if ok then s else nil
end

local function read(obj: any, key: string): any
	if obj == nil then
		return nil
	end
	local ok, v = pcall(function()
		return obj[key]
	end)
	return if ok then v else nil
end

local function call(obj: any, method: string): any
	if obj == nil then
		return nil
	end
	local ok, v = pcall(function()
		return obj[method](obj)
	end)
	return if ok then v else nil
end

-- Pure rule, for tests and for callers that already know the inputs.
function Device.fromInputs(vr: boolean?, tenFoot: boolean?, touch: boolean?, keyboard: boolean?, shortSide: number?): string
	if vr then
		return "VR"
	elseif tenFoot then
		return "Console"
	elseif touch and not keyboard then
		if shortSide and shortSide >= TABLET_SHORT_SIDE then
			return "Tablet"
		end
		return "Mobile"
	end
	return "Desktop"
end

function Device.detect(): string
	local uis = getService("UserInputService")
	local gui = getService("GuiService")
	local vrs = getService("VRService")
	local shortSide: number? = nil
	local camera = read(workspace, "CurrentCamera")
	local size = read(camera, "ViewportSize")
	if size ~= nil then
		local x, y = read(size, "X"), read(size, "Y")
		if type(x) == "number" and type(y) == "number" and x > 0 and y > 0 then
			shortSide = math.min(x, y)
		end
	end
	return Device.fromInputs(
		read(vrs, "VREnabled") == true,
		call(gui, "IsTenFootInterface") == true,
		read(uis, "TouchEnabled") == true,
		read(uis, "KeyboardEnabled") == true,
		shortSide
	)
end

-- Cached device class (detected on first call).
function Device.get(): string
	local d = cached
	if d == nil then
		d = Device.detect()
		cached = d
	end
	return d
end

function Device.reset()
	cached = nil
end

return Device
