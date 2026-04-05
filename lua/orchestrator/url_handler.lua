-- URL Handler Module
-- Detects and opens URLs from Claude terminal buffer lines
-- Handles ANSI stripping, cursor proximity, and edge cases like
-- balanced parentheses, markdown links, and trailing punctuation

---@class UrlHandlerModule
local M = {}

-- Forward declaration for instances (set via setter to avoid circular dep)
---@type table|nil
local instances = nil

--- Set the instances module reference (called from init.lua)
--- @param inst table The instances module
function M.set_instances(inst)
	instances = inst
end

-- ============================================================
-- TEXT CLEANING
-- ============================================================

--- Strip ANSI escape codes from a line
--- Handles SGR sequences (colors, styles), cursor/clear sequences, and OSC sequences
--- @param line string Input line potentially containing ANSI codes
--- @return string Cleaned line without ANSI codes
local function strip_ansi(line)
	-- SGR sequences (colors, styles): ESC[...m
	-- This handles all color codes including 256-color (38;5;N) and truecolor (38;2;R;G;B)
	line = line:gsub("\27%[[0-9;]*m", "")

	-- Cursor/clear sequences: ESC[...H/A/B/C/D/J/K/s/u
	line = line:gsub("\27%[[0-9;]*[HABCDJKsu]", "")

	-- OSC sequences (title, hyperlinks): ESC]...BEL or ESC]...ST
	line = line:gsub("\27%][^\7\27]*\7", "") -- BEL terminator
	line = line:gsub("\27%][^\27]*\27\\", "") -- ST terminator (ESC \)

	-- Single-char escape sequences (save/restore cursor: ESC 7 and ESC 8)
	line = line:gsub("\27[78]", "")

	return line
end

-- ============================================================
-- URL EXTRACTION
-- ============================================================

--- Strip trailing punctuation that is likely sentence-ending, not part of the URL
--- Handles balanced parentheses for Wikipedia-style URLs
--- @param url string Raw URL string
--- @return string Cleaned URL
local function strip_trailing_punctuation(url)
	-- Strip trailing chars that are almost never part of URLs
	url = url:gsub("[%.%,%;%:%!%?]+$", "")

	-- Handle balanced parentheses:
	-- "https://en.wikipedia.org/wiki/Foo_(bar)" → keep balanced )
	-- "(https://example.com)" → strip unbalanced trailing )
	local open_count = select(2, url:gsub("%(", ""))
	local close_count = select(2, url:gsub("%)", ""))
	while close_count > open_count and url:sub(-1) == ")" do
		url = url:sub(1, -2)
		close_count = close_count - 1
	end

	return url
end

--- Check if a position range overlaps with any existing URL entry
--- @param urls table[] Existing URL entries with start_col and end_col
--- @param start_col number Start column to check
--- @param end_col number End column to check
--- @return boolean overlaps True if the range overlaps an existing entry
local function overlaps_existing(urls, start_col, end_col)
	for _, entry in ipairs(urls) do
		if start_col >= entry.start_col and start_col <= entry.end_col then
			return true
		end
		if end_col >= entry.start_col and end_col <= entry.end_col then
			return true
		end
	end
	return false
end

--- Find all URLs in a line of text
--- Pass 1: markdown links [text](url)
--- Pass 2: bare http(s):// URLs not already captured by markdown
--- @param line string ANSI-stripped line text
--- @return table[] urls Array of {url, start_col, end_col} (0-indexed columns)
local function find_urls_in_line(line)
	local urls = {}

	-- Pass 1: Markdown links [text](url) — extract URL from parens
	local search_start = 1
	while true do
		-- Find next markdown link pattern
		local bracket_start, bracket_end = line:find("%[.-%]%(", search_start)
		if not bracket_start then
			break
		end

		-- Find the closing paren for the URL
		local url_start = bracket_end + 1
		local paren_depth = 1
		local url_end = url_start

		while url_end <= #line and paren_depth > 0 do
			local char = line:sub(url_end, url_end)
			if char == "(" then
				paren_depth = paren_depth + 1
			elseif char == ")" then
				paren_depth = paren_depth - 1
			end
			if paren_depth > 0 then
				url_end = url_end + 1
			end
		end

		if paren_depth == 0 and url_end > url_start then
			local url = line:sub(url_start, url_end - 1)
			if url:match("^https?://") then
				table.insert(urls, {
					url = url,
					-- Use the full markdown link span for cursor proximity
					start_col = bracket_start - 1, -- 0-indexed
					end_col = url_end - 1, -- 0-indexed (includes closing paren)
				})
			end
		end

		search_start = bracket_end + 1
	end

	-- Pass 2: Bare http(s):// URLs not already captured by markdown
	-- URL-valid characters per RFC 3986 (unreserved + reserved subset)
	local url_pattern = "https?://[%w%-%.%_%~%:%/%?%#%[%]%@%!%$%&%'%(%)%*%+%,%;%%=]+"

	search_start = 1
	while true do
		local match_start, match_end = line:find(url_pattern, search_start)
		if not match_start then
			break
		end

		local raw_url = line:sub(match_start, match_end)
		local cleaned_url = strip_trailing_punctuation(raw_url)

		-- Recalculate end position after stripping
		local cleaned_end = match_start + #cleaned_url - 1

		-- 0-indexed columns
		local start_col = match_start - 1
		local end_col = cleaned_end - 1

		-- Skip if this URL is already captured by a markdown link
		if not overlaps_existing(urls, start_col, end_col) then
			table.insert(urls, {
				url = cleaned_url,
				start_col = start_col,
				end_col = end_col,
			})
		end

		search_start = match_end + 1
	end

	return urls
end

--- Find the URL nearest to the cursor column
--- Returns the URL the cursor is ON (distance=0), or the closest one
--- @param urls table[] Array of {url, start_col, end_col}
--- @param cursor_col number 0-indexed cursor column
--- @return table|nil nearest The nearest URL entry, or nil if empty
local function nearest_url(urls, cursor_col)
	if #urls == 0 then
		return nil
	end
	if #urls == 1 then
		return urls[1]
	end

	local best = nil
	local best_dist = math.huge

	for _, entry in ipairs(urls) do
		local dist
		if cursor_col >= entry.start_col and cursor_col <= entry.end_col then
			dist = 0 -- Cursor is ON this URL
		elseif cursor_col < entry.start_col then
			dist = entry.start_col - cursor_col
		else
			dist = cursor_col - entry.end_col
		end

		if dist < best_dist then
			best_dist = dist
			best = entry
		end
	end

	return best
end

-- ============================================================
-- PUBLIC API
-- ============================================================

--- Copy the URL nearest to the cursor on the current line to the system clipboard
--- Only works in Claude terminal buffers in normal mode
--- @return boolean success True if a URL was found and copied
function M.open_url_at_cursor()
	-- 1. Validate context (same pattern as edit_tracker:validate_jump_context)
	if not instances then
		vim.notify("URL handler not initialized", vim.log.levels.ERROR)
		return false
	end

	local current_buf = vim.api.nvim_get_current_buf()
	local instance = instances.get_by_buf(current_buf)

	if not instance then
		vim.notify("Not in a Claude terminal buffer", vim.log.levels.WARN)
		return false
	end

	-- 2. Get current line and cursor position
	local cursor = vim.api.nvim_win_get_cursor(0)
	local cursor_line = cursor[1] - 1 -- Convert to 0-indexed for buf_get_lines
	local cursor_col = cursor[2] -- Already 0-indexed

	local lines = vim.api.nvim_buf_get_lines(current_buf, cursor_line, cursor_line + 1, false)
	if #lines == 0 then
		return false
	end

	local clean_line = strip_ansi(lines[1])

	-- 3. Find URLs in visible text
	local found_urls = find_urls_in_line(clean_line)

	if #found_urls == 0 then
		vim.notify("No URL found on current line", vim.log.levels.INFO)
		return false
	end

	local target = nearest_url(found_urls, cursor_col)
	if not target then
		return false
	end

	-- 4. Copy to system clipboard (+ register, uses wl-copy on Wayland)
	vim.fn.setreg("+", target.url)
	vim.notify("Copied: " .. target.url, vim.log.levels.INFO)
	return true
end

return M
