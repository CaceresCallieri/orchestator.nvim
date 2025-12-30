-- Status Bar Module
-- Floating status bar UI for displaying Claude instances
-- Positioned above lualine, styled to match its aesthetic

local state = require("orchestrator.state")
local highlights = require("orchestrator.highlights")
local instances = require("orchestrator.instances")

---@class StatusBarModule
local M = {}

-- Configuration constants
local config = {
	zindex = 45, -- Below editor (50), above normal content
	lualine_offset = 3, -- Lines from bottom (cmdline=-1, statusline=-2, bar=-3)
	min_width = 10, -- Minimum window width
	padding = 4, -- Horizontal padding around content
	max_width_ratio = 0.8, -- Maximum 80% of screen width
	-- Bubble effect separators (powerline rounded symbols)
	bubble_left = "", -- U+E0B6 (left semicircle)
	bubble_right = "", -- U+E0B4 (right semicircle)
	-- Title display settings
	title = {
		max_length = 32, -- Maximum characters before truncation
		ellipsis = "…", -- Truncation indicator (U+2026)
		separator = " │ ", -- Between number and title (U+2502 thin vertical bar)
		fallback = nil, -- Show when no title available (nil = number only)
	},
}

-- Padding constants for bubble content
local ACTIVE_PADDING = 2 -- spaces on each side for active bubble
local INACTIVE_PADDING = 1 -- spaces on each side for inactive bubbles

-- Shell names to filter out (before Claude sets actual title)
local SHELL_NAMES = { "zsh", "bash", "fish", "sh", "dash", "ksh", "tcsh", "csh" }

--- Check if the current window is a Claude terminal window
--- @return boolean is_claude_win True if current window is a Claude terminal
local function is_in_claude_terminal()
	local current_win = vim.api.nvim_get_current_win()
	if not vim.api.nvim_win_is_valid(current_win) then
		return false
	end

	for _, inst in ipairs(instances.get_all()) do
		if inst.win and vim.api.nvim_win_is_valid(inst.win) and inst.win == current_win then
			return true
		end
	end

	return false
end

--- Check if a specific instance is currently active
--- @param inst table Instance object with win field
--- @param in_claude boolean Whether currently in a Claude terminal
--- @param current_win number Current window ID
--- @return boolean is_active True if this instance is active
local function is_instance_active(inst, in_claude, current_win)
	return in_claude
		and inst.win
		and vim.api.nvim_win_is_valid(inst.win)
		and inst.win == current_win
end

--- Check if any Claude instance is currently active
--- Mirrors the logic in render() to determine active state
--- @return boolean has_active True if an instance is active
local function has_active_instance()
	local all_instances = instances.get_all()
	if #all_instances == 0 then
		return false
	end

	local current_win = vim.api.nvim_get_current_win()
	if not vim.api.nvim_win_is_valid(current_win) then
		return false
	end

	-- Only show active indicator when inside a Claude terminal
	if not is_in_claude_terminal() then
		return false
	end

	-- Check if current window matches any Claude instance
	for _, inst in ipairs(all_instances) do
		if inst.win and vim.api.nvim_win_is_valid(inst.win) and inst.win == current_win then
			return true
		end
	end

	return false
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

--- Calculate the content width based on number of instances and their titles
--- Iterates through instances to sum variable widths (titles vary in length)
--- @param all_instances table Array of instance objects
--- @param title_cache table Map of buf -> title (cached lookups)
--- @return number width Content width in display columns
local function calculate_content_width(all_instances, title_cache)
	local count = #all_instances
	if count == 0 then
		return 0
	end

	local current_win = vim.api.nvim_get_current_win()
	local in_claude = is_in_claude_terminal()
	local total_width = 0

	for i, inst in ipairs(all_instances) do
		-- Determine if this instance is active (for padding calculation)
		local is_active = is_instance_active(inst, in_claude, current_win)
		local padding_size = is_active and ACTIVE_PADDING or INACTIVE_PADDING

		-- Calculate bubble content width: padding + number + (separator + title)? + padding
		local content_width = padding_size -- left padding
		content_width = content_width + vim.fn.strdisplaywidth(tostring(inst.number))

		local title = title_cache[inst.buf]
		if title then
			content_width = content_width + vim.fn.strdisplaywidth(config.title.separator)
			content_width = content_width + vim.fn.strdisplaywidth(title)
		elseif config.title.fallback then
			content_width = content_width + vim.fn.strdisplaywidth(config.title.separator)
			content_width = content_width + vim.fn.strdisplaywidth(config.title.fallback)
		end

		content_width = content_width + padding_size -- right padding

		-- Add bubble caps
		content_width = content_width + vim.fn.strdisplaywidth(config.bubble_left)
		content_width = content_width + vim.fn.strdisplaywidth(config.bubble_right)

		total_width = total_width + content_width

		-- Add space between bubbles
		if i < count then
			total_width = total_width + 1
		end
	end

	return total_width
end

--- Get window position for status bar
--- Positioned just above lualine
--- @param all_instances? table Array of instance objects (optional, fetched if nil)
--- @param title_cache? table Map of buf -> title (optional, built if nil)
--- @return table win_opts Window configuration
local function get_position(all_instances, title_cache)
	-- Fallback: fetch instances and build cache if not provided
	if not all_instances then
		all_instances = instances.get_all()
	end
	if not title_cache then
		title_cache = {}
		for _, inst in ipairs(all_instances) do
			title_cache[inst.buf] = get_instance_title(inst.buf)
		end
	end
	local content_width = calculate_content_width(all_instances, title_cache)
	local max_width = math.floor(vim.o.columns * config.max_width_ratio)
	local width = math.max(config.min_width, math.min(content_width + config.padding, max_width))

	return {
		relative = "editor",
		width = width,
		height = 1,
		row = vim.o.lines - config.lualine_offset,
		col = math.floor((vim.o.columns - width) / 2),
		style = "minimal",
		border = "none",
		focusable = false,
		zindex = config.zindex,
	}
end

--- Create or get the status bar buffer
--- @return number buf Buffer ID
local function get_or_create_buffer()
	if state.state.status_bar.buf and vim.api.nvim_buf_is_valid(state.state.status_bar.buf) then
		return state.state.status_bar.buf
	end

	local buf = vim.api.nvim_create_buf(false, true) -- unlisted, scratch

	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].swapfile = false
	vim.bo[buf].modifiable = true

	vim.api.nvim_buf_set_name(buf, "orchestrator-status-bar")

	state.state.status_bar.buf = buf
	return buf
end

--- Render status bar content with colored instance indicators
--- Active instance displayed as bubble with chevron separators
--- Inactive instances displayed with parentheses
--- @param buf number Status bar buffer
local function render(buf)
	local all_instances = instances.get_all()

	if #all_instances == 0 then
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "" })
		return
	end

	-- Cache titles once for both width calculation and rendering
	local title_cache = {}
	for _, inst in ipairs(all_instances) do
		title_cache[inst.buf] = get_instance_title(inst.buf)
	end

	-- Detect active instance (the one in the current window)
	local current_win = vim.api.nvim_get_current_win()

	-- Validate current window before proceeding
	if not vim.api.nvim_win_is_valid(current_win) then
		return
	end

	-- Check if we're currently in a Claude terminal window
	local in_claude_terminal = is_in_claude_terminal()

	local win_opts = get_position(all_instances, title_cache)

	-- Build parts and track highlight regions
	local parts = {}
	local highlight_regions = {} -- {start_byte, end_byte, hl_group}
	local byte_offset = 0 -- Track byte position for extmarks

	for i, inst in ipairs(all_instances) do
		-- Only mark as active when inside a Claude terminal that matches this instance
		local is_active = is_instance_active(inst, in_claude_terminal, current_win)

		-- Bubble format: active gets wider padding for emphasis
		local left_cap = config.bubble_left
		local padding = string.rep(" ", is_active and ACTIVE_PADDING or INACTIVE_PADDING)

		-- Build content: number + (separator + title)?
		local number_str = tostring(inst.number)
		local title = title_cache[inst.buf]
		local content

		if title then
			content = padding .. number_str .. config.title.separator .. title .. padding
		elseif config.title.fallback then
			content = padding .. number_str .. config.title.separator .. config.title.fallback .. padding
		else
			content = padding .. number_str .. padding
		end

		local right_cap = config.bubble_right

		-- Add parts
		table.insert(parts, left_cap)
		table.insert(parts, content)
		table.insert(parts, right_cap)

		-- Determine highlight groups based on active state
		-- Active: full brightness, Inactive: dimmed
		local left_cap_hl, content_hl, right_cap_hl
		if is_active then
			left_cap_hl = highlights.get_instance_chevron_highlight(inst.color_idx, "left")
			content_hl = highlights.get_instance_active_highlight(inst.color_idx)
			right_cap_hl = highlights.get_instance_chevron_highlight(inst.color_idx, "right")
		else
			left_cap_hl = highlights.get_instance_chevron_dim_highlight(inst.color_idx, "left")
			content_hl = highlights.get_instance_dim_highlight(inst.color_idx)
			right_cap_hl = highlights.get_instance_chevron_dim_highlight(inst.color_idx, "right")
		end

		-- Track highlight regions for left bubble cap
		table.insert(highlight_regions, {
			start_byte = byte_offset,
			end_byte = byte_offset + #left_cap,
			hl_group = left_cap_hl,
		})
		byte_offset = byte_offset + #left_cap

		-- Track highlight regions for content
		table.insert(highlight_regions, {
			start_byte = byte_offset,
			end_byte = byte_offset + #content,
			hl_group = content_hl,
		})
		byte_offset = byte_offset + #content

		-- Track highlight regions for right bubble cap
		table.insert(highlight_regions, {
			start_byte = byte_offset,
			end_byte = byte_offset + #right_cap,
			hl_group = right_cap_hl,
		})
		byte_offset = byte_offset + #right_cap

		-- Add space between instances
		if i < #all_instances then
			table.insert(parts, " ")
			byte_offset = byte_offset + 1
		end
	end

	local line = table.concat(parts)

	-- Center the content with padding
	local display_width = vim.fn.strdisplaywidth(line)
	local padding = math.max(0, math.floor((win_opts.width - display_width) / 2))
	local padded_line = string.rep(" ", padding) .. line

	vim.bo[buf].modifiable = true
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, { padded_line })
	vim.bo[buf].modifiable = false

	-- Apply highlights using extmarks
	vim.api.nvim_buf_clear_namespace(buf, highlights.namespace, 0, -1)

	for _, region in ipairs(highlight_regions) do
		vim.api.nvim_buf_set_extmark(buf, highlights.namespace, 0, padding + region.start_byte, {
			end_col = padding + region.end_byte,
			hl_group = region.hl_group,
		})
	end
end

--- Show the status bar floating window
function M.show()
	if instances.count() == 0 then
		return
	end

	if not state.state.status_bar.visible then
		return
	end

	local buf = get_or_create_buffer()
	local win_opts = get_position()

	if state.state.status_bar.win and vim.api.nvim_win_is_valid(state.state.status_bar.win) then
		vim.api.nvim_win_set_config(state.state.status_bar.win, win_opts)
		render(buf)
		return
	end

	local win = vim.api.nvim_open_win(buf, false, win_opts)

	vim.wo[win].number = false
	vim.wo[win].relativenumber = false
	vim.wo[win].cursorline = false
	vim.wo[win].signcolumn = "no"
	vim.wo[win].winhighlight = "Normal:OrchestratorStatusBarBg,NormalFloat:OrchestratorStatusBarBg"

	state.state.status_bar.win = win
	render(buf)
end

--- Hide the status bar floating window
function M.hide()
	if state.state.status_bar.win and vim.api.nvim_win_is_valid(state.state.status_bar.win) then
		vim.api.nvim_win_close(state.state.status_bar.win, true)
		state.state.status_bar.win = nil
	end
end

--- Update status bar (re-render and resize)
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

--- Toggle status bar visibility
function M.toggle()
	state.state.status_bar.visible = not state.state.status_bar.visible

	if state.state.status_bar.visible then
		M.show()
	else
		M.hide()
	end
end

--- Reposition status bar (call on VimResized)
function M.reposition()
	if state.state.status_bar.win and vim.api.nvim_win_is_valid(state.state.status_bar.win) then
		local win_opts = get_position()
		vim.api.nvim_win_set_config(state.state.status_bar.win, win_opts)

		if state.state.status_bar.buf and vim.api.nvim_buf_is_valid(state.state.status_bar.buf) then
			render(state.state.status_bar.buf)
		end
	end
end

return M
