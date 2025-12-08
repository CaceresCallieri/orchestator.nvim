-- Terminal Module
-- Claude terminal spawning and lifecycle management
-- Handles spawn, focus, and kill operations for Claude instances

---@class TerminalModule
local M = {}

-- Forward declaration for instances (set via setter to avoid circular dep)
---@type table|nil
local instances = nil

-- Configuration constants
local config = {
	valid_spawn_types = { "fresh", "resume", "continue" },
}

--- Set the instances module reference (called from init.lua)
--- @param inst table The instances module
function M.set_instances(inst)
	instances = inst
end

-- CLI command configurations for different spawn types
---@type table<string, {cmd: string, label: string, description: string}>
M.spawn_types = {
	fresh = {
		cmd = "claude",
		label = "New Claude",
		description = "Start fresh conversation",
	},
	resume = {
		cmd = "claude -r",
		label = "Resume Claude",
		description = "Resume last conversation",
	},
	continue = {
		cmd = "claude -c",
		label = "Continue Claude",
		description = "Continue conversation",
	},
}

-- Ordered list of spawn type keys for consistent picker display
---@type string[]
M.spawn_order = { "fresh", "resume", "continue" }

--- Check if a spawn type is valid
--- @param spawn_type string The spawn type to validate
--- @return boolean is_valid True if spawn_type is valid
function M.is_valid_spawn_type(spawn_type)
	for _, valid in ipairs(config.valid_spawn_types) do
		if spawn_type == valid then
			return true
		end
	end
	return false
end

--- Spawn a new Claude terminal
--- Creates buffer, opens terminal with specified variant, registers instance
--- @param spawn_type string|nil "fresh" | "resume" | "continue" (defaults to "fresh")
--- @return table|nil instance The created instance, or nil on failure
function M.spawn(spawn_type)
	-- Fail fast if dependencies aren't wired up
	if not instances then
		error("terminal.lua: instances module not initialized. Call set_instances() in setup.")
	end

	spawn_type = spawn_type or "fresh"

	if not M.is_valid_spawn_type(spawn_type) then
		vim.notify("Unknown spawn type: " .. tostring(spawn_type), vim.log.levels.ERROR)
		return nil
	end

	local cmd_config = M.spawn_types[spawn_type]

	-- Verify CLI is installed before attempting to spawn
	local cmd_name = cmd_config.cmd:match("^%S+")
	if vim.fn.executable(cmd_name) == 0 then
		vim.notify(
			string.format("Command '%s' not found. Is Claude CLI installed?", cmd_name),
			vim.log.levels.ERROR
		)
		return nil
	end

	local cwd = vim.fn.getcwd()

	-- Create a new buffer for the terminal (listed, not scratch)
	local buf = vim.api.nvim_create_buf(true, false)

	-- Switch to the buffer (full-screen style)
	vim.api.nvim_set_current_buf(buf)

	-- Spawn terminal with Claude command
	local job_id = vim.fn.termopen(cmd_config.cmd, {
		cwd = cwd,
		on_exit = function(_, exit_code, _)
			vim.schedule(function()
				-- Only notify if exit was abnormal (non-zero)
				-- Normal exits happen when user types /exit
				if exit_code ~= 0 then
					vim.notify(string.format("Claude exited with code %d", exit_code), vim.log.levels.WARN)
				end
			end)
		end,
	})

	if job_id <= 0 then
		-- Switch to alternate buffer so user isn't left in deleted buffer
		pcall(vim.cmd, "buffer #")
		pcall(vim.api.nvim_buf_delete, buf, { force = true })
		vim.notify("Failed to spawn Claude terminal", vim.log.levels.ERROR)
		return nil
	end

	vim.cmd("startinsert")

	return instances.register_spawned(buf, job_id, cwd, spawn_type)
end

--- Focus an existing Claude terminal
--- Switches to buffer, enters terminal mode
--- @param instance table Instance to focus {buf, job_id, ...}
function M.focus(instance)
	if not instance or not instance.buf then
		vim.notify("Invalid instance", vim.log.levels.ERROR)
		return
	end

	if not vim.api.nvim_buf_is_valid(instance.buf) then
		vim.notify("Terminal buffer no longer valid", vim.log.levels.ERROR)
		return
	end

	-- Find window displaying this buffer, with defensive checks
	-- Windows can become invalid during iteration
	local win = nil
	for _, w in ipairs(vim.api.nvim_list_wins()) do
		if vim.api.nvim_win_is_valid(w) then
			local ok, buf = pcall(vim.api.nvim_win_get_buf, w)
			if ok and buf == instance.buf then
				win = w
				break
			end
		end
	end

	if win then
		vim.api.nvim_set_current_win(win)
	else
		-- Buffer not visible, switch current window to it
		vim.api.nvim_set_current_buf(instance.buf)
	end

	vim.cmd("startinsert")
end

--- Kill a Claude terminal
--- Closes the terminal job and cleans up the buffer
--- @param instance table Instance to kill {buf, job_id, ...}
function M.kill(instance)
	if not instance or not instance.buf then
		vim.notify("Invalid instance", vim.log.levels.ERROR)
		return
	end

	if not vim.api.nvim_buf_is_valid(instance.buf) then
		-- Buffer already gone, just clean up tracking
		if instances then
			instances.unregister(instance.buf)
		end
		return
	end

	-- Use tracked job_id (not vim.b[].terminal_job_id) for consistency
	-- Wrap in pcall since job may have already exited
	if instance.job_id and instance.job_id > 0 then
		pcall(vim.fn.jobstop, instance.job_id)
	end

	pcall(vim.api.nvim_buf_delete, instance.buf, { force = true })

	-- TermClose autocmd will handle unregister
end

return M
