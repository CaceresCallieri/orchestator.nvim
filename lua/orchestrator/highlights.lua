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

--- Setup all highlight groups
--- Call this during plugin setup
function M.setup()
	-- Create namespace for status bar highlights
	M.namespace = vim.api.nvim_create_namespace("OrchestratorStatusBar")

	-- Create highlight groups for each instance color
	-- OrchestratorClaude1 through OrchestratorClaude8
	for i, color in ipairs(M.instance_colors) do
		vim.api.nvim_set_hl(0, "OrchestratorClaude" .. i, {
			fg = color.fg,
			bg = "none", -- Transparent to match lualine
			bold = true,
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

--- Get highlight group name for a color index
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
