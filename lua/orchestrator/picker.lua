-- Picker Module
-- Unified terminal selection UI for spawning and selecting Claude instances
-- Shows existing instances at top, spawn options below

local instances = require("orchestrator.instances")
local highlights = require("orchestrator.highlights")
local state = require("orchestrator.state")

---@class PickerModule
local M = {}

-- Forward declaration for terminal module (to avoid circular dep)
---@type table|nil
local terminal = nil

--- Set the terminal module reference (called from init.lua)
--- @param term table The terminal module
function M.set_terminal(term)
	terminal = term
end

--- Format timestamp as relative time
--- @param timestamp number Unix timestamp
--- @return string Formatted string like "2m ago", "1h ago"
local function format_time_ago(timestamp)
	if not timestamp then
		return ""
	end

	local diff = os.time() - timestamp

	if diff < 60 then
		return "just now"
	elseif diff < 3600 then
		return string.format("%dm ago", math.floor(diff / 60))
	elseif diff < 86400 then
		return string.format("%dh ago", math.floor(diff / 3600))
	else
		return string.format("%dd ago", math.floor(diff / 86400))
	end
end

--- Show unified picker for Claude instances and spawn options
--- Displays existing instances first, then spawn options for current project
--- @param callback function Called with selected terminal {buf, job_id, win, is_new}
function M.select(callback)
	if not terminal then
		vim.notify("Terminal module not initialized", vim.log.levels.ERROR)
		return
	end

	local project_instances = instances.get_for_current_project()
	local items = {}

	-- Prioritize the last active Claude instance (tracked via WinEnter/BufEnter)
	local last_active_buf = state.state.last_active_buf
	if last_active_buf then
		local last_active_idx = nil
		for i, inst in ipairs(project_instances) do
			if inst.buf == last_active_buf then
				last_active_idx = i
				break
			end
		end

		-- Move last active instance to the front if found and not already first
		if last_active_idx and last_active_idx > 1 then
			local active_inst = table.remove(project_instances, last_active_idx)
			table.insert(project_instances, 1, active_inst)
		end
	end

	-- Section 1: Existing instances (current project only)
	for _, inst in ipairs(project_instances) do
		local time_ago = format_time_ago(inst.spawned_at)
		local spawn_label = ""
		if inst.spawn_type == "resume" then
			spawn_label = " [resumed]"
		elseif inst.spawn_type == "continue" then
			spawn_label = " [continued]"
		end

		table.insert(items, {
			type = "existing",
			instance = inst,
			display = string.format(
				"[%d] Claude (%s)%s - %s",
				inst.number,
				highlights.get_color_name(inst.color_idx),
				spawn_label,
				time_ago
			),
		})
	end

	-- Section 2: Spawn new options (in consistent order)
	for _, key in ipairs(terminal.spawn_order) do
		local config = terminal.spawn_types[key]
		table.insert(items, {
			type = "spawn",
			spawn_type = key,
			display = string.format("+ %s", config.label),
			description = config.description,
		})
	end

	vim.ui.select(items, {
		prompt = "Claude Terminal:",
		format_item = function(item)
			return item.display
		end,
	}, function(choice)
		if not choice then
			return
		end

		if choice.type == "spawn" then
			-- Spawn new instance
			local instance = terminal.spawn(choice.spawn_type)
			if instance then
				callback({
					buf = instance.buf,
					job_id = instance.job_id,
					win = nil, -- Will be current window after spawn
					is_new = true,
				})
			end
		else
			-- Existing instance
			callback({
				buf = choice.instance.buf,
				job_id = choice.instance.job_id,
				win = choice.instance.win,
				is_new = false,
			})
		end
	end)
end

--- Show picker for existing instances only (no spawn options)
--- Used when you specifically want to select from existing terminals
--- @param callback function Called with selected instance {buf, job_id, win}
function M.select_existing(callback)
	local project_instances = instances.get_for_current_project()

	if #project_instances == 0 then
		vim.notify("No Claude terminals found in current project", vim.log.levels.WARN)
		return
	end

	local items = {}
	for _, inst in ipairs(project_instances) do
		local time_ago = format_time_ago(inst.spawned_at)
		table.insert(items, {
			instance = inst,
			display = string.format(
				"[%d] Claude (%s) - %s",
				inst.number,
				highlights.get_color_name(inst.color_idx),
				time_ago
			),
		})
	end

	vim.ui.select(items, {
		prompt = "Select Claude Terminal:",
		format_item = function(item)
			return item.display
		end,
	}, function(choice)
		if choice then
			callback({
				buf = choice.instance.buf,
				job_id = choice.instance.job_id,
				win = choice.instance.win,
			})
		end
	end)
end

--- Select and execute an action on a Claude terminal
--- Convenience wrapper that validates the terminal is still valid
--- @param action function Action to perform with selected terminal
--- @param on_error function|nil Called if terminal is no longer valid
function M.select_and_execute(action, on_error)
	M.select_existing(function(term)
		-- Validate terminal is still valid
		if not vim.api.nvim_buf_is_valid(term.buf) then
			if on_error then
				on_error("Selected terminal is no longer valid")
			else
				vim.notify("Selected terminal is no longer valid", vim.log.levels.ERROR)
			end
			return
		end

		action(term)
	end)
end

return M
