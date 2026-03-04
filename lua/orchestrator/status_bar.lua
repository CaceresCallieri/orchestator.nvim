-- Status Bar Module
-- Winbar-based status bar for displaying Claude instances
-- Uses vim.wo.winbar with statusline format strings for lualine-style rendering

local state = require("orchestrator.state")
local highlights = require("orchestrator.highlights")
local instances = require("orchestrator.instances")

---@class StatusBarModule
local M = {}

-- Configuration constants
local config = {
	-- Title display settings
	title = {
		max_length = 32, -- Maximum characters before truncation
		ellipsis = "…", -- Truncation indicator (U+2026)
		separator = " │ ", -- Between number and title (U+2502 thin vertical bar)
		fallback = nil, -- Show when no title available (nil = number only)
	},
	-- Separators between instances
	instance_separator = "  ", -- Two spaces between instance segments
}

-- Bubble cap symbols (powerline semicircles)
local BUBBLE_LEFT = "" -- U+E0B6 (left semicircle)
local BUBBLE_RIGHT = "" -- U+E0B4 (right semicircle)


-- Permission-restricted mode indicator (lock U+F023 - nerd font)
local LOCKED_INDICATOR = " "

-- Padding around instance content
local INSTANCE_PADDING = "  " -- Two spaces on each side

-- Shell names to filter out (before Claude sets actual title)
local SHELL_NAMES = { "zsh", "bash", "fish", "sh", "dash", "ksh", "tcsh", "csh" }

--- Check if a specific instance is currently active (displayed in current window)
--- @param inst table Instance object with win field
--- @param current_win number Current window ID
--- @return boolean is_active True if this instance is the active one
local function is_instance_active(inst, current_win)
	return inst.win
		and vim.api.nvim_win_is_valid(inst.win)
		and inst.win == current_win
end

--- Get and truncate the session title for an instance
--- Reads vim.b.term_title at render time (Neovim maintains this via OSC 2)
--- @param buf number Terminal buffer ID
--- @return string|nil title The formatted title or nil if unavailable
local function get_instance_title(buf)
	-- Guard: validate buffer
	if not buf or not vim.api.nvim_buf_is_valid(buf) then
		return nil
	end

	-- Read term_title - Neovim populates this from OSC 2 sequences
	local ok, title = pcall(vim.api.nvim_buf_get_var, buf, "term_title")
	if not ok or not title or title == "" then
		return nil
	end

	-- Filter out non-title values:
	-- 1. Neovim terminal buffer names (term://path/to/dir//cmd)
	-- 2. Common shell names or paths (before Claude sets the actual title)
	if title:match("^term://") then
		return nil
	end
	-- Match shell names as exact match or as basename of path (e.g., /bin/zsh)
	local basename = title:match("([^/]+)$") or title
	for _, shell in ipairs(SHELL_NAMES) do
		if basename == shell then
			return nil
		end
	end

	-- Truncate if needed (with proper UTF-8 handling)
	local display_width = vim.fn.strdisplaywidth(title)
	if display_width > config.title.max_length then
		local truncated = ""
		local width = 0
		-- UTF-8 aware iteration: matches single-byte ASCII or multi-byte sequences
		for char in title:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
			local char_width = vim.fn.strdisplaywidth(char)
			if width + char_width + vim.fn.strdisplaywidth(config.title.ellipsis) > config.title.max_length then
				break
			end
			truncated = truncated .. char
			width = width + char_width
		end
		return truncated .. config.title.ellipsis
	end

	return title
end

--- Check if a window should have the winbar applied
--- Excludes floating windows, special buffers, etc.
--- @param win number Window ID
--- @return boolean should_apply True if winbar should be applied
local function should_apply_winbar(win)
	if not vim.api.nvim_win_is_valid(win) then
		return false
	end

	-- Skip floating windows
	local win_config = vim.api.nvim_win_get_config(win)
	if win_config.relative ~= "" then
		return false
	end

	-- Get the buffer in this window
	local buf = vim.api.nvim_win_get_buf(win)
	if not vim.api.nvim_buf_is_valid(buf) then
		return false
	end

	-- Skip special buffer types (quickfix, loclist, nofile)
	-- Terminal buffers (buftype="terminal") are allowed so Claude instances get winbar
	local buftype = vim.bo[buf].buftype
	if buftype == "quickfix" or buftype == "loclist" or buftype == "nofile" then
		return false
	end

	return true
end

--- Build the winbar string using statusline format syntax
--- Format: %#Highlight#text for colored segments
--- @return string winbar_str The formatted winbar string
local function build_winbar_string()
	local all_instances = instances.get_all()

	if #all_instances == 0 then
		return ""
	end

	-- Cache titles once for rendering
	local title_cache = {}
	for _, inst in ipairs(all_instances) do
		title_cache[inst.buf] = get_instance_title(inst.buf)
	end

	-- Get current window for active state detection
	local current_win = vim.api.nvim_get_current_win()

	-- Build the winbar string with statusline format syntax
	-- Start with background and center alignment
	local parts = { "%#OrchestratorWinbar#%=" }

	for i, inst in ipairs(all_instances) do
		-- Determine if this instance is active (its window is focused)
		local is_active = is_instance_active(inst, current_win)

		-- Select highlight groups based on active state
		local body_hl = is_active
				and highlights.get_instance_active_highlight(inst.color_idx)
			or highlights.get_instance_dim_highlight(inst.color_idx)
		local cap_hl = is_active
				and highlights.get_instance_active_cap_highlight(inst.color_idx)
			or highlights.get_instance_dim_cap_highlight(inst.color_idx)

		-- Build content: padding + (lock?) + number + (separator + title)? + padding
		local mode_prefix = (not inst.dangerous) and LOCKED_INDICATOR or ""
		local number_str = tostring(inst.number)
		local title = title_cache[inst.buf]
		local content

		if title then
			content = INSTANCE_PADDING .. mode_prefix .. number_str .. config.title.separator .. title .. INSTANCE_PADDING
		elseif config.title.fallback then
			content = INSTANCE_PADDING .. mode_prefix .. number_str .. config.title.separator .. config.title.fallback .. INSTANCE_PADDING
		else
			content = INSTANCE_PADDING .. mode_prefix .. number_str .. INSTANCE_PADDING
		end

		-- Add bubble: left_cap + content + right_cap
		-- Caps use cap_hl (colored fg, transparent bg), body uses body_hl (dark fg, colored bg)
		table.insert(parts, string.format("%%#%s#%s", cap_hl, BUBBLE_LEFT))
		table.insert(parts, string.format("%%#%s#%s", body_hl, content))
		table.insert(parts, string.format("%%#%s#%s", cap_hl, BUBBLE_RIGHT))

		-- Add separator between instances (with winbar background)
		if i < #all_instances then
			table.insert(parts, string.format("%%#OrchestratorWinbar#%s", config.instance_separator))
		end
	end

	-- End with background fill and right alignment marker
	table.insert(parts, "%#OrchestratorWinbar#%=")

	return table.concat(parts)
end

--- Apply winbar to all applicable windows
--- @param winbar_str string The winbar string to apply (empty string to clear)
local function apply_to_all_windows(winbar_str)
	for _, win in ipairs(vim.api.nvim_list_wins()) do
		if should_apply_winbar(win) then
			-- Use pcall to handle race condition where window closes between check and assignment
			pcall(function()
				vim.wo[win].winbar = winbar_str
			end)
		end
	end
end

--- Show the winbar on all windows
function M.show()
	if instances.count() == 0 then
		M.hide()
		return
	end

	if not state.state.status_bar.visible then
		return
	end

	local winbar_str = build_winbar_string()
	apply_to_all_windows(winbar_str)
end

--- Hide the winbar from all windows
function M.hide()
	apply_to_all_windows("")
end

--- Update the winbar (rebuild and reapply)
--- Call this after instances change
function M.update()
	if instances.count() == 0 then
		M.hide()
		return
	end

	if state.state.status_bar.visible then
		M.show()
	end
end

--- Toggle winbar visibility
function M.toggle()
	state.state.status_bar.visible = not state.state.status_bar.visible

	if state.state.status_bar.visible then
		M.show()
	else
		M.hide()
	end
end

--- Get the current winbar string (for external use/debugging)
--- @return string winbar_str The current winbar string
function M.get_winbar_string()
	if instances.count() == 0 or not state.state.status_bar.visible then
		return ""
	end
	return build_winbar_string()
end

-- Public API: Used by picker_utils for session title display in picker items
-- This function is intentionally exported as part of the module's public interface
M.get_instance_title = get_instance_title

return M
