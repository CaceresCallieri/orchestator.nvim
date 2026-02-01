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

-- Search limits (extracted as constants for readability)
local HEADER_SEARCH_LIMIT = 1000 -- Max lines to search backwards for edit header
local CONTENT_MATCH_RANGE = 20 -- Search ±N lines for content match fallback

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
	-- Prevent re-entrance from simultaneous WinLeave/BufLeave autocmd firing
	if state.state.edit_picker.closing then
		return
	end
	state.state.edit_picker.closing = true

	-- Clear autocmds before closing to prevent additional triggers
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
	state.state.edit_picker.closing = nil -- Reset for next time
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
--- Handles SGR sequences (colors, styles), cursor/clear sequences, and OSC sequences
--- @param line string Input line potentially containing ANSI codes
--- @return string Cleaned line without ANSI codes
local function strip_ansi(line)
	-- SGR sequences (colors, styles): ESC[...m
	-- This handles all color codes including 256-color (38;5;N) and truecolor (38;2;R;G;B)
	line = line:gsub("\27%[[0-9;]*m", "")

	-- Cursor/clear sequences: ESC[...H/A/B/C/D/J/K/s/u
	line = line:gsub("\27%[[0-9;]*[HABCDJKsu]", "")

	-- OSC sequences (title, hyperlinks): ESC]...BEL or ESC]...ST
	line = line:gsub("\27%][^\7\27]*\7", "") -- BEL terminator
	line = line:gsub("\27%][^\27]*\27\\", "") -- ST terminator (ESC \)

	-- Single-char escape sequences (save/restore cursor: ESC 7 and ESC 8)
	line = line:gsub("\27[78]", "")

	return line
end

--- Normalize a line for content comparison (trim leading/trailing whitespace)
--- @param str string Input string
--- @return string Normalized string
local function normalize_for_match(str)
	return str:gsub("^%s+", ""):gsub("%s+$", "")
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

--- Parse diff line for line number (simple version for edit detection)
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

--- Parse a diff line and extract full information for cursor positioning
--- Handles diff lines with +/- indicators AND context lines (no indicator)
--- @param line string Cleaned line (ANSI stripped)
--- @return table|nil result {line_num, indicator, prefix_len}
local function parse_diff_line_full(line)
	-- First try: Match lines with +/- indicator
	-- Pattern: (leading_ws)(line_num)(mid_ws)(indicator +/-)
	local leading_ws, line_num, mid_ws, indicator = line:match("^(%s*)(%d+)(%s+)([%+%-])")

	if line_num then
		-- Prefix = leading whitespace + line number + middle whitespace + indicator
		local prefix_len = #leading_ws + #line_num + #mid_ws + 1
		return {
			line_num = tonumber(line_num),
			indicator = indicator,
			prefix_len = prefix_len,
		}
	end

	-- Second try: Match context lines (no +/- indicator, just whitespace after line number)
	-- These show unchanged lines for context in the diff
	-- Pattern: leading_ws + line_num + whitespace (at least 2 spaces to distinguish from regular text)
	leading_ws, line_num, mid_ws = line:match("^(%s*)(%d+)(%s%s+)")

	if line_num then
		-- For context lines, prefix = leading whitespace + line number + middle whitespace
		local prefix_len = #leading_ws + #line_num + #mid_ws
		return {
			line_num = tonumber(line_num),
			indicator = " ", -- context line indicator
			prefix_len = prefix_len,
		}
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

--- Search backwards from current line to find edit header (● Update/Edit/Write)
--- @param buf number Buffer ID
--- @param start_line number Line to start searching from (0-indexed)
--- @param cwd string Working directory for path resolution
--- @return string|nil filepath The resolved file path, or nil if not found
local function find_edit_header_backwards(buf, start_line, cwd)
	-- Limit search to prevent scanning entire large terminal buffer
	local search_start = math.max(0, start_line - HEADER_SEARCH_LIMIT)

	local lines = vim.api.nvim_buf_get_lines(buf, search_start, start_line + 1, false)

	-- Search from end (current line) backwards to find most recent header
	for i = #lines, 1, -1 do
		local line = lines[i]
		-- Quick check: only strip ANSI if line might contain header marker
		-- This avoids expensive regex on every line in long buffers
		if line:find("●", 1, true) then
			local clean_line = strip_ansi(line)
			local op, filepath = parse_operation_line(clean_line)
			if op and filepath then
				return resolve_filepath(filepath, cwd)
			end
		end
	end

	return nil
end

-- ============================================================
-- JUMP-TO-DIFF HELPERS
-- ============================================================

--- @class JumpContext
--- @field buf number Terminal buffer ID
--- @field instance table Claude instance with cwd
--- @field cursor_line number 0-indexed line number
--- @field cursor_col number 0-indexed column number
--- @field clean_line string ANSI-stripped line content

--- Validate that jump can be performed from current context
--- @return JumpContext|nil context Context table or nil on failure
local function validate_jump_context()
	if not instances then
		vim.notify("Edit tracker not initialized", vim.log.levels.ERROR)
		return nil
	end

	-- Verify we're in a Claude terminal buffer
	local current_buf = vim.api.nvim_get_current_buf()
	local instance = instances.get_by_buf(current_buf)

	if not instance then
		vim.notify("Not in a Claude terminal buffer", vim.log.levels.WARN)
		return nil
	end

	-- Get cursor position (1-indexed line, 0-indexed column)
	local cursor = vim.api.nvim_win_get_cursor(0)
	local cursor_line = cursor[1] - 1 -- Convert to 0-indexed for buf_get_lines
	local cursor_col = cursor[2] -- Already 0-indexed

	-- Get the current line
	local lines = vim.api.nvim_buf_get_lines(current_buf, cursor_line, cursor_line + 1, false)
	if #lines == 0 then
		vim.notify("Could not read current line", vim.log.levels.ERROR)
		return nil
	end

	local raw_line = lines[1]
	local clean_line = strip_ansi(raw_line)

	return {
		buf = current_buf,
		instance = instance,
		cursor_line = cursor_line,
		cursor_col = cursor_col,
		clean_line = clean_line,
	}
end

--- @class HeaderJumpResult
--- @field handled boolean Whether this was a header line
--- @field success boolean Whether jump succeeded (only valid if handled)

--- Attempt to jump if cursor is on an edit header line (● Update/Edit/Write)
--- @param clean_line string ANSI-stripped line content
--- @param instance table Claude instance with cwd
--- @return HeaderJumpResult result {handled=true/false, success=true/false}
local function try_jump_to_header_line(clean_line, instance)
	local op, filepath = parse_operation_line(clean_line)
	if not op or not filepath then
		return { handled = false, success = false }
	end

	local resolved_path = resolve_filepath(filepath, instance.cwd)
	if vim.fn.filereadable(resolved_path) ~= 1 then
		vim.notify("File not found: " .. resolved_path, vim.log.levels.ERROR)
		return { handled = true, success = false }
	end

	-- Jump to file at line 1, column 0
	local target_buf = vim.fn.bufadd(resolved_path)
	vim.fn.bufload(target_buf)
	vim.api.nvim_set_current_buf(target_buf)
	vim.api.nvim_win_set_cursor(0, { 1, 0 })
	vim.cmd("normal! zz")

	vim.notify(string.format("Jumped to %s:1", vim.fn.fnamemodify(resolved_path, ":t")), vim.log.levels.INFO)
	return { handled = true, success = true }
end

--- Find target file by searching backwards for edit header
--- @param buf number Terminal buffer ID
--- @param cursor_line number 0-indexed cursor line
--- @param instance table Claude instance with cwd
--- @return string|nil filepath Resolved filepath or nil if header not found
local function find_target_file(buf, cursor_line, instance)
	local header_filepath = find_edit_header_backwards(buf, cursor_line, instance.cwd)
	if not header_filepath then
		vim.notify("Could not find edit header (● Update/Edit/Write)", vim.log.levels.WARN)
		return nil
	end
	return header_filepath
end

--- Handle jump for deleted lines (- indicator)
--- @param target_buf number Target file buffer
--- @param filepath string Target file path
--- @param diff_info table Parsed diff info with line_num
--- @return boolean success Always returns true
local function handle_deleted_line_jump(target_buf, filepath, diff_info)
	local file_lines = vim.api.nvim_buf_line_count(target_buf)
	local target_line = math.min(diff_info.line_num, file_lines)

	vim.api.nvim_win_set_cursor(0, { target_line, 0 })
	vim.cmd("normal! zz")

	vim.notify(
		string.format("Line was deleted - jumped to %s:%d", vim.fn.fnamemodify(filepath, ":t"), target_line),
		vim.log.levels.INFO
	)
	return true
end

--- Search nearby lines for matching content when line numbers have shifted
--- @param target_buf number Target file buffer
--- @param expected_content string Expected line content (after diff prefix)
--- @param target_line number Original target line number (1-indexed)
--- @param file_lines number Total lines in file
--- @return number adjusted_line The found or original line number
--- @return boolean content_mismatch Whether content was not found at original position
local function search_content_nearby(target_buf, expected_content, target_line, file_lines)
	-- Clamp target_line to valid range
	target_line = math.max(1, math.min(target_line, file_lines))

	local target_line_content = vim.api.nvim_buf_get_lines(target_buf, target_line - 1, target_line, false)[1] or ""
	local expected_normalized = normalize_for_match(expected_content)

	-- For whitespace-only content, skip search (unreliable for matching)
	if expected_normalized == "" then
		return target_line, false
	end

	-- Check if content matches at expected position
	if normalize_for_match(target_line_content) == expected_normalized then
		return target_line, false
	end

	-- Content mismatch - search nearby
	local start_search = math.max(1, target_line - CONTENT_MATCH_RANGE)
	local end_search = math.min(file_lines, target_line + CONTENT_MATCH_RANGE)
	local nearby_lines = vim.api.nvim_buf_get_lines(target_buf, start_search - 1, end_search, false)

	for i, line in ipairs(nearby_lines) do
		if normalize_for_match(line) == expected_normalized then
			return start_search + i - 1, true
		end
	end

	return target_line, true -- Content not found nearby, return original
end

--- Notify user about content shift if applicable
--- @param original_line number Original target line
--- @param adjusted_line number Adjusted line after search
--- @param content_mismatch boolean Whether content didn't match original position
local function notify_content_shift(original_line, adjusted_line, content_mismatch)
	if not content_mismatch then
		return
	end

	local offset = adjusted_line - original_line
	if offset ~= 0 then
		vim.notify(
			string.format("File changed since edit: adjusted %+d lines", offset),
			vim.log.levels.INFO
		)
	else
		vim.notify(
			"File changed since edit: content not found nearby",
			vim.log.levels.WARN
		)
	end
end

--- Calculate final cursor position with proper clamping
--- @param target_line number Target line number (1-indexed)
--- @param source_col number Source column from diff (0-indexed)
--- @param line_content string Content of the target line (passed to avoid redundant read)
--- @return number line Line number (unchanged)
--- @return number col Clamped column number
local function calculate_cursor_position(target_line, source_col, line_content)
	-- Handle empty lines
	if #line_content == 0 then
		return target_line, 0
	end

	-- Clamp column to line length (byte-based for nvim_win_set_cursor)
	-- Valid positions are 0 to #content (cursor can be at end of line)
	local target_col = math.min(source_col, #line_content)
	return target_line, target_col
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

--- Jump to source file location from a diff line under cursor
--- Works only in Claude terminal buffers in NORMAL mode
--- Parses the diff line to extract line number and calculates exact column position
--- @return boolean success True if jump was successful
function M.jump_to_diff_location()
	-- 1. Validate context
	local ctx = validate_jump_context()
	if not ctx then
		return false
	end

	-- 2. Try header line jump first (● Update/Edit/Write)
	local header_result = try_jump_to_header_line(ctx.clean_line, ctx.instance)
	if header_result.handled then
		return header_result.success
	end

	-- 3. Parse as diff line
	local diff_info = parse_diff_line_full(ctx.clean_line)
	if not diff_info then
		vim.notify("Cursor not on a diff line", vim.log.levels.WARN)
		return false
	end

	-- 4. Find target file by searching backwards for edit header
	local filepath = find_target_file(ctx.buf, ctx.cursor_line, ctx.instance)
	if not filepath then
		return false
	end

	-- 5. Verify file exists and open buffer
	if vim.fn.filereadable(filepath) ~= 1 then
		vim.notify("File not found: " .. filepath, vim.log.levels.ERROR)
		return false
	end
	local target_buf = vim.fn.bufadd(filepath)
	vim.fn.bufload(target_buf)
	vim.api.nvim_set_current_buf(target_buf)

	-- 6. Handle deleted lines specially
	if diff_info.indicator == "-" then
		return handle_deleted_line_jump(target_buf, filepath, diff_info)
	end

	-- 7. Calculate source column and search for content
	-- Subtract diff prefix (leading ws + line number + middle ws + indicator)
	local source_col = math.max(0, ctx.cursor_col - diff_info.prefix_len)
	local file_lines = vim.api.nvim_buf_line_count(target_buf)
	local target_line = math.min(diff_info.line_num, file_lines)
	local expected_content = ctx.clean_line:sub(diff_info.prefix_len + 1)

	local adjusted_line, content_mismatch = search_content_nearby(
		target_buf, expected_content, target_line, file_lines
	)

	-- 8. Notify about content shift if applicable
	notify_content_shift(target_line, adjusted_line, content_mismatch)

	-- 9. Get line content and calculate final cursor position
	local line_content = vim.api.nvim_buf_get_lines(target_buf, adjusted_line - 1, adjusted_line, false)[1] or ""
	local final_line, final_col = calculate_cursor_position(adjusted_line, source_col, line_content)
	vim.api.nvim_win_set_cursor(0, { final_line, final_col })
	vim.cmd("normal! zz")

	vim.notify(
		string.format("Jumped to %s:%d:%d", vim.fn.fnamemodify(filepath, ":t"), final_line, final_col + 1),
		vim.log.levels.INFO
	)
	return true
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
