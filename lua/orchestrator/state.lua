-- State Module
-- Centralized state management for orchestrator.nvim
-- Single source of truth for all plugin state

---@class StateModule
local M = {}

-- Main state table
-- All modules should access state through this module's functions
M.state = {
	-- Prompt editor window state (multi-tab)
	editor = {
		win = nil, -- Window ID of floating prompt editor (shared across tabs)
		tabs = {}, -- Array of {buf = number, name = string}
		current_tab_idx = 1, -- Index into tabs array (1-indexed)
	},

	-- Status bar state
	status_bar = {
		win = nil, -- Window ID of status bar
		buf = nil, -- Buffer ID of status bar buffer
		visible = true, -- Whether bar should be shown when instances exist
	},

	-- Claude instance tracking (spawn-controlled)
	-- Array of: {
	--   buf = number,           -- Terminal buffer ID
	--   job_id = number,        -- Terminal job ID (for chan_send)
	--   color_idx = number,     -- Color index (1-8) for UI
	--   cwd = string,           -- Working directory at spawn time
	--   spawn_type = string,    -- "fresh" | "resume" | "continue"
	--   spawned_at = number,    -- os.time() timestamp
	-- }
	claude_instances = {},

	-- Next color index to assign (1-8, wraps around)
	next_color_idx = 1,

	-- Last active Claude instance buffer (for picker prioritization)
	last_active_buf = nil,
}

--- Reset all state to initial values
--- Used in teardown for clean plugin unload
function M.reset()
	M.state.editor.win = nil
	M.state.editor.tabs = {}
	M.state.editor.current_tab_idx = 1
	M.state.status_bar.win = nil
	M.state.status_bar.buf = nil
	M.state.status_bar.visible = true
	M.state.claude_instances = {}
	M.state.next_color_idx = 1
	M.state.last_active_buf = nil
end

--- Get next color index and increment
--- Wraps around 1-8
--- @return number color_idx
function M.get_next_color_idx()
	local idx = M.state.next_color_idx
	M.state.next_color_idx = (M.state.next_color_idx % 8) + 1
	return idx
end

return M
