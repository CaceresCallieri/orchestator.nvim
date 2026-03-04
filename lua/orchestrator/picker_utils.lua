-- Picker Utilities Module
-- Shared functions for picker and telescope_picker to reduce duplication
-- Contains formatting helpers and common picker operations

local status_bar = require("orchestrator.status_bar")

---@class PickerUtilsModule
local M = {}

--- Format timestamp as relative time (e.g., "2m ago", "1h ago")
--- @param timestamp number|nil Unix timestamp
--- @return string Formatted relative time string
function M.format_time_ago(timestamp)
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

--- Build display text for an instance (without dot prefix)
--- Used by both vim.ui.select and Telescope pickers for consistent formatting
--- @param inst table Instance data with number, spawn_type, dangerous, buf, spawned_at
--- @return string Formatted display text
function M.build_instance_text(inst)
	local spawn_label = ""
	if inst.spawn_type == "resume" then
		spawn_label = " [resumed]"
	elseif inst.spawn_type == "continue" then
		spawn_label = " [continued]"
	end

	local mode_prefix = (not inst.dangerous) and " " or "" -- lock U+F023 + space separator
	local title = status_bar.get_instance_title(inst.buf)
	local title_part = title and (" - " .. title) or ""
	local time_ago = M.format_time_ago(inst.spawned_at)

	return string.format(
		"%s[%d] Claude%s%s - %s",
		mode_prefix,
		inst.number,
		spawn_label,
		title_part,
		time_ago
	)
end

return M
