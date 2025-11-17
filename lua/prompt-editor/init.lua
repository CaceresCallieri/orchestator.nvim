-- Prompt Editor Module
-- Provides a toggle-able floating window for writing prompts to send to terminal
-- Usage: <leader>ap to toggle editor, <leader><CR> to send prompt to visible terminal

local M = {}

-- State management
local state = {
	win = nil, -- Window ID of floating prompt editor
	buf = nil, -- Buffer ID of prompt buffer
}

-- Create autocmd group (cleared on reload to prevent duplicates)
local augroup = vim.api.nvim_create_augroup("PromptEditor", { clear = true })

-- Configuration
local config = {
	width_ratio = 0.6, -- 60% of editor width
	height_ratio = 0.4, -- 40% of editor height
	border = "rounded",
	title = " Prompt Editor ",
}

-- Create or get the prompt buffer
local function get_or_create_buffer()
	-- If buffer exists and is valid, reuse it
	if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
		return state.buf
	end

	-- Create new buffer
	local buf = vim.api.nvim_create_buf(false, false) -- listed=false, scratch=false

	-- Set buffer options for editing
	vim.bo[buf].buftype = "nofile" -- Non-file buffer (cannot be saved with :w)
	vim.bo[buf].bufhidden = "hide" -- Hide when not displayed (don't wipe)
	vim.bo[buf].filetype = "markdown" -- Markdown syntax highlighting
	vim.bo[buf].swapfile = false

	-- Set buffer name
	vim.api.nvim_buf_set_name(buf, "prompt-" .. buf)

	-- Store buffer reference
	state.buf = buf

	return buf
end

-- Calculate window position (bottom-anchored, horizontally centered)
local function get_window_position()
	local width = math.floor(vim.o.columns * config.width_ratio)
	local height = math.floor(vim.o.lines * config.height_ratio)
	local row = vim.o.lines - height - 2 -- Anchor to bottom with margin
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
	}
end

-- Calculate end position of buffer (last line, last column)
local function get_end_position(buf)
	local line_count = vim.api.nvim_buf_line_count(buf)
	local last_line = vim.api.nvim_buf_get_lines(buf, -1, -1, false)[1]
	local last_col = last_line and #last_line or 0
	return line_count, last_col
end

-- Open the floating prompt editor
local function open_floating_editor()
	local buf = get_or_create_buffer()
	local win_opts = get_window_position()

	-- Open floating window
	local win = vim.api.nvim_open_win(buf, true, win_opts)

	-- Set window options
	vim.wo[win].number = false
	vim.wo[win].relativenumber = false
	vim.wo[win].cursorline = true
	vim.wo[win].wrap = true

	-- Store window reference
	state.win = win

	-- Restore cursor position and mode
	local line_count = vim.api.nvim_buf_line_count(buf)
	-- Check if buffer is truly empty (no lines or one empty line)
	local is_empty = line_count == 0 or (line_count == 1 and vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] == "")

	if is_empty then
		-- Empty buffer: clear stale mark and start at beginning in insert mode
		pcall(vim.api.nvim_buf_del_mark, buf, "p") -- Clear mark if exists
		vim.api.nvim_win_set_cursor(win, { 1, 0 })
		vim.cmd("startinsert")
	else
		-- Buffer has content: restore saved position and mode
		local mark = vim.api.nvim_buf_get_mark(buf, "p")

		if mark and mark[1] > 0 then
			-- Valid mark exists, restore position
			vim.api.nvim_win_set_cursor(win, mark)
		else
			-- No mark yet (first time with content), go to end
			local end_line, end_col = get_end_position(buf)
			vim.api.nvim_win_set_cursor(win, { end_line, end_col })
		end

		-- Restore mode
		if vim.b[buf].prompt_was_insert then
			vim.cmd("startinsert!")
		end
		-- else: stay in normal mode (default)
	end

	return win
end

-- Close the floating prompt editor
local function close_floating_editor()
	if state.win and vim.api.nvim_win_is_valid(state.win) then
		-- Save cursor position as buffer-local mark 'p'
		local cursor = vim.api.nvim_win_get_cursor(state.win)
		vim.api.nvim_buf_set_mark(state.buf, "p", cursor[1], cursor[2], {})

		-- Save mode as buffer variable
		local mode = vim.api.nvim_get_mode().mode
		vim.b[state.buf].prompt_was_insert = (mode == "i")

		vim.api.nvim_win_close(state.win, false)
		state.win = nil
	end
end

-- Toggle the floating prompt editor
function M.toggle()
	-- If window is open and valid, close it
	if state.win and vim.api.nvim_win_is_valid(state.win) then
		close_floating_editor()
	else
		-- Otherwise, open it
		open_floating_editor()
	end
end

-- Find currently visible terminal window
local function find_visible_terminal()
	-- Iterate through all windows
	for _, win in ipairs(vim.api.nvim_list_wins()) do
		local buf = vim.api.nvim_win_get_buf(win)

		-- Check if this buffer is a terminal
		if vim.bo[buf].buftype == "terminal" then
			-- Check if it has a valid job ID
			local job_id = vim.b[buf].terminal_job_id
			if job_id then
				return win, buf, job_id
			end
		end
	end

	return nil, nil, nil
end

-- Send prompt to terminal
function M.send_to_terminal()
	-- Get prompt buffer content (all lines)
	if not state.buf or not vim.api.nvim_buf_is_valid(state.buf) then
		vim.notify("Prompt buffer not found", vim.log.levels.ERROR)
		return
	end

	local lines = vim.api.nvim_buf_get_lines(state.buf, 0, -1, false)
	local text = table.concat(lines, "\n")

	-- Check if there's actual content
	if text:match("^%s*$") then
		vim.notify("Prompt is empty", vim.log.levels.WARN)
		return
	end

	-- Find visible terminal
	local term_win, term_buf, job_id = find_visible_terminal()

	if not term_win then
		vim.notify("No visible terminal found", vim.log.levels.WARN)
		return
	end

	-- Send text to terminal
	vim.api.nvim_chan_send(job_id, text .. "\n")

	-- Close the floating editor
	close_floating_editor()

	-- Focus the terminal window (check validity in case it closed)
	if term_win and vim.api.nvim_win_is_valid(term_win) then
		vim.api.nvim_set_current_win(term_win)
	end

	vim.notify("Prompt sent to terminal", vim.log.levels.INFO)
end

-- Set up buffer-local keybinding for sending (called when buffer is created)
local function setup_buffer_keybindings(buf)
	-- <leader><CR> to send prompt (works in normal and insert mode)
	vim.keymap.set("n", "<leader><CR>", M.send_to_terminal, {
		buffer = buf,
		noremap = true,
		silent = true,
		desc = "Send prompt to terminal",
	})

	vim.keymap.set("i", "<leader><CR>", function()
		vim.cmd("stopinsert")
		M.send_to_terminal()
	end, {
		buffer = buf,
		noremap = true,
		silent = true,
		desc = "Send prompt to terminal",
	})
end

-- Setup function to initialize the module
function M.setup()
	-- Set up keybindings when buffer is created
	vim.api.nvim_create_autocmd("BufEnter", {
		group = augroup,
		callback = function(args)
			-- Only set up keybindings for our prompt buffer
			if args.buf == state.buf then
				setup_buffer_keybindings(args.buf)
			end
		end,
	})

	-- Create user commands (keybindings should be set by user in their config)
	vim.api.nvim_create_user_command("PromptToggle", M.toggle, {
		desc = "Toggle prompt editor",
	})

	vim.api.nvim_create_user_command("PromptSend", M.send_to_terminal, {
		desc = "Send prompt to visible terminal",
	})
end

-- Teardown function for testing and cleanup
function M.teardown()
	-- Close window if open
	if state.win and vim.api.nvim_win_is_valid(state.win) then
		vim.api.nvim_win_close(state.win, true)
		state.win = nil
	end

	-- Delete buffer if exists
	if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
		vim.api.nvim_buf_delete(state.buf, { force = true })
		state.buf = nil
	end

	-- Clear augroup (removes all autocmds)
	pcall(vim.api.nvim_del_augroup_by_name, "PromptEditor")

	-- Remove user commands
	pcall(vim.api.nvim_del_user_command, "PromptToggle")
	pcall(vim.api.nvim_del_user_command, "PromptSend")

	-- Note: Global keymaps cannot be easily removed without IDs
	-- They will persist until Neovim restart
end

return M
