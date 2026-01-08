---@module nvim-float.health
---@brief Health check module for nvim-float
---
---Run with :checkhealth nvim-float

local M = {}

---Perform health checks for nvim-float
function M.check()
  vim.health.start("nvim-float")

  -- Check Neovim version
  local nvim_version = vim.version()
  local version_str = string.format("%d.%d.%d", nvim_version.major, nvim_version.minor, nvim_version.patch)

  if vim.fn.has("nvim-0.9.0") == 1 then
    vim.health.ok("Neovim version: " .. version_str)
  else
    vim.health.error("Neovim >= 0.9.0 required (found " .. version_str .. ")")
  end

  -- Check if plugin loaded
  if vim.g.loaded_nvim_float then
    vim.health.ok("Plugin loaded")
  else
    vim.health.warn("Plugin not loaded - check your plugin manager configuration")
  end

  -- Check if setup was called
  local ok, nvim_float = pcall(require, "nvim-float")
  if not ok then
    vim.health.error("Failed to load nvim-float module")
    return
  end

  vim.health.ok("Module version: " .. (nvim_float.version or "unknown"))

  if nvim_float.is_setup() then
    vim.health.ok("Setup complete")
  else
    vim.health.info("Setup not called - using defaults (this is fine)")
  end

  -- Check theme initialization
  local theme_ok, theme = pcall(require, "nvim-float.theme")
  if theme_ok then
    if theme.is_initialized and theme.is_initialized() then
      vim.health.ok("Theme highlights initialized")
    else
      vim.health.info("Theme not initialized - will auto-initialize on first use")
    end
  else
    vim.health.warn("Could not load theme module")
  end

  -- Check for required highlight groups
  local required_highlights = {
    "NvimFloatNormal",
    "NvimFloatBorder",
    "NvimFloatTitle",
    "NvimFloatInput",
  }

  local missing_highlights = {}
  for _, hl_name in ipairs(required_highlights) do
    local hl = vim.api.nvim_get_hl(0, { name = hl_name })
    if not hl or (not hl.fg and not hl.bg and not hl.link) then
      table.insert(missing_highlights, hl_name)
    end
  end

  if #missing_highlights == 0 then
    vim.health.ok("Core highlight groups defined")
  elseif #missing_highlights == #required_highlights then
    vim.health.info("Highlight groups not yet defined - will be created on setup()")
  else
    vim.health.warn("Some highlight groups missing: " .. table.concat(missing_highlights, ", "))
  end

  -- Check commands exist
  local commands = { "NvimFloatDemo", "NvimFloatStyle", "NvimFloatVersion" }
  local missing_commands = {}
  for _, cmd in ipairs(commands) do
    if vim.fn.exists(":" .. cmd) ~= 2 then
      table.insert(missing_commands, cmd)
    end
  end

  if #missing_commands == 0 then
    vim.health.ok("All commands registered")
  else
    vim.health.warn("Missing commands: " .. table.concat(missing_commands, ", "))
  end

  -- Configuration check
  local config_ok, config = pcall(require, "nvim-float.config")
  if config_ok then
    local cfg = config.get()
    vim.health.ok("Configuration loaded")
    if cfg.debug then
      vim.health.info("Debug mode: enabled")
    end
  else
    vim.health.warn("Could not load config module")
  end
end

return M
