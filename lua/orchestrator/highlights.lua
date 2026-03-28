-- Highlights Module
-- Color palette and highlight group definitions
-- Styled for winbar with flat lualine-style backgrounds

---@class HighlightsModule
local M = {}

-- Base colors (from wine theme)
M.colors = {
	white = "#C2C2C2", -- matched to lualine terminal mode text
	black = "#131313", -- bg_primary from wine theme
	yellow = "#fdd888", -- func from wine theme
	matte_charcoal = "#1f1f1f", -- Symmetria matte pill background
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

--- Validate and normalize color index to valid range (1-8)
--- @param color_idx number|nil Raw color index
--- @return number valid_idx Validated index (defaults to 1 if invalid)
local function validate_color_idx(color_idx)
	if type(color_idx) ~= "number" or color_idx < 1 or color_idx > 8 then
		return 1
	end
	return math.floor(color_idx)
end

--- Setup all highlight groups
--- Call this during plugin setup
function M.setup()
	-- Override Neovim's default WinBar highlights for transparency
	-- In Neovim 0.10+, WinBar is linked to StatusLine by default which may have a background
	-- We explicitly set these to ensure transparent winbar background
	vim.api.nvim_set_hl(0, "WinBar", {
		fg = M.colors.white,
		bg = "NONE",
	})
	vim.api.nvim_set_hl(0, "WinBarNC", {
		fg = M.colors.white,
		bg = "NONE",
	})

	-- Winbar base highlight (transparent background)
	vim.api.nvim_set_hl(0, "OrchestratorWinbar", {
		fg = M.colors.white,
		bg = "NONE",
	})

	-- Create highlight groups for each instance color
	-- OrchestratorClaude1 through OrchestratorClaude8
	local dimmed_white = dim_color(M.colors.white, DIM_FACTOR)
	local dimmed_matte = dim_color(M.colors.matte_charcoal, DIM_FACTOR)

	for i, color in ipairs(M.instance_colors) do
		-- Active instance: full-brightness white text on matte charcoal
		vim.api.nvim_set_hl(0, "OrchestratorClaude" .. i .. "Active", {
			fg = M.colors.white,
			bg = M.colors.matte_charcoal,
			bold = true,
		})

		-- Active bubble cap: matte charcoal foreground on transparent (for powerline semicircles)
		vim.api.nvim_set_hl(0, "OrchestratorClaude" .. i .. "ActiveCap", {
			fg = M.colors.matte_charcoal,
			bg = "NONE",
		})

		-- Inactive instance: dimmed text + dimmed bg (simulates reduced opacity)
		vim.api.nvim_set_hl(0, "OrchestratorClaude" .. i .. "Dim", {
			fg = dimmed_white,
			bg = dimmed_matte,
		})

		-- Inactive bubble cap: dimmed matte foreground (pill fades with content)
		vim.api.nvim_set_hl(0, "OrchestratorClaude" .. i .. "DimCap", {
			fg = dimmed_matte,
			bg = "NONE",
		})

		-- Simple colored text variant (used in picker, etc.)
		vim.api.nvim_set_hl(0, "OrchestratorClaude" .. i, {
			fg = color.fg,
			bg = "none",
			bold = true,
		})
	end

	-- Spawn menu highlight groups
	vim.api.nvim_set_hl(0, "OrchestratorSpawnMenuKey", {
		fg = M.instance_colors[2].fg, -- Blue (#6d94e9)
		bold = true,
	})

	vim.api.nvim_set_hl(0, "OrchestratorSpawnMenuDanger", {
		fg = M.colors.yellow, -- Warning yellow (#fdd888)
		bold = true,
	})
end

--- Get highlight group name for active instance (full brightness background)
--- @param color_idx number Color index (1-8)
--- @return string highlight_group
function M.get_instance_active_highlight(color_idx)
	return "OrchestratorClaude" .. validate_color_idx(color_idx) .. "Active"
end

--- Get highlight group name for inactive instance (dimmed background)
--- @param color_idx number Color index (1-8)
--- @return string highlight_group
function M.get_instance_dim_highlight(color_idx)
	return "OrchestratorClaude" .. validate_color_idx(color_idx) .. "Dim"
end

--- Get highlight group name for active bubble cap (colored fg, transparent bg)
--- @param color_idx number Color index (1-8)
--- @return string highlight_group
function M.get_instance_active_cap_highlight(color_idx)
	return "OrchestratorClaude" .. validate_color_idx(color_idx) .. "ActiveCap"
end

--- Get highlight group name for inactive bubble cap (dimmed fg, transparent bg)
--- @param color_idx number Color index (1-8)
--- @return string highlight_group
function M.get_instance_dim_cap_highlight(color_idx)
	return "OrchestratorClaude" .. validate_color_idx(color_idx) .. "DimCap"
end

--- Get highlight group name for colored text (no background)
--- @param color_idx number Color index (1-8)
--- @return string highlight_group
function M.get_instance_highlight(color_idx)
	return "OrchestratorClaude" .. validate_color_idx(color_idx)
end

--- Get color name for display (e.g., in picker)
--- @param color_idx number Color index (1-8)
--- @return string color_name
function M.get_color_name(color_idx)
	local idx = validate_color_idx(color_idx)
	local color = M.instance_colors[idx]
	return color and color.name or "Unknown"
end

return M
