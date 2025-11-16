# prompt-editor.nvim

A Neovim plugin providing a floating prompt editor for terminal workflows.

## Features

- **Toggle-able floating window** - Quick access to a dedicated prompt buffer
- **Cursor position and mode memory** - Automatically restores your cursor position and editing mode
- **Send prompts to visible terminals** - Seamlessly send multi-line prompts to any visible terminal window
- **Bottom-anchored, centered layout** - Non-intrusive floating window design
- **Markdown syntax highlighting** - Enhanced editing experience with proper syntax highlighting
- **Smart buffer handling** - Persistent buffer that retains content across toggles

## Installation

### lazy.nvim

For local development:

```lua
{
  dir = "~/Dev/prompt-editor.nvim",
  name = "prompt-editor.nvim",
  dev = true,
  keys = {
    { "<leader>ap", desc = "Toggle prompt editor" },
    { "<C-S-Space>", mode = { "n", "i" }, desc = "Toggle prompt editor" },
  },
}
```

For installation from GitHub (once published):

```lua
{
  "yourusername/prompt-editor.nvim",
  keys = {
    { "<leader>ap", desc = "Toggle prompt editor" },
    { "<C-S-Space>", mode = { "n", "i" }, desc = "Toggle prompt editor" },
  },
}
```

### Configuration

No configuration needed - works out of the box! The plugin automatically sets up when loaded.

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

### Keybindings

**Toggle Prompt Editor:**
- `<leader>ap` (Normal mode)
- `<C-S-Space>` (Normal and Insert mode)

**Send Prompt to Terminal:**
- `<leader><CR>` (Normal and Insert mode, when inside prompt editor)

### Commands

- `:PromptToggle` - Toggle the floating prompt editor
- `:PromptSend` - Send the current prompt to a visible terminal

### Workflow

1. Open the prompt editor with `<leader>ap` or `<C-S-Space>`
2. Write your multi-line prompt in the floating window (markdown syntax highlighting enabled)
3. Press `<leader><CR>` to send the prompt to any visible terminal window
4. The prompt editor closes automatically and focuses the terminal
5. Your prompt content is saved - toggle the editor again to see your previous text

### Smart Behavior

- **Empty buffer**: Opens in insert mode at the beginning
- **Existing content**: Restores your last cursor position and editing mode
- **Terminal detection**: Automatically finds visible terminal windows
- **Error handling**: Provides helpful notifications if no terminal is found or prompt is empty

## Development

### Testing

The plugin includes a `teardown()` function for cleanup during development:

```lua
require("prompt-editor").teardown()
```

This is useful when:
- Reloading the plugin during development
- Cleaning up resources in tests
- Resetting state completely

### Project Structure

```
prompt-editor.nvim/
├── README.md                    # This file
├── lua/
│   └── prompt-editor/
│       └── init.lua            # Main module implementation
└── plugin/
    └── prompt-editor.lua       # Auto-setup on plugin load
```

## Requirements

- Neovim >= 0.8.0 (for floating window API)
- A terminal buffer (`:terminal`) to send prompts to

## License

MIT

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## Acknowledgments

Originally developed as part of a Neovim dotfiles configuration, extracted into a standalone plugin for easier sharing and maintenance.
