-- Status Bar Module
-- Floating status bar UI for displaying Claude instances
-- Positioned above lualine, styled to match its aesthetic

local state = require("prompt-editor.state")
local highlights = require("prompt-editor.highlights")
local instances = require("prompt-editor.instances")

---@class StatusBarModule
local M = {}

-- Configuration constants
local config = {
	zindex = 45, -- Below editor (50), above normal content
	lualine_offset = 3, -- Lines from bottom (cmdline=-1, statusline=-2, bar=-3)
	min_width = 10, -- Minimum window width
	padding = 4, -- Horizontal padding around content
	max_width_ratio = 0.8, -- Maximum 80% of screen width
	truncation_indicator = "...", -- Shown when list is truncated
}

--- Calculate the content width based on number of instances
--- @return number width Content width in characters
local function calculate_content_width()
	local count = instances.count()
	if count == 0 then
		return 0
	end

	-- Format: "[1] [2] [3]" = 3 chars per instance + 1 space between
	local width = 0
	for i = 1, count do
		width = width + #string.format("[%d]", i)
		if i < count then
			width = width + 1 -- space between
		end
	end

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

	vim.api.nvim_buf_set_name(buf, "prompt-editor-status-bar")

	state.state.status_bar.buf = buf
	return buf
end

--- Render status bar content with colored instance indicators
--- Handles overflow by truncating with "..." indicator
--- @param buf number Status bar buffer
local function render(buf)
	local all_instances = instances.get_all()

	if #all_instances == 0 then
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "" })
		return
	end

	local win_opts = get_position()
	local available_width = win_opts.width - config.padding

	-- Build parts, checking for overflow
	-- First pass: calculate total width needed for all instances
	local total_needed = 0
	for i, inst in ipairs(all_instances) do
		total_needed = total_needed + #string.format("[%d]", inst.number)
		if i < #all_instances then
			total_needed = total_needed + 1 -- space separator
		end
	end

	local parts = {}
	local current_width = 0
	local truncated = false
	local displayed_instances = {}
	local needs_truncation = total_needed > available_width

	for i, inst in ipairs(all_instances) do
		local part = string.format("[%d]", inst.number)
		local separator = i < #all_instances and " " or ""
		local part_width = #part + #separator
		local remaining = available_width - current_width

		-- Only reserve truncation space if we know we can't fit everything
		if needs_truncation then
			local truncation_width = #config.truncation_indicator + 1
			if remaining < part_width + truncation_width then
				truncated = true
				break
			end
		else
			-- Everything fits, just check if this item fits
			if remaining < part_width then
				truncated = true
				break
			end
		end

		table.insert(parts, part)
		table.insert(displayed_instances, inst)
		if separator ~= "" then
			table.insert(parts, separator)
		end
		current_width = current_width + part_width
	end

	if truncated then
		table.insert(parts, " " .. config.truncation_indicator)
	end

	local line = table.concat(parts)

	-- Center the content with padding
	local padding = math.floor((win_opts.width - #line) / 2)
	local padded_line = string.rep(" ", padding) .. line

	vim.bo[buf].modifiable = true
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, { padded_line })
	vim.bo[buf].modifiable = false

	-- Apply highlights using extmarks
	vim.api.nvim_buf_clear_namespace(buf, highlights.namespace, 0, -1)

	local col = padding
	for i, inst in ipairs(displayed_instances) do
		local text = string.format("[%d]", inst.number)
		vim.api.nvim_buf_set_extmark(buf, highlights.namespace, 0, col, {
			end_col = col + #text,
			hl_group = highlights.get_instance_highlight(inst.color_idx),
		})
		col = col + #text
		if i < #displayed_instances then
			col = col + 1 -- space
		end
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
	vim.wo[win].winhighlight = "Normal:PromptEditorStatusBarBg,NormalFloat:PromptEditorStatusBarBg"

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
