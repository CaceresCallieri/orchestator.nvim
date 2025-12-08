# orchestrator.nvim

A Neovim plugin for orchestrating AI agent terminal workflows with Claude Code.

## Features

- **Toggle-able floating window** - Quick access to a dedicated prompt buffer
- **Cursor position and mode memory** - Automatically restores your cursor position and editing mode
- **Multiple Claude instances** - Spawn and manage multiple Claude Code terminals per project
- **Unified picker** - Single picker for spawning new or selecting existing Claude terminals
- **Agents status bar** - Visual indicator of active Claude instances
- **Bottom-anchored, centered layout** - Non-intrusive floating window design
- **Markdown syntax highlighting** - Enhanced editing experience with proper syntax highlighting
- **Smart buffer handling** - Persistent buffer that retains content across toggles

## Installation

### lazy.nvim

For local development:

```lua
{
  dir = "~/Dev/orchestrator.nvim",
  name = "orchestrator.nvim",
  dev = true,
  config = function()
    require("orchestrator").setup()
  end,
  keys = {
    -- Prompt editor
    { "<leader>ap", "<cmd>PromptEditorToggle<cr>", desc = "Toggle prompt editor" },
    { "<C-S-Space>", "<cmd>PromptEditorToggle<cr>", mode = { "n", "i", "t" }, desc = "Toggle prompt editor" },
    { "<C-S-CR>", "<cmd>PromptEditorSend<cr>", mode = { "n", "i" }, desc = "Send prompt to Claude" },

    -- Agent management
    { "<leader>aa", "<cmd>AgentsPick<cr>", desc = "AI/Agents picker" },
    { "<leader>an", "<cmd>AgentsSpawn fresh<cr>", desc = "New Claude" },
    { "<leader>ar", "<cmd>AgentsSpawn resume<cr>", desc = "Resume Claude" },
    { "<leader>ac", "<cmd>AgentsSpawn continue<cr>", desc = "Continue Claude" },
  },
}
```

For installation from GitHub (once published):

```lua
{
  "yourusername/orchestrator.nvim",
  config = function()
    require("orchestrator").setup()
  end,
  keys = {
    { "<leader>ap", "<cmd>PromptEditorToggle<cr>", desc = "Toggle prompt editor" },
    { "<C-S-Space>", "<cmd>PromptEditorToggle<cr>", mode = { "n", "i", "t" }, desc = "Toggle prompt editor" },
    { "<leader>aa", "<cmd>AgentsPick<cr>", desc = "AI/Agents picker" },
  },
}
```

### Configuration

**No configuration required!** The plugin provides commands that you can bind to any keys you prefer.

The keybindings shown above are **recommended defaults** - feel free to customize them to your preference.

If you're using lazy.nvim with local dev plugins, ensure your `dev.path` is configured:

```lua
require("lazy").setup("your.plugins", {
  dev = {
    path = "~/Dev",  -- Where local plugins live
    patterns = {},   -- Or specify specific patterns
    fallback = false,
  },
})
```

## Usage

### Commands

The plugin provides feature-specific commands:

**Prompt Editor:**
- `:PromptEditorToggle` - Toggle the floating prompt editor
- `:PromptEditorSend` - Send the current prompt to a Claude terminal

**Agent Management:**
- `:AgentsPick` - Show unified picker to spawn or select Claude terminals
- `:AgentsSpawn [type]` - Spawn new Claude terminal (fresh/resume/continue)
- `:AgentsKill [num]` - Kill Claude instance by project-local number
- `:AgentsStatusBarToggle` - Toggle the agents status bar visibility

**Debug:**
- `:OrchestratorDebug` - Debug plugin state

### Recommended Keybindings

**Toggle Prompt Editor:**
- `<leader>ap` (Normal mode)
- `<C-S-Space>` (Normal, Insert, and Terminal mode)

**Send Prompt to Terminal:**
- `<leader><CR>` (Normal and Insert mode, when inside prompt editor)
- `<C-S-CR>` (Normal and Insert mode)

**Agent Management:**
- `<leader>aa` - Open agents picker
- `<leader>an` - New Claude instance
- `<leader>ar` - Resume Claude conversation
- `<leader>ac` - Continue Claude conversation

### Workflow

1. Open the prompt editor with `<leader>ap` or `<C-S-Space>`
2. Write your multi-line prompt in the floating window (markdown syntax highlighting enabled)
3. Press `<leader><CR>` to send the prompt to a Claude terminal
4. If no Claude instance exists, the picker shows spawn options
5. The prompt editor closes automatically and focuses the terminal
6. Your prompt content is saved - toggle the editor again to see your previous text

### Smart Behavior

- **Empty buffer**: Opens in insert mode at the beginning
- **Existing content**: Restores your last cursor position and editing mode
- **Per-project instances**: Claude instances are filtered by working directory
- **Error handling**: Provides helpful notifications if terminal has exited or prompt is empty

## Development

### Testing

The plugin includes a `teardown()` function for cleanup during development:

```lua
require("orchestrator").teardown()
```

This is useful when:
- Reloading the plugin during development
- Cleaning up resources in tests
- Resetting state completely

### Project Structure

```
orchestrator.nvim/
├── README.md                    # This file
├── lua/
│   └── orchestrator/
│       ├── init.lua             # Main module, public API
│       ├── state.lua            # Centralized state management
│       ├── highlights.lua       # Color palette and highlight groups
│       ├── terminal.lua         # Spawn, focus, kill operations
│       ├── instances.lua        # Instance tracking and queries
│       ├── status_bar.lua       # Floating status bar UI
│       ├── picker.lua           # Unified spawn/select picker
│       └── editor.lua           # Floating prompt editor
└── plugin/
    └── orchestrator.lua         # Guard against multiple loads
```

## Requirements

- Neovim >= 0.8.0 (for floating window API)
- Claude CLI (`claude`) installed and accessible in PATH

## License

MIT

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## Acknowledgments

Originally developed as part of a Neovim dotfiles configuration, extracted into a standalone plugin for easier sharing and maintenance.
