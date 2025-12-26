---@module nvim-float
---@brief Floating window UI library for Neovim
---
---nvim-float provides a comprehensive floating window system with:
--- - Easy window creation and management
--- - Content building with highlights and styling
--- - Input fields (text, dropdowns, multi-select)
--- - Multi-panel layouts
--- - Scrollbars
--- - Dialogs (confirm, info, select)

local M = {}

M.version = "0.1.0"

-- Lazy-loaded submodules
local _float = nil
local _content_builder = nil
local _input_manager = nil
local _config = nil
local _theme = nil

---Get the config module (lazy-loaded)
---@return table
local function get_config()
  if not _config then
    _config = require("nvim-float.config")
  end
  return _config
end

---Get the theme module (lazy-loaded)
---@return table
local function get_theme()
  if not _theme then
    _theme = require("nvim-float.theme")
  end
  return _theme
end

---Get the float module (lazy-loaded)
---@return UiFloat
local function get_float()
  if not _float then
    _float = require("nvim-float.float")
  end
  return _float
end

---Get the content builder module (lazy-loaded)
---@return table
local function get_content_builder()
  if not _content_builder then
    _content_builder = require("nvim-float.content_builder")
  end
  return _content_builder
end

---Get the input manager module (lazy-loaded)
---@return table
local function get_input_manager()
  if not _input_manager then
    _input_manager = require("nvim-float.input_manager")
  end
  return _input_manager
end

-- ============================================================================
-- Setup
-- ============================================================================

---Setup nvim-float with user configuration
---@param opts table? User configuration options
function M.setup(opts)
  opts = opts or {}

  -- Merge user config with defaults
  local config = get_config()
  config.setup(opts)

  -- Setup highlight groups
  local theme = get_theme()
  theme.setup(opts.theme or {})
end

-- ============================================================================
-- Float Window API (delegated to float module)
-- ============================================================================

---Create a new floating window
---@param lines string[]|FloatConfig? Initial content lines OR config
---@param config FloatConfig? Configuration options
---@return FloatWindow
function M.create(lines, config)
  return get_float().create(lines, config)
end

---Z-index layers for proper window stacking
M.ZINDEX = {
  BASE = 50,        -- Base floating windows
  OVERLAY = 100,    -- Overlay windows (popups, tooltips)
  MODAL = 150,      -- Modal dialogs
  DROPDOWN = 200,   -- Dropdowns and menus
}

-- ============================================================================
-- Content Builder API
-- ============================================================================

---Create a new ContentBuilder instance
---@return ContentBuilder
function M.content_builder()
  return get_content_builder().new()
end

-- ============================================================================
-- Input Manager API
-- ============================================================================

---Create a new InputManager instance
---@param float_win FloatWindow The floating window to manage inputs for
---@param content_builder ContentBuilder The content builder with input definitions
---@return InputManager
function M.input_manager(float_win, content_builder)
  return get_input_manager().new(float_win, content_builder)
end

-- ============================================================================
-- Dialog API (convenience wrappers)
-- ============================================================================

---Show a confirmation dialog
---@param opts table Dialog options
---@return FloatWindow
function M.confirm(opts)
  return get_float().confirm(opts)
end

---Show an info dialog
---@param opts table Dialog options
---@return FloatWindow
function M.info(opts)
  return get_float().info(opts)
end

---Show a select dialog
---@param opts table Dialog options
---@return FloatWindow
function M.select(opts)
  return get_float().select(opts)
end

-- ============================================================================
-- Multi-Panel API
-- ============================================================================

---Create a multi-panel floating window layout
---@param opts table Multi-panel options
---@return table Multi-panel instance
function M.multipanel(opts)
  return get_float().multipanel(opts)
end

-- ============================================================================
-- Demo
-- ============================================================================

---Show a demo window to test the plugin
function M.demo()
  local float = get_float()
  local ContentBuilder = get_content_builder()

  local builder = ContentBuilder.new()
  builder:header("nvim-float Demo")
  builder:blank()
  builder:text("This is a demo of the nvim-float plugin.")
  builder:blank()
  builder:subheader("Features")
  builder:bullet("Floating windows with borders")
  builder:bullet("Content building with highlights")
  builder:bullet("Input fields and dropdowns")
  builder:bullet("Multi-panel layouts")
  builder:bullet("Scrollbars")
  builder:blank()
  builder:muted("Press 'q' or <Esc> to close")

  local lines = builder:build_lines()

  float.create(lines, {
    title = " nvim-float ",
    title_pos = "center",
    border = "rounded",
    width = 50,
    zindex = M.ZINDEX.MODAL,
  })
end

return M
