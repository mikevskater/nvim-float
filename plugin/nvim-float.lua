-- nvim-float plugin entry point
-- This file is automatically loaded by Neovim

-- Prevent loading twice
if vim.g.loaded_nvim_float then
  return
end
vim.g.loaded_nvim_float = 1

-- ============================================================================
-- User Commands
-- ============================================================================

-- Version command
vim.api.nvim_create_user_command("NvimFloatVersion", function()
  local nvim_float = require("nvim-float")
  vim.notify(string.format("nvim-float version: %s", nvim_float.version), vim.log.levels.INFO)
end, {
  desc = "Show nvim-float version",
})

-- Demo command for testing
vim.api.nvim_create_user_command("NvimFloatDemo", function()
  local nvim_float = require("nvim-float")
  nvim_float.demo()
end, {
  desc = "Show nvim-float demo window",
})

-- Style editor command
vim.api.nvim_create_user_command("NvimFloatStyle", function()
  local nvim_float = require("nvim-float")
  nvim_float.show_style_editor()
end, {
  desc = "Open nvim-float style editor",
})

-- ============================================================================
-- <Plug> Mappings
-- ============================================================================
-- These allow users to create their own keymaps without hardcoding commands.
-- Usage: vim.keymap.set("n", "<leader>fd", "<Plug>(nvim-float-demo)")

vim.keymap.set("n", "<Plug>(nvim-float-demo)", function()
  require("nvim-float").demo()
end, { desc = "Show nvim-float demo window" })

vim.keymap.set("n", "<Plug>(nvim-float-style-editor)", function()
  require("nvim-float").show_style_editor()
end, { desc = "Open nvim-float style editor" })

vim.keymap.set("n", "<Plug>(nvim-float-version)", function()
  local nvim_float = require("nvim-float")
  vim.notify(string.format("nvim-float version: %s", nvim_float.version), vim.log.levels.INFO)
end, { desc = "Show nvim-float version" })
