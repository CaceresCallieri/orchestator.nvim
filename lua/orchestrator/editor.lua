-- Editor Module
-- Floating prompt editor window management
-- Provides a toggle-able markdown editor for composing prompts

local state = require("orchestrator.state")

---@class EditorModule
local M = {}

-- Configuration for the floating editor
local config = {
	width_ratio = 0.6, -- 60% of editor width
	height_ratio = 0.4, -- 40% of editor height
	border = "rounded",
	title = " Prompt Editor ",
	bottom_margin = 2, -- Space between editor bottom and lualine
	zindex = 50, -- Above status bar (45)
}

-- Forward declaration for send function (set by init.lua)
---@type function|nil
local send_to_terminal_fn = nil

--- Set the send function reference (called from init.lua)
--- @param fn function The send_to_terminal function
function M.set_send_function(fn)
	send_to_terminal_fn = fn
end

--- Create or get the prompt buffer
--- @return number buf Buffer ID
local function get_or_create_buffer()
	if state.state.editor.buf and vim.api.nvim_buf_is_valid(state.state.editor.buf) then
		return state.state.editor.buf
	end

	local buf = vim.api.nvim_create_buf(false, false) -- listed=false, scratch=false

	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].bufhidden = "hide"
	vim.bo[buf].filetype = "markdown"
	vim.bo[buf].swapfile = false

	vim.api.nvim_buf_set_name(buf, "prompt-" .. buf)

	state.state.editor.buf = buf

	return buf
end

--- Calculate window position (bottom-anchored, horizontally centered)
--- @return table win_opts Window configuration
local function get_window_position()
	local width = math.floor(vim.o.columns * config.width_ratio)
	local height = math.floor(vim.o.lines * config.height_ratio)

	-- Dynamic bottom margin: account for status bar when visible
	-- Use larger margin (5) to keep status bar visible below the editor
	local status_bar_visible = state.state.status_bar.visible
		and state.state.status_bar.win
		and vim.api.nvim_win_is_valid(state.state.status_bar.win)
	local bottom_margin = status_bar_visible and 5 or config.bottom_margin

	local row = vim.o.lines - height - bottom_margin
	local col = math.floor((vim.o.columns - width) / 2)

	return {
		relative = "editor",
		width = width,
		height = height,
		row = row,
		col = col,
		style = "minimal",
		border = config.border,
		title = config.title,
		title_pos = "center",
		zindex = config.zindex,
	}
end

--- Calculate end position of buffer (last line, last column)
--- @param buf number Buffer ID
--- @return number line Line number
--- @return number col Column number
local function get_end_position(buf)
	local line_count = vim.api.nvim_buf_line_count(buf)
	local last_line = vim.api.nvim_buf_get_lines(buf, -1, -1, false)[1]
	local last_col = last_line and #last_line or 0
	return line_count, last_col
end

--- Set up buffer-local keybindings for sending
--- @param buf number Buffer ID
local function setup_buffer_keybindings(buf)
	vim.keymap.set("n", "<leader><CR>", function()
		if send_to_terminal_fn then
			send_to_terminal_fn()
		end
	end, {
		buffer = buf,
		noremap = true,
		silent = true,
		desc = "Send prompt to Claude",
	})

	vim.keymap.set("i", "<leader><CR>", function()
		vim.cmd("stopinsert")
		if send_to_terminal_fn then
			send_to_terminal_fn()
		end
	end, {
		buffer = buf,
		noremap = true,
		silent = true,
		desc = "Send prompt to Claude",
	})
end

--- Open the floating prompt editor
--- @return number win Window ID
function M.open()
	local buf = get_or_create_buffer()
	local win_opts = get_window_position()

	local win = vim.api.nvim_open_win(buf, true, win_opts)

	vim.wo[win].number = false
	vim.wo[win].relativenumber = false
	vim.wo[win].cursorline = true
	vim.wo[win].wrap = true

	state.state.editor.win = win

	setup_buffer_keybindings(buf)

	-- Restore cursor position and mode
	local line_count = vim.api.nvim_buf_line_count(buf)
	local is_empty = line_count == 0 or (line_count == 1 and vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] == "")

	if is_empty then
		pcall(vim.api.nvim_buf_del_mark, buf, "p")
		vim.api.nvim_win_set_cursor(win, { 1, 0 })
		vim.cmd("startinsert")
	else
		local mark = vim.api.nvim_buf_get_mark(buf, "p")

		if mark and mark[1] > 0 then
			vim.api.nvim_win_set_cursor(win, mark)
		else
			local end_line, end_col = get_end_position(buf)
			vim.api.nvim_win_set_cursor(win, { end_line, end_col })
		end

		if vim.b[buf].prompt_was_insert then
			vim.cmd("startinsert!")
		end
	end

	return win
end

--- Close the floating prompt editor
function M.close()
	if state.state.editor.win and vim.api.nvim_win_is_valid(state.state.editor.win) then
		local cursor = vim.api.nvim_win_get_cursor(state.state.editor.win)
		vim.api.nvim_buf_set_mark(state.state.editor.buf, "p", cursor[1], cursor[2], {})

		local mode = vim.api.nvim_get_mode().mode
		vim.b[state.state.editor.buf].prompt_was_insert = (mode == "i")

		vim.api.nvim_win_close(state.state.editor.win, false)
		state.state.editor.win = nil
	end
end

--- Toggle the floating prompt editor
function M.toggle()
	if state.state.editor.win and vim.api.nvim_win_is_valid(state.state.editor.win) then
		M.close()
	else
		M.open()
	end
end

--- Check if the editor window is currently open
--- @return boolean is_open
function M.is_open()
	return state.state.editor.win ~= nil and vim.api.nvim_win_is_valid(state.state.editor.win)
end

--- Get the prompt content from the editor buffer
--- @return string|nil content The prompt text, or nil if buffer is invalid
function M.get_content()
	if not state.state.editor.buf or not vim.api.nvim_buf_is_valid(state.state.editor.buf) then
		return nil
	end

	local lines = vim.api.nvim_buf_get_lines(state.state.editor.buf, 0, -1, false)
	return table.concat(lines, "\n")
end

--- Clear the editor buffer content
function M.clear()
	if state.state.editor.buf and vim.api.nvim_buf_is_valid(state.state.editor.buf) then
		vim.api.nvim_buf_set_lines(state.state.editor.buf, 0, -1, false, { "" })
		pcall(vim.api.nvim_buf_del_mark, state.state.editor.buf, "p")
	end
end

return M
