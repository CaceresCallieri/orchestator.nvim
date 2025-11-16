-- Auto-setup when plugin loads
if vim.g.loaded_prompt_editor then
	return
end
vim.g.loaded_prompt_editor = 1

-- Lazy-load the module when first used
vim.api.nvim_create_user_command("PromptToggle", function()
	require("prompt-editor").toggle()
end, { desc = "Toggle prompt editor" })

vim.api.nvim_create_user_command("PromptSend", function()
	require("prompt-editor").send_to_terminal()
end, { desc = "Send prompt to terminal" })

-- Setup function can be called from config
vim.api.nvim_create_autocmd("VimEnter", {
	once = true,
	callback = function()
		require("prompt-editor").setup()
	end,
})
