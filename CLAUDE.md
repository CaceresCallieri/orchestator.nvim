# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

orchestrator.nvim is a Neovim plugin for orchestrating AI agent terminal workflows with Claude Code. It provides a floating prompt editor for composing multi-line prompts, manages multiple Claude Code terminal instances per project, and displays a visual status bar showing active instances.

## Development Commands

```bash
# Reload plugin during development (preserves running Claude instances)
:OrchestratorReload

# Debug plugin state
:OrchestratorDebug

# Test teardown (cleans up all state)
:lua require("orchestrator").teardown()
```

## Architecture

### Module Dependency Flow

```
init.lua (entry point, public API, setup)
    ├── state.lua (centralized state - no dependencies)
    ├── highlights.lua (color palette, highlight groups)
    ├── instances.lua (instance tracking) ─── requires state, highlights
    ├── status_bar.lua (winbar status bar) ─── requires state, highlights, instances
    ├── picker.lua (vim.ui.select wrapper) ─── requires instances, highlights, state
    ├── editor.lua (floating prompt editor) ─── requires state
    └── terminal.lua (spawn/focus/kill) ─── no direct requires
```

### Breaking Circular Dependencies

The plugin uses setter injection to avoid circular dependencies between modules. In `init.lua` setup():
- `instances.set_status_bar(status_bar)` - instances notifies status_bar on changes
- `terminal.set_instances(instances)` - terminal registers spawned instances
- `picker.set_terminal(terminal)` - picker spawns new terminals
- `editor.set_send_function(M.send_to_terminal)` - editor sends prompts to init's orchestration function

### State Management

All plugin state is centralized in `state.lua` via `M.state`:
- `editor` - Window ID, tabs array (`{buf, name}`), current tab index
- `status_bar` - Visibility flag only (winbar is per-window, no central window/buffer)
- `claude_instances` - Array of instance objects with buf, job_id, color_idx, cwd, spawn_type, spawned_at
- `next_color_idx` - Rotating 1-8 color assignment
- `last_active_buf` - Tracks last focused Claude terminal for picker prioritization

### Instance Lifecycle

1. **Spawn**: `terminal.spawn()` creates buffer → opens terminal with `termopen()` → registers via `instances.register_spawned()`
2. **Track**: Instances stored in `state.state.claude_instances` with unique color index (1-8, wraps)
3. **Focus**: `terminal.focus()` finds/switches to window containing buffer, enters insert mode
4. **Cleanup**: `TermClose` autocmd triggers `instances.unregister()`, updates status bar

### UI Components

The plugin uses different UI strategies for its components:
- **Editor**: Floating window (z=50), 60% width × 40% height, bottom-centered
- **Status bar**: Native `vim.wo.winbar` applied to all non-floating windows, displays instance bubbles
- **Picker**: Uses native `vim.ui.select`, integrates with telescope/fzf-lua if available

### Multi-Tab Prompt Editor

The editor supports multiple prompt tabs:
- Tabs stored in `state.state.editor.tabs` as `{buf, name}` pairs
- Names auto-generated as "prompt-N" (fills gaps in numbering, checks existing buffers)
- Each tab preserves cursor position (mark 'p') and insert mode state (`vim.b[buf].prompt_was_insert`)
- Tab deletion switches buffer before deleting to prevent window close

### Keymaps System

Uses a hybrid approach:
1. **<Plug> mappings** - Global function references (e.g., `<Plug>(OrchestratorSend)`)
2. **Buffer-local keymaps** - Applied when editor opens, configurable via `setup({keymaps = {...}})`
3. **User commands** - `:PromptEditorToggle`, `:AgentsPick`, `:AgentsSpawn`, etc.

Keymap config validation in `validate_config()` - values must be string or false (to disable).

### Status Bar (Winbar) Rendering

Uses native `vim.wo.winbar` with statusline format syntax (`%#Highlight#text`):
- Applied to all non-floating, non-special windows via `WinEnter`/`BufEnter` autocmds
- 8 color palettes with Active/Dim variants for body and ActiveCap/DimCap for bubble borders
- Bubble effect with powerline semicircles (`` U+E0B6, `` U+E0B4)
- Active instance: the one whose window matches `vim.api.nvim_get_current_win()`
- Title display: reads `vim.b.term_title` (populated by Neovim from OSC 2 sequences)
- Title updates debounced via `TermRequest` autocmd (50ms) to prevent flicker during streaming

Key functions in `status_bar.lua`:
- `build_winbar_string()` - constructs the statusline format string with highlight groups
- `apply_to_all_windows()` - applies winbar to all applicable windows (uses pcall for safety)
- `should_apply_winbar()` - filters out floating windows, quickfix, loclist, nofile buffers
- `update()` - main entry point called when instances change or focus shifts

## Key Patterns

### Defensive Window/Buffer Checks

Always validate before operations:
```lua
if state.state.editor.win and vim.api.nvim_win_is_valid(state.state.editor.win) then
```

### Window Lookup Optimization

`instances.lua` uses `build_window_lookup()` to create buf→win mapping once rather than iterating windows per buffer (O(w) vs O(n*w)).

### Job Validation

Before sending to terminal, validate job is running:
```lua
local job_status = vim.fn.jobwait({ term.job_id }, 0)[1]
if job_status ~= -1 then -- -1 means still running
```

### Scheduled Callbacks

Use `vim.schedule()` in async contexts (TermClose, on_exit) to ensure Neovim state is consistent.

## Testing Considerations

- `teardown()` cleans all state for test isolation
- `reload()` preserves Claude instances while refreshing code
- Buffer names must be unique - `generate_tab_name()` checks both tabs array and `vim.fn.bufexists()`
