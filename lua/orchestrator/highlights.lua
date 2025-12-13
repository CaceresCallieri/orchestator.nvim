-- Highlights Module
-- Color palette and highlight group definitions
-- Styled to match user's lualine theme (transparent backgrounds)

---@class HighlightsModule
local M = {}

-- Base colors (matching user's lualine theme)
M.colors = {
	white = "#C2C2C2", -- Default text color
	black = "#1A1A1A", -- Background when needed
	yellow = "#FDD886", -- Terminal mode accent
}

-- Instance color palette (8 distinct colors for Claude instances)
-- All use transparent backgrounds to match lualine aesthetic
M.instance_colors = {
	{ name = "Red", fg = "#FF6B6B" },
	{ name = "Blue", fg = "#6B9FFF" },
	{ name = "Green", fg = "#6BFF9F" },
	{ name = "Yellow", fg = "#FFD96B" },
	{ name = "Magenta", fg = "#FF6BD9" },
	{ name = "Cyan", fg = "#6BD9FF" },
	{ name = "Orange", fg = "#FF9F6B" },
	{ name = "Purple", fg = "#9F6BFF" },
}

-- Namespace for status bar extmarks
M.namespace = nil

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
	-- Create namespace for status bar highlights
	M.namespace = vim.api.nvim_create_namespace("OrchestratorStatusBar")

	-- Create highlight groups for each instance color
	-- OrchestratorClaude1 through OrchestratorClaude8
	for i, color in ipairs(M.instance_colors) do
		-- Inactive state: colored text on transparent background
		vim.api.nvim_set_hl(0, "OrchestratorClaude" .. i, {
			fg = color.fg,
			bg = "none", -- Transparent to match lualine
			bold = true,
		})

		-- Active bubble body: dark text on colored background
		vim.api.nvim_set_hl(0, "OrchestratorClaude" .. i .. "Active", {
			fg = M.colors.black,
			bg = color.fg,
			bold = true,
		})

		-- Left chevron (): transitions into the bubble
		vim.api.nvim_set_hl(0, "OrchestratorClaude" .. i .. "ChevronLeft", {
			fg = color.fg,
			bg = "none",
		})

		-- Right chevron (): transitions out of the bubble
		vim.api.nvim_set_hl(0, "OrchestratorClaude" .. i .. "ChevronRight", {
			fg = color.fg,
			bg = "none",
		})

		-- Dimmed variants for inactive agents
		local dimmed_fg = dim_color(color.fg, DIM_FACTOR)

		-- Dimmed bubble body: dark text on dimmed colored background
		vim.api.nvim_set_hl(0, "OrchestratorClaude" .. i .. "Dim", {
			fg = M.colors.black,
			bg = dimmed_fg,
			bold = true,
		})

		-- Dimmed left cap
		vim.api.nvim_set_hl(0, "OrchestratorClaude" .. i .. "ChevronLeftDim", {
			fg = dimmed_fg,
			bg = "none",
		})

		-- Dimmed right cap
		vim.api.nvim_set_hl(0, "OrchestratorClaude" .. i .. "ChevronRightDim", {
			fg = dimmed_fg,
			bg = "none",
		})
	end

	-- Base status bar highlight (for brackets and spacing)
	vim.api.nvim_set_hl(0, "OrchestratorStatusBar", {
		fg = M.colors.white,
		bg = "none",
	})

	-- Status bar window background (fully transparent)
	vim.api.nvim_set_hl(0, "OrchestratorStatusBarBg", {
		bg = "none",
	})
end

--- Get highlight group name for inactive instance
--- @param color_idx number Color index (1-8)
--- @return string highlight_group
function M.get_instance_highlight(color_idx)
	return "OrchestratorClaude" .. color_idx
end

--- Get highlight group name for active bubble content
--- @param color_idx number Color index (1-8)
--- @return string highlight_group
function M.get_instance_active_highlight(color_idx)
	return "OrchestratorClaude" .. color_idx .. "Active"
end

--- Get highlight group name for chevron separators
--- @param color_idx number Color index (1-8)
--- @param side "left"|"right" Side of the bubble cap
--- @return string highlight_group
function M.get_instance_chevron_highlight(color_idx, side)
	return "OrchestratorClaude" .. color_idx .. "Chevron" .. (side == "left" and "Left" or "Right")
end

--- Get highlight group name for dimmed bubble content (inactive agents)
--- @param color_idx number Color index (1-8)
--- @return string highlight_group
function M.get_instance_dim_highlight(color_idx)
	return "OrchestratorClaude" .. color_idx .. "Dim"
end

--- Get highlight group name for dimmed chevron separators (inactive agents)
--- @param color_idx number Color index (1-8)
--- @param side "left"|"right" Side of the bubble cap
--- @return string highlight_group
function M.get_instance_chevron_dim_highlight(color_idx, side)
	return "OrchestratorClaude" .. color_idx .. "Chevron" .. (side == "left" and "Left" or "Right") .. "Dim"
end

--- Get color name for display (e.g., in picker)
--- @param color_idx number Color index (1-8)
--- @return string color_name
function M.get_color_name(color_idx)
	local color = M.instance_colors[color_idx]
	return color and color.name or "Unknown"
end

return M
