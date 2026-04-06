-- Bridge Module
-- Connects orchestrator.nvim to Symmetria's agent-bridge.py via Unix socket.
-- Sends JSON-line state updates so the desktop shell can display agent status.
-- All operations are non-blocking (libuv async). Connection failures are silent.

local state = require("orchestrator.state")
local status_bar = require("orchestrator.status_bar")

---@class BridgeModule
local M = {}

local uv = vim.loop or vim.uv

-- Socket path: /run/user/$UID/symmetria-agents.sock (overridable via SYMMETRIA_AGENT_SOCKET)
local SOCKET_PATH = uv.os_getenv("SYMMETRIA_AGENT_SOCKET")
	or string.format("/run/user/%d/symmetria-agents.sock", uv.getuid())
local SOCKET_DIR = SOCKET_PATH:match("(.+)/[^/]+$") or string.format("/run/user/%d", uv.getuid())
local SOCKET_NAME = SOCKET_PATH:match("[^/]+$") or "symmetria-agents.sock"

-- Debug logging (set to true to enable diagnostic output in :messages)
local DEBUG = false

--- Log a debug message to Neovim's message area and :messages history.
--- @param fmt string Format string (passed to string.format)
--- @param ... any Format arguments
local function dbg(fmt, ...)
	if not DEBUG then
		return
	end
	local pid = uv.getpid() or 0
	-- Evaluate caller's format first, then prefix — avoids misinterpreting
	-- stray % characters from unexpected sources in fmt arguments.
	local body = string.format(fmt, ...)
	local msg = string.format("[bridge:%d] %s", pid, body)
	vim.schedule(function()
		vim.api.nvim_echo({ { msg, "Comment" } }, true, {})
	end)
end

-- Title update debounce (ms)
local TITLE_DEBOUNCE_MS = 200

---@type userdata|nil libuv pipe handle
local pipe = nil

---@type userdata|nil Filesystem watcher for socket directory (inotify-backed)
local socket_watcher = nil

---@type userdata|nil Title debounce timer
local title_debounce_timer = nil

---@type boolean Whether we're currently connected
local connected = false

---@type number|nil Neovim's PID (stable identifier for this session)
local nvim_pid = nil

--- Monotonically increasing connection generation. Each connect() attempt
--- increments this; callbacks capture their generation and bail if it has
--- advanced, preventing races between overlapping read_start/connect callbacks.
---@type number
local connection_gen = 0

-- ============================================================
-- INTERNAL: Connection Lifecycle Helpers
-- ============================================================

--- Start watching the socket directory for the bridge socket to appear.
--- Uses libuv fs_event (inotify on Linux) — no polling, instant notification.
--- Called when connect() finds no socket; stops itself once connected.
local function start_watching()
	if socket_watcher then
		return -- already watching
	end

	socket_watcher = uv.new_fs_event()
	local _, start_err = socket_watcher:start(SOCKET_DIR, {}, function(err, filename, _events)
		if err then
			dbg("watch: error %s", tostring(err))
			return
		end
		if filename ~= SOCKET_NAME then
			return -- not our file
		end
		-- Socket file appeared — try to connect on the main thread
		vim.schedule(function()
			if connected or pipe then
				return -- already connected or connection in-flight
			end
			dbg("watch: socket appeared, calling connect()")
			M.connect()
		end)
	end)
	if start_err then
		dbg("start_watching: FAILED: %s", tostring(start_err))
		socket_watcher:close()
		socket_watcher = nil
	else
		dbg("start_watching: watching %s for %s", SOCKET_DIR, SOCKET_NAME)
	end
end

--- Stop watching for the socket file.
local function stop_watching()
	if socket_watcher then
		if not socket_watcher:is_closing() then
			socket_watcher:stop()
			socket_watcher:close()
		end
		socket_watcher = nil
	end
end

--- Close the current pipe and mark as disconnected.
--- Captures `pipe` into a local before clearing, preventing stale-handle
--- errors if a concurrent vim.schedule callback has already nilled it.
--- Reconnection is handled externally by bridge.py solicitation via reconnect().
local function handle_disconnect()
	connected = false
	local p = pipe
	pipe = nil
	if p and not p:is_closing() then
		p:close()
	end
	start_watching()
end

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
		dbg("send(%s) WRITE FAILED: %s — marking disconnected", msg.type or "?", tostring(write_err))
		handle_disconnect()
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
		active = (inst.buf == state.state.last_active_buf),
	}
end

-- ============================================================
-- PUBLIC API
-- ============================================================

--- Attempt to connect to the bridge socket.
function M.connect()
	-- pipe non-nil means a connect is in-flight (callback not yet called)
	dbg("connect() called: connected=%s, pipe=%s", tostring(connected), tostring(pipe))
	if connected or pipe then
		dbg("connect() BAILED: already connected or pipe exists")
		return
	end

	-- Check if socket exists; if not, watch for it to appear (inotify)
	local stat = uv.fs_stat(SOCKET_PATH)
	if not stat then
		dbg("connect(): socket not found at %s, watching directory", SOCKET_PATH)
		start_watching()
		return
	end

	-- Increment generation so stale callbacks from a previous connect() bail
	connection_gen = connection_gen + 1
	local my_gen = connection_gen

	dbg("connect(): socket found, creating pipe (gen=%d)...", my_gen)
	pipe = uv.new_pipe(false)

	pipe:connect(SOCKET_PATH, function(err)
		if err then
			dbg("connect(): pipe:connect FAILED: %s", tostring(err))
			if my_gen == connection_gen then
				handle_disconnect()
			end
			return
		end

		dbg("connect(): pipe:connect SUCCESS (gen=%d), setting up read_start", my_gen)

		-- Detect server disconnection (bridge restart/crash).
		-- The bridge never writes to clients, so any data or EOF means the
		-- connection is dead. Without this, `connected` stays true forever
		-- because nothing reads the kernel-buffered EOF after the server exits.
		pipe:read_start(function(read_err, data)
			dbg("read_start FIRED (gen=%d): err=%s, data=%s", my_gen, tostring(read_err), tostring(data))
			if read_err or not data then
				vim.schedule(function()
					-- Stale callback — a newer connect() has superseded us
					if my_gen ~= connection_gen then
						dbg("read_start: stale gen=%d (current=%d), ignoring", my_gen, connection_gen)
						return
					end
					dbg("read_start: EOF/error detected — disconnecting (gen=%d)", my_gen)
					connection_gen = connection_gen + 1
					handle_disconnect()
				end)
			end
		end)

		vim.schedule(function()
			-- Stale callback — EOF already fired before we got scheduled
			if my_gen ~= connection_gen then
				dbg("connect(): stale gen=%d (current=%d), not marking connected", my_gen, connection_gen)
				return
			end

			connected = true
			stop_watching()
			dbg("connect(): CONNECTED (gen=%d) — sending hello + sync", my_gen)

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

--- Force reconnection to the bridge (called via RPC when bridge restarts).
--- Unlike connect(), this tears down stale state first (connect bails if
--- pipe/connected are set). Unlike disconnect(), this skips the goodbye
--- message (the old bridge is dead — nobody is listening).
function M.reconnect()
	if not nvim_pid then
		return "not_initialized"
	end
	dbg("reconnect(): tearing down stale state and reconnecting")
	connection_gen = connection_gen + 1 -- invalidate stale callbacks
	connected = false -- prevent send() during teardown
	local p = pipe
	pipe = nil -- clear before close so connect() doesn't bail
	if p and not p:is_closing() then
		p:close()
	end
	M.connect() -- connect to new socket immediately
	return "ok"
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
	-- Cancel pending debounce timer (capture into local to avoid identity races)
	if title_debounce_timer then
		local t = title_debounce_timer
		title_debounce_timer = nil
		if not t:is_closing() then
			t:stop()
			t:close()
		end
	end

	-- One-shot timer (repeat=0) auto-stops after firing; no close-from-callback
	-- needed. This avoids the bug where the callback checks title_debounce_timer
	-- by identity but it has already been replaced by a newer timer.
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
	-- Mark disconnected first to prevent racing callbacks from sending messages
	local was_connected = connected
	connected = false
	stop_watching()

	-- Clean up title debounce timer
	if title_debounce_timer then
		local t = title_debounce_timer
		title_debounce_timer = nil
		if not t:is_closing() then
			t:stop()
			t:close()
		end
	end

	-- Send goodbye directly on the still-open pipe (bypassing send()'s
	-- connected guard which we just set to false)
	if was_connected and pipe and not pipe:is_closing() then
		local ok, json = pcall(vim.json.encode, { type = "goodbye", nvim_pid = nvim_pid })
		if ok then
			pcall(function()
				pipe:write(json .. "\n")
			end)
		end
	end

	-- Close pipe
	local p = pipe
	pipe = nil
	if p and not p:is_closing() then
		p:close()
	end
end

return M
