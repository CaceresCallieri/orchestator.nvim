-- Picker Module
-- Unified terminal selection UI for spawning and selecting Claude instances
-- Shows existing instances at top, spawn options below
-- Uses Telescope when available, falls back to vim.ui.select

local instances = require("orchestrator.instances")
local state = require("orchestrator.state")
local picker_utils = require("orchestrator.picker_utils")

---@class PickerModule
local M = {}

-- Forward declaration for terminal module (to avoid circular dep)
---@type table|nil
local terminal = nil

-- Cache telescope availability at module load time
-- Validates both telescope core and our telescope_picker module exist
local telescope_available = (function()
	local telescope_ok = pcall(require, "telescope")
	if not telescope_ok then
		return false
	end
	local picker_ok = pcall(require, "orchestrator.telescope_picker")
	return picker_ok
end)()

--- Set the terminal module reference (called from init.lua)
--- @param term table The terminal module
function M.set_terminal(term)
	terminal = term
end

--- Internal fallback picker using vim.ui.select (no colors)
--- Used when Telescope is unavailable or fails to load
--- @param callback function Called with selected terminal {buf, job_id, win, is_new}
local function select_fallback(callback)
	local project_instances = instances.get_for_current_project()
	local items = {}

	-- Single-pass prioritization: build items and find last active in one loop
	local last_active_buf = state.state.last_active_buf
	local last_active_item = nil

	for _, inst in ipairs(project_instances) do
		local item = {
			type = "existing",
			instance = inst,
			display = string.format("● %s", picker_utils.build_instance_text(inst)),
		}
		if inst.buf == last_active_buf then
			last_active_item = item
		else
			table.insert(items, item)
		end
	end

	-- Insert last active at front if found
	if last_active_item then
		table.insert(items, 1, last_active_item)
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

--- Show unified picker for Claude instances and spawn options
--- Displays existing instances first, then spawn options for current project
--- Uses Telescope when available for colored dots, falls back to vim.ui.select
--- @param callback function Called with selected terminal {buf, job_id, win, is_new}
function M.select(callback)
	if not terminal then
		vim.notify("Terminal module not initialized", vim.log.levels.ERROR)
		return
	end

	-- Use Telescope picker if available (supports colored dots)
	if telescope_available then
		local telescope_picker = require("orchestrator.telescope_picker")
		telescope_picker.set_terminal(terminal)
		telescope_picker.set_fallback(select_fallback)
		return telescope_picker.select(callback)
	end

	-- Fallback to vim.ui.select (no colors, but uses ● symbol)
	select_fallback(callback)
end

--- Show picker for existing instances only (no spawn options)
--- Used when you specifically want to select from existing terminals
--- Uses Telescope when available for colored dots, falls back to vim.ui.select
--- @param callback function Called with selected instance {buf, job_id, win}
function M.select_existing(callback)
	local project_instances = instances.get_for_current_project()

	if #project_instances == 0 then
		vim.notify("No Claude terminals found in current project", vim.log.levels.WARN)
		return
	end

	-- Use Telescope picker if available (supports colored dots)
	if telescope_available then
		local telescope_picker = require("orchestrator.telescope_picker")
		return telescope_picker.select_existing(callback)
	end

	-- Fallback to vim.ui.select (no colors, but uses ● symbol)
	local items = {}
	for _, inst in ipairs(project_instances) do
		table.insert(items, {
			instance = inst,
			display = string.format("● %s", picker_utils.build_instance_text(inst)),
		})
	end

	vim.ui.select(items, {
		prompt = "Select Claude Terminal:",
		format_item = function(item)
			return item.display
		end,
	}, function(choice)
		if not choice then
			return
		end

		callback({
			buf = choice.instance.buf,
			job_id = choice.instance.job_id,
			win = choice.instance.win,
		})
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
