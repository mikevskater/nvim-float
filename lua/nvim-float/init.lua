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
--- - Form inputs with validation
--- - Interactive list pickers

local M = {}

M.version = "1.0.7"

-- Track if setup has been called
local _setup_complete = false

-- Lazy-loaded submodules
local _float = nil
local _content_builder = nil
local _input_manager = nil
local _config = nil
local _theme = nil
local _form = nil
local _interactive = nil
local _style_editor = nil

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

---Get the form module (lazy-loaded)
---@return UiFloatForm
local function get_form()
  if not _form then
    _form = require("nvim-float.float.form")
  end
  return _form
end

---Get the interactive module (lazy-loaded)
---@return UiFloatInteractive
local function get_interactive()
  if not _interactive then
    _interactive = require("nvim-float.float.interactive")
  end
  return _interactive
end

---Get the style editor module (lazy-loaded)
---@return table
local function get_style_editor()
  if not _style_editor then
    _style_editor = require("nvim-float.style_editor")
  end
  return _style_editor
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

  -- Setup highlight groups with user theme options
  local theme = get_theme()
  theme.setup(opts.theme or {})

  -- Mark setup as complete
  _setup_complete = true
end

---Check if setup has been called
---@return boolean
function M.is_setup()
  return _setup_complete
end

---Ensure setup has been called, auto-setup with defaults if not
---Call this before using features that require theme initialization
function M.ensure_setup()
  if not _setup_complete then
    M.setup({})
  end
end

-- ============================================================================
-- Plugin Extensibility API
-- ============================================================================

---Register additional style mappings for ContentBuilder
---Allows plugins to add their own semantic styles that map to highlight groups
---@param styles table<string, string> Map of style name -> highlight group name
---@param override boolean? If true, allows overriding existing styles (default: false)
function M.register_styles(styles, override)
  get_content_builder().register_styles(styles, override)
end

---Register additional highlight groups
---Allows plugins to add their own highlight groups
---@param highlights table<string, table> Map of highlight group name -> definition
function M.register_highlights(highlights)
  get_theme().register_highlights(highlights)
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
---@param config InputManagerConfig Configuration for the input manager
---@return InputManager
function M.input_manager(config)
  return get_input_manager().new(config)
end

---Get the InputManager class directly (for advanced usage)
---@return table InputManager class
function M.InputManager()
  return get_input_manager()
end

-- ============================================================================
-- Dialog API (convenience wrappers)
-- ============================================================================

---Show a confirmation dialog
---@param message string|string[] Message to display
---@param on_confirm function Callback on confirmation
---@param on_cancel function? Callback on cancel (optional)
---@return FloatWindow
function M.confirm(message, on_confirm, on_cancel)
  return get_float().confirm(message, on_confirm, on_cancel)
end

---Show an info dialog
---@param message string|string[] Message to display
---@param title string? Optional title
---@return FloatWindow
function M.info(message, title)
  return get_float().info(message, title)
end

---Show a select dialog
---@param items string[] List of items
---@param on_select function Callback with selected index and item
---@param title string? Optional title
---@return FloatWindow
function M.select(items, on_select, title)
  return get_float().select(items, on_select, title)
end

-- ============================================================================
-- Multi-Panel API
-- ============================================================================

---Create a multi-panel floating window layout
---@param config MultiPanelConfig Multi-panel configuration
---@return MultiPanelState? state State object (nil if creation failed)
function M.create_multi_panel(config)
  return get_float().create_multi_panel(config)
end

-- ============================================================================
-- Form API
-- ============================================================================

---Create a form with input fields, checkboxes, and validation
---@param config FormConfig Form configuration
---@return FormState? state Form state object (nil if creation failed)
function M.create_form(config)
  return get_form().create(config)
end

---Get the Form module directly (for advanced usage)
---@return UiFloatForm
function M.Form()
  return get_form()
end

-- ============================================================================
-- Interactive Picker API
-- ============================================================================

---Create an interactive list picker with navigation
---@param config FloatInteractiveConfig Picker configuration
---@return FloatInteractiveState? state Picker state object (nil if creation failed)
function M.create_picker(config)
  return get_interactive().create(config)
end

---Get the Interactive module directly (for advanced usage)
---@return UiFloatInteractive
function M.Interactive()
  return get_interactive()
end

-- ============================================================================
-- Demo
-- ============================================================================

---Show a demo window to test the plugin
function M.demo()
  -- Ensure theme highlights are set up
  M.ensure_setup()

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

  -- Use create_styled for proper highlight application
  float.create_styled(builder, {
    title = " nvim-float ",
    title_pos = "center",
    border = "rounded",
    width = 50,
    zindex = M.ZINDEX.MODAL,
  })
end

-- ============================================================================
-- Style Editor API
-- ============================================================================

---Show the style editor for customizing highlight groups
function M.show_style_editor()
  return get_style_editor().show()
end

return M
