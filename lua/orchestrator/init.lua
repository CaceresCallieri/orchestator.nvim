-- Orchestrator Module
-- Main entry point and public API for orchestrator.nvim
-- Orchestrates all sub-modules for a unified experience

---@class OrchestratorModule
local M = {}

-- Unified debug log (shared timeline with Symmetria QML/C++/bash)
local _stt_log_path = (os.getenv("XDG_STATE_HOME") or (os.getenv("HOME") .. "/.local/state"))
	.. "/symmetria/debug.log"
local function _stt_log(msg)
	local f = io.open(_stt_log_path, "a")
	if f then
		local ms = math.floor((vim.uv.hrtime() / 1e6) % 1000)
		f:write(string.format("%s.%03d [lua:stt] %s\n", os.date("%H:%M:%S"), ms, msg))
		f:close()
	end
end

-- ============================================================
-- CONFIGURATION
-- ============================================================

--- Default configuration
--- @type table
local default_config = {
	keymaps = {
		-- Buffer-local keymaps for prompt editor (set to false to disable)
		-- NOTE: <C-Tab> and <C-S-Tab> require terminal support for modified keys.
		-- If these don't work in your terminal, configure custom keymaps via setup()
		-- or use the <Plug>(OrchestratorXxx) mappings directly.
		prompt_editor = {
			send = "<CR>", -- Send prompt to Claude (normal mode only)
			close = "<Esc>", -- Close editor (normal mode)
			next_tab = "<C-Tab>", -- Next prompt tab
			prev_tab = "<C-S-Tab>", -- Previous prompt tab
			new_tab = "<C-S-n>", -- New prompt tab
			delete_tab = "<C-S-x>", -- Delete current tab
		},
		-- Buffer-local keymaps for Claude terminal buffers (set to false to disable)
		terminal = {
			close = "<C-S-q>", -- Close current Claude instance
			jump_to_diff = "gd", -- Jump to source file from diff line
			jump_to_prompt = "gp", -- Jump to last user prompt
			jump_to_plan = "gP", -- Jump to last plan
			open_url = "gx", -- Open URL under cursor
		},
	},
	-- Dangerous mode configuration (--dangerously-skip-permissions)
	dangerous_mode = {
		enabled = true, -- Set to false to completely disable dangerous mode
		require_confirmation = false, -- Prompt user before spawning in dangerous mode
	},
}

--- Active configuration (merged with user opts)
--- @type table
local config = {}

-- Load sub-modules
local state = require("orchestrator.state")
local highlights = require("orchestrator.highlights")
local instances = require("orchestrator.instances")
local status_bar = require("orchestrator.status_bar")
local picker = require("orchestrator.picker")
local editor = require("orchestrator.editor")
local terminal = require("orchestrator.terminal")
local spawn_menu = require("orchestrator.spawn_menu")
local edit_tracker = require("orchestrator.edit_tracker")
local url_handler = require("orchestrator.url_handler")
local bridge = require("orchestrator.bridge")

-- Create autocmd group
local augroup = vim.api.nvim_create_augroup("Orchestrator", { clear = true })

-- Debounce timer for terminal title updates
local title_update_timer = nil
local TITLE_DEBOUNCE_MS = 50

-- Whether this Neovim's terminal window currently has focus.
-- Toggled by FocusGained/FocusLost autocmds (terminal sends focus escape sequences).
-- Used by STT socket selection: only the focused Neovim gets injected into.
local has_terminal_focus = false

-- ============================================================
-- PUBLIC API: Editor Functions
-- ============================================================

--- Toggle the floating prompt editor
function M.toggle()
	editor.toggle()
end

--- Open the floating prompt editor
function M.open()
	editor.open()
end

--- Close the floating prompt editor
function M.close()
	editor.close()
end

-- ============================================================
-- PUBLIC API: Editor Tab Functions
-- ============================================================

--- Create a new prompt editor tab
function M.new_tab()
	editor.new_tab()
end

--- Navigate to the next prompt editor tab
function M.next_tab()
	editor.next_tab()
end

--- Navigate to the previous prompt editor tab
function M.prev_tab()
	editor.prev_tab()
end

--- Delete the current prompt editor tab
function M.delete_tab()
	editor.delete_tab()
end

-- ============================================================
-- PUBLIC API: Status Bar Functions
-- ============================================================

--- Show the status bar
function M.show_status_bar()
	status_bar.show()
end

--- Hide the status bar
function M.hide_status_bar()
	status_bar.hide()
end

--- Toggle the status bar visibility
function M.toggle_status_bar()
	status_bar.toggle()
end

-- ============================================================
-- PUBLIC API: Instance Functions
-- ============================================================

--- Get all tracked Claude instances
--- @return table[] Array of {buf, job_id, color_idx, number, win, cwd, spawn_type, spawned_at}
function M.get_claude_instances()
	return instances.get_all()
end

--- Get Claude instances for current project only
--- @return table[] Array of instances in current cwd
function M.get_project_instances()
	return instances.get_for_current_project()
end

-- ============================================================
-- PUBLIC API: Terminal Spawning
-- ============================================================

--- Spawn a new Claude terminal
--- @param spawn_type string|nil "fresh" (default), "resume", or "continue"
--- @param opts table|nil Options { dangerous = boolean }
--- @return table|nil instance The spawned instance
function M.spawn(spawn_type, opts)
	opts = opts or {}

	-- Check dangerous mode configuration
	if opts.dangerous then
		if not config.dangerous_mode.enabled then
			vim.notify(
				"Dangerous mode is disabled. Enable via setup({ dangerous_mode = { enabled = true } })",
				vim.log.levels.ERROR
			)
			return nil
		end

		if config.dangerous_mode.require_confirmation then
			local confirmed = vim.fn.confirm(
				"Spawn Claude with --dangerously-skip-permissions?\n" .. "This bypasses all permission checks.",
				"&Yes\n&No",
				2 -- default to No
			)
			if confirmed ~= 1 then
				return nil
			end
		end
	end

	-- Pass kill function for terminal buffer keymap setup
	opts.kill_fn = M.kill_current_or_pick

	return terminal.spawn(spawn_type or "fresh", opts)
end

--- Show unified picker to spawn or select Claude terminal
function M.pick()
	picker.select(function(term)
		if not term.is_new then
			terminal.focus(term)
		end
	end)
end

--- Kill a Claude instance by project-local number
--- @param num number|nil Instance number (1-indexed, within current project)
function M.kill(num)
	local project_instances = instances.get_for_current_project()

	if #project_instances == 0 then
		vim.notify("No Claude instances in current project", vim.log.levels.WARN)
		return
	end

	if not num then
		vim.notify("Usage: :AgentsKill <number> (1-" .. #project_instances .. ")", vim.log.levels.WARN)
		return
	end

	if num < 1 or num > #project_instances then
		vim.notify(
			string.format("Invalid instance number %d. Valid range: 1-%d", num, #project_instances),
			vim.log.levels.WARN
		)
		return
	end

	terminal.kill(project_instances[num])
	vim.notify(string.format("Killed Claude instance %d", num), vim.log.levels.INFO)
end

--- Kill current Claude instance or pick one to kill
--- Context-aware: if inside Claude terminal, kills it; otherwise shows picker
function M.kill_current_or_pick()
	local current_buf = vim.api.nvim_get_current_buf()
	local current_instance = instances.get_by_buf(current_buf)

	if current_instance then
		-- Inside a Claude terminal - kill this instance directly
		terminal.kill(current_instance)
		return
	end

	-- Not inside a Claude terminal - check for project instances
	local project_instances = instances.get_for_current_project()

	if #project_instances == 0 then
		vim.notify("No Claude instances in current project", vim.log.levels.WARN)
		return
	end

	-- Single instance: skip picker for efficiency
	if #project_instances == 1 then
		terminal.kill(project_instances[1])
		return
	end

	-- Multiple instances: show picker
	picker.select_existing(function(term)
		local inst = instances.get_by_buf(term.buf)
		if inst then
			terminal.kill(inst)
		end
	end)
end

--- Focus a Claude instance by project-local number
--- @param num number|nil Instance number (1-indexed, within current project)
function M.focus(num)
	local project_instances = instances.get_for_current_project()

	-- No instances exist - show spawn menu
	if #project_instances == 0 then
		spawn_menu.show(num)
		return
	end

	-- No number provided - show usage
	if not num then
		vim.notify("Usage: :AgentsFocus <number> (1-" .. #project_instances .. ")", vim.log.levels.WARN)
		return
	end

	-- Instance number out of range - show spawn menu
	if num < 1 or num > #project_instances then
		spawn_menu.show(num)
		return
	end

	terminal.focus(project_instances[num])
end

-- ============================================================
-- PUBLIC API: Edit Tracker Functions
-- ============================================================

--- Show all edits from Claude in quickfix list
--- @param num number|nil Instance number (1-indexed, within current project)
function M.show_edits(num)
	edit_tracker.show_edits(num)
end

--- Jump to the most recent edit location
--- @param num number|nil Instance number (1-indexed, within current project)
function M.jump_to_last_edit(num)
	edit_tracker.jump_to_last_edit(num)
end

--- Close the edit picker if open
function M.close_edit_picker()
	edit_tracker.close_picker()
end

--- Jump to source file location from diff line under cursor
--- Only works when cursor is in a Claude terminal buffer in normal mode
--- @return boolean success True if jump was successful
function M.jump_to_diff_location()
	return edit_tracker.jump_to_diff_location()
end

--- Jump to the last user prompt (or Nth previous)
--- Only works when cursor is in a Claude terminal buffer
--- @param count number|nil How many prompts to go back (default: 1)
--- @return boolean success True if jump was successful
function M.jump_to_last_prompt(count)
	return edit_tracker.jump_to_last_prompt(count)
end

--- Jump to the last plan header (or Nth previous)
--- Only works when cursor is in a Claude terminal buffer
--- @param count number|nil How many plans to go back (default: 1)
--- @return boolean success True if jump was successful
function M.jump_to_last_plan(count)
	return edit_tracker.jump_to_last_plan(count)
end

-- ============================================================
-- PUBLIC API: URL Handler Functions
-- ============================================================

--- Open the URL nearest to the cursor on the current line
--- Only works when cursor is in a Claude terminal buffer in normal mode
--- @return boolean success True if a URL was opened
function M.open_url_at_cursor()
	return url_handler.open_url_at_cursor()
end

-- ============================================================
-- PUBLIC API: STT Targeting & Injection (External RPC)
-- ============================================================

--- Get targeting info for STT socket selection.
--- Lightweight query — no side effects, no file I/O.
--- Called via: nvim --server <sock> --remote-expr 'luaeval("require(\"orchestrator\").stt_target_info()")'
--- @return string JSON: {"has_instances": bool, "has_focus": bool, "last_active_buf": number}
function M.stt_target_info()
	local active_buf = state.state.last_active_buf
	local buf_num = -1
	local title = ""
	local cwd = ""

	-- Resolve target buffer: last_active_buf, then single-instance fallback
	-- (mirrors the priority chain in stt_inject)
	local target_buf = nil
	if active_buf ~= nil and vim.api.nvim_buf_is_valid(active_buf) then
		target_buf = active_buf
	elseif #state.state.claude_instances == 1 then
		-- Single instance: unambiguous target even without BufEnter tracking
		target_buf = state.state.claude_instances[1].buf
	end

	if target_buf and vim.api.nvim_buf_is_valid(target_buf) then
		buf_num = target_buf
		-- Get title from term_title (same source as winbar, filters shell names)
		title = status_bar.get_instance_title(target_buf) or ""
		-- Find instance for this buffer to get project cwd
		for _, inst in ipairs(state.state.claude_instances) do
			if inst.buf == target_buf then
				cwd = inst.cwd or ""
				break
			end
		end
	end

	return vim.json.encode({
		has_instances = #state.state.claude_instances > 0,
		has_focus = has_terminal_focus,
		last_active_buf = buf_num,
		instance_title = title,
		instance_cwd = cwd,
	})
end

--- Inject text from STT into the last active Claude instance.
--- Designed for external RPC callers (no UI, returns JSON).
--- Called via: nvim --server <sock> --remote-expr 'luaeval("require(\"orchestrator\").stt_inject(_A[1], _A[2], _A[3])", [filepath, submit, target_buf])'
--- @param filepath string Path to temp file containing the transcription text
--- @param submit boolean If true, append newline (Enter) after text
--- @param target_buf number|nil Specific buffer to target (-1 or nil = use internal heuristic)
--- @return string JSON result: {"ok": bool, "submitted"?: bool, "error"?: string, "instance_cwd"?: string}
function M.stt_inject(filepath, submit, target_buf)
	-- Read text from temp file
	local file = io.open(filepath, "r")
	if not file then
		return vim.json.encode({ ok = false, error = "file_read_failed" })
	end
	local text = file:read("*a")
	file:close()

	if not text or text == "" then
		return vim.json.encode({ ok = false, error = "empty_text" })
	end

	-- Find best Claude instance
	local all_instances = state.state.claude_instances
	if #all_instances == 0 then
		return vim.json.encode({ ok = false, error = "no_instances" })
	end

	local target = nil

	-- Priority 0: explicit target_buf from stop-time capture.
	-- When an explicit buf is passed, it MUST resolve — silent fallback to
	-- last_active_buf caused wrong-agent delivery when the user switched
	-- agents during recording and the original buf became invalid.
	if target_buf and target_buf > 0 then
		local buf_valid = vim.api.nvim_buf_is_valid(target_buf)
		if buf_valid then
			for _, inst in ipairs(all_instances) do
				if inst.buf == target_buf then
					target = inst
					break
				end
			end
		end
		if not target then
			_stt_log(string.format("target_buf=%d specified but not found (valid=%s, instances=%d) — refusing silent fallback",
				target_buf, tostring(buf_valid), #all_instances))
			return vim.json.encode({ ok = false, error = "target_buf_invalid", target_buf = target_buf })
		end
	end

	-- Fallback 1: last_active_buf → find matching instance
	if not target and state.state.last_active_buf then
		for _, inst in ipairs(all_instances) do
			if inst.buf == state.state.last_active_buf then
				target = inst
				break
			end
		end
	end

	-- Fallback 2: most recently spawned instance
	if not target then
		local latest = nil
		for _, inst in ipairs(all_instances) do
			if not latest or inst.spawned_at > latest.spawned_at then
				latest = inst
			end
		end
		target = latest
	end

	if not target then
		return vim.json.encode({ ok = false, error = "no_instances" })
	end

	-- Verify job is still running (jobwait returns -1 for running jobs)
	local job_status = vim.fn.jobwait({ target.job_id }, 0)[1]
	if job_status ~= -1 then
		return vim.json.encode({ ok = false, error = "job_exited" })
	end

	-- Send text to terminal (without Enter — sent separately below)
	local text_len = #text
	_stt_log(string.format("chan_send | buf=%d job=%d textLen=%d submit=%s",
		target.buf, target.job_id, text_len, tostring(submit)))

	local ok, err = pcall(vim.api.nvim_chan_send, target.job_id, text)
	if not ok then
		_stt_log(string.format("chan_send FAILED: %s", tostring(err)))
		return vim.json.encode({ ok = false, error = "chan_send_failed: " .. tostring(err) })
	end
	_stt_log(string.format("chan_send OK | textLen=%d", text_len))

	local submitted = false

	if submit then
		-- Two-phase submit: send \r in a separate chan_send call so it
		-- arrives as a distinct write() syscall. Ink reads each write()
		-- as a standalone stdin chunk — separating text from \r ensures
		-- the Enter is processed as a keypress (submit), not as part of
		-- a paste (literal newline insertion).
		--
		-- Fast path: use on_lines to detect when the terminal buffer has
		-- updated (PTY echoed the text), then send \r immediately.
		-- Fallback: if on_lines doesn't fire within 200ms (e.g. terminal
		-- is in normal mode where Neovim freezes buffer updates), send \r
		-- anyway — vim.wait() already ensured enough event loop iterations
		-- for the two write() syscalls to be separate.
		local text_confirmed = false
		local on_lines_count = 0
		local attach_ok = pcall(vim.api.nvim_buf_attach, target.buf, false, {
			on_lines = function()
				on_lines_count = on_lines_count + 1
				text_confirmed = true
				return true -- detach after first fire
			end,
		})

		_stt_log(string.format("buf_attach | ok=%s buf=%d",
			tostring(attach_ok), target.buf))

		-- Wait for on_lines (fast path) or timeout (normal-mode fallback).
		-- 200ms is generous for PTY echo but keeps latency low when
		-- on_lines can't fire (terminal-normal mode freezes buffer).
		local wait_start = vim.uv.hrtime()
		if attach_ok then
			vim.wait(200, function() return text_confirmed end, 10)
		else
			-- buf_attach failed — still send Enter after a brief yield
			-- to guarantee separate write() syscall.
			vim.wait(50, function() return false end, 10)
		end
		local wait_ms = (vim.uv.hrtime() - wait_start) / 1e6

		_stt_log(string.format("vim.wait done | confirmed=%s waitMs=%.1f onLinesCount=%d attachOk=%s",
			tostring(text_confirmed), wait_ms, on_lines_count, tostring(attach_ok)))

		if not text_confirmed then
			_stt_log("on_lines did not fire (terminal likely in normal mode) — sending Enter anyway")
		end

		local enter_ok, enter_err = pcall(vim.api.nvim_chan_send, target.job_id, "\r")
		_stt_log(string.format("Enter sent | ok=%s err=%s",
			tostring(enter_ok), tostring(enter_err)))
		if enter_ok then
			submitted = true
		end
	end

	-- Clean up temp file (best-effort)
	os.remove(filepath)

	local result = vim.json.encode({
		ok = true,
		submitted = submitted,
		instance_cwd = target.cwd,
	})
	_stt_log(string.format("returning | %s", result))
	return result
end

-- ============================================================
-- CORE: Send to Terminal
-- ============================================================

--- Send prompt to Claude Code terminal
--- Shows picker if multiple instances or spawn options
--- Only works when called from inside the prompt editor
function M.send_to_terminal()
	-- Guard: Only allow sending from inside the prompt editor
	if not editor.is_current_buffer_prompt() then
		vim.notify("Send prompt only works inside the Prompt Editor", vim.log.levels.WARN)
		return
	end

	local content = editor.get_content()

	if not content then
		vim.notify("Prompt buffer not found", vim.log.levels.ERROR)
		return
	end

	if content:match("^%s*$") then
		vim.notify("Prompt is empty", vim.log.levels.WARN)
		return
	end

	picker.select(function(term)
		-- Verify job is still running before sending
		-- jobwait returns -1 for running jobs, exit code otherwise
		local job_status = vim.fn.jobwait({ term.job_id }, 0)[1]
		if job_status ~= -1 then
			vim.notify("Claude terminal has exited. Please spawn a new one.", vim.log.levels.ERROR)
			instances.unregister(term.buf)
			return
		end

		local ok, err = pcall(vim.api.nvim_chan_send, term.job_id, content .. "\n")
		if not ok then
			vim.notify("Failed to send to terminal: " .. tostring(err), vim.log.levels.ERROR)
			return
		end

		-- Delete the tab after sending (per user preference)
		editor.delete_tab()
		editor.close()

		if not term.is_new then
			terminal.focus(term)
		end

		vim.notify("Prompt sent to Claude", vim.log.levels.INFO)
	end)
end

-- ============================================================
-- SETUP: Autocmds
-- ============================================================

--- Set up autocmds for terminal lifecycle
local function setup_terminal_autocmds()
	-- Terminal closed: unregister if tracked
	-- Only unregister if it's one of our tracked terminals
	vim.api.nvim_create_autocmd("TermClose", {
		group = augroup,
		callback = function(args)
			local inst = instances.get_by_buf(args.buf)
			if inst then
				instances.unregister(args.buf)
			end
		end,
	})

	-- Buffer deleted: cleanup if tracked (fallback if TermClose didn't fire)
	-- Use vim.schedule to let TermClose fire first if both events occur
	vim.api.nvim_create_autocmd("BufDelete", {
		group = augroup,
		callback = function(args)
			vim.schedule(function()
				if instances.get_by_buf(args.buf) then
					instances.unregister(args.buf)
				end
			end)
		end,
	})

	-- Terminal title changed: update status bar to show session name
	-- TermRequest fires when terminal sends OSC/DCS escape sequences
	-- Neovim updates vim.b.term_title from OSC 2 before this fires
	-- Debounced to prevent flicker during rapid title updates (e.g., Claude streaming)
	vim.api.nvim_create_autocmd("TermRequest", {
		group = augroup,
		callback = function(args)
			-- Only process if it's a tracked Claude terminal
			if not instances.get_by_buf(args.buf) then
				return
			end

			-- Debounce: cancel pending update and schedule new one
			if title_update_timer then
				vim.fn.timer_stop(title_update_timer)
			end

			title_update_timer = vim.fn.timer_start(TITLE_DEBOUNCE_MS, function()
				vim.schedule(function()
					status_bar.update()
					bridge.notify_title(args.buf)
					title_update_timer = nil
				end)
			end)
		end,
	})

	-- Focus changed: update winbar and track active instance
	-- WinEnter: fires when switching windows (split navigation)
	-- BufEnter: fires when switching buffers in same window (<C-6>, :bnext, etc.)
	-- BufWinEnter: fires when a buffer is displayed in a window (new splits, etc.)
	-- Also applies winbar to new windows as they're created
	vim.api.nvim_create_autocmd({ "WinEnter", "BufEnter", "BufWinEnter" }, {
		group = augroup,
		callback = function()
			local current_buf = vim.api.nvim_get_current_buf()

			-- Track last active Claude instance for picker prioritization
			local current_is_claude = instances.get_by_buf(current_buf) ~= nil
			if current_is_claude then
				state.state.last_active_buf = current_buf
				bridge.notify_focus(current_buf)
			end

			-- Update all winbars to reflect correct active state
			-- (must update all windows so previously active one dims)
			status_bar.update()
		end,
	})

	-- Track terminal focus state for STT socket selection.
	-- Ghostty sends focus-in/focus-out escape sequences; Neovim translates these
	-- to FocusGained/FocusLost autocmds. At stop-time, only the Neovim in the
	-- active terminal window has has_terminal_focus=true, giving deterministic
	-- socket selection even with multiple Neovim instances.
	vim.api.nvim_create_autocmd("FocusGained", {
		group = augroup,
		callback = function()
			has_terminal_focus = true
		end,
	})

	vim.api.nvim_create_autocmd("FocusLost", {
		group = augroup,
		callback = function()
			has_terminal_focus = false
		end,
	})
end

-- ============================================================
-- SETUP: User Commands
-- ============================================================

--- Create user commands
local function setup_user_commands()
	vim.api.nvim_create_user_command("PromptEditorToggle", M.toggle, {
		desc = "Toggle prompt editor",
	})

	vim.api.nvim_create_user_command("PromptEditorSend", M.send_to_terminal, {
		desc = "Send prompt to Claude Code terminal",
	})

	vim.api.nvim_create_user_command("PromptEditorNew", M.new_tab, {
		desc = "Create new prompt editor tab",
	})

	vim.api.nvim_create_user_command("PromptEditorNext", M.next_tab, {
		desc = "Navigate to next prompt editor tab",
	})

	vim.api.nvim_create_user_command("PromptEditorPrev", M.prev_tab, {
		desc = "Navigate to previous prompt editor tab",
	})

	vim.api.nvim_create_user_command("PromptEditorDelete", M.delete_tab, {
		desc = "Delete current prompt editor tab",
	})

	vim.api.nvim_create_user_command("AgentsStatusBarToggle", M.toggle_status_bar, {
		desc = "Toggle Claude instances status bar",
	})

	vim.api.nvim_create_user_command("AgentsPick", M.pick, {
		desc = "Pick/spawn Claude terminal",
	})

	vim.api.nvim_create_user_command("AgentsSpawn", function(opts)
		local spawn_type = opts.args ~= "" and opts.args or "fresh"
		local dangerous = opts.bang
		M.spawn(spawn_type, { dangerous = dangerous })
	end, {
		desc = "Spawn new Claude terminal (use ! for dangerous mode)",
		nargs = "?",
		bang = true,
		complete = function()
			return { "fresh", "resume", "continue" }
		end,
	})

	vim.api.nvim_create_user_command("AgentsKill", function(opts)
		if opts.args == "" then
			M.kill(nil) -- Will show usage message
			return
		end
		local num = tonumber(opts.args)
		if not num then
			vim.notify("Instance number must be a number", vim.log.levels.ERROR)
			return
		end
		M.kill(num)
	end, {
		desc = "Kill Claude instance by number",
		nargs = "?",
	})

	vim.api.nvim_create_user_command("AgentsFocus", function(opts)
		if opts.args == "" then
			M.focus(nil) -- Will show usage message
			return
		end
		local num = tonumber(opts.args)
		if not num then
			vim.notify("Instance number must be a number", vim.log.levels.ERROR)
			return
		end
		M.focus(num)
	end, {
		desc = "Focus Claude instance by number",
		nargs = "?",
	})

	vim.api.nvim_create_user_command("AgentsClose", M.kill_current_or_pick, {
		desc = "Close current Claude instance or pick one",
	})

	vim.api.nvim_create_user_command("AgentsEdits", function(opts)
		local num = nil
		if opts.args ~= "" then
			num = tonumber(opts.args)
			if not num then
				vim.notify("Instance number must be a number", vim.log.levels.ERROR)
				return
			end
		end
		M.show_edits(num)
	end, {
		desc = "Show Claude edits in quickfix list",
		nargs = "?",
	})

	vim.api.nvim_create_user_command("AgentsJump", function(opts)
		local num = nil
		if opts.args ~= "" then
			num = tonumber(opts.args)
			if not num then
				vim.notify("Instance number must be a number", vim.log.levels.ERROR)
				return
			end
		end
		M.jump_to_last_edit(num)
	end, {
		desc = "Jump to most recent Claude edit",
		nargs = "?",
	})

	vim.api.nvim_create_user_command("AgentsEditsClose", function()
		edit_tracker.close_picker()
	end, {
		desc = "Close Claude edits picker window",
	})

	vim.api.nvim_create_user_command("AgentsDiffJump", function()
		M.jump_to_diff_location()
	end, {
		desc = "Jump to source file from diff line in Claude terminal",
	})

	vim.api.nvim_create_user_command("AgentsPromptJump", function(opts)
		local count = 1
		if opts.args ~= "" then
			count = tonumber(opts.args)
			if not count then
				vim.notify("Count must be a number", vim.log.levels.ERROR)
				return
			end
		end
		M.jump_to_last_prompt(count)
	end, {
		desc = "Jump to last user prompt (or Nth previous)",
		nargs = "?",
	})

	vim.api.nvim_create_user_command("AgentsPlanJump", function(opts)
		local count = 1
		if opts.args ~= "" then
			count = tonumber(opts.args)
			if not count then
				vim.notify("Count must be a number", vim.log.levels.ERROR)
				return
			end
		end
		M.jump_to_last_plan(count)
	end, {
		desc = "Jump to last plan (or Nth previous)",
		nargs = "?",
	})

	vim.api.nvim_create_user_command("AgentsOpenUrl", function()
		M.open_url_at_cursor()
	end, {
		desc = "Open URL under cursor in Claude terminal",
	})

	vim.api.nvim_create_user_command("OrchestratorDebug", function()
		local all = instances.get_all()
		local project = instances.get_for_current_project()
		print("=== Orchestrator Debug ===")
		print("Total instances: " .. #all)
		print("Project instances: " .. #project)
		print("Current cwd: " .. vim.fn.getcwd())
		for i, inst in ipairs(all) do
			print(string.format(
				"  [%d] buf=%d, job_id=%d, color=%d, cwd=%s, type=%s, dangerous=%s",
				i,
				inst.buf,
				inst.job_id,
				inst.color_idx,
				inst.cwd,
				inst.spawn_type,
				tostring(inst.dangerous or false)
			))
		end
		print("Winbar visible: " .. tostring(state.state.status_bar.visible))
		print("Winbar string: " .. status_bar.get_winbar_string())
	end, {
		desc = "Debug orchestrator state",
	})

	vim.api.nvim_create_user_command("OrchestratorReload", function()
		M.reload()
	end, {
		desc = "Reload orchestrator plugin (preserves instances)",
	})
end

-- ============================================================
-- SETUP: <Plug> Mappings
-- ============================================================

--- Create <Plug> mappings for user customization
--- These are global function references that users can map to their preferred keys
local function setup_plug_mappings()
	-- Prompt editor actions
	vim.keymap.set({ "n", "i" }, "<Plug>(OrchestratorNextTab)", M.next_tab, { desc = "Next prompt tab" })
	vim.keymap.set({ "n", "i" }, "<Plug>(OrchestratorPrevTab)", M.prev_tab, { desc = "Previous prompt tab" })
	vim.keymap.set({ "n", "i" }, "<Plug>(OrchestratorNewTab)", M.new_tab, { desc = "New prompt tab" })
	vim.keymap.set({ "n", "i" }, "<Plug>(OrchestratorDeleteTab)", M.delete_tab, { desc = "Delete prompt tab" })
	vim.keymap.set({ "n", "i" }, "<Plug>(OrchestratorSend)", M.send_to_terminal, { desc = "Send prompt to Claude" })
	vim.keymap.set("n", "<Plug>(OrchestratorClose)", M.close, { desc = "Close prompt editor" })
	vim.keymap.set({ "n", "i", "t" }, "<Plug>(OrchestratorToggle)", M.toggle, { desc = "Toggle prompt editor" })

	-- Agent actions
	vim.keymap.set("n", "<Plug>(OrchestratorPick)", M.pick, { desc = "Pick/spawn Claude terminal" })
	vim.keymap.set("n", "<Plug>(OrchestratorSpawn)", function()
		M.spawn("fresh")
	end, { desc = "Spawn new Claude terminal" })
	vim.keymap.set("n", "<Plug>(OrchestratorSpawnResume)", function()
		M.spawn("resume")
	end, { desc = "Spawn Claude terminal (resume)" })
	vim.keymap.set("n", "<Plug>(OrchestratorSpawnContinue)", function()
		M.spawn("continue")
	end, { desc = "Spawn Claude terminal (continue)" })

	-- Dangerous mode variants (--dangerously-skip-permissions)
	vim.keymap.set("n", "<Plug>(OrchestratorSpawnDangerous)", function()
		M.spawn("fresh", { dangerous = true })
	end, { desc = "Spawn new Claude terminal (dangerous mode)" })
	vim.keymap.set("n", "<Plug>(OrchestratorSpawnResumeDangerous)", function()
		M.spawn("resume", { dangerous = true })
	end, { desc = "Spawn Claude terminal (resume, dangerous mode)" })
	vim.keymap.set("n", "<Plug>(OrchestratorSpawnContinueDangerous)", function()
		M.spawn("continue", { dangerous = true })
	end, { desc = "Spawn Claude terminal (continue, dangerous mode)" })

	-- Terminal actions
	vim.keymap.set({ "n", "t" }, "<Plug>(OrchestratorKillCurrentOrPick)", M.kill_current_or_pick, {
		desc = "Kill current Claude terminal or pick one",
	})

	-- Edit tracker actions
	vim.keymap.set("n", "<Plug>(OrchestratorShowEdits)", M.show_edits, {
		desc = "Show Claude edits in quickfix",
	})
	vim.keymap.set("n", "<Plug>(OrchestratorJumpLastEdit)", M.jump_to_last_edit, {
		desc = "Jump to most recent Claude edit",
	})
	vim.keymap.set("n", "<Plug>(OrchestratorJumpToDiff)", M.jump_to_diff_location, {
		desc = "Jump to source from diff line in terminal",
	})
	vim.keymap.set("n", "<Plug>(OrchestratorJumpToPrompt)", M.jump_to_last_prompt, {
		desc = "Jump to last user prompt in terminal",
	})
	vim.keymap.set("n", "<Plug>(OrchestratorJumpToPlan)", M.jump_to_last_plan, {
		desc = "Jump to last plan in terminal",
	})
	vim.keymap.set("n", "<Plug>(OrchestratorOpenUrl)", M.open_url_at_cursor, {
		desc = "Open URL under cursor in terminal",
	})
end

-- ============================================================
-- SETUP: Main Entry Point
-- ============================================================

--- Validate a keymap section
--- @param cfg table The merged config
--- @param section_name string e.g., "prompt_editor" or "terminal"
--- @param defaults table The default keymaps for this section
local function validate_keymap_section(cfg, section_name, defaults)
	local km = cfg.keymaps[section_name]

	if km == nil then
		return -- nil is valid (will use defaults via fallback)
	end

	if km == false then
		return -- false explicitly disables all keymaps
	end

	if type(km) ~= "table" then
		vim.notify(
			string.format(
				"orchestrator.nvim: keymaps.%s must be a table or false, got %s. Using defaults.",
				section_name,
				type(km)
			),
			vim.log.levels.WARN
		)
		cfg.keymaps[section_name] = defaults
		return
	end

	-- Validate individual keymap values
	for key, value in pairs(km) do
		if value ~= false and type(value) ~= "string" then
			vim.notify(
				string.format(
					"orchestrator.nvim: keymaps.%s.%s must be a string or false, got %s. Ignoring.",
					section_name,
					key,
					type(value)
				),
				vim.log.levels.WARN
			)
			km[key] = nil -- Will fall back to default
		end
	end
end

--- Validate configuration and warn about invalid values
--- @param cfg table The merged configuration
local function validate_config(cfg)
	if not cfg.keymaps then
		return
	end

	validate_keymap_section(cfg, "prompt_editor", default_config.keymaps.prompt_editor)
	validate_keymap_section(cfg, "terminal", default_config.keymaps.terminal)
end

--- Setup function to initialize the plugin
--- @param opts table|nil User configuration options
function M.setup(opts)
	-- Merge user config with defaults
	config = vim.tbl_deep_extend("force", default_config, opts or {})

	-- Validate user configuration
	validate_config(config)

	highlights.setup()

	-- Wire up module dependencies (break circular references)
	instances.set_status_bar(status_bar)
	instances.set_bridge(bridge)
	terminal.set_instances(instances)
	terminal.set_config(config)
	terminal.set_jump_to_diff_fn(edit_tracker.jump_to_diff_location)
	terminal.set_jump_to_prompt_fn(edit_tracker.jump_to_last_prompt)
	terminal.set_jump_to_plan_fn(edit_tracker.jump_to_last_plan)
	terminal.set_open_url_fn(url_handler.open_url_at_cursor)
	url_handler.set_instances(instances)
	picker.set_terminal(terminal)
	editor.set_send_function(M.send_to_terminal)
	editor.set_config(config)
	spawn_menu.set_terminal(terminal)
	spawn_menu.set_config(config)
	spawn_menu.set_spawn_fn(M.spawn)
	edit_tracker.set_instances(instances)
	edit_tracker.set_picker(picker)

	setup_plug_mappings()
	setup_terminal_autocmds()
	setup_user_commands()

	-- Connect to Symmetria shell bridge (non-blocking, silently retries)
	bridge.setup()
end

-- ============================================================
-- CLEANUP HELPERS: Shared by reload and teardown
-- ============================================================

-- List of all user commands registered by the plugin
local user_commands = {
	"PromptEditorToggle",
	"PromptEditorSend",
	"PromptEditorNew",
	"PromptEditorNext",
	"PromptEditorPrev",
	"PromptEditorDelete",
	"AgentsStatusBarToggle",
	"AgentsPick",
	"AgentsSpawn",
	"AgentsKill",
	"AgentsFocus",
	"AgentsClose",
	"AgentsEdits",
	"AgentsJump",
	"AgentsEditsClose",
	"AgentsDiffJump",
	"AgentsPromptJump",
	"AgentsPlanJump",
	"AgentsOpenUrl",
	"OrchestratorDebug",
	"OrchestratorReload",
}

--- Close UI windows and delete UI buffers
local function cleanup_ui()
	-- Close editor window
	if state.state.editor.win and vim.api.nvim_win_is_valid(state.state.editor.win) then
		vim.api.nvim_win_close(state.state.editor.win, true)
	end

	-- Delete all editor tab buffers
	for _, tab in ipairs(state.state.editor.tabs or {}) do
		if tab.buf and vim.api.nvim_buf_is_valid(tab.buf) then
			vim.api.nvim_buf_delete(tab.buf, { force = true })
		end
	end

	-- Close spawn menu if open
	spawn_menu.close()

	-- Close edit picker if open
	edit_tracker.close_picker()

	-- Hide winbar from all windows
	status_bar.hide()
end

--- Delete autocmds and user commands
local function cleanup_commands()
	-- Stop pending debounce timer to prevent stale callbacks after reload
	if title_update_timer then
		pcall(vim.fn.timer_stop, title_update_timer)
		title_update_timer = nil
	end

	pcall(vim.api.nvim_del_augroup_by_name, "Orchestrator")

	for _, cmd in ipairs(user_commands) do
		pcall(vim.api.nvim_del_user_command, cmd)
	end
end

-- ============================================================
-- RELOAD: Hot-reload for development
-- ============================================================

--- Reload the plugin without restarting Neovim
--- Preserves running Claude instances while reloading all code
--- Note: Editor tab contents are not preserved (buffers are recreated)
function M.reload()
	-- 1. Save state before teardown
	local saved_instances = vim.deepcopy(state.state.claude_instances)
	local saved_color_idx = state.state.next_color_idx
	local saved_last_active = state.state.last_active_buf
	local saved_status_bar_visible = state.state.status_bar.visible
	local saved_focus = has_terminal_focus

	-- 2. Disconnect bridge before module cache is cleared
	bridge.disconnect()

	-- 3. Close UI windows (but NOT terminal buffers)
	cleanup_ui()

	-- 4. Delete autocmds and commands
	cleanup_commands()

	-- 5. Clear Lua module cache
	local modules = {
		"orchestrator",
		"orchestrator.state",
		"orchestrator.highlights",
		"orchestrator.instances",
		"orchestrator.status_bar",
		"orchestrator.picker",
		"orchestrator.editor",
		"orchestrator.terminal",
		"orchestrator.spawn_menu",
		"orchestrator.edit_tracker",
		"orchestrator.url_handler",
		"orchestrator.bridge",
	}
	for _, mod in ipairs(modules) do
		package.loaded[mod] = nil
	end

	-- 6. Reset plugin guard
	vim.g.loaded_orchestrator = 0

	-- 7. Re-require and setup
	local ok, orchestrator = pcall(require, "orchestrator")
	if not ok then
		vim.notify("Orchestrator reload failed: " .. tostring(orchestrator), vim.log.levels.ERROR)
		return
	end
	orchestrator.setup()

	-- 8. Restore instance state
	local new_state = require("orchestrator.state")
	new_state.state.claude_instances = saved_instances
	new_state.state.next_color_idx = saved_color_idx
	new_state.state.last_active_buf = saved_last_active
	new_state.state.status_bar.visible = saved_status_bar_visible

	-- 9. Restore terminal focus state (has_terminal_focus is module-local,
	-- so clearing module cache resets it). Fire synthetic FocusGained so
	-- the new module's autocmd handler sets the variable correctly.
	if saved_focus then
		vim.api.nvim_exec_autocmds("FocusGained", { group = "Orchestrator" })
	end

	-- 10. Refresh status bar if instances exist and was visible
	if #saved_instances > 0 and saved_status_bar_visible then
		require("orchestrator.status_bar").show()
	end

	-- 11. Reapply terminal buffer keymaps to existing instances
	if #saved_instances > 0 then
		require("orchestrator.terminal").reapply_keybindings_to_existing(
			saved_instances,
			orchestrator.kill_current_or_pick
		)
	end

	vim.notify("Orchestrator reloaded (" .. #saved_instances .. " instances preserved)", vim.log.levels.INFO)
end

-- ============================================================
-- TEARDOWN: Cleanup
-- ============================================================

--- Teardown function for testing and cleanup
function M.teardown()
	bridge.disconnect()
	cleanup_ui()
	state.reset()
	cleanup_commands()
end

return M
