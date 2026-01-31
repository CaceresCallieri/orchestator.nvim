-- Edit Tracker Module
-- Parses Claude Code terminal output to detect file edits
-- Allows jumping to edit locations in Neovim

local state = require("orchestrator.state")

---@class EditTrackerModule
local M = {}

-- Forward declarations for injected dependencies
---@type table|nil
local instances = nil
---@type table|nil
local picker = nil

-- Floating window configuration
local float_config = {
	width = 80,
	max_height = 15,
	border = "rounded",
	zindex = 55, -- Same as spawn_menu (above editor)
}

--- Set the instances module reference (called from init.lua to break circular dep)
--- @param inst table The instances module
function M.set_instances(inst)
	instances = inst
end

--- Set the picker module reference (called from init.lua)
--- @param p table The picker module
function M.set_picker(p)
	picker = p
end

-- ============================================================
-- FLOATING WINDOW HELPERS
-- ============================================================

--- Close the floating edit picker window
local function close_edit_picker()
	-- Clear autocmds before closing to prevent double-fire race condition
	if state.state.edit_picker.buf and vim.api.nvim_buf_is_valid(state.state.edit_picker.buf) then
		pcall(vim.api.nvim_clear_autocmds, {
			buffer = state.state.edit_picker.buf,
			event = { "WinLeave", "BufLeave" },
		})
	end

	if state.state.edit_picker.win and vim.api.nvim_win_is_valid(state.state.edit_picker.win) then
		vim.api.nvim_win_close(state.state.edit_picker.win, true)
	end
	if state.state.edit_picker.buf and vim.api.nvim_buf_is_valid(state.state.edit_picker.buf) then
		vim.api.nvim_buf_delete(state.state.edit_picker.buf, { force = true })
	end
	state.state.edit_picker.win = nil
	state.state.edit_picker.buf = nil
	state.state.edit_picker.edits = {}
end

--- Build display lines for the edit picker, filtering non-existent files
--- @param edits table[] Array of edit entries
--- @return string[] lines Display lines for the floating window
--- @return table[] valid_edits Filtered edits (only files that exist)
local function build_display_lines(edits)
	local lines = {}
	local valid_edits = {}
	for _, edit in ipairs(edits) do
		-- Only include edits for files that still exist
		if vim.fn.filereadable(edit.filepath) == 1 then
			-- Show path relative to cwd, with ~ for home directory
			local filepath = vim.fn.fnamemodify(edit.filepath, ":~:.")
			local line_num = edit.line_number or 1
			table.insert(
				lines,
				string.format("%s:%d  %s +%d/-%d", filepath, line_num, edit.operation, edit.lines_added, edit.lines_removed)
			)
			table.insert(valid_edits, edit)
		end
	end
	return lines, valid_edits
end

--- Calculate floating window options (centered horizontally and vertically)
--- @param lines string[] Content lines to size the window
--- @return table opts Window configuration options
local function get_float_opts(lines)
	local width = float_config.width
	local height = math.min(#lines, float_config.max_height)

	-- Center both horizontally and vertically (matching spawn_menu positioning)
	local row = math.floor((vim.o.lines - height) / 2)
	local col = math.floor((vim.o.columns - width) / 2)

	return {
		relative = "editor",
		width = width,
		height = height,
		row = row,
		col = col,
		style = "minimal",
		border = float_config.border,
		title = " Claude Edits ",
		title_pos = "center",
		zindex = float_config.zindex,
	}
end

--- Jump to a specific edit location by replacing current buffer
--- @param edit table Edit entry with filepath and line_number
local function jump_to_edit(edit)
	-- Check file exists
	if vim.fn.filereadable(edit.filepath) ~= 1 then
		vim.notify("File not found: " .. edit.filepath, vim.log.levels.ERROR)
		return
	end

	-- Find or create buffer for the file
	local target_buf = vim.fn.bufadd(edit.filepath)
	vim.fn.bufload(target_buf)

	-- Replace current window's buffer
	vim.api.nvim_set_current_buf(target_buf)

	-- Jump to line
	if edit.line_number then
		vim.api.nvim_win_set_cursor(0, { edit.line_number, 0 })
		vim.cmd("normal! zz") -- Center on screen
	end

	vim.notify(
		string.format("Jumped to %s:%d (%s)", vim.fn.fnamemodify(edit.filepath, ":t"), edit.line_number or 1, edit.operation),
		vim.log.levels.INFO
	)
end

--- Jump to the currently selected edit in the picker
local function jump_to_selected_edit()
	if not M.is_picker_open() then
		return
	end

	local cursor = vim.api.nvim_win_get_cursor(state.state.edit_picker.win)
	local idx = cursor[1] -- 1-indexed line number
	local edit = state.state.edit_picker.edits[idx]

	if edit then
		close_edit_picker()
		jump_to_edit(edit)
	end
end

--- Setup buffer-local keymaps for the floating edit picker
--- @param buf number Buffer ID
local function setup_float_keymaps(buf)
	local opts = { buffer = buf, noremap = true, silent = true }

	-- Navigate and select
	vim.keymap.set("n", "<CR>", jump_to_selected_edit, opts)

	-- Close
	vim.keymap.set("n", "<Esc>", close_edit_picker, opts)
	vim.keymap.set("n", "q", close_edit_picker, opts)
end

--- Show the floating edit picker window
--- @param edits table[] Array of edit entries
local function show_floating_window(edits)
	if #edits == 0 then
		vim.notify("No edits found in this Claude session yet", vim.log.levels.INFO)
		return
	end

	-- Close existing window if open
	close_edit_picker()

	-- Reverse edits so most recent appears at the top
	local reversed_edits = {}
	for i = #edits, 1, -1 do
		table.insert(reversed_edits, edits[i])
	end

	-- Build display lines and filter to only existing files
	local lines, valid_edits = build_display_lines(reversed_edits)

	-- Check if any valid edits remain after filtering
	if #lines == 0 then
		vim.notify("No valid edits found (files may have been deleted)", vim.log.levels.INFO)
		return
	end

	-- Create buffer
	local buf = vim.api.nvim_create_buf(false, true)
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].modifiable = true

	-- Set content
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

	-- Make buffer non-modifiable after setting content
	vim.bo[buf].modifiable = false

	-- Create floating window (centered, sized to content)
	local win_opts = get_float_opts(lines)
	local win = vim.api.nvim_open_win(buf, true, win_opts)

	-- Window options
	vim.wo[win].cursorline = true
	vim.wo[win].number = false
	vim.wo[win].relativenumber = false
	vim.wo[win].signcolumn = "no"
	vim.wo[win].wrap = false

	-- Store state (valid_edits matches display line indices after filtering)
	state.state.edit_picker.win = win
	state.state.edit_picker.buf = buf
	state.state.edit_picker.edits = valid_edits

	-- Setup keymaps
	setup_float_keymaps(buf)

	-- Auto-close on leave
	vim.api.nvim_create_autocmd({ "WinLeave", "BufLeave" }, {
		buffer = buf,
		once = true,
		callback = function()
			vim.schedule(close_edit_picker)
		end,
	})
end

-- ============================================================
-- PARSING UTILITIES
-- ============================================================

--- Strip ANSI escape codes from a line
--- Handles CSI sequences (colors, cursor), OSC sequences (title), and extended color codes
--- @param line string Input line potentially containing ANSI codes
--- @return string Cleaned line without ANSI codes
local function strip_ansi(line)
	-- CSI sequences: ESC [ <params> <command>
	-- Covers: colors (m), cursor movement (HABCD), clear (JK), save/restore (su)
	line = line:gsub("\27%[[0-9;]*[mHABCDJKsu]", "")

	-- OSC sequences: ESC ] ... BEL or ESC ] ... ST
	-- Used for terminal title, hyperlinks, etc.
	line = line:gsub("\27%][^\7\27]*\7", "") -- BEL terminator
	line = line:gsub("\27%][^\27]*\27\\", "") -- ST terminator (ESC \)

	-- Extended color sequences (256-color and true color)
	-- Format: ESC[38;5;Nm or ESC[48;5;Nm (256-color)
	-- Format: ESC[38;2;R;G;Bm or ESC[48;2;R;G;Bm (true color)
	line = line:gsub("\27%[[34]8;[25];[0-9;]*m", "")

	return line
end

--- Parse a single line for operation start (Update/Edit/Write)
--- @param line string The cleaned line to parse
--- @return string|nil operation Operation type if matched
--- @return string|nil filepath File path if matched
local function parse_operation_line(line)
	-- Match: ● Update(filepath) or ● Edit(filepath) or ● Write(filepath)
	-- The bullet may have surrounding whitespace
	local op, filepath = line:match("^%s*●%s+(%w+)%((.+)%)%s*$")
	if op and filepath then
		-- Normalize operation to known types
		local known_ops = { Update = true, Edit = true, Write = true }
		if known_ops[op] then
			return op, filepath
		end
	end
	return nil, nil
end

--- Parse summary line for added/removed counts
--- @param line string The cleaned line to parse
--- @return number|nil added Lines added count
--- @return number|nil removed Lines removed count
local function parse_summary_line(line)
	-- Match: "Added N lines, removed M lines" or variants
	-- Handle singular "line" and plural "lines"
	local added, removed = line:match("Added%s+(%d+)%s+lines?,%s+removed%s+(%d+)%s+lines?")
	if added and removed then
		return tonumber(added), tonumber(removed)
	end
	return nil, nil
end

--- Parse diff line for line number
--- @param line string The cleaned line to parse
--- @return number|nil line_number The line number from the diff
local function parse_diff_line(line)
	-- Match: leading whitespace, line number, whitespace, +/- indicator
	-- Examples: "  260 +  return build_winbar_string()" or "  263 -old code"
	local line_num = line:match("^%s*(%d+)%s+[%+%-]")
	if line_num then
		return tonumber(line_num)
	end
	return nil
end

--- Resolve a filepath relative to instance's working directory
--- Normalizes the path to handle ../, ./, and other path components
--- @param filepath string The file path from Claude output
--- @param cwd string The working directory of the Claude instance
--- @return string Resolved and normalized absolute path
local function resolve_filepath(filepath, cwd)
	-- If already absolute, normalize and return
	if filepath:sub(1, 1) == "/" then
		return vim.fn.fnamemodify(filepath, ":p")
	end

	-- Handle ~ expansion first, then normalize
	if filepath:sub(1, 1) == "~" then
		return vim.fn.fnamemodify(vim.fn.expand(filepath), ":p")
	end

	-- Relative path - join with cwd and normalize (handles ../ properly)
	return vim.fn.fnamemodify(cwd .. "/" .. filepath, ":p")
end

-- ============================================================
-- BUFFER PARSING
-- ============================================================

--- Parse a terminal buffer for edit entries
--- @param buf number Terminal buffer ID
--- @param instance table Instance object with cwd
--- @return table[] Array of edit entries
local function parse_buffer_for_edits(buf, instance)
	if not vim.api.nvim_buf_is_valid(buf) then
		return {}
	end

	-- Get all lines from the terminal buffer
	local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
	local edits = {}
	local current_edit = nil

	for _, raw_line in ipairs(lines) do
		local line = strip_ansi(raw_line)

		-- Check for operation start
		local op, filepath = parse_operation_line(line)
		if op and filepath then
			-- Save previous edit if exists
			if current_edit then
				table.insert(edits, current_edit)
			end

			-- Start new edit entry
			current_edit = {
				filepath = resolve_filepath(filepath, instance.cwd),
				operation = op,
				line_number = nil,
				lines_added = 0,
				lines_removed = 0,
				timestamp = os.time(),
			}
		elseif current_edit then
			-- We're inside an edit block, look for summary and line numbers
			local added, removed = parse_summary_line(line)
			if added and removed then
				current_edit.lines_added = added
				current_edit.lines_removed = removed
			end

			-- Look for line numbers in diff (take first one for jump location)
			if not current_edit.line_number then
				local line_num = parse_diff_line(line)
				if line_num then
					current_edit.line_number = line_num
				end
			end
		end
	end

	-- Only save the last edit if it has valid summary data (not mid-stream)
	if current_edit and (current_edit.lines_added > 0 or current_edit.lines_removed > 0) then
		table.insert(edits, current_edit)
	end

	return edits
end

--- Get edits for a buffer by parsing its content
--- @param buf number Terminal buffer ID
--- @param instance table Instance object
--- @return table[] Array of edit entries
local function get_edits_for_instance(buf, instance)
	-- Always re-parse (on-demand, no caching of results to ensure freshness)
	return parse_buffer_for_edits(buf, instance)
end

-- ============================================================
-- CONTEXT DETECTION
-- ============================================================

--- Determine which instance to use based on context
--- @param num number|nil Optional instance number
--- @return table|nil instance The selected instance
--- @return boolean needs_picker Whether picker should be shown
local function determine_instance(num)
	if not instances then
		return nil, false
	end

	local project_instances = instances.get_for_current_project()

	-- No instances
	if #project_instances == 0 then
		return nil, false
	end

	-- Instance number provided
	if num then
		if num >= 1 and num <= #project_instances then
			return project_instances[num], false
		else
			vim.notify(
				string.format("Invalid instance number %d. Valid range: 1-%d", num, #project_instances),
				vim.log.levels.WARN
			)
			return nil, false
		end
	end

	-- Check if currently in a Claude terminal
	local current_buf = vim.api.nvim_get_current_buf()
	local current_instance = instances.get_by_buf(current_buf)
	if current_instance then
		return current_instance, false
	end

	-- Single instance - use it directly
	if #project_instances == 1 then
		return project_instances[1], false
	end

	-- Multiple instances - need picker
	return nil, true
end

-- ============================================================
-- PUBLIC API
-- ============================================================

--- Get all edits from an instance
--- @param num number|nil Instance number (optional)
--- @param callback function|nil Callback for async picker (receives edits array)
--- @return table[]|nil edits Array of edits if synchronous, nil if picker shown
function M.get_edits(num, callback)
	local instance, needs_picker = determine_instance(num)

	if needs_picker then
		if not picker then
			vim.notify("Multiple instances exist. Specify instance number.", vim.log.levels.WARN)
			return nil
		end

		picker.select_existing(function(term)
			local inst = instances.get_by_buf(term.buf)
			if inst then
				local edits = get_edits_for_instance(term.buf, inst)
				if callback then
					callback(edits)
				end
			end
		end)
		return nil
	end

	if not instance then
		vim.notify("No Claude instances in current project", vim.log.levels.WARN)
		return nil
	end

	-- Synchronous path: return edits directly, don't call callback
	-- (callback is only for async picker path)
	local edits = get_edits_for_instance(instance.buf, instance)
	return edits
end

--- Show all edits in a floating picker window
--- @param num number|nil Instance number (optional)
function M.show_edits(num)
	local edits = M.get_edits(num, show_floating_window)
	if edits then
		show_floating_window(edits)
	end
end

--- Jump to the most recent edit (or Nth most recent)
--- @param num number|nil Instance number OR negative for Nth most recent edit
function M.jump_to_last_edit(num)
	-- Parse num: positive = instance number, negative = Nth most recent
	local instance_num = nil
	local edit_offset = 1 -- 1 = most recent

	if num then
		if num < 0 then
			edit_offset = math.abs(num)
		else
			instance_num = num
		end
	end

	local function process_edits(edits)
		if #edits == 0 then
			vim.notify("No edits found in Claude output", vim.log.levels.INFO)
			return
		end

		-- Get Nth most recent (from end of array)
		local idx = #edits - edit_offset + 1
		if idx < 1 then
			idx = 1
		end

		local edit = edits[idx]
		jump_to_edit(edit)
	end

	local edits = M.get_edits(instance_num, process_edits)
	if edits then
		process_edits(edits)
	end
end

--- Close the edit picker if open (public API for cleanup)
function M.close_picker()
	close_edit_picker()
end

--- Check if the edit picker is currently open
--- @return boolean is_open
function M.is_picker_open()
	return state.state.edit_picker.win ~= nil and vim.api.nvim_win_is_valid(state.state.edit_picker.win)
end

--- Cleanup function for teardown
function M.teardown()
	close_edit_picker()
end

return M
