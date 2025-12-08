-- Prompt Editor Module
-- Provides a toggle-able floating window for writing prompts to send to Claude Code
-- Usage: <leader>ap to toggle editor, <leader><CR> to send prompt to Claude terminal

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

--- Get Claude's working directory from /proc
--- Returns nil if not a Claude terminal or Claude not found
--- @param shell_pid number The shell's PID (from terminal_job_pid)
--- @return string|nil cwd The working directory, or nil if not found
local function get_claude_cwd(shell_pid)
	-- Validate PID is numeric
	if type(shell_pid) ~= "number" or shell_pid <= 0 then
		return nil
	end

	-- Find Claude process among children (single pgrep call with -a for command args)
	local pgrep_result = vim.fn.system("pgrep -P " .. shell_pid .. " -a 2>/dev/null")

	-- Check if any child process contains "claude" and extract its PID
	local claude_pid = pgrep_result:match("(%d+)%s+.*claude")

	if not claude_pid then
		return nil -- Not a Claude terminal
	end

	-- Read working directory from /proc
	local cwd = vim.fn.system("readlink /proc/" .. claude_pid .. "/cwd 2>/dev/null")
	cwd = cwd:gsub("%s+$", "") -- Trim trailing whitespace/newline

	if cwd == "" then
		return nil
	end

	return cwd
end

--- Find all Claude Code terminal buffers in current project
--- @return table[] Array of {win, buf, job_id, name} for each Claude terminal
local function find_claude_terminals()
	local terminals = {}
	local nvim_cwd = vim.fn.getcwd()

	for _, buf in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].buftype == "terminal" then
			local job_id = vim.b[buf].terminal_job_id
			local pid = vim.b[buf].terminal_job_pid

			if job_id and pid then
				-- Single call - combines Claude detection + cwd retrieval
				local claude_cwd = get_claude_cwd(pid)

				if claude_cwd and claude_cwd == nvim_cwd then
					-- Find window displaying this buffer
					local win = nil
					for _, w in ipairs(vim.api.nvim_list_wins()) do
						if vim.api.nvim_win_get_buf(w) == buf then
							win = w
							break
						end
					end

					table.insert(terminals, {
						win = win,
						buf = buf,
						job_id = job_id,
						name = "Claude",
					})
				end
			end
		end
	end

	return terminals
end

--- Show selector for Claude terminals
--- @param terminals table[] Array from find_claude_terminals()
--- @param callback function Called with selected terminal
local function select_claude_terminal(terminals, callback)
	local items = {}
	for i, term in ipairs(terminals) do
		items[i] = term.name
	end

	vim.ui.select(items, {
		prompt = "Select Claude Terminal:",
		format_item = function(item)
			return item
		end,
	}, function(choice, idx)
		if idx then
			callback(terminals[idx])
		end
	end)
end

-- Send prompt to Claude Code terminal
function M.send_to_terminal()
	-- Validate prompt buffer
	if not state.buf or not vim.api.nvim_buf_is_valid(state.buf) then
		vim.notify("Prompt buffer not found", vim.log.levels.ERROR)
		return
	end

	-- Get prompt content
	local lines = vim.api.nvim_buf_get_lines(state.buf, 0, -1, false)
	local text = table.concat(lines, "\n")

	if text:match("^%s*$") then
		vim.notify("Prompt is empty", vim.log.levels.WARN)
		return
	end

	-- Find Claude terminals
	local terminals = find_claude_terminals()

	if #terminals == 0 then
		vim.notify("No Claude Code terminals found in current project", vim.log.levels.WARN)
		return
	end

	-- Helper to send to a specific terminal
	local function send_to(terminal)
		vim.api.nvim_chan_send(terminal.job_id, text .. "\n")
		close_floating_editor()

		if terminal.win and vim.api.nvim_win_is_valid(terminal.win) then
			vim.api.nvim_set_current_win(terminal.win)
		end

		vim.notify("Prompt sent to Claude", vim.log.levels.INFO)
	end

	-- Always show picker (even for single terminal)
	select_claude_terminal(terminals, send_to)
end

-- Set up buffer-local keybinding for sending (called when buffer is created)
local function setup_buffer_keybindings(buf)
	-- <leader><CR> to send prompt (works in normal and insert mode)
	vim.keymap.set("n", "<leader><CR>", M.send_to_terminal, {
		buffer = buf,
		noremap = true,
		silent = true,
		desc = "Send prompt to Claude",
	})

	vim.keymap.set("i", "<leader><CR>", function()
		vim.cmd("stopinsert")
		M.send_to_terminal()
	end, {
		buffer = buf,
		noremap = true,
		silent = true,
		desc = "Send prompt to Claude",
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
		desc = "Send prompt to Claude Code terminal",
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
