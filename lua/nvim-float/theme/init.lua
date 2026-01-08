---@module 'nvim-float.theme'
---@brief Theme and highlight group management for nvim-float
---
---This module manages all highlight groups used by nvim-float.
---Users can override these by defining their own highlights after setup().

local Defaults = require("nvim-float.theme.defaults")
local Styles = require("nvim-float.theme.styles")

local M = {}

---@class NvimFloatThemeConfig
---@field link_to_existing boolean? Link to existing Neovim highlight groups (default: true)
---@field override table<string, table>? Custom highlight overrides

---Custom highlight groups registered by plugins
---@type table<string, table>
local custom_highlights = {}

---Cached persisted overrides
---@type table<string, table>?
local persisted_overrides = nil

---Track if theme has been initialized
---@type boolean
local _initialized = false

-- ============================================================================
-- Setup
-- ============================================================================

---Setup highlight groups
---@param opts NvimFloatThemeConfig? Theme configuration
function M.setup(opts)
  opts = opts or {}

  -- Load persisted overrides from style editor (if any)
  persisted_overrides = Defaults.load_persisted()

  -- Apply default highlights
  -- Priority: persisted > user config > default
  for name, def in pairs(Defaults.highlights) do
    local persisted_def = persisted_overrides and persisted_overrides[name]
    local user_def = opts.override and opts.override[name]

    if persisted_def then
      vim.api.nvim_set_hl(0, name, persisted_def)
    elseif user_def then
      vim.api.nvim_set_hl(0, name, user_def)
    else
      vim.api.nvim_set_hl(0, name, def)
    end
  end

  -- Apply custom highlights registered by plugins
  for name, def in pairs(custom_highlights) do
    local persisted_def = persisted_overrides and persisted_overrides[name]
    local user_def = opts.override and opts.override[name]

    if persisted_def then
      vim.api.nvim_set_hl(0, name, persisted_def)
    elseif user_def then
      vim.api.nvim_set_hl(0, name, user_def)
    else
      vim.api.nvim_set_hl(0, name, def)
    end
  end

  _initialized = true
end

---Check if theme has been initialized
---@return boolean
function M.is_initialized()
  return _initialized
end

-- ============================================================================
-- Highlight Group Registration
-- ============================================================================

---Register additional highlight groups
---Allows plugins to add their own highlight groups
---@param highlights table<string, table> Map of highlight group name -> definition
function M.register_highlights(highlights)
  for name, def in pairs(highlights) do
    custom_highlights[name] = def
  end
  -- Apply immediately if already setup
  for name, def in pairs(highlights) do
    vim.api.nvim_set_hl(0, name, def)
  end
end

-- ============================================================================
-- Style Mapping (delegates to Styles module)
-- ============================================================================

---Get the highlight group name for a semantic style
---This maps user-friendly style names to actual highlight groups
---@param style string Semantic style name
---@return string? hl_group Highlight group name or nil
function M.get_hl_group(style)
  return Styles.get(style)
end

---Register additional style mappings
---@param mappings table<string, string> Map of style name -> highlight group
function M.register_styles(mappings)
  Styles.register(mappings)
end

-- ============================================================================
-- Highlight Group Queries
-- ============================================================================

---Get all defined highlight group names
---@return string[]
function M.get_all_groups()
  return Defaults.get_all_names()
end

---Get the default highlight definition for a group
---@param name string Highlight group name
---@return table? definition The default definition or nil
function M.get_default_highlight(name)
  return Defaults.get(name)
end

-- ============================================================================
-- Re-exports for convenience
-- ============================================================================

---Get all style names
---@return string[]
function M.get_all_styles()
  return Styles.get_all_names()
end

---Check if a style exists
---@param style string Style name
---@return boolean
function M.style_exists(style)
  return Styles.exists(style)
end

-- Expose submodules for advanced usage
M.Defaults = Defaults
M.Styles = Styles

return M
