--!strict
-- Pooled bar graph for the frame-time history. All Instances are made in Graph.new;
-- Graph:set only writes properties, so a refresh creates nothing.

local Theme = require(script.Parent.Theme)

local Graph = {}
Graph.__index = Graph

export type Graph = typeof(setmetatable(
	{} :: {
		frame: Frame,
		bars: { Frame },
		heights: { number },
		colors: { Color3 },
		budgetLine: Frame,
		budgetLabel: TextLabel,
		maxLabel: TextLabel,
		count: number,
		scaleMs: number,
		budgetMs: number,
	},
	Graph
))

-- Rounds the graph's top up to a readable value (ms).
local STEPS = { 20, 25, 33.4, 40, 50, 66.7, 100, 150, 200, 300, 500, 1000, 2000 }
local function niceTop(ms: number): number
	for _, step in STEPS do
		if ms <= step then
			return step
		end
	end
	return math.ceil(ms / 1000) * 1000
end

local function label(parent: Instance, name: string, anchorY: number): TextLabel
	local l = Instance.new("TextLabel")
	l.Name = name
	l.BackgroundTransparency = 1
	l.Font = Theme.fonts.mono
	l.TextSize = Theme.text.small
	l.TextColor3 = Theme.colors.dim
	l.TextXAlignment = Enum.TextXAlignment.Right
	l.AnchorPoint = Vector2.new(1, anchorY)
	l.Size = UDim2.fromOffset(80, 14)
	l.ZIndex = 4
	l.Parent = parent
	return l
end

function Graph.new(parent: Instance, count: number): Graph
	local frame = Instance.new("Frame")
	frame.Name = "Graph"
	frame.BackgroundColor3 = Theme.colors.barBack
	frame.BackgroundTransparency = 0.35
	frame.BorderSizePixel = 0
	frame.ClipsDescendants = true
	frame.Parent = parent

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 4)
	corner.Parent = frame

	local bars = table.create(count)
	local width = 1 / count
	for i = 1, count do
		local bar = Instance.new("Frame")
		bar.Name = "B"
		bar.BorderSizePixel = 0
		bar.AnchorPoint = Vector2.new(0, 1)
		-- 1 px gap between bars where there is room for it
		bar.Position = UDim2.new((i - 1) * width, 0, 1, 0)
		bar.Size = UDim2.new(width, -1, 0, 0)
		bar.BackgroundColor3 = Theme.colors.good
		bar.ZIndex = 2
		bar.Parent = frame
		bars[i] = bar
	end

	local budgetLine = Instance.new("Frame")
	budgetLine.Name = "Budget"
	budgetLine.BorderSizePixel = 0
	budgetLine.BackgroundColor3 = Theme.colors.budgetLine
	budgetLine.BackgroundTransparency = 0.5
	budgetLine.AnchorPoint = Vector2.new(0, 0.5)
	budgetLine.Size = UDim2.new(1, 0, 0, 1)
	budgetLine.Position = UDim2.fromScale(0, 0.5)
	budgetLine.ZIndex = 3
	budgetLine.Parent = frame

	local self = setmetatable({
		frame = frame,
		bars = bars,
		heights = table.create(count, -1),
		colors = table.create(count, Theme.colors.good),
		budgetLine = budgetLine,
		budgetLabel = label(frame, "BudgetLabel", 1),
		maxLabel = label(frame, "MaxLabel", 0),
		count = count,
		scaleMs = 0,
		budgetMs = 0,
	}, Graph)
	self.maxLabel.Position = UDim2.new(1, -4, 0, 2)
	return self
end

-- history: frame times in ms, oldest first (the newest is drawn on the right).
-- budgetMs: frame budget in ms.
function Graph.set(self: Graph, history: { number }?, budgetMs: number)
	local count = self.count
	local n = if history then #history else 0
	local first = math.max(1, n - count + 1)
	local shown = n - first + 1

	-- Scale: at least twice the budget, so the budget line sits at half height or lower.
	local peak = budgetMs * 2
	for i = first, n do
		local v = (history :: { number })[i]
		if type(v) == "number" and v > peak and v < math.huge then
			peak = v
		end
	end
	local top = niceTop(peak)
	if top ~= self.scaleMs or budgetMs ~= self.budgetMs then
		self.scaleMs = top
		self.budgetMs = budgetMs
		self.maxLabel.Text = string.format("%g ms", top)
		local y = 1 - budgetMs / top
		self.budgetLine.Position = UDim2.fromScale(0, y)
		self.budgetLabel.Position = UDim2.new(1, -4, y, -1)
		self.budgetLabel.Text = string.format("%.1f", budgetMs)
	end

	local bars, heights, colors = self.bars, self.heights, self.colors
	local offset = count - shown -- right-align when the history is short
	for i = 1, count do
		local h = 0
		local color = Theme.colors.good
		local src = i - offset
		if src >= 1 then
			local ms = (history :: { number })[first + src - 1]
			if type(ms) ~= "number" or ms ~= ms or ms < 0 then -- NaN, negative or junk: draw nothing
				ms = 0
			elseif ms == math.huge then
				ms = top
			end
			h = math.min(ms / top, 1)
			-- quantize so tiny changes do not rewrite the property
			h = math.floor(h * 200 + 0.5) / 200
			color = Theme.frameColor(ms, budgetMs)
		end
		if heights[i] ~= h then
			heights[i] = h
			bars[i].Size = UDim2.new(1 / count, -1, h, 0)
		end
		if colors[i] ~= color then
			colors[i] = color
			bars[i].BackgroundColor3 = color
		end
	end
end

function Graph.destroy(self: Graph)
	self.frame:Destroy()
end

return Graph
