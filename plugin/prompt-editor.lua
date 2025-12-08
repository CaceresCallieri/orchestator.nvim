-- Plugin loader for prompt-editor.nvim
-- Guards against multiple loads
-- Actual setup is done via require("prompt-editor").setup() in user config

if vim.g.loaded_prompt_editor then
	return
end
vim.g.loaded_prompt_editor = 1
