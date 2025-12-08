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
	active_indicator_display_width = 2, -- Display width of ● character (2 columns in most terminals)
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

	-- Add space for active indicator (●) - only 1 instance can be active at a time
	width = width + config.active_indicator_display_width

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
--- Shows ● indicator for the currently focused instance
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

	local win_opts = get_position()

	-- Build parts for all instances
	local parts = {}
	local displayed_instances = {}

	for i, inst in ipairs(all_instances) do
		-- Validate inst.win before comparing (may have been closed)
		local is_active = inst.win
			and vim.api.nvim_win_is_valid(inst.win)
			and inst.win == current_win
		local part = is_active and string.format("[%d●]", inst.number) or string.format("[%d]", inst.number)

		table.insert(parts, part)
		table.insert(displayed_instances, { inst = inst, is_active = is_active })

		if i < #all_instances then
			table.insert(parts, " ")
		end
	end

	local line = table.concat(parts)

	-- Center the content with padding
	-- Use strdisplaywidth for correct Unicode character width (● is 2 columns)
	local display_width = vim.fn.strdisplaywidth(line)
	local padding = math.floor((win_opts.width - display_width) / 2)
	local padded_line = string.rep(" ", padding) .. line

	vim.bo[buf].modifiable = true
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, { padded_line })
	vim.bo[buf].modifiable = false

	-- Apply highlights using extmarks
	vim.api.nvim_buf_clear_namespace(buf, highlights.namespace, 0, -1)

	local col = padding
	for i, entry in ipairs(displayed_instances) do
		local inst = entry.inst
		local is_active = entry.is_active
		local text = is_active and string.format("[%d●]", inst.number) or string.format("[%d]", inst.number)
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
