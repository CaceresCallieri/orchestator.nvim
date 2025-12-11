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

-- ============================================================
-- MULTI-TAB HELPER FUNCTIONS
-- ============================================================

--- Get the current tab entry
--- @return table|nil tab The current tab {buf, name} or nil
local function get_current_tab()
	local tabs = state.state.editor.tabs
	local idx = state.state.editor.current_tab_idx
	if #tabs == 0 or idx < 1 or idx > #tabs then
		return nil
	end
	return tabs[idx]
end

--- Get the current buffer ID
--- @return number|nil buf The current buffer ID or nil
local function get_current_buffer()
	local tab = get_current_tab()
	return tab and tab.buf or nil
end

--- Generate a unique tab name (fills gaps in numbering)
--- @return string name The generated name like "prompt-1"
local function generate_tab_name()
	local used_numbers = {}
	for _, tab in ipairs(state.state.editor.tabs) do
		local num = tab.name:match("prompt%-(%d+)")
		if num then
			used_numbers[tonumber(num)] = true
		end
	end

	local n = 1
	while used_numbers[n] do
		n = n + 1
	end
	return "prompt-" .. n
end

--- Create a new tab with a fresh buffer
--- @return table tab The created tab {buf, name}
local function create_new_tab()
	local buf = vim.api.nvim_create_buf(false, false)

	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].bufhidden = "hide"
	vim.bo[buf].filetype = "markdown"
	vim.bo[buf].swapfile = false

	local name = generate_tab_name()
	vim.api.nvim_buf_set_name(buf, name)

	local tab = { buf = buf, name = name }
	table.insert(state.state.editor.tabs, tab)

	return tab
end

--- Ensure at least one tab exists
local function ensure_at_least_one_tab()
	if #state.state.editor.tabs == 0 then
		create_new_tab()
		state.state.editor.current_tab_idx = 1
	end
end

--- Get the dynamic window title with tab indicator
--- @return string title The window title
local function get_window_title()
	local total = #state.state.editor.tabs
	local current = state.state.editor.current_tab_idx
	if total <= 1 then
		return " Prompt Editor "
	end
	return string.format(" Prompt Editor [%d/%d] ", current, total)
end

--- Update the floating window title
local function update_window_title()
	local win = state.state.editor.win
	if win and vim.api.nvim_win_is_valid(win) then
		vim.api.nvim_win_set_config(win, { title = get_window_title() })
	end
end

--- Get or create the current tab's buffer
--- @return number buf Buffer ID
local function get_or_create_buffer()
	ensure_at_least_one_tab()

	local tab = get_current_tab()

	-- Validate buffer is still valid
	if tab and vim.api.nvim_buf_is_valid(tab.buf) then
		return tab.buf
	end

	-- Buffer became invalid, remove the tab
	if tab then
		for i, t in ipairs(state.state.editor.tabs) do
			if t == tab then
				table.remove(state.state.editor.tabs, i)
				break
			end
		end
	end

	-- Ensure we have at least one valid tab
	ensure_at_least_one_tab()
	return get_current_buffer()
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
		title = get_window_title(),
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

	-- Close editor with Escape in normal mode
	vim.keymap.set("n", "<Esc>", function()
		M.close()
	end, {
		buffer = buf,
		noremap = true,
		silent = true,
		desc = "Close prompt editor",
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
		local buf = get_current_buffer()
		if buf and vim.api.nvim_buf_is_valid(buf) then
			local cursor = vim.api.nvim_win_get_cursor(state.state.editor.win)
			vim.api.nvim_buf_set_mark(buf, "p", cursor[1], cursor[2], {})

			local mode = vim.api.nvim_get_mode().mode
			vim.b[buf].prompt_was_insert = (mode == "i")
		end

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
	local buf = get_current_buffer()
	if not buf or not vim.api.nvim_buf_is_valid(buf) then
		return nil
	end

	local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
	return table.concat(lines, "\n")
end

--- Clear the editor buffer content
function M.clear()
	local buf = get_current_buffer()
	if buf and vim.api.nvim_buf_is_valid(buf) then
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "" })
		pcall(vim.api.nvim_buf_del_mark, buf, "p")
	end
end

-- ============================================================
-- MULTI-TAB HELPER: Switch to current tab
-- ============================================================

--- Switch the window to the current tab's buffer and restore state
local function switch_to_current_tab()
	local buf = get_current_buffer()
	if not buf or not vim.api.nvim_buf_is_valid(buf) then
		return
	end

	local win = state.state.editor.win
	if not win or not vim.api.nvim_win_is_valid(win) then
		return
	end

	vim.api.nvim_win_set_buf(win, buf)
	setup_buffer_keybindings(buf)
	update_window_title()

	-- Restore cursor position and mode for this buffer
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
end

-- ============================================================
-- PUBLIC TAB MANAGEMENT FUNCTIONS
-- ============================================================

--- Create a new prompt editor tab
function M.new_tab()
	local tab = create_new_tab()
	state.state.editor.current_tab_idx = #state.state.editor.tabs

	-- If window is open, switch to new buffer
	if M.is_open() then
		vim.api.nvim_win_set_buf(state.state.editor.win, tab.buf)
		setup_buffer_keybindings(tab.buf)
		update_window_title()
		vim.api.nvim_win_set_cursor(state.state.editor.win, { 1, 0 })
		vim.cmd("startinsert")
	end
end

--- Navigate to the next prompt editor tab (wraps around)
function M.next_tab()
	local tabs = state.state.editor.tabs
	if #tabs <= 1 then
		return -- No navigation needed with single tab
	end

	-- Save current buffer state before switching
	local current_buf = get_current_buffer()
	if current_buf and vim.api.nvim_buf_is_valid(current_buf) and M.is_open() then
		local cursor = vim.api.nvim_win_get_cursor(state.state.editor.win)
		vim.api.nvim_buf_set_mark(current_buf, "p", cursor[1], cursor[2], {})
		local mode = vim.api.nvim_get_mode().mode
		vim.b[current_buf].prompt_was_insert = (mode == "i")
	end

	-- Wrap around navigation
	local new_idx = state.state.editor.current_tab_idx + 1
	if new_idx > #tabs then
		new_idx = 1
	end
	state.state.editor.current_tab_idx = new_idx

	-- If window is open, switch buffer and restore state
	if M.is_open() then
		switch_to_current_tab()
	end
end

--- Navigate to the previous prompt editor tab (wraps around)
function M.prev_tab()
	local tabs = state.state.editor.tabs
	if #tabs <= 1 then
		return -- No navigation needed with single tab
	end

	-- Save current buffer state before switching
	local current_buf = get_current_buffer()
	if current_buf and vim.api.nvim_buf_is_valid(current_buf) and M.is_open() then
		local cursor = vim.api.nvim_win_get_cursor(state.state.editor.win)
		vim.api.nvim_buf_set_mark(current_buf, "p", cursor[1], cursor[2], {})
		local mode = vim.api.nvim_get_mode().mode
		vim.b[current_buf].prompt_was_insert = (mode == "i")
	end

	-- Wrap around navigation
	local new_idx = state.state.editor.current_tab_idx - 1
	if new_idx < 1 then
		new_idx = #tabs
	end
	state.state.editor.current_tab_idx = new_idx

	-- If window is open, switch buffer and restore state
	if M.is_open() then
		switch_to_current_tab()
	end
end

--- Delete the current prompt editor tab
function M.delete_tab()
	local tabs = state.state.editor.tabs
	local idx = state.state.editor.current_tab_idx

	if #tabs == 0 then
		return
	end

	-- Get the tab to delete
	local tab_to_delete = tabs[idx]

	-- Delete the buffer
	if tab_to_delete and vim.api.nvim_buf_is_valid(tab_to_delete.buf) then
		vim.api.nvim_buf_delete(tab_to_delete.buf, { force = true })
	end

	-- Remove from tabs array
	table.remove(tabs, idx)

	-- If this was the last tab, create a new empty one
	if #tabs == 0 then
		create_new_tab()
		state.state.editor.current_tab_idx = 1
	else
		-- Adjust current index if we deleted the last tab
		if idx > #tabs then
			state.state.editor.current_tab_idx = #tabs
		end
		-- Otherwise idx stays the same (next tab slides into position)
	end

	-- If window is open, switch to new current buffer
	if M.is_open() then
		switch_to_current_tab()
	end
end

--- Get the total number of tabs
--- @return number count
function M.tab_count()
	return #state.state.editor.tabs
end

--- Get the current tab index
--- @return number index
function M.current_tab_index()
	return state.state.editor.current_tab_idx
end

return M
