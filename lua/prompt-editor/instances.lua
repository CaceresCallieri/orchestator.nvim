-- Instances Module
-- Claude Code instance tracking for spawn-controlled architecture
-- Handles registration, unregistration, and querying of instances

local state = require("prompt-editor.state")

---@class InstancesModule
local M = {}

-- Forward declaration for status_bar (to avoid circular dependency)
---@type table|nil
local status_bar = nil

--- Set the status_bar module reference (called from init.lua to break circular dep)
--- @param sb table The status_bar module
function M.set_status_bar(sb)
	status_bar = sb
end

--- Build a lookup table mapping buffer IDs to window IDs
--- Much faster than iterating windows for each buffer: O(w) vs O(n*w)
--- @return table<number, number> buf_to_win Map of buffer ID to window ID
local function build_window_lookup()
	local buf_to_win = {}
	for _, win in ipairs(vim.api.nvim_list_wins()) do
		if vim.api.nvim_win_is_valid(win) then
			local ok, buf = pcall(vim.api.nvim_win_get_buf, win)
			if ok then
				buf_to_win[buf] = win
			end
		end
	end
	return buf_to_win
end

--- Register a spawned Claude instance
--- @param buf number Terminal buffer ID
--- @param job_id number Terminal job ID
--- @param cwd string Working directory at spawn time
--- @param spawn_type string "fresh" | "resume" | "continue"
--- @return table instance The registered instance
function M.register_spawned(buf, job_id, cwd, spawn_type)
	-- Check if already registered (prevent duplicates)
	for _, inst in ipairs(state.state.claude_instances) do
		if inst.buf == buf then
			return inst
		end
	end

	local color_idx = state.get_next_color_idx()

	local instance = {
		buf = buf,
		job_id = job_id,
		color_idx = color_idx,
		cwd = cwd,
		spawn_type = spawn_type,
		spawned_at = os.time(),
	}

	table.insert(state.state.claude_instances, instance)

	if status_bar then
		status_bar.show()
		status_bar.update()
	end

	return instance
end

--- Unregister a Claude instance by buffer ID
--- @param buf number Buffer ID to remove
--- @return boolean removed True if instance was found and removed
function M.unregister(buf)
	for i, inst in ipairs(state.state.claude_instances) do
		if inst.buf == buf then
			table.remove(state.state.claude_instances, i)

			if status_bar then
				if #state.state.claude_instances == 0 then
					status_bar.hide()
				else
					status_bar.update()
				end
			end

			return true
		end
	end
	return false
end

--- Get instance info by buffer ID
--- @param buf number Buffer ID
--- @return table|nil instance Instance table or nil if not found
function M.get_by_buf(buf)
	for _, inst in ipairs(state.state.claude_instances) do
		if inst.buf == buf then
			return inst
		end
	end
	return nil
end

--- Get all tracked instances with their display numbers
--- Returns instances from all projects
--- @return table[] Array of instances with added 'number' and 'win' fields
function M.get_all()
	local buf_to_win = build_window_lookup()
	local result = {}

	for i, inst in ipairs(state.state.claude_instances) do
		table.insert(result, {
			buf = inst.buf,
			job_id = inst.job_id,
			color_idx = inst.color_idx,
			cwd = inst.cwd,
			spawn_type = inst.spawn_type,
			spawned_at = inst.spawned_at,
			number = i,
			win = buf_to_win[inst.buf],
		})
	end

	return result
end

--- Get instances for current working directory only
--- Filters by cwd and re-numbers for display
--- @return table[] Filtered instances for current cwd
function M.get_for_current_project()
	local cwd = vim.fn.getcwd()
	local buf_to_win = build_window_lookup()
	local result = {}
	local number = 1

	for _, inst in ipairs(state.state.claude_instances) do
		if inst.cwd == cwd then
			table.insert(result, {
				buf = inst.buf,
				job_id = inst.job_id,
				color_idx = inst.color_idx,
				cwd = inst.cwd,
				spawn_type = inst.spawn_type,
				spawned_at = inst.spawned_at,
				number = number,
				win = buf_to_win[inst.buf],
			})
			number = number + 1
		end
	end

	return result
end

--- Get count of tracked instances
--- @return number count
function M.count()
	return #state.state.claude_instances
end

--- Get count of instances for current project
--- @return number count
function M.count_for_current_project()
	local cwd = vim.fn.getcwd()
	local count = 0

	for _, inst in ipairs(state.state.claude_instances) do
		if inst.cwd == cwd then
			count = count + 1
		end
	end

	return count
end

--- Find the window displaying a buffer (if any)
--- @param buf number Buffer ID
--- @return number|nil win Window ID or nil
function M.find_window_for_buf(buf)
	if not buf or not vim.api.nvim_buf_is_valid(buf) then
		return nil
	end

	for _, win in ipairs(vim.api.nvim_list_wins()) do
		if vim.api.nvim_win_is_valid(win) then
			local ok, win_buf = pcall(vim.api.nvim_win_get_buf, win)
			if ok and win_buf == buf then
				return win
			end
		end
	end
	return nil
end

return M
