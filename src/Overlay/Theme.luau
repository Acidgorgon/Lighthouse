--!strict
-- Colours, fonts and sizes for the Lighthouse overlay.
-- Sizes are in design units: the panel is laid out at DESIGN_W x DESIGN_H and a UIScale
-- (see Theme.scaleFor) makes it bigger on TVs and fits it on small phones. Text uses fixed
-- TextSize (never TextScaled), so text never resizes per update and never drops below
-- MIN_TEXT * scale on screen.

local Theme = {}

local rgb = Color3.fromRGB

Theme.colors = {
	panel = rgb(14, 16, 21),
	panelTransparency = 0.12,
	header = rgb(22, 25, 32),
	row = rgb(28, 32, 40),
	rowAlt = rgb(22, 25, 32),
	stroke = rgb(245, 177, 61),
	strokeTransparency = 0.55,

	accent = rgb(245, 177, 61), -- beacon amber
	accentDim = rgb(150, 110, 45),
	text = rgb(232, 230, 225),
	dim = rgb(150, 152, 160),
	faint = rgb(95, 98, 108),

	good = rgb(76, 195, 138), -- under budget
	warn = rgb(245, 177, 61), -- over budget
	bad = rgb(239, 91, 91), -- over 2x budget

	tab = rgb(30, 34, 43),
	tabActive = rgb(245, 177, 61),
	tabText = rgb(190, 192, 198),
	tabTextActive = rgb(20, 16, 8),

	bar = rgb(245, 177, 61),
	barBack = rgb(38, 42, 52),
	budgetLine = rgb(232, 230, 225),
}

-- Fonts: monospace for numbers so columns do not jump, a sans font for words.
-- Enum items that do not exist error when indexed, so newer fonts are read in a pcall.
local function font(name: string, fallback: Enum.Font): Enum.Font
	local ok, value = pcall(function()
		return (Enum.Font :: any)[name]
	end)
	return if ok and value ~= nil then value else fallback
end

Theme.fonts = {
	mono = Enum.Font.RobotoMono,
	text = font("BuilderSansMedium", Enum.Font.GothamMedium),
	bold = font("BuilderSansBold", Enum.Font.GothamBold),
}

Theme.text = {
	title = 16,
	body = 14,
	row = 13,
	small = 12,
	MIN_TEXT = 12,
}

Theme.size = {
	DESIGN_W = 460,
	DESIGN_H = 330,
	header = 30,
	tabs = 28,
	row = 18,
	pad = 8,
	corner = 8,
	margin = 12,
	topInset = 64, -- below the Roblox top bar (the ScreenGui ignores the inset)
}

-- Thresholds that colour numbers.
Theme.limits = {
	garbageWarnKbPerSec = 500, -- Luau garbage rate that usually shows up as GC time
	garbageBadKbPerSec = 2000,
}

-- Picks the UIScale for a viewport.
--   tenFoot: console / TV (10-foot UI): large, readable from a couch
--   touch:   touch device without a keyboard: fit the screen, never below 0.72
--   else:    desktop: 1, or 1.25 on very tall viewports
function Theme.scaleFor(viewportX: number, viewportY: number, tenFoot: boolean, touch: boolean): number
	local w, h = Theme.size.DESIGN_W, Theme.size.DESIGN_H
	if tenFoot then
		local fit = math.min((viewportX - 2 * Theme.size.margin) / w, (viewportY - Theme.size.topInset - 24) / h)
		return math.clamp(math.min(1.5, fit), 1, 1.5)
	end
	if touch then
		local fit = math.min((viewportX - 2 * Theme.size.margin) / w, (viewportY - Theme.size.topInset) / h)
		return math.clamp(fit, 0.72, 1.1)
	end
	if viewportY >= 1300 then
		return 1.25
	end
	return 1
end

-- Colour of a frame time against the budget (both in ms).
function Theme.frameColor(ms: number, budgetMs: number): Color3
	if ms <= budgetMs then
		return Theme.colors.good
	elseif ms <= budgetMs * 2 then
		return Theme.colors.warn
	end
	return Theme.colors.bad
end

return Theme
