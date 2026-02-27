-- Terminal Module
-- Claude terminal spawning and lifecycle management
-- Handles spawn, focus, and kill operations for Claude instances

---@class TerminalModule
local M = {}

-- Forward declaration for instances (set via setter to avoid circular dep)
---@type table|nil
local instances = nil

-- Forward declaration for jump_to_diff function (set via setter from init.lua)
---@type function|nil
local jump_to_diff_fn = nil

-- Forward declaration for jump_to_prompt function (set via setter from init.lua)
---@type function|nil
local jump_to_prompt_fn = nil

-- Forward declaration for jump_to_plan function (set via setter from init.lua)
---@type function|nil
local jump_to_plan_fn = nil

-- Plugin configuration (set via setter from init.lua)
---@type table
local terminal_config = {}

-- Configuration constants
local config = {
	valid_spawn_types = { "fresh", "resume", "continue" },
}

--- Set the instances module reference (called from init.lua)
--- @param inst table The instances module
function M.set_instances(inst)
	instances = inst
end

--- Set the plugin configuration (called from init.lua)
--- @param cfg table The plugin configuration
function M.set_config(cfg)
	terminal_config = cfg
end

--- Set the jump_to_diff function (called from init.lua to break circular dep)
--- @param fn function The jump_to_diff_location function from edit_tracker
function M.set_jump_to_diff_fn(fn)
	jump_to_diff_fn = fn
end

--- Set the jump_to_prompt function (called from init.lua to break circular dep)
--- @param fn function The jump_to_last_prompt function from edit_tracker
function M.set_jump_to_prompt_fn(fn)
	jump_to_prompt_fn = fn
end

--- Set the jump_to_plan function (called from init.lua to break circular dep)
--- @param fn function The jump_to_last_plan function from edit_tracker
function M.set_jump_to_plan_fn(fn)
	jump_to_plan_fn = fn
end

--- Set up buffer-local keybindings for Claude terminal
--- @param buf number Buffer ID
--- @param kill_fn function The kill_current_or_pick function from init.lua
local function setup_terminal_keybindings(buf, kill_fn)
	local km = terminal_config.keymaps and terminal_config.keymaps.terminal
	if km == false then
		return -- All terminal keymaps disabled
	end
	km = km or {}

	if km.close and km.close ~= false then
		-- Both terminal mode (t) and normal mode (n) to cover active input
		-- and when user exits terminal mode with <C-\><C-n>
		vim.keymap.set({ "t", "n" }, km.close, function()
			kill_fn()
		end, {
			buffer = buf,
			noremap = true,
			silent = true,
			desc = "Close Claude instance",
		})
	end

	-- Jump to source from diff line (normal mode only)
	if km.jump_to_diff and km.jump_to_diff ~= false and jump_to_diff_fn then
		vim.keymap.set("n", km.jump_to_diff, function()
			jump_to_diff_fn()
		end, {
			buffer = buf,
			noremap = true,
			silent = true,
			desc = "Jump to source from diff line",
		})
	end

	-- Jump to last user prompt (normal mode only)
	if km.jump_to_prompt and km.jump_to_prompt ~= false and jump_to_prompt_fn then
		vim.keymap.set("n", km.jump_to_prompt, function()
			jump_to_prompt_fn()
		end, {
			buffer = buf,
			noremap = true,
			silent = true,
			desc = "Jump to last user prompt",
		})
	end

	-- Jump to last plan (normal mode only)
	if km.jump_to_plan and km.jump_to_plan ~= false and jump_to_plan_fn then
		vim.keymap.set("n", km.jump_to_plan, function()
			jump_to_plan_fn()
		end, {
			buffer = buf,
			noremap = true,
			silent = true,
			desc = "Jump to last plan",
		})
	end
end

--- Reapply terminal keybindings to existing instances (called during reload)
--- @param instances_list table[] Array of instance objects
--- @param kill_fn function The kill_current_or_pick function from init.lua
function M.reapply_keybindings_to_existing(instances_list, kill_fn)
	for _, inst in ipairs(instances_list) do
		if vim.api.nvim_buf_is_valid(inst.buf) then
			setup_terminal_keybindings(inst.buf, kill_fn)
		end
	end
end

-- CLI command configurations for different spawn types
-- Stores flags separately for cleaner command construction
---@type table<string, {flags: string[], label: string, description: string}>
M.spawn_types = {
	fresh = {
		flags = {},
		label = "New Claude",
		description = "Start fresh conversation",
	},
	resume = {
		flags = { "-r" },
		label = "Resume Claude",
		description = "Resume last conversation",
	},
	continue = {
		flags = { "-c" },
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
--- @param opts table|nil Options { dangerous = boolean, kill_fn = function }
--- @return table|nil instance The created instance, or nil on failure
function M.spawn(spawn_type, opts)
	-- Fail fast if dependencies aren't wired up
	if not instances then
		error("terminal.lua: instances module not initialized. Call set_instances() in setup.")
	end

	spawn_type = spawn_type or "fresh"
	opts = opts or {}

	if not M.is_valid_spawn_type(spawn_type) then
		vim.notify("Unknown spawn type: " .. tostring(spawn_type), vim.log.levels.ERROR)
		return nil
	end

	local cmd_config = M.spawn_types[spawn_type]

	-- Build command from parts: claude [--dangerously-skip-permissions] [action-flags]
	local cmd_parts = { "claude" }
	if opts.dangerous then
		table.insert(cmd_parts, "--dangerously-skip-permissions")
	end
	for _, flag in ipairs(cmd_config.flags) do
		table.insert(cmd_parts, flag)
	end
	local cmd = table.concat(cmd_parts, " ")

	-- Verify CLI is installed before attempting to spawn
	if vim.fn.executable("claude") == 0 then
		vim.notify(
			"Command 'claude' not found. Is Claude CLI installed?",
			vim.log.levels.ERROR
		)
		return nil
	end

	local cwd = vim.fn.getcwd()

	-- Create a new buffer for the terminal (listed, not scratch)
	local buf = vim.api.nvim_create_buf(true, false)

	-- Switch to the buffer (full-screen style)
	vim.api.nvim_set_current_buf(buf)

	-- Inject agent ID for Symmetria activity tracking hooks
	local agent_id = string.format("%d_%d", vim.uv.getpid(), buf)
	cmd = string.format("env SYMMETRIA_AGENT_ID=%s %s", agent_id, cmd)

	-- Spawn terminal with Claude command
	local job_id = vim.fn.termopen(cmd, {
		cwd = cwd,
		on_exit = function(_, exit_code, _)
			vim.schedule(function()
				-- Only notify if exit was abnormal
				-- Normal exits: 0 (/exit command), 129 (SIGHUP from jobstop when killed)
				if exit_code ~= 0 and exit_code ~= 129 then
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

	-- Set up buffer-local keymaps if kill function was provided
	if opts.kill_fn then
		setup_terminal_keybindings(buf, opts.kill_fn)
	end

	return instances.register_spawned(buf, job_id, cwd, spawn_type, opts.dangerous)
end

--- Focus an existing Claude terminal
--- Switches to the window/buffer containing the terminal
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
