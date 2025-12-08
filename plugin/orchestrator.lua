-- Plugin loader for orchestrator.nvim
-- Guards against multiple loads
-- Actual setup is done via require("orchestrator").setup() in user config

if vim.g.loaded_orchestrator then
	return
end
vim.g.loaded_orchestrator = 1
