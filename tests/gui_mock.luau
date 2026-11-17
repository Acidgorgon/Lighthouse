--!optimize 2
-- GUI additions to the Roblox mock, for the overlay tests only (tests/mock.luau stays shared and
-- unchanged). GuiMock.install(Mock, env) adds:
--   * globals: UDim, UDim2, Color3, Vector2, Font, and lazily created Enum items
--   * client services: UserInputService, GuiService; a PlayerGui under the player;
--     Camera.ViewportSize
--   * button signals (Activated, MouseButton1Click, SelectionGained, ...) on new GUI Instances
--   * a counter of Instance.new calls, to check that refreshes create nothing
-- It returns a handle with :uninstall(), which puts the globals back as they were so later test
-- files see the plain mock.

-- One instance per process: compiled chunks are cached by the mock and resolve global imports
-- once, so every test file must share the same value tables (see lazyEnum below).
local existing = rawget(_G, "__LighthouseGuiMock")
if existing then
	return existing
end

local GuiMock = {}
rawset(_G, "__LighthouseGuiMock", GuiMock)

local function valueType(name: string)
	return { __robloxtype = name }
end

local UDimMT = valueType("UDim")
local UDim2MT = valueType("UDim2")
local Color3MT = valueType("Color3")
local Vector2MT = valueType("Vector2")
local FontMT = valueType("Font")

UDimMT.__eq = function(a, b)
	return a.Scale == b.Scale and a.Offset == b.Offset
end
UDim2MT.__eq = function(a, b)
	return a.X == b.X and a.Y == b.Y
end
Color3MT.__eq = function(a, b)
	return a.R == b.R and a.G == b.G and a.B == b.B
end
Vector2MT.__eq = function(a, b)
	return a.X == b.X and a.Y == b.Y
end

local function finite(v: any, what: string): number
	if type(v) ~= "number" or v ~= v or v == math.huge or v == -math.huge then
		error(`{what}: expected a finite number, got {tostring(v)}`, 3)
	end
	return v
end

local function udim(s, o)
	return setmetatable({ Scale = finite(s or 0, "UDim.new"), Offset = finite(o or 0, "UDim.new") }, UDimMT)
end

local GLOBALS = {
	UDim = {
		new = udim,
	},
	UDim2 = {
		new = function(xs, xo, ys, yo)
			return setmetatable({ X = udim(xs, xo), Y = udim(ys, yo) }, UDim2MT)
		end,
		fromScale = function(x, y)
			return setmetatable({ X = udim(x, 0), Y = udim(y, 0) }, UDim2MT)
		end,
		fromOffset = function(x, y)
			return setmetatable({ X = udim(0, x), Y = udim(0, y) }, UDim2MT)
		end,
	},
	Color3 = {
		new = function(r, g, b)
			return setmetatable({ R = r or 0, G = g or 0, B = b or 0 }, Color3MT)
		end,
		fromRGB = function(r, g, b)
			return setmetatable({ R = (r or 0) / 255, G = (g or 0) / 255, B = (b or 0) / 255 }, Color3MT)
		end,
	},
	Vector2 = {
		new = function(x, y)
			return setmetatable({ X = finite(x or 0, "Vector2.new"), Y = finite(y or 0, "Vector2.new") }, Vector2MT)
		end,
	},
	Font = {
		new = function(family, weight, style)
			return setmetatable({ Family = family, Weight = weight, Style = style }, FontMT)
		end,
	},
}

local GUI_BUTTON = { TextButton = true, ImageButton = true }
local GUI_OBJECT = {
	Frame = true,
	TextLabel = true,
	TextButton = true,
	ImageLabel = true,
	ImageButton = true,
	ScrollingFrame = true,
	TextBox = true,
	CanvasGroup = true,
}

-- Enum items made on first use: Enum.KeyCode.F7 -> { Name = "F7", EnumType = "KeyCode" }.
-- The tables are kept across installs: compiled chunks are cached by the mock and Luau resolves
-- `Enum.KeyCode.F7` imports once per chunk, so every install must hand out the same objects.
local enums = {}
local function lazyEnum(enumName: string)
	if enums[enumName] then
		return enums[enumName]
	end
	enums[enumName] = setmetatable({}, {
		__index = function(t, item)
			local value = table.freeze({ Name = item, EnumType = enumName })
			rawset(t, item, value)
			return value
		end,
	})
	return enums[enumName]
end

function GuiMock.install(Mock, env, opts: any?)
	opts = opts or {}
	local handle = { created = 0, byClass = {} }

	-- globals
	local saved = {}
	for name, value in GLOBALS do
		saved[name] = { value = rawget(_G, name) }
		rawset(_G, name, value)
	end
	local enumAdded = {}
	local enumMT = getmetatable(Enum)
	setmetatable(Enum, {
		__index = function(t, enumName)
			local e = lazyEnum(enumName)
			rawset(t, enumName, e)
			table.insert(enumAdded, enumName)
			return e
		end,
	})

	-- services
	local game = env.game
	local function service(className: string)
		local s = game:FindFirstChild(className)
		if s == nil then
			s = Mock.newInstance(className)
			s.Parent = game
		end
		return s
	end
	local uis = service("UserInputService")
	rawset(uis, "InputBegan", Mock.Signal.new())
	rawset(uis, "InputEnded", Mock.Signal.new())
	rawset(uis, "LastInputTypeChanged", Mock.Signal.new())
	rawset(uis, "TouchEnabled", opts.touch == true)
	rawset(uis, "KeyboardEnabled", opts.touch ~= true)
	rawset(uis, "MouseEnabled", opts.touch ~= true)
	rawset(uis, "GamepadEnabled", opts.gamepad == true)
	rawset(uis, "GetFocusedTextBox", function()
		return nil
	end)
	handle.UserInputService = uis

	local guiService = service("GuiService")
	rawset(guiService, "SelectedObject", nil)
	rawset(guiService, "IsTenFootInterface", function()
		return opts.tenFoot == true
	end)
	handle.GuiService = guiService

	local camera = env.Workspace.CurrentCamera
	if camera then
		local size = opts.viewport or { 1280, 720 }
		rawset(camera, "ViewportSize", GLOBALS.Vector2.new(size[1], size[2]))
	end
	handle.camera = camera

	local player = env.player
	if player and player:FindFirstChildOfClass("PlayerGui") == nil then
		local playerGui = Mock.newInstance("PlayerGui")
		playerGui.Parent = player
		handle.PlayerGui = playerGui
	elseif player then
		handle.PlayerGui = player:FindFirstChildOfClass("PlayerGui")
	end

	-- Instance.new: count, and give GUI objects their signals
	local lib = env.InstanceLib
	local originalNew = lib.new
	lib.new = function(className: string, parent)
		local inst = originalNew(className, parent)
		handle.created += 1
		handle.byClass[className] = (handle.byClass[className] or 0) + 1
		if GUI_OBJECT[className] then
			for _, name in { "InputBegan", "InputEnded", "MouseEnter", "MouseLeave", "SelectionGained", "SelectionLost" } do
				rawset(inst, name, Mock.Signal.new())
			end
		end
		if GUI_BUTTON[className] then
			for _, name in { "Activated", "MouseButton1Click", "MouseButton1Down", "MouseButton1Up" } do
				rawset(inst, name, Mock.Signal.new())
			end
		end
		return inst
	end

	function handle:uninstall()
		lib.new = originalNew
		for name, s in saved do
			rawset(_G, name, s.value)
		end
		setmetatable(Enum, enumMT)
		for _, enumName in enumAdded do
			rawset(Enum, enumName, nil)
		end
	end

	return handle
end

-- Counts the Instances under root (root included).
function GuiMock.count(root): number
	return 1 + #root:GetDescendants()
end

return GuiMock
