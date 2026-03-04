-- Spawn Menu Module
-- Quick spawn menu displayed when user attempts to focus a non-existent Claude instance
-- Provides single-key shortcuts for spawning fresh/continue/resume instances

local state = require("orchestrator.state")

---@class SpawnMenuModule
local M = {}

-- Configuration for the floating menu
local config = {
	width = 30,
	border = "rounded",
	zindex = 55, -- Above editor (50) and status bar (45)
}

-- Forward declarations (set via setters to avoid circular dependencies)
---@type table|nil
local terminal = nil

---@type table|nil
local plugin_config = nil

--- Set terminal module reference (called from init.lua)
--- @param term table The terminal module
function M.set_terminal(term)
	terminal = term
end

--- Set plugin configuration reference (called from init.lua)
--- @param cfg table The plugin configuration
function M.set_config(cfg)
	plugin_config = cfg
end

--- Check if dangerous mode is enabled in config
--- @return boolean enabled
local function is_dangerous_mode_enabled()
	return plugin_config
		and plugin_config.dangerous_mode
		and plugin_config.dangerous_mode.enabled
		or false
end

--- Build menu content lines based on config
--- @return table lines Array of strings for menu content
local function build_menu_content()
	local lines = {
		"",
		"  n   New Claude (dangerous)",
		"  c   Continue Claude (dangerous)",
		"  r   Resume Claude (dangerous)",
	}

	-- Only show normal (non-dangerous) options if dangerous mode is enabled
	if is_dangerous_mode_enabled() then
		table.insert(lines, "")
		table.insert(lines, "  N   New Claude")
		table.insert(lines, "  C   Continue Claude")
		table.insert(lines, "  R   Resume Claude")
	end

	table.insert(lines, "")
	table.insert(lines, "  Press Esc or q to close")
	table.insert(lines, "")

	return lines
end

--- Check if the spawn menu is currently open
--- @return boolean is_open
function M.is_open()
	return state.state.spawn_menu.win ~= nil
		and vim.api.nvim_win_is_valid(state.state.spawn_menu.win)
end

--- Close the spawn menu
function M.close()
	if state.state.spawn_menu.win and vim.api.nvim_win_is_valid(state.state.spawn_menu.win) then
		vim.api.nvim_win_close(state.state.spawn_menu.win, true)
	end
	if state.state.spawn_menu.buf and vim.api.nvim_buf_is_valid(state.state.spawn_menu.buf) then
		vim.api.nvim_buf_delete(state.state.spawn_menu.buf, { force = true })
	end
	state.state.spawn_menu.win = nil
	state.state.spawn_menu.buf = nil
end

--- Build window title with optional context
--- @param target_num number|nil The instance number the user tried to focus
--- @return string title Window title
local function build_title(target_num)
	if target_num then
		return string.format(" Quick Spawn (#%d) ", target_num)
	end
	return " Quick Spawn "
end

--- Calculate window position (centered horizontally, upper-third vertically)
--- @param content_lines table Array of content lines
--- @param title string Window title
--- @return table opts Window configuration options
local function get_window_opts(content_lines, title)
	local width = config.width
	local height = #content_lines -- Dynamic height based on content

	-- Center horizontally, position in upper third vertically
	local row = math.floor((vim.o.lines - height) / 3)
	local col = math.floor((vim.o.columns - width) / 2)

	return {
		relative = "editor",
		width = width,
		height = height,
		row = row,
		col = col,
		style = "minimal",
		border = config.border,
		title = title,
		title_pos = "center",
		zindex = config.zindex,
	}
end

--- Apply highlights to menu content dynamically
--- @param buf number Buffer ID
--- @param lines table Content lines
local function apply_highlights(buf, lines)
	local ns_id = vim.api.nvim_create_namespace("OrchestratorSpawnMenu")

	for i, line in ipairs(lines) do
		local line_idx = i - 1 -- 0-based for nvim API

		-- Match key bindings: "  n   " or "  N   "
		local key = line:match("^%s+([ncrNCR])%s+")
		if key then
			local is_dangerous = key:match("[ncr]")
			local group = is_dangerous and "OrchestratorSpawnMenuDanger" or "OrchestratorSpawnMenuKey"

			-- Highlight the key character (at column 2, length 1)
			vim.api.nvim_buf_add_highlight(buf, ns_id, group, line_idx, 2, 3)

			-- Highlight "(dangerous)" suffix for dangerous options
			if is_dangerous then
				local danger_start = line:find("%(dangerous%)")
				if danger_start then
					vim.api.nvim_buf_add_highlight(buf, ns_id, group, line_idx, danger_start - 1, -1)
				end
			end
		elseif line:match("Press Esc or q") then
			-- Dismiss hint (dimmed)
			vim.api.nvim_buf_add_highlight(buf, ns_id, "Comment", line_idx, 0, -1)
		end
	end
end

--- Spawn a Claude instance after closing the menu
--- Must close menu BEFORE spawning to avoid window management conflicts
--- (terminal.spawn switches current buffer, which triggers BufLeave on menu)
--- @param spawn_type string "fresh" | "continue" | "resume"
--- @param dangerous boolean Whether to use --dangerously-skip-permissions
local function spawn_and_close(spawn_type, dangerous)
	if not terminal then
		vim.notify("Terminal module not available", vim.log.levels.ERROR)
		return
	end

	-- Close menu FIRST to avoid conflicts with terminal.spawn's buffer switching
	M.close()

	-- Spawn after menu is closed
	terminal.spawn(spawn_type, { dangerous = dangerous })
end

--- Setup buffer-local keymaps for the menu
--- @param buf number Buffer ID
local function setup_keymaps(buf)
	local opts = { buffer = buf, noremap = true, silent = true }

	-- Spawn configurations: key -> {spawn_type, dangerous}
	-- Lowercase = dangerous (quick access), Uppercase = normal
	local spawn_configs = {
		{ key = "n", spawn_type = "fresh", dangerous = true },
		{ key = "c", spawn_type = "continue", dangerous = true },
		{ key = "r", spawn_type = "resume", dangerous = true },
	}

	-- Add normal (non-dangerous) spawn options if dangerous mode is enabled
	if is_dangerous_mode_enabled() then
		table.insert(spawn_configs, { key = "N", spawn_type = "fresh", dangerous = false })
		table.insert(spawn_configs, { key = "C", spawn_type = "continue", dangerous = false })
		table.insert(spawn_configs, { key = "R", spawn_type = "resume", dangerous = false })
	end

	-- Setup keymaps from config
	for _, cfg in ipairs(spawn_configs) do
		vim.keymap.set("n", cfg.key, function()
			spawn_and_close(cfg.spawn_type, cfg.dangerous)
		end, opts)
	end

	-- Dismiss keys
	vim.keymap.set("n", "<Esc>", M.close, opts)
	vim.keymap.set("n", "q", M.close, opts)
end

--- Show the quick spawn menu
--- @param target_num number|nil The instance number the user tried to focus (for context)
function M.show(target_num)
	-- Close existing menu if open
	if M.is_open() then
		M.close()
	end

	-- Build content and title
	local lines = build_menu_content()
	local title = build_title(target_num)

	-- Create buffer
	local buf = vim.api.nvim_create_buf(false, true)
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].modifiable = true

	-- Set content
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

	-- Apply highlights
	apply_highlights(buf, lines)

	-- Make buffer non-modifiable after rendering
	vim.bo[buf].modifiable = false

	-- Create floating window
	local win_opts = get_window_opts(lines, title)
	local win = vim.api.nvim_open_win(buf, true, win_opts)

	-- Window options
	vim.wo[win].cursorline = false
	vim.wo[win].number = false
	vim.wo[win].relativenumber = false
	vim.wo[win].signcolumn = "no"
	vim.wo[win].wrap = false

	-- Store state in central state module
	state.state.spawn_menu.win = win
	state.state.spawn_menu.buf = buf

	-- Setup keymaps
	setup_keymaps(buf)

	-- Auto-close when leaving the window
	vim.api.nvim_create_autocmd({ "WinLeave", "BufLeave" }, {
		buffer = buf,
		once = true,
		callback = function()
			-- Schedule to avoid issues during window transition
			vim.schedule(M.close)
		end,
	})
end

--- Cleanup function for teardown
function M.teardown()
	M.close()
end

return M
