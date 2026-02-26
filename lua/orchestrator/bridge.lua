-- Bridge Module
-- Connects orchestrator.nvim to Symmetria's agent-bridge.py via Unix socket.
-- Sends JSON-line state updates so the desktop shell can display agent status.
-- All operations are non-blocking (libuv async). Connection failures are silent.

local state = require("orchestrator.state")
local status_bar = require("orchestrator.status_bar")

---@class BridgeModule
local M = {}

local uv = vim.loop or vim.uv

-- Socket path: /run/user/$UID/symmetria-agents.sock
local SOCKET_PATH = string.format("/run/user/%d/symmetria-agents.sock", uv.getuid())

-- Reconnection interval (ms)
local RECONNECT_INTERVAL = 5000

-- Debug logging (set to false to silence)
local DEBUG = false

--- Log a debug message to Neovim's message area and :messages history.
--- @param fmt string Format string (passed to string.format)
--- @param ... any Format arguments
local function dbg(fmt, ...)
	if not DEBUG then
		return
	end
	local pid = uv.getpid() or 0
	local msg = string.format("[bridge:%d] " .. fmt, pid, ...)
	vim.schedule(function()
		vim.api.nvim_echo({ { msg, "Comment" } }, true, {})
	end)
end

-- Title update debounce (ms)
local TITLE_DEBOUNCE_MS = 200

---@type userdata|nil libuv pipe handle
local pipe = nil

---@type userdata|nil Reconnection timer
local reconnect_timer = nil

---@type userdata|nil Title debounce timer
local title_debounce_timer = nil

---@type boolean Whether we're currently connected
local connected = false

---@type number|nil Neovim's PID (stable identifier for this session)
local nvim_pid = nil

-- Forward declaration (start_reconnect is defined after send but referenced by it)
local start_reconnect

-- ============================================================
-- INTERNAL: Socket Communication
-- ============================================================

--- Send a JSON message to the bridge (fire-and-forget).
--- @param msg table Message table to serialize
local function send(msg)
	if not connected or not pipe then
		dbg("send(%s) skipped: connected=%s, pipe=%s", msg.type or "?", tostring(connected), tostring(pipe))
		return
	end

	local ok, json = pcall(vim.json.encode, msg)
	if not ok then
		dbg("send(%s) JSON encode failed", msg.type or "?")
		return
	end

	-- uv.write is non-blocking; errors are silently ignored
	local write_ok, write_err = pcall(function()
		pipe:write(json .. "\n")
	end)
	if not write_ok then
		-- Connection likely broken, mark as disconnected
		dbg("send(%s) WRITE FAILED: %s — marking disconnected", msg.type or "?", tostring(write_err))
		connected = false
		if pipe and not pipe:is_closing() then
			pipe:close()
		end
		pipe = nil
		start_reconnect()
	else
		dbg("send(%s) ok (%d bytes)", msg.type or "?", #json)
	end
end

--- Extract project name from a cwd path (basename).
--- @param cwd string Full path like "/home/jc/projects/kosmos"
--- @return string Project name like "kosmos"
local function project_from_cwd(cwd)
	if not cwd or cwd == "" then
		return "unknown"
	end
	-- Remove trailing slash, then get basename
	return cwd:gsub("/$", ""):match("([^/]+)$") or "unknown"
end

--- Build instance data table for a single Claude instance.
--- @param inst table Instance from state.claude_instances
--- @return table Serializable instance data
local function build_instance_data(inst)
	return {
		buf = inst.buf,
		cwd = inst.cwd or "",
		project = project_from_cwd(inst.cwd),
		spawn_type = inst.spawn_type or "fresh",
		color_idx = inst.color_idx or 0,
		dangerous = inst.dangerous or false,
		title = status_bar.get_instance_title(inst.buf) or "",
		spawned_at = inst.spawned_at or 0,
	}
end

-- ============================================================
-- INTERNAL: Connection Management
-- ============================================================

--- Start reconnection timer (checks every RECONNECT_INTERVAL ms).
start_reconnect = function()
	if reconnect_timer then
		dbg("start_reconnect: timer already running, skipping")
		return -- Already running
	end

	dbg("start_reconnect: starting %dms reconnect timer", RECONNECT_INTERVAL)
	reconnect_timer = uv.new_timer()
	reconnect_timer:start(RECONNECT_INTERVAL, RECONNECT_INTERVAL, function()
		-- Check if socket file exists before attempting connection
		local stat = uv.fs_stat(SOCKET_PATH)
		if stat then
			dbg("reconnect tick: socket exists, calling connect()")
			vim.schedule(function()
				M.connect()
			end)
		else
			dbg("reconnect tick: socket NOT found at %s", SOCKET_PATH)
		end
	end)
end

--- Stop reconnection timer.
local function stop_reconnect()
	if reconnect_timer then
		if not reconnect_timer:is_closing() then
			reconnect_timer:stop()
			reconnect_timer:close()
		end
		reconnect_timer = nil
	end
end

-- ============================================================
-- PUBLIC API
-- ============================================================

--- Attempt to connect to the bridge socket.
function M.connect()
	dbg("connect() called: connected=%s, pipe=%s", tostring(connected), tostring(pipe))
	if connected or pipe then
		dbg("connect() BAILED: already connected or pipe exists")
		return
	end

	-- Check if socket exists
	local stat = uv.fs_stat(SOCKET_PATH)
	if not stat then
		dbg("connect(): socket not found at %s, starting reconnect", SOCKET_PATH)
		start_reconnect()
		return
	end

	dbg("connect(): socket found, creating pipe and connecting...")
	pipe = uv.new_pipe(false)

	pipe:connect(SOCKET_PATH, function(err)
		if err then
			-- Connection failed, try again later
			dbg("connect(): pipe:connect FAILED: %s", tostring(err))
			if pipe and not pipe:is_closing() then
				pipe:close()
			end
			pipe = nil
			start_reconnect()
			return
		end

		dbg("connect(): pipe:connect SUCCESS, setting up read_start")

		-- Detect server disconnection (bridge restart/crash).
		-- The bridge never writes to clients, so any data or EOF means the
		-- connection is dead. Without this, `connected` stays true forever
		-- because nothing reads the kernel-buffered EOF after the server exits.
		pipe:read_start(function(read_err, data)
			dbg("read_start FIRED: err=%s, data=%s", tostring(read_err), tostring(data))
			if read_err or not data then
				dbg("read_start: EOF/error detected — marking disconnected, starting reconnect")
				vim.schedule(function()
					connected = false
					if pipe and not pipe:is_closing() then
						pipe:close()
					end
					pipe = nil
					start_reconnect()
				end)
			end
		end)

		vim.schedule(function()
			connected = true
			stop_reconnect()
			dbg("connect(): CONNECTED — sending hello + sync")

			-- Send hello
			send({
				type = "hello",
				nvim_pid = nvim_pid,
				nvim_socket = vim.v.servername or "",
			})

			-- Send full sync
			M.send_sync()
		end)
	end)
end

--- Send full state synchronization.
function M.send_sync()
	local instances_data = {}
	for _, inst in ipairs(state.state.claude_instances) do
		table.insert(instances_data, build_instance_data(inst))
	end

	send({
		type = "sync",
		nvim_pid = nvim_pid,
		instances = instances_data,
	})
end

--- Notify bridge of a new instance.
--- @param instance table The registered instance data
function M.notify_spawn(instance)
	send({
		type = "added",
		nvim_pid = nvim_pid,
		instance = build_instance_data(instance),
	})
end

--- Notify bridge of a removed instance.
--- @param buf number Buffer ID of the removed instance
function M.notify_remove(buf)
	send({
		type = "removed",
		nvim_pid = nvim_pid,
		buf = buf,
	})
end

--- Notify bridge of focus change.
--- @param buf number Buffer ID that received focus
function M.notify_focus(buf)
	send({
		type = "focus",
		nvim_pid = nvim_pid,
		buf = buf,
	})
end

--- Notify bridge of a title update (debounced).
--- @param buf number Buffer ID
function M.notify_title(buf)
	-- Debounce: cancel pending update and schedule new one
	if title_debounce_timer then
		if not title_debounce_timer:is_closing() then
			title_debounce_timer:stop()
			title_debounce_timer:close()
		end
		title_debounce_timer = nil
	end

	title_debounce_timer = uv.new_timer()
	title_debounce_timer:start(TITLE_DEBOUNCE_MS, 0, function()
		vim.schedule(function()
			local title = status_bar.get_instance_title(buf) or ""
			send({
				type = "updated",
				nvim_pid = nvim_pid,
				buf = buf,
				title = title,
			})
			if title_debounce_timer and not title_debounce_timer:is_closing() then
				title_debounce_timer:close()
			end
			title_debounce_timer = nil
		end)
	end)
end

--- Initialize the bridge (called from orchestrator.setup).
function M.setup()
	nvim_pid = uv.getpid()
	dbg("setup(): nvim_pid=%d, socket=%s", nvim_pid, SOCKET_PATH)
	M.connect()
end

--- Clean disconnect (called from orchestrator.teardown).
function M.disconnect()
	-- Send goodbye before disconnecting
	if connected then
		send({
			type = "goodbye",
			nvim_pid = nvim_pid,
		})
	end

	stop_reconnect()

	if title_debounce_timer then
		if not title_debounce_timer:is_closing() then
			title_debounce_timer:stop()
			title_debounce_timer:close()
		end
		title_debounce_timer = nil
	end

	if pipe then
		if not pipe:is_closing() then
			pipe:close()
		end
		pipe = nil
	end

	connected = false
end

return M
