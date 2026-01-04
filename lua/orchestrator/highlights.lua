-- Highlights Module
-- Color palette and highlight group definitions
-- Styled for winbar with flat lualine-style backgrounds

---@class HighlightsModule
local M = {}

-- Base colors (from wine theme)
M.colors = {
	white = "#DDDDDD", -- fg_primary from wine theme
	black = "#131313", -- bg_primary from wine theme
	yellow = "#fdd888", -- func from wine theme
	winbar_bg = "#1a1a1a", -- slightly lighter than black for winbar background
}

-- Instance color palette (8 distinct colors for Claude instances)
-- Wine theme colors: mix of syntax and terminal colors
M.instance_colors = {
	{ name = "Func", fg = "#fdd888" }, -- warm yellow (syntax)
	{ name = "Blue", fg = "#6d94e9" }, -- accent blue (terminal)
	{ name = "Green", fg = "#62BA46" }, -- string green (syntax)
	{ name = "Magenta", fg = "#D86DE9" }, -- bright magenta (terminal)
	{ name = "Orange", fg = "#c75828" }, -- type color (syntax)
	{ name = "Cyan", fg = "#5BDFD8" }, -- bright cyan (terminal)
	{ name = "Amber", fg = "#c28b12" }, -- keyword amber (syntax)
	{ name = "Peach", fg = "#E19773" }, -- variable peach (syntax)
}

-- Dim factor for inactive agents (0.55 = 55% brightness)
local DIM_FACTOR = 0.55

--- Dim a hex color by reducing its RGB values
--- @param hex string Hex color like "#FF6B6B"
--- @param factor number Multiplier (0.0-1.0)
--- @return string dimmed_hex
local function dim_color(hex, factor)
	local r = tonumber(hex:sub(2, 3), 16)
	local g = tonumber(hex:sub(4, 5), 16)
	local b = tonumber(hex:sub(6, 7), 16)
	r = math.floor(r * factor)
	g = math.floor(g * factor)
	b = math.floor(b * factor)
	return string.format("#%02X%02X%02X", r, g, b)
end

--- Setup all highlight groups
--- Call this during plugin setup
function M.setup()
	-- Winbar base highlight (solid background spanning full width)
	vim.api.nvim_set_hl(0, "OrchestratorWinbar", {
		fg = M.colors.white,
		bg = M.colors.winbar_bg,
	})

	-- Winbar text (for labels and separators)
	vim.api.nvim_set_hl(0, "OrchestratorWinbarText", {
		fg = M.colors.white,
		bg = M.colors.winbar_bg,
	})

	-- Winbar separator between instances
	vim.api.nvim_set_hl(0, "OrchestratorWinbarSep", {
		fg = "#555555",
		bg = M.colors.winbar_bg,
	})

	-- Create highlight groups for each instance color
	-- OrchestratorClaude1 through OrchestratorClaude8
	for i, color in ipairs(M.instance_colors) do
		-- Dimmed variants for inactive agents
		local dimmed_fg = dim_color(color.fg, DIM_FACTOR)

		-- Active instance: dark text on colored background (full brightness)
		vim.api.nvim_set_hl(0, "OrchestratorClaude" .. i .. "Active", {
			fg = M.colors.black,
			bg = color.fg,
			bold = true,
		})

		-- Inactive instance: dark text on dimmed colored background
		vim.api.nvim_set_hl(0, "OrchestratorClaude" .. i .. "Dim", {
			fg = M.colors.black,
			bg = dimmed_fg,
			bold = true,
		})

		-- Simple colored text variant (used in picker, etc.)
		vim.api.nvim_set_hl(0, "OrchestratorClaude" .. i, {
			fg = color.fg,
			bg = "none",
			bold = true,
		})
	end
end

--- Get highlight group name for active instance (full brightness background)
--- @param color_idx number Color index (1-8)
--- @return string highlight_group
function M.get_instance_active_highlight(color_idx)
	return "OrchestratorClaude" .. color_idx .. "Active"
end

--- Get highlight group name for inactive instance (dimmed background)
--- @param color_idx number Color index (1-8)
--- @return string highlight_group
function M.get_instance_dim_highlight(color_idx)
	return "OrchestratorClaude" .. color_idx .. "Dim"
end

--- Get highlight group name for colored text (no background)
--- @param color_idx number Color index (1-8)
--- @return string highlight_group
function M.get_instance_highlight(color_idx)
	return "OrchestratorClaude" .. color_idx
end

--- Get color name for display (e.g., in picker)
--- @param color_idx number Color index (1-8)
--- @return string color_name
function M.get_color_name(color_idx)
	local color = M.instance_colors[color_idx]
	return color and color.name or "Unknown"
end

return M
