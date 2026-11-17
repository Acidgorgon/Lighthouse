--!strict
-- The Lighthouse in-game panel.
--
--   local overlay = Overlay.new(sourceFn)
--   overlay:setVisible(true)  -- builds the panel on first open, then shows it
--   overlay:setVisible(false) -- hides it (kept for the next open)
--   overlay:destroy()
--
-- sourceFn(side) returns the latest Snapshot for "client" or "server" (nil when there is none yet),
-- and sourceFn("telemetry") returns the player telemetry aggregate (nil when telemetry is off).
--
-- Plain Instances only. Every Instance is created once in build(); refreshes (4 Hz, from a
-- Heartbeat accumulator that only runs while the panel is open) only write properties, and only
-- when a value changed. Works with mouse, touch and gamepad: every button is Selectable, LB/RB
-- switch tabs, and the panel is a SelectionGroup so GuiService.SelectedObject stays inside it.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local GuiService = game:GetService("GuiService")

local Theme = require(script.Parent.Theme)
local Graph = require(script.Parent.Graph)

local C = Theme.colors
local F = Theme.fonts
local T = Theme.text
local S = Theme.size

local REFRESH = 0.25 -- seconds between refreshes (4 Hz)
local HISTORY = 120 -- bars in the frame graph
local FLARE_ROWS = 4

local TAB_NAMES = { "Frame", "Probes", "Network", "Memory", "Players" }

--------------------------------------------------------------------------------
-- Formatting
--------------------------------------------------------------------------------

local function num(v: any): number
	if type(v) ~= "number" or v ~= v or v == math.huge or v == -math.huge then
		return 0
	end
	return v
end

local function fmtMs(v: any): string
	if type(v) ~= "number" or v ~= v or v == math.huge or v == -math.huge then
		return "-"
	end
	if v >= 100 then
		return string.format("%.0f", v)
	elseif v >= 10 then
		return string.format("%.1f", v)
	end
	return string.format("%.2f", v)
end

local function fmtBytes(v: any): string
	v = num(v)
	if v >= 1048576 then
		return string.format("%.2f MB", v / 1048576)
	elseif v >= 1024 then
		return string.format("%.1f KB", v / 1024)
	end
	return string.format("%d B", math.floor(v + 0.5))
end

local function fmtCount(v: any): string
	v = num(v)
	if v >= 1e6 then
		return string.format("%.2fM", v / 1e6)
	elseif v >= 1e4 then
		return string.format("%.1fk", v / 1e3)
	elseif v == math.floor(v) then
		return string.format("%d", v)
	elseif v >= 10 then
		return string.format("%.1f", v)
	end
	return string.format("%.2f", v)
end

local function fmtMb(v: any): string
	v = num(v)
	if v >= 100 then
		return string.format("%.0f", v)
	end
	return string.format("%.1f", v)
end

-- Snapshot budgets are in ms; accept seconds too (anything under 1 is taken as seconds).
local function budgetMs(frame: any): number
	local b = num(frame and frame.budget)
	if b <= 0 then
		return 1000 / 60
	elseif b < 1 then
		return b * 1000
	end
	return b
end

--------------------------------------------------------------------------------
-- Instance helpers (used only while building)
--------------------------------------------------------------------------------

local function make(className: string, props: { [string]: any }, parent: Instance?): any
	local inst = Instance.new(className)
	for k, v in props do
		(inst :: any)[k] = v
	end
	if parent then
		inst.Parent = parent
	end
	return inst
end

local function textLabel(parent: Instance, props: { [string]: any }): TextLabel
	local l = make("TextLabel", {
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Font = F.mono,
		TextSize = T.row,
		TextColor3 = C.text,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Center,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Text = "",
	}, parent)
	for k, v in props do
		(l :: any)[k] = v
	end
	return l
end

local function corner(parent: Instance, radius: number)
	make("UICorner", { CornerRadius = UDim.new(0, radius) }, parent)
end

--------------------------------------------------------------------------------
-- Pooled table (rows of cells inside a ScrollingFrame)
--------------------------------------------------------------------------------

type Column = { title: string, width: number } -- width 0 = the flexible name column (first)

type Row = {
	frame: Frame,
	bar: Frame,
	cells: { TextLabel },
	kind: string,
	barFrac: number,
}

type Pool = {
	scroll: ScrollingFrame,
	rows: { Row },
	columns: { Column },
	numericWidth: number,
	used: number,
	shown: number,
	rowH: number,
}

local function columnLayout(columns: { Column }): (number, { number })
	-- returns total numeric width and each numeric column's right offset
	local right = table.create(#columns, 0)
	local x = 4
	for c = #columns, 2, -1 do
		right[c] = x
		x += columns[c].width
	end
	return x, right
end

local function headerRow(parent: Instance, columns: { Column }, y: number): Frame
	local frame = make("Frame", {
		Name = "Header",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(0, y),
		Size = UDim2.new(1, 0, 0, 16),
	}, parent)
	local numericWidth, right = columnLayout(columns)
	for c, col in columns do
		local l = textLabel(frame, {
			Name = "H" .. c,
			Text = col.title,
			TextSize = T.small,
			TextColor3 = C.dim,
			Font = F.text,
		})
		if c == 1 then
			l.Position = UDim2.fromOffset(6, 0)
			l.Size = UDim2.new(1, -(numericWidth + 10), 1, 0)
		else
			l.TextXAlignment = Enum.TextXAlignment.Right
			l.Position = UDim2.new(1, -(right[c] + col.width), 0, 0)
			l.Size = UDim2.new(0, col.width, 1, 0)
		end
	end
	return frame
end

local function newPool(parent: Instance, columns: { Column }, size: number, y: number): Pool
	local rowH = S.row
	local scroll = make("ScrollingFrame", {
		Name = "Rows",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(0, y),
		Size = UDim2.new(1, 0, 1, -y),
		CanvasSize = UDim2.fromOffset(0, 0),
		ScrollBarThickness = 4,
		ScrollBarImageColor3 = C.accent,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		ElasticBehavior = Enum.ElasticBehavior.Never,
		Selectable = true, -- select it with the D-pad, then scroll with the thumbstick
		SelectionImageObject = nil,
	}, parent)

	local numericWidth, right = columnLayout(columns)
	local rows = table.create(size)
	for i = 1, size do
		local frame = make("Frame", {
			Name = "R" .. i,
			BackgroundColor3 = if i % 2 == 0 then C.rowAlt else C.row,
			BackgroundTransparency = 0.55,
			BorderSizePixel = 0,
			Position = UDim2.fromOffset(0, (i - 1) * rowH),
			Size = UDim2.new(1, -6, 0, rowH),
			Visible = false,
		}, scroll)
		local bar = make("Frame", {
			Name = "Bar",
			BackgroundColor3 = C.bar,
			BackgroundTransparency = 0.78,
			BorderSizePixel = 0,
			Size = UDim2.fromScale(0, 1),
		}, frame)
		local cells = table.create(#columns)
		for c, col in columns do
			local l = textLabel(frame, { Name = "C" .. c, ZIndex = 2 })
			if c == 1 then
				l.Position = UDim2.fromOffset(6, 0)
				l.Size = UDim2.new(1, -(numericWidth + 10), 1, 0)
			else
				l.TextXAlignment = Enum.TextXAlignment.Right
				l.Position = UDim2.new(1, -(right[c] + col.width), 0, 0)
				l.Size = UDim2.new(0, col.width, 1, 0)
			end
			cells[c] = l
		end
		rows[i] = { frame = frame, bar = bar, cells = cells, kind = "", barFrac = 0 }
	end
	return {
		scroll = scroll,
		rows = rows,
		columns = columns,
		numericWidth = numericWidth,
		used = 0,
		shown = 0,
		rowH = rowH,
	}
end

--------------------------------------------------------------------------------
-- Overlay
--------------------------------------------------------------------------------

local Overlay = {}
Overlay.__index = Overlay

export type SourceFn = (side: string) -> any

export type Overlay = typeof(setmetatable(
	{} :: {
		source: SourceFn,
		visible: boolean,
		built: boolean,
		destroyed: boolean,
		side: string,
		tab: number,
		gui: ScreenGui?,
		ui: any,
		connections: { RBXScriptConnection },
		heartbeat: RBXScriptConnection?,
		acc: number,
		lastText: { [Instance]: string },
		lastColor: { [Instance]: Color3 },
		viewport: Vector2?,
		cornerIndex: number,
		refreshes: number,
		errors: number,
		lastError: string?,
	},
	Overlay
))

function Overlay.new(sourceFn: SourceFn): Overlay
	return setmetatable({
		source = sourceFn,
		visible = false,
		built = false,
		destroyed = false,
		side = "client",
		tab = 1,
		gui = nil,
		ui = {},
		connections = {},
		heartbeat = nil,
		acc = 0,
		lastText = setmetatable({}, { __mode = "k" }) :: any,
		lastColor = setmetatable({}, { __mode = "k" }) :: any,
		viewport = nil,
		cornerIndex = 1,
		refreshes = 0,
		errors = 0,
		lastError = nil,
	}, Overlay)
end

-- Property writes that skip unchanged values.
function Overlay._text(self: Overlay, label: TextLabel, text: string)
	if self.lastText[label] ~= text then
		self.lastText[label] = text
		label.Text = text
	end
end

function Overlay._color(self: Overlay, label: TextLabel, color: Color3)
	if self.lastColor[label] ~= color then
		self.lastColor[label] = color
		label.TextColor3 = color
	end
end

--------------------------------------------------------------------------------
-- Pool rows
--------------------------------------------------------------------------------

-- kind: "group" (accent header), "item" (indented), "plain", "note" (one dim line across the row)
function Overlay._row(self: Overlay, pool: Pool, kind: string, barFrac: number): Row?
	local i = pool.used + 1
	local row = pool.rows[i]
	if row == nil then
		return nil
	end
	pool.used = i
	if not row.frame.Visible then
		row.frame.Visible = true
	end
	if row.kind ~= kind then
		row.kind = kind
		local name = row.cells[1]
		if kind == "note" then
			name.Size = UDim2.new(1, -12, 1, 0)
			name.Font = F.text
		else
			name.Size = UDim2.new(1, -(pool.numericWidth + 10), 1, 0)
			name.Font = if kind == "group" then F.bold else F.mono
		end
		self:_color(name, if kind == "group" then C.accent elseif kind == "note" then C.dim else C.text)
		if kind == "note" then
			for c = 2, #row.cells do
				self:_text(row.cells[c], "")
			end
		end
	end
	barFrac = math.clamp(math.floor(num(barFrac) * 100 + 0.5) / 100, 0, 1)
	if row.barFrac ~= barFrac then
		row.barFrac = barFrac
		row.bar.Size = UDim2.fromScale(barFrac, 1)
	end
	return row
end

function Overlay._finish(self: Overlay, pool: Pool)
	local used = pool.used
	for i = used + 1, pool.shown do
		pool.rows[i].frame.Visible = false
	end
	if used ~= pool.shown then
		pool.shown = used
		pool.scroll.CanvasSize = UDim2.fromOffset(0, used * pool.rowH)
	end
	pool.used = 0
end

-- Writes a note row; when the pool is full, the last row says how many rows did not fit.
function Overlay._note(self: Overlay, pool: Pool, text: string)
	local row = self:_row(pool, "note", 0)
	if row then
		self:_text(row.cells[1], text)
	end
end

local function overflowText(missing: number): string
	return string.format("+%d more", missing)
end

--------------------------------------------------------------------------------
-- Build
--------------------------------------------------------------------------------

local function tabButton(parent: Instance, name: string, selection: GuiObject): TextButton
	local b = make("TextButton", {
		Name = name,
		AutoButtonColor = false,
		BackgroundColor3 = C.tab,
		BorderSizePixel = 0,
		Font = F.text,
		TextSize = T.body,
		TextColor3 = C.tabText,
		Text = name,
		Selectable = true,
		SelectionImageObject = selection,
	}, parent)
	corner(b, 5)
	return b
end

local function smallButton(parent: Instance, name: string, text: string, width: number, selection: GuiObject): TextButton
	local b = make("TextButton", {
		Name = name,
		AutoButtonColor = true,
		BackgroundColor3 = C.tab,
		BorderSizePixel = 0,
		Font = F.text,
		TextSize = T.small,
		TextColor3 = C.text,
		Text = text,
		Size = UDim2.new(0, width, 1, -8),
		Selectable = true,
		SelectionImageObject = selection,
	}, parent)
	corner(b, 5)
	return b
end

-- A caption over a big number (Frame and Memory tabs).
local function statCell(parent: Instance, caption: string, x: number, w: number): TextLabel
	textLabel(parent, {
		Name = caption,
		Text = caption,
		Font = F.text,
		TextSize = T.small,
		TextColor3 = C.dim,
		Position = UDim2.new(x, 0, 0, 0),
		Size = UDim2.new(w, -4, 0, 14),
	})
	return textLabel(parent, {
		Name = caption .. "Value",
		TextSize = 18,
		Position = UDim2.new(x, 0, 0, 14),
		Size = UDim2.new(w, -4, 0, 20),
	})
end

function Overlay._build(self: Overlay)
	local player = Players.LocalPlayer
	assert(player, "Lighthouse overlay runs on the client")
	local playerGui = player:FindFirstChildOfClass("PlayerGui") or player:WaitForChild("PlayerGui", 10)
	assert(playerGui, "Lighthouse overlay: no PlayerGui")

	local touch = UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled
	local headerH = if touch then 34 else S.header
	local tabsH = if touch then 36 else S.tabs
	local panelH = S.DESIGN_H + (headerH - S.header) + (tabsH - S.tabs)
	local ui: any = { touch = touch }
	self.ui = ui

	local gui = make("ScreenGui", {
		Name = "Lighthouse",
		ResetOnSpawn = false,
		IgnoreGuiInset = true,
		DisplayOrder = 1000000,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		Enabled = false,
	})
	self.gui = gui

	-- Shared selection highlight (amber outline) for every selectable control.
	local selection = make("Frame", {
		Name = "Selection",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
	})
	make("UIStroke", { Color = C.accent, Thickness = 2, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }, selection)
	corner(selection, 6)
	ui.selection = selection

	local panel = make("Frame", {
		Name = "Panel",
		BackgroundColor3 = C.panel,
		BackgroundTransparency = C.panelTransparency,
		BorderSizePixel = 0,
		Size = UDim2.fromOffset(S.DESIGN_W, panelH),
		Active = true, -- clicks and touches on the panel do not fall through to the game
		SelectionGroup = true,
		SelectionBehaviorUp = Enum.SelectionBehavior.Stop,
		SelectionBehaviorDown = Enum.SelectionBehavior.Stop,
		SelectionBehaviorLeft = Enum.SelectionBehavior.Stop,
		SelectionBehaviorRight = Enum.SelectionBehavior.Stop,
	}, gui)
	corner(panel, S.corner)
	make("UIStroke", { Color = C.stroke, Transparency = C.strokeTransparency, Thickness = 1 }, panel)
	ui.panel = panel
	ui.scale = make("UIScale", { Scale = 1 }, panel)

	-- Header: title, side switch, device line, move and close buttons.
	local header = make("Frame", {
		Name = "Header",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, headerH),
	}, panel)
	textLabel(header, {
		Name = "Title",
		Text = "lighthouse",
		Font = F.bold,
		TextSize = T.title,
		TextColor3 = C.accent,
		Position = UDim2.fromOffset(S.pad + 2, 0),
		Size = UDim2.new(0, 90, 1, 0),
	})
	ui.sideButton = smallButton(header, "Side", "client", 58, selection)
	ui.sideButton.Position = UDim2.new(0, 104, 0, 4)
	ui.info = textLabel(header, {
		Name = "Info",
		TextSize = T.small,
		TextColor3 = C.dim,
		TextXAlignment = Enum.TextXAlignment.Right,
		Position = UDim2.new(0, 168, 0, 0),
		Size = UDim2.new(1, -168 - 80, 1, 0),
	})
	ui.moveButton = smallButton(header, "Move", "move", 40, selection)
	ui.moveButton.AnchorPoint = Vector2.new(1, 0)
	ui.moveButton.Position = UDim2.new(1, -(S.pad + 30), 0, 4)
	ui.closeButton = smallButton(header, "Close", "x", 26, selection)
	ui.closeButton.AnchorPoint = Vector2.new(1, 0)
	ui.closeButton.Position = UDim2.new(1, -S.pad, 0, 4)

	-- Tab bar with LB / RB hints for gamepads.
	local tabBar = make("Frame", {
		Name = "Tabs",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(S.pad, headerH),
		Size = UDim2.new(1, -2 * S.pad, 0, tabsH - 4),
	}, panel)
	ui.lbHint = textLabel(tabBar, {
		Name = "LB",
		Text = "LB",
		Font = F.bold,
		TextSize = T.small,
		TextColor3 = C.dim,
		TextXAlignment = Enum.TextXAlignment.Center,
		Size = UDim2.new(0, 24, 1, 0),
		Visible = false,
	})
	ui.rbHint = textLabel(tabBar, {
		Name = "RB",
		Text = "RB",
		Font = F.bold,
		TextSize = T.small,
		TextColor3 = C.dim,
		TextXAlignment = Enum.TextXAlignment.Center,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.fromScale(1, 0),
		Size = UDim2.new(0, 24, 1, 0),
		Visible = false,
	})
	local tabHolder = make("Frame", {
		Name = "Holder",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
	}, tabBar)
	ui.tabHolder = tabHolder
	ui.hints = false
	make("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		SortOrder = Enum.SortOrder.LayoutOrder,
		Padding = UDim.new(0, 4),
	}, tabHolder)
	ui.tabButtons = {}
	for i, name in TAB_NAMES do
		local b = tabButton(tabHolder, name, selection)
		b.LayoutOrder = i
		b.Size = UDim2.new(1 / #TAB_NAMES, -4, 1, 0)
		ui.tabButtons[i] = b
	end
	for i, b in ui.tabButtons do
		b.NextSelectionLeft = ui.tabButtons[if i == 1 then #TAB_NAMES else i - 1]
		b.NextSelectionRight = ui.tabButtons[if i == #TAB_NAMES then 1 else i + 1]
	end

	-- Body: one page per tab, plus a message shown when there is no data.
	local bodyY = headerH + tabsH + 2
	local body = make("Frame", {
		Name = "Body",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(S.pad, bodyY),
		Size = UDim2.new(1, -2 * S.pad, 1, -(bodyY + S.pad)),
	}, panel)
	ui.message = textLabel(body, {
		Name = "Message",
		Font = F.text,
		TextSize = T.body,
		TextColor3 = C.dim,
		TextWrapped = true,
		TextTruncate = Enum.TextTruncate.None,
		TextXAlignment = Enum.TextXAlignment.Center,
		Size = UDim2.fromScale(1, 1),
		Visible = false,
	})
	ui.pages = {}
	for i, name in TAB_NAMES do
		ui.pages[i] = make("Frame", {
			Name = name,
			BackgroundTransparency = 1,
			Size = UDim2.fromScale(1, 1),
			Visible = false,
		}, body)
	end

	self:_buildFrame(ui.pages[1])
	self:_buildProbes(ui.pages[2])
	self:_buildNetwork(ui.pages[3])
	self:_buildMemory(ui.pages[4])
	self:_buildPlayers(ui.pages[5])

	-- Input
	for i, b in ui.tabButtons do
		table.insert(self.connections, b.Activated:Connect(function()
			self:setTab(i)
		end))
	end
	table.insert(self.connections, ui.sideButton.Activated:Connect(function()
		self:setSide(if self.side == "client" then "server" else "client")
	end))
	table.insert(self.connections, ui.moveButton.Activated:Connect(function()
		self.cornerIndex = self.cornerIndex % 4 + 1
		self:_place()
	end))
	table.insert(self.connections, ui.closeButton.Activated:Connect(function()
		self:setVisible(false)
	end))
	table.insert(self.connections, UserInputService.InputBegan:Connect(function(input: InputObject)
		if not self.visible then
			return
		end
		local key = input.KeyCode
		if key == Enum.KeyCode.ButtonL1 or key == Enum.KeyCode.ButtonR1 then
			if UserInputService:GetFocusedTextBox() then
				return
			end
			self:setTab(self.tab + (if key == Enum.KeyCode.ButtonL1 then -1 else 1))
		end
	end))

	self.built = true
	self:_layoutTabs()
	self:_place()
	gui.Parent = playerGui
end

function Overlay._buildFrame(self: Overlay, page: Frame)
	local ui = self.ui
	local stats = make("Frame", { Name = "Stats", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 36) }, page)
	ui.fLast = statCell(stats, "last ms", 0, 0.2)
	ui.fP50 = statCell(stats, "p50", 0.2, 0.2)
	ui.fP95 = statCell(stats, "p95", 0.4, 0.2)
	ui.fP99 = statCell(stats, "p99", 0.6, 0.2)
	ui.fFps = statCell(stats, "fps", 0.8, 0.2)

	ui.fScript = textLabel(page, {
		Name = "Script",
		TextSize = T.small,
		TextColor3 = C.dim,
		Position = UDim2.fromOffset(0, 38),
		Size = UDim2.new(1, 0, 0, 16),
	})
	local split = make("Frame", {
		Name = "Split",
		BackgroundColor3 = C.barBack,
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(0, 56),
		Size = UDim2.new(1, 0, 0, 5),
	}, page)
	corner(split, 2)
	ui.fSplit = make("Frame", {
		Name = "Script",
		BackgroundColor3 = C.accent,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(0, 1),
	}, split)
	corner(ui.fSplit, 2)
	ui.fSplitFrac = -1

	local graph = Graph.new(page, HISTORY)
	graph.frame.Position = UDim2.fromOffset(0, 66)
	graph.frame.Size = UDim2.new(1, 0, 1, -(66 + 14 + FLARE_ROWS * 16 + 4))
	ui.graph = graph

	ui.fFlareTitle = textLabel(page, {
		Name = "FlareTitle",
		Text = "flares",
		Font = F.text,
		TextSize = T.small,
		TextColor3 = C.dim,
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 0, 1, -FLARE_ROWS * 16),
		Size = UDim2.new(1, 0, 0, 14),
	})
	ui.fFlares = {}
	for i = 1, FLARE_ROWS do
		ui.fFlares[i] = textLabel(page, {
			Name = "Flare" .. i,
			TextSize = T.small,
			AnchorPoint = Vector2.new(0, 1),
			Position = UDim2.new(0, 0, 1, -(FLARE_ROWS - i) * 16),
			Size = UDim2.new(1, 0, 0, 16),
		})
	end
end

function Overlay._buildProbes(self: Overlay, page: Frame)
	local columns = {
		{ title = "probe", width = 0 },
		{ title = "self ms", width = 64 },
		{ title = "p95", width = 52 },
		{ title = "total", width = 56 },
		{ title = "calls", width = 48 },
	}
	headerRow(page, columns, 0)
	self.ui.probes = newPool(page, columns, 72, 16)
end

function Overlay._buildNetwork(self: Overlay, page: Frame)
	self.ui.nSummary = textLabel(page, {
		Name = "Summary",
		TextSize = T.small,
		TextColor3 = C.dim,
		Size = UDim2.new(1, 0, 0, 16),
	})
	local columns = {
		{ title = "channel", width = 0 },
		{ title = "dir", width = 34 },
		{ title = "per s", width = 70 },
		{ title = "pkt/s", width = 50 },
		{ title = "avg", width = 56 },
		{ title = "peak", width = 70 },
	}
	headerRow(page, columns, 18)
	self.ui.net = newPool(page, columns, 48, 34)
end

function Overlay._buildMemory(self: Overlay, page: Frame)
	local ui = self.ui
	local stats = make("Frame", { Name = "Stats", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 36) }, page)
	ui.mTotal = statCell(stats, "total MB", 0, 0.25)
	ui.mHeap = statCell(stats, "Luau heap MB", 0.25, 0.25)
	ui.mGarbage = statCell(stats, "garbage KB/s", 0.5, 0.25)
	ui.mInstances = statCell(stats, "instances", 0.75, 0.25)
	local columns = {
		{ title = "tag", width = 0 },
		{ title = "MB", width = 64 },
		{ title = "share", width = 56 },
	}
	headerRow(page, columns, 40)
	ui.mem = newPool(page, columns, 32, 56)
end

function Overlay._buildPlayers(self: Overlay, page: Frame)
	self.ui.pSummary = textLabel(page, {
		Name = "Summary",
		TextSize = T.small,
		TextColor3 = C.dim,
		Size = UDim2.new(1, 0, 0, 16),
	})
	local columns = {
		{ title = "device", width = 0 },
		{ title = "n", width = 34 },
		{ title = "p50", width = 46 },
		{ title = "p95", width = 46 },
		{ title = "p99", width = 46 },
		{ title = "script", width = 50 },
		{ title = "MB", width = 46 },
		{ title = "ping", width = 42 },
	}
	headerRow(page, columns, 18)
	self.ui.players = newPool(page, columns, 40, 34)
end

--------------------------------------------------------------------------------
-- Layout
--------------------------------------------------------------------------------

function Overlay._layoutTabs(self: Overlay)
	local ui = self.ui
	local hints = UserInputService.GamepadEnabled == true
	if hints == ui.hints and ui.hintsSet then
		return
	end
	ui.hints = hints
	ui.hintsSet = true
	ui.lbHint.Visible = hints
	ui.rbHint.Visible = hints
	if hints then
		ui.tabHolder.Position = UDim2.fromOffset(28, 0)
		ui.tabHolder.Size = UDim2.new(1, -56, 1, 0)
	else
		ui.tabHolder.Position = UDim2.fromOffset(0, 0)
		ui.tabHolder.Size = UDim2.fromScale(1, 1)
	end
end

-- Scales the panel for the viewport and puts it in the chosen corner.
function Overlay._place(self: Overlay)
	local ui = self.ui
	local camera = workspace.CurrentCamera
	local viewport = if camera then camera.ViewportSize else nil
	if viewport == nil then
		viewport = Vector2.new(1280, 720)
	end
	self.viewport = viewport
	local vp = viewport :: Vector2
	local tenFoot = GuiService:IsTenFootInterface()
	ui.scale.Scale = Theme.scaleFor(vp.X, vp.Y, tenFoot, ui.touch)

	local m, top = S.margin, S.topInset
	local i = self.cornerIndex
	if i == 1 then
		ui.panel.AnchorPoint = Vector2.new(0, 0)
		ui.panel.Position = UDim2.fromOffset(m, top)
	elseif i == 2 then
		ui.panel.AnchorPoint = Vector2.new(1, 0)
		ui.panel.Position = UDim2.new(1, -m, 0, top)
	elseif i == 3 then
		ui.panel.AnchorPoint = Vector2.new(1, 1)
		ui.panel.Position = UDim2.new(1, -m, 1, -m)
	else
		ui.panel.AnchorPoint = Vector2.new(0, 1)
		ui.panel.Position = UDim2.new(0, m, 1, -m)
	end
end

--------------------------------------------------------------------------------
-- Public
--------------------------------------------------------------------------------

function Overlay.setVisible(self: Overlay, visible: boolean)
	if self.destroyed or visible == self.visible then
		return
	end
	if visible and not self.built then
		local ok, err = pcall(self._build, self)
		if not ok then
			-- never break the game: report once and stay closed
			self.errors += 1
			self.lastError = tostring(err)
			warn("[Lighthouse] overlay could not be built: " .. tostring(err))
			if self.gui then
				self.gui:Destroy()
				self.gui = nil
			end
			for _, c in self.connections do
				c:Disconnect()
			end
			table.clear(self.connections)
			self.built = false
			return
		end
	end
	self.visible = visible
	local gui = self.gui :: ScreenGui
	gui.Enabled = visible
	if visible then
		self.acc = 0
		self:setTab(self.tab)
		self.heartbeat = RunService.Heartbeat:Connect(function(dt: number)
			self.acc += dt
			if self.acc >= REFRESH then
				self.acc = math.min(self.acc - REFRESH, REFRESH)
				self:refresh()
			end
		end)
	else
		if self.heartbeat then
			self.heartbeat:Disconnect()
			self.heartbeat = nil
		end
		-- Give gamepad focus back to the game if it was inside the panel.
		local selected = GuiService.SelectedObject
		if selected and selected:IsDescendantOf(gui) then
			GuiService.SelectedObject = nil
		end
	end
end

function Overlay.isVisible(self: Overlay): boolean
	return self.visible
end

function Overlay.setTab(self: Overlay, index: number)
	local n = #TAB_NAMES
	index = ((index - 1) % n) + 1
	self.tab = index
	if not self.built then
		return
	end
	local ui = self.ui
	for i, b in ui.tabButtons do
		local active = i == index
		b.BackgroundColor3 = if active then C.tabActive else C.tab
		b.TextColor3 = if active then C.tabTextActive else C.tabText
		ui.pages[i].Visible = active
	end
	-- Keep gamepad selection on the tab bar when it was there.
	local selected = GuiService.SelectedObject
	if selected and table.find(ui.tabButtons, selected) then
		GuiService.SelectedObject = ui.tabButtons[index]
	end
	if self.visible then
		self:refresh()
	end
end

function Overlay.setSide(self: Overlay, side: string)
	if side ~= "client" and side ~= "server" then
		return
	end
	self.side = side
	if self.built then
		self.ui.sideButton.Text = side
		if self.visible then
			self:refresh()
		end
	end
end

function Overlay.destroy(self: Overlay)
	if self.destroyed then
		return
	end
	self:setVisible(false)
	self.destroyed = true
	for _, c in self.connections do
		c:Disconnect()
	end
	table.clear(self.connections)
	if self.gui then
		self.gui:Destroy()
		self.gui = nil
	end
	if self.ui.selection then
		self.ui.selection:Destroy()
	end
	self.ui = {}
end

-- Reads the sources and writes the active tab. Called at 4 Hz while visible; never throws.
function Overlay.refresh(self: Overlay)
	if not self.built or self.destroyed then
		return
	end
	local ok, err = pcall(self._refresh, self)
	self.refreshes += 1
	if not ok then
		self.errors += 1
		self.lastError = tostring(err)
	end
end

local function read(self: Overlay, what: string): any
	local ok, value = pcall(self.source, what)
	if ok and type(value) == "table" then
		return value
	end
	return nil
end

function Overlay._refresh(self: Overlay)
	local ui = self.ui
	local camera = workspace.CurrentCamera
	if camera and camera.ViewportSize ~= self.viewport then
		self:_place()
	end
	self:_layoutTabs()

	local tab = self.tab
	local snap = read(self, self.side)

	-- header info line
	if snap then
		local info = tostring(snap.device or snap.side or self.side)
		if snap.players then
			info = string.format("%s  %d players", info, num(snap.players))
		end
		self:_text(ui.info, info)
	else
		self:_text(ui.info, "")
	end

	if tab == 5 then
		local telemetry = read(self, "telemetry")
		if telemetry == nil then
			local server = if self.side == "server" then snap else read(self, "server")
			telemetry = server and type(server.reports) == "table" and server.reports or nil
		end
		self:_showMessage(nil)
		self:_updatePlayers(telemetry)
		return
	end

	if snap == nil then
		self:_showMessage(if self.side == "server"
			then "No server numbers yet.\nThe server streams them to viewers only (see the viewers option)."
			else "Waiting for the first client snapshot.")
		return
	end
	self:_showMessage(nil)

	if tab == 1 then
		self:_updateFrame(snap)
	elseif tab == 2 then
		self:_updateProbes(snap)
	elseif tab == 3 then
		self:_updateNetwork(snap)
	else
		self:_updateMemory(snap)
	end
end

function Overlay._showMessage(self: Overlay, text: string?)
	local ui = self.ui
	local show = text ~= nil
	if ui.message.Visible ~= show then
		ui.message.Visible = show
	end
	if text then
		self:_text(ui.message, text)
	end
	local page = ui.pages[self.tab]
	if page.Visible == show then
		page.Visible = not show
	end
end

--------------------------------------------------------------------------------
-- Tabs
--------------------------------------------------------------------------------

function Overlay._updateFrame(self: Overlay, snap: any)
	local ui = self.ui
	local frame = if type(snap.frame) == "table" then snap.frame else {}
	local budget = budgetMs(frame)

	local function stat(label: TextLabel, v: any)
		self:_text(label, fmtMs(v))
		self:_color(label, if type(v) == "number" then Theme.frameColor(v, budget) else C.dim)
	end
	stat(ui.fLast, frame.last)
	stat(ui.fP50, frame.p50)
	stat(ui.fP95, frame.p95)
	stat(ui.fP99, frame.p99)
	self:_text(ui.fFps, if type(frame.fps) == "number" then string.format("%.0f", frame.fps) else "-")

	local frameMs = num(frame.avg1)
	if frameMs <= 0 then
		frameMs = num(frame.last)
	end
	local scriptMs = num(frame.scriptMs)
	local frac = if frameMs > 0 then math.clamp(scriptMs / frameMs, 0, 1) else 0
	self:_text(
		ui.fScript,
		string.format(
			"script %s ms of %s ms frame (%d%%)   unmeasured %s ms   budget %s",
			fmtMs(scriptMs),
			fmtMs(frameMs),
			math.floor(frac * 100 + 0.5),
			fmtMs(math.max(frameMs - scriptMs, 0)),
			fmtMs(budget)
		)
	)
	frac = math.floor(frac * 200 + 0.5) / 200
	if ui.fSplitFrac ~= frac then
		ui.fSplitFrac = frac
		ui.fSplit.Size = UDim2.fromScale(frac, 1)
	end

	ui.graph:set(if type(frame.history) == "table" then frame.history else nil, budget)

	local flares = if type(snap.flares) == "table" then snap.flares else {}
	local n = #flares
	self:_text(ui.fFlareTitle, if n > 0 then string.format("flares (%d, newest first)", n) else "flares: none")
	local now = num(snap.t)
	for i = 1, FLARE_ROWS do
		local label = ui.fFlares[i]
		local flare = flares[i] -- Snapshot.flares is newest first
		if type(flare) == "table" then
			local parts = {}
			if type(flare.top) == "table" then
				for j = 1, math.min(#flare.top, 3) do
					local top = flare.top[j]
					if type(top) == "table" then
						parts[#parts + 1] = string.format("%s %s", tostring(top.name or top[1]), fmtMs(top.ms or top.selfMs or top[2]))
					end
				end
			end
			local age = if now > 0 and type(flare.t) == "number" then math.max(now - flare.t, 0) else nil
			self:_text(
				label,
				string.format(
					"%6s ms  %5s  %s",
					fmtMs(flare.frameMs),
					if age then string.format("-%ds", math.floor(age)) else "",
					table.concat(parts, ", ")
				)
			)
			self:_color(label, Theme.frameColor(num(flare.frameMs), budget))
		else
			self:_text(label, "")
		end
	end
end

-- Probes grouped by their dot prefix ("Crowd.Step" and "Crowd.Path" under "Crowd").
function Overlay._updateProbes(self: Overlay, snap: any)
	local pool: Pool = self.ui.probes
	local probes = if type(snap.probes) == "table" then snap.probes else {}

	local groups = {}
	local order = {}
	local maxSelf = 0
	for _, p in probes do
		if type(p) == "table" and type(p.name) == "string" then
			local selfAvg = num(p.selfAvg)
			if selfAvg > maxSelf then
				maxSelf = selfAvg
			end
			local prefix = string.match(p.name, "^([^%.]+)%.") or p.name
			local g = groups[prefix]
			if g == nil then
				g = { name = prefix, self = 0, total = 0, items = {} }
				groups[prefix] = g
				order[#order + 1] = g
			end
			g.self += selfAvg
			g.items[#g.items + 1] = p
		end
	end
	table.sort(order, function(a, b)
		return a.self > b.self
	end)

	local capacity = #pool.rows
	local function full(): boolean
		return pool.used >= capacity - 1
	end
	local skipped = 0

	local function probeRow(p: any, kind: string, name: string)
		local row = self:_row(pool, kind, if maxSelf > 0 then num(p.selfAvg) / maxSelf else 0)
		if row then
			local cells = row.cells
			self:_text(cells[1], name)
			self:_text(cells[2], fmtMs(p.selfAvg))
			self:_text(cells[3], fmtMs(p.selfP95))
			self:_text(cells[4], fmtMs(p.totalAvg))
			self:_text(cells[5], fmtCount(p.calls))
		end
	end

	for _, g in order do
		local items = g.items
		if #items == 1 and items[1].name == g.name then
			if full() then
				skipped += 1
			else
				probeRow(items[1], "plain", g.name)
			end
		else
			if full() then
				skipped += #items
			else
				local row = self:_row(pool, "group", 0)
				if row then
					local cells = row.cells
					self:_text(cells[1], g.name)
					self:_text(cells[2], fmtMs(g.self))
					self:_text(cells[3], "")
					self:_text(cells[4], "")
					self:_text(cells[5], string.format("%d", #items))
				end
				for _, p in items do
					if full() then
						skipped += 1
					else
						probeRow(p, "item", "  " .. string.sub(p.name, #g.name + 2))
					end
				end
			end
		end
	end

	-- counters and gauges
	local counters = if type(snap.counters) == "table" then snap.counters else {}
	if #counters > 0 and not full() then
		local row = self:_row(pool, "group", 0)
		if row then
			self:_text(row.cells[1], "counters")
			self:_text(row.cells[2], "per s")
			for c = 3, 5 do
				self:_text(row.cells[c], "")
			end
		end
		for _, c in counters do
			if full() then
				skipped += 1
			elseif type(c) == "table" then
				local r = self:_row(pool, "item", 0)
				if r then
					self:_text(r.cells[1], "  " .. tostring(c.name))
					self:_text(r.cells[2], fmtCount(c.perSec))
					for k = 3, 5 do
						self:_text(r.cells[k], "")
					end
				end
			end
		end
	end
	local gauges = if type(snap.gauges) == "table" then snap.gauges else {}
	if #gauges > 0 and not full() then
		local row = self:_row(pool, "group", 0)
		if row then
			self:_text(row.cells[1], "gauges")
			self:_text(row.cells[2], "value")
			self:_text(row.cells[3], "min")
			self:_text(row.cells[4], "max")
			self:_text(row.cells[5], "")
		end
		for _, gauge in gauges do
			if full() then
				skipped += 1
			elseif type(gauge) == "table" then
				local r = self:_row(pool, "item", 0)
				if r then
					self:_text(r.cells[1], "  " .. tostring(gauge.name))
					self:_text(r.cells[2], fmtCount(gauge.value))
					self:_text(r.cells[3], fmtCount(gauge.min))
					self:_text(r.cells[4], fmtCount(gauge.max))
					self:_text(r.cells[5], "")
				end
			end
		end
	end

	if pool.used == 0 then
		self:_note(pool, "No probes yet. Add one with Lighthouse.probe, wrap or bind.")
	elseif skipped > 0 then
		self:_note(pool, overflowText(skipped))
	elseif num(snap.misuse) > 0 then
		self:_note(pool, string.format("%d probe misuses repaired (finish without begin)", num(snap.misuse)))
	end
	self:_finish(pool)
end

function Overlay._updateNetwork(self: Overlay, snap: any)
	local ui = self.ui
	local pool: Pool = ui.net
	local engine = if type(snap.engine) == "table" then snap.engine else {}
	self:_text(
		ui.nSummary,
		string.format(
			"engine recv %.1f KB/s  send %.1f KB/s  ping %s ms",
			num(engine.recvKbps) / 8,
			num(engine.sendKbps) / 8,
			if type(engine.ping) == "number" then string.format("%.0f", engine.ping) else "-"
		)
	)

	local libs = {}
	local order = {}
	local peakBps = 0
	for _, ch in (if type(snap.net) == "table" then snap.net else {}) do
		if type(ch) == "table" then
			local lib = tostring(ch.lib or "?")
			local g = libs[lib]
			if g == nil then
				g = { name = lib, bpsIn = 0, bpsOut = 0, pps = 0, items = {} }
				libs[lib] = g
				order[#order + 1] = g
			end
			local bps = num(ch.bps)
			if ch.dir == "in" then
				g.bpsIn += bps
			else
				g.bpsOut += bps
			end
			g.pps += num(ch.pps)
			if bps > peakBps then
				peakBps = bps
			end
			g.items[#g.items + 1] = ch
		end
	end
	table.sort(order, function(a, b)
		return a.bpsIn + a.bpsOut > b.bpsIn + b.bpsOut
	end)

	local capacity = #pool.rows
	local skipped = 0
	for _, g in order do
		table.sort(g.items, function(a, b)
			return num(a.bps) > num(b.bps)
		end)
		if pool.used >= capacity - 1 then
			skipped += #g.items
			continue
		end
		local row = self:_row(pool, "group", 0)
		if row then
			local cells = row.cells
			self:_text(cells[1], g.name)
			self:_text(cells[2], "")
			self:_text(cells[3], fmtBytes(g.bpsIn + g.bpsOut))
			self:_text(cells[4], fmtCount(g.pps))
			self:_text(cells[5], string.format("in %s", fmtBytes(g.bpsIn)))
			self:_text(cells[6], string.format("out %s", fmtBytes(g.bpsOut)))
		end
		for _, ch in g.items do
			if pool.used >= capacity - 1 then
				skipped += 1
				continue
			end
			local r = self:_row(pool, "item", if peakBps > 0 then num(ch.bps) / peakBps else 0)
			if r then
				local cells = r.cells
				self:_text(cells[1], "  " .. tostring(ch.channel or "?"))
				self:_text(cells[2], if ch.dir == "in" then "in" else "out")
				self:_text(cells[3], fmtBytes(ch.bps))
				self:_text(cells[4], fmtCount(ch.pps))
				self:_text(cells[5], fmtBytes(ch.avg))
				self:_text(cells[6], fmtBytes(ch.peak))
			end
		end
	end
	if pool.used == 0 then
		self:_note(pool, "No channels yet. Current, Ripple and Tide report here; use Lighthouse.net for your own.")
	elseif skipped > 0 then
		self:_note(pool, overflowText(skipped))
	end
	self:_finish(pool)
end

function Overlay._updateMemory(self: Overlay, snap: any)
	local ui = self.ui
	local pool: Pool = ui.mem
	local memory = if type(snap.memory) == "table" then snap.memory else {}
	local engine = if type(snap.engine) == "table" then snap.engine else {}
	local total = num(memory.totalMb)

	self:_text(ui.mTotal, fmtMb(total))
	self:_text(ui.mHeap, fmtMb(memory.luaHeapMb))
	local garbage = num(memory.gcKbPerSec)
	self:_text(ui.mGarbage, string.format("%.0f", garbage))
	self:_color(
		ui.mGarbage,
		if garbage >= Theme.limits.garbageBadKbPerSec
			then C.bad
			elseif garbage >= Theme.limits.garbageWarnKbPerSec then C.warn
			else C.good
	)
	self:_text(ui.mInstances, if type(engine.instances) == "number" then fmtCount(engine.instances) else "-")

	local tags = {}
	if type(memory.tags) == "table" then
		for tag, mb in memory.tags do
			if type(mb) == "number" then
				tags[#tags + 1] = { tag = tostring(tag), mb = mb }
			end
		end
	end
	table.sort(tags, function(a, b)
		return a.mb > b.mb
	end)
	local capacity = #pool.rows
	for i, t in tags do
		if pool.used >= capacity - 1 then
			self:_note(pool, overflowText(#tags - i + 1))
			break
		end
		local row = self:_row(pool, "plain", if total > 0 then t.mb / total else 0)
		if row then
			self:_text(row.cells[1], t.tag)
			self:_text(row.cells[2], fmtMb(t.mb))
			self:_text(row.cells[3], if total > 0 then string.format("%.0f%%", t.mb / total * 100) else "-")
		end
	end
	if #tags == 0 then
		self:_note(pool, "No memory tags yet (read once per second).")
	end
	self:_finish(pool)
end

function Overlay._updatePlayers(self: Overlay, telemetry: any)
	local ui = self.ui
	local pool: Pool = ui.players
	if telemetry == nil then
		self:_text(ui.pSummary, "Player telemetry is off.")
		self:_note(pool, "Turn it on with Lighthouse.start({ telemetry = true }) on the server.")
		self:_note(pool, "Only viewers receive the aggregate.")
		self:_finish(pool)
		return
	end
	self:_text(
		ui.pSummary,
		string.format(
			"%d players reporting, %d reports, %d dropped",
			num(telemetry.players),
			num(telemetry.reports),
			num(telemetry.dropped)
		)
	)
	local devices = if type(telemetry.devices) == "table" then telemetry.devices else {}
	local maxPlayers = 0
	for _, d in devices do
		if type(d) == "table" and num(d.players) > maxPlayers then
			maxPlayers = num(d.players)
		end
	end
	local capacity = #pool.rows
	for _, d in devices do
		if type(d) ~= "table" or pool.used >= capacity - 1 then
			continue
		end
		local row = self:_row(pool, "group", if maxPlayers > 0 then num(d.players) / maxPlayers else 0)
		if row then
			local cells = row.cells
			self:_text(cells[1], tostring(d.device or "?"))
			self:_text(cells[2], fmtCount(d.players))
			self:_text(cells[3], fmtMs(d.frameP50))
			self:_text(cells[4], fmtMs(d.frameP95))
			self:_text(cells[5], fmtMs(d.frameP99))
			self:_text(cells[6], fmtMs(d.scriptP50))
			self:_text(cells[7], fmtMb(d.memoryMb))
			self:_text(cells[8], if type(d.pingMs) == "number" then string.format("%.0f", d.pingMs) else "-")
			-- colour p95 against a 60 fps budget
			self:_color(cells[4], if type(d.frameP95) == "number" then Theme.frameColor(d.frameP95, 1000 / 60) else C.text)
		end
		if type(d.probes) == "table" and #d.probes > 0 and pool.used < capacity - 1 then
			local parts = {}
			for j = 1, math.min(#d.probes, 4) do
				local p = d.probes[j]
				if type(p) == "table" then
					parts[#parts + 1] = string.format("%s %s", tostring(p.name), fmtMs(p.ms))
				end
			end
			self:_note(pool, "  top: " .. table.concat(parts, ", "))
		end
	end
	if #devices == 0 then
		self:_note(pool, "No reports yet. Sampled clients report every `every` seconds.")
	end
	self:_finish(pool)
end

return Overlay
