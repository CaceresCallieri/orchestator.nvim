-- Orchestrator Module
-- Main entry point and public API for orchestrator.nvim
-- Orchestrates all sub-modules for a unified experience

---@class OrchestratorModule
local M = {}

-- Load sub-modules
local state = require("orchestrator.state")
local highlights = require("orchestrator.highlights")
local instances = require("orchestrator.instances")
local status_bar = require("orchestrator.status_bar")
local picker = require("orchestrator.picker")
local editor = require("orchestrator.editor")
local terminal = require("orchestrator.terminal")

-- Create autocmd group
local augroup = vim.api.nvim_create_augroup("Orchestrator", { clear = true })

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
--- @return table|nil instance The spawned instance
function M.spawn(spawn_type)
	return terminal.spawn(spawn_type or "fresh")
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

-- ============================================================
-- CORE: Send to Terminal
-- ============================================================

--- Send prompt to Claude Code terminal
--- Shows picker if multiple instances or spawn options
function M.send_to_terminal()
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

	-- Window resized: reposition status bar
	vim.api.nvim_create_autocmd("VimResized", {
		group = augroup,
		callback = function()
			status_bar.reposition()
		end,
	})

	-- Focus changed: update status bar to show active instance indicator
	-- WinEnter: fires when switching windows (split navigation)
	-- BufEnter: fires when switching buffers in same window (<C-6>, :bnext, etc.)
	-- Filtering prevents excessive updates - only triggers for Claude buffers
	vim.api.nvim_create_autocmd({ "WinEnter", "BufEnter" }, {
		group = augroup,
		callback = function()
			if instances.count() == 0 then
				return
			end

			local current_buf = vim.api.nvim_get_current_buf()
			local prev_buf = vim.fn.bufnr("#")

			-- Only update if entering or leaving a Claude terminal
			local current_is_claude = instances.get_by_buf(current_buf) ~= nil
			local prev_is_claude = prev_buf > 0 and instances.get_by_buf(prev_buf) ~= nil

			if current_is_claude or prev_is_claude then
				status_bar.update()
			end
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

	vim.api.nvim_create_user_command("AgentsStatusBarToggle", M.toggle_status_bar, {
		desc = "Toggle Claude instances status bar",
	})

	vim.api.nvim_create_user_command("AgentsPick", M.pick, {
		desc = "Pick/spawn Claude terminal",
	})

	vim.api.nvim_create_user_command("AgentsSpawn", function(opts)
		local spawn_type = opts.args ~= "" and opts.args or "fresh"
		M.spawn(spawn_type)
	end, {
		desc = "Spawn new Claude terminal",
		nargs = "?",
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

	vim.api.nvim_create_user_command("OrchestratorDebug", function()
		local all = instances.get_all()
		local project = instances.get_for_current_project()
		print("=== Orchestrator Debug ===")
		print("Total instances: " .. #all)
		print("Project instances: " .. #project)
		print("Current cwd: " .. vim.fn.getcwd())
		for i, inst in ipairs(all) do
			print(string.format(
				"  [%d] buf=%d, job_id=%d, color=%d, cwd=%s, type=%s",
				i,
				inst.buf,
				inst.job_id,
				inst.color_idx,
				inst.cwd,
				inst.spawn_type
			))
		end
		print("Status bar visible: " .. tostring(state.state.status_bar.visible))
		print("Status bar win: " .. tostring(state.state.status_bar.win))
	end, {
		desc = "Debug orchestrator state",
	})
end

-- ============================================================
-- SETUP: Main Entry Point
-- ============================================================

--- Setup function to initialize the plugin
function M.setup()
	highlights.setup()

	-- Wire up module dependencies (break circular references)
	instances.set_status_bar(status_bar)
	terminal.set_instances(instances)
	picker.set_terminal(terminal)
	editor.set_send_function(M.send_to_terminal)

	setup_terminal_autocmds()
	setup_user_commands()
end

-- ============================================================
-- TEARDOWN: Cleanup
-- ============================================================

--- Teardown function for testing and cleanup
function M.teardown()
	if state.state.editor.win and vim.api.nvim_win_is_valid(state.state.editor.win) then
		vim.api.nvim_win_close(state.state.editor.win, true)
	end

	if state.state.editor.buf and vim.api.nvim_buf_is_valid(state.state.editor.buf) then
		vim.api.nvim_buf_delete(state.state.editor.buf, { force = true })
	end

	status_bar.hide()

	if state.state.status_bar.buf and vim.api.nvim_buf_is_valid(state.state.status_bar.buf) then
		vim.api.nvim_buf_delete(state.state.status_bar.buf, { force = true })
	end

	state.reset()

	pcall(vim.api.nvim_del_augroup_by_name, "Orchestrator")

	pcall(vim.api.nvim_del_user_command, "PromptEditorToggle")
	pcall(vim.api.nvim_del_user_command, "PromptEditorSend")
	pcall(vim.api.nvim_del_user_command, "AgentsStatusBarToggle")
	pcall(vim.api.nvim_del_user_command, "AgentsPick")
	pcall(vim.api.nvim_del_user_command, "AgentsSpawn")
	pcall(vim.api.nvim_del_user_command, "AgentsKill")
	pcall(vim.api.nvim_del_user_command, "OrchestratorDebug")
end

return M
