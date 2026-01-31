-- Telescope Picker Module
-- Custom Telescope picker with colored instance dots
-- Falls back gracefully when Telescope modules are unavailable

local instances = require("orchestrator.instances")
local highlights = require("orchestrator.highlights")
local state = require("orchestrator.state")
local picker_utils = require("orchestrator.picker_utils")

---@class TelescopePickerModule
local M = {}

-- Forward declaration for terminal module (to avoid circular dep)
---@type table|nil
local terminal = nil

-- Forward declaration for fallback picker (set by picker.lua)
---@type function|nil
local fallback_select = nil

--- Set the terminal module reference (called from picker.lua)
--- @param term table The terminal module
function M.set_terminal(term)
	terminal = term
end

--- Set the fallback select function (called from picker.lua)
--- This allows telescope_picker to fall back to vim.ui.select if Telescope fails
--- @param fn function The fallback select function
function M.set_fallback(fn)
	fallback_select = fn
end

--- Create a Telescope displayer for entries with colored dot
--- Module-level helper to reduce repetition in select/select_existing
--- @return table displayer The entry_display displayer object
local function create_displayer()
	local entry_display = require("telescope.pickers.entry_display")
	return entry_display.create({
		separator = " ",
		items = {
			{ width = 1 }, -- Colored dot
			{ remaining = true }, -- Rest of entry
		},
	})
end

--- Safely load all required Telescope modules
--- @return table|nil modules Table of loaded modules or nil if loading failed
local function load_telescope_modules()
	local ok, result = pcall(function()
		return {
			pickers = require("telescope.pickers"),
			finders = require("telescope.finders"),
			conf = require("telescope.config").values,
			actions = require("telescope.actions"),
			action_state = require("telescope.actions.state"),
		}
	end)

	if not ok then
		return nil
	end
	return result
end

--- Show Telescope picker for Claude instances and spawn options
--- @param callback function Called with selected terminal {buf, job_id, win, is_new}
function M.select(callback)
	if not terminal then
		vim.notify("Terminal module not initialized", vim.log.levels.ERROR)
		return
	end

	-- Safe module loading with fallback
	local modules = load_telescope_modules()
	if not modules then
		vim.notify("Telescope modules unavailable, using fallback", vim.log.levels.WARN)
		if fallback_select then
			fallback_select(callback)
		end
		return
	end

	local pickers = modules.pickers
	local finders = modules.finders
	local conf = modules.conf
	local actions = modules.actions
	local action_state = modules.action_state

	local project_instances = instances.get_for_current_project()

	-- Single-pass prioritization: build items and find last active in one loop
	local items = {}
	local last_active_buf = state.state.last_active_buf
	local last_active_item = nil

	for _, inst in ipairs(project_instances) do
		local item = {
			type = "existing",
			instance = inst,
			text = picker_utils.build_instance_text(inst),
			color_idx = inst.color_idx,
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

	-- Add spawn options
	for _, key in ipairs(terminal.spawn_order) do
		local config = terminal.spawn_types[key]
		table.insert(items, {
			type = "spawn",
			spawn_type = key,
			text = string.format("+ %s", config.label),
			config = config,
		})
	end

	-- Create displayer for entries with colored dot
	local displayer = create_displayer()

	-- Entry maker function
	local function make_entry(item)
		local display_func = function(entry)
			if entry.type == "existing" then
				local dot = "●"
				local hl_group = highlights.get_instance_highlight(entry.color_idx)
				return displayer({
					{ dot, hl_group },
					entry.text,
				})
			else
				-- Spawn option - no dot
				return displayer({
					{ " " },
					entry.text,
				})
			end
		end

		return {
			value = item,
			display = display_func,
			ordinal = item.text,
			type = item.type,
			instance = item.instance,
			spawn_type = item.spawn_type,
			text = item.text,
			color_idx = item.color_idx,
			config = item.config,
		}
	end

	-- Create and show picker (compact layout)
	pickers
		.new({}, {
			prompt_title = "Claude Terminal",
			finder = finders.new_table({
				results = items,
				entry_maker = make_entry,
			}),
			sorter = conf.generic_sorter({}),
			layout_strategy = "vertical",
			layout_config = {
				width = 0.4,
				height = 0.3,
				prompt_position = "top",
			},
			attach_mappings = function(prompt_bufnr, _)
				actions.select_default:replace(function()
					actions.close(prompt_bufnr)
					local selection = action_state.get_selected_entry()
					if not selection then
						return
					end

					if selection.type == "spawn" then
						-- Spawn new instance
						local instance = terminal.spawn(selection.spawn_type)
						if instance then
							callback({
								buf = instance.buf,
								job_id = instance.job_id,
								win = nil,
								is_new = true,
							})
						end
					else
						-- Existing instance
						callback({
							buf = selection.instance.buf,
							job_id = selection.instance.job_id,
							win = selection.instance.win,
							is_new = false,
						})
					end
				end)
				return true
			end,
		})
		:find()
end

--- Show Telescope picker for existing instances only (no spawn options)
--- @param callback function Called with selected instance {buf, job_id, win}
function M.select_existing(callback)
	local project_instances = instances.get_for_current_project()

	if #project_instances == 0 then
		vim.notify("No Claude terminals found in current project", vim.log.levels.WARN)
		return
	end

	-- Safe module loading
	local modules = load_telescope_modules()
	if not modules then
		vim.notify("Telescope modules unavailable", vim.log.levels.WARN)
		return
	end

	local pickers = modules.pickers
	local finders = modules.finders
	local conf = modules.conf
	local actions = modules.actions
	local action_state = modules.action_state

	-- Create displayer for entries with colored dot
	local displayer = create_displayer()

	-- Entry maker function
	local function make_entry(inst)
		local display_func = function(entry)
			local dot = "●"
			local hl_group = highlights.get_instance_highlight(entry.color_idx)
			return displayer({
				{ dot, hl_group },
				entry.text,
			})
		end

		local text = picker_utils.build_instance_text(inst)

		return {
			value = inst,
			display = display_func,
			ordinal = text,
			instance = inst,
			text = text,
			color_idx = inst.color_idx,
		}
	end

	-- Create and show picker (compact layout)
	pickers
		.new({}, {
			prompt_title = "Select Claude Terminal",
			finder = finders.new_table({
				results = project_instances,
				entry_maker = make_entry,
			}),
			sorter = conf.generic_sorter({}),
			layout_strategy = "vertical",
			layout_config = {
				width = 0.4,
				height = 0.3,
				prompt_position = "top",
			},
			attach_mappings = function(prompt_bufnr, _)
				actions.select_default:replace(function()
					actions.close(prompt_bufnr)
					local selection = action_state.get_selected_entry()
					if not selection then
						return
					end

					callback({
						buf = selection.instance.buf,
						job_id = selection.instance.job_id,
						win = selection.instance.win,
					})
				end)
				return true
			end,
		})
		:find()
end

return M
