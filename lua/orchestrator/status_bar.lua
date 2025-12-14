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
}

-- Padding constants for bubble content
local ACTIVE_PADDING = 2 -- spaces on each side for active bubble
local INACTIVE_PADDING = 1 -- spaces on each side for inactive bubbles

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

	local current_buf = vim.api.nvim_win_get_buf(current_win)
	local editor_is_focused = state.state.editor.buf
		and vim.api.nvim_buf_is_valid(state.state.editor.buf)
		and current_buf == state.state.editor.buf

	for _, inst in ipairs(all_instances) do
		if editor_is_focused then
			local last_buf = state.state.last_active_buf
			if last_buf and vim.api.nvim_buf_is_valid(last_buf) and inst.buf == last_buf then
				return true
			end
		else
			if inst.win and vim.api.nvim_win_is_valid(inst.win) and inst.win == current_win then
				return true
			end
		end
	end

	return false
end

--- Calculate the content width based on number of instances
--- Uses bubble format for active ( X ) and parentheses for inactive (X)
--- @return number width Content width in display columns
local function calculate_content_width()
	local count = instances.count()
	if count == 0 then
		return 0
	end

	-- Base bubble width (narrow format)
	local bubble_width = vim.fn.strdisplaywidth(config.bubble_left .. " 9 " .. config.bubble_right)

	-- Only add extra width if an instance is actually active
	local active_extra = has_active_instance() and (ACTIVE_PADDING - INACTIVE_PADDING) * 2 or 0

	-- Each agent is a bubble + space between (except last) + extra for active
	local width = count * bubble_width + (count - 1) + active_extra

	return width
end

--- Get window position for status bar
--- Positioned just above lualine
--- @return table win_opts Window configuration
local function get_position()
	local content_width = calculate_content_width()
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

	-- Detect active instance (the one in the current window)
	local current_win = vim.api.nvim_get_current_win()

	-- Validate current window before proceeding
	if not vim.api.nvim_win_is_valid(current_win) then
		return
	end

	-- Check if the Prompt Editor is currently focused
	-- When focused, use last_active_buf to determine which Claude instance is "contextually active"
	-- NOTE: We check the BUFFER, not the window, because the window ID isn't set until after
	-- nvim_open_win returns, but the WinEnter autocmd fires during nvim_open_win
	local current_buf = vim.api.nvim_win_get_buf(current_win)
	local editor_is_focused = state.state.editor.buf
		and vim.api.nvim_buf_is_valid(state.state.editor.buf)
		and current_buf == state.state.editor.buf

	local win_opts = get_position()

	-- Build parts and track highlight regions
	local parts = {}
	local highlight_regions = {} -- {start_byte, end_byte, hl_group}
	local byte_offset = 0 -- Track byte position for extmarks

	for i, inst in ipairs(all_instances) do
		local is_active
		if editor_is_focused then
			-- When editor is focused, match by last_active_buf instead of window
			-- Validate that last_active_buf is still valid before using it
			local last_buf = state.state.last_active_buf
			is_active = last_buf
				and vim.api.nvim_buf_is_valid(last_buf)
				and inst.buf == last_buf
		else
			-- Normal case: match by window
			is_active = inst.win
				and vim.api.nvim_win_is_valid(inst.win)
				and inst.win == current_win
		end

		-- Bubble format: active gets wider padding for emphasis
		local left_cap = config.bubble_left
		local padding = string.rep(" ", is_active and ACTIVE_PADDING or INACTIVE_PADDING)
		local content = padding .. inst.number .. padding
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
