---@module 'nvim-float.window.config'
---@brief Configuration, defaults, and Z-index management for FloatWindow

local M = {}

-- ============================================================================
-- Type Definitions
-- ============================================================================

---@class ControlKeyDef
---@field key string The key or key combination
---@field desc string Description of what the key does

---@class ControlsDefinition
---@field header string? Section header text
---@field keys ControlKeyDef[] Array of key definitions

---@class FloatConfig
---Configuration for floating window creation
---@field title string? Window title text
---@field title_pos "left"|"center"|"right"? Title alignment (default: "center")
---@field footer string? Footer text
---@field footer_pos "left"|"center"|"right"? Footer alignment (default: "center")
---@field border "none"|"single"|"double"|"rounded"|"solid"|"shadow"|table? Border style (default: "rounded")
---@field width number? Fixed width in columns
---@field min_width number? Minimum width
---@field max_width number? Maximum width (default: vim.o.columns - 4)
---@field height number? Fixed height in rows
---@field min_height number? Minimum height
---@field max_height number? Maximum height (default: vim.o.lines - 6)
---@field relative "editor"|"cursor"|"win"? Position relative to (default: "editor")
---@field row number? Y position (for non-centered)
---@field col number? X position (for non-centered)
---@field centered boolean? Center window on screen (default: true)
---@field enter boolean? Enter window after creation (default: true)
---@field focusable boolean? Window can receive focus (default: true)
---@field keymaps table<string, function|string>? Key -> function/command mappings
---@field default_keymaps boolean? Include default close keys (q, <Esc>) (default: true)
---@field filetype string? Buffer filetype for syntax highlighting
---@field buftype string? Buffer type (default: "nofile")
---@field readonly boolean? Make buffer read-only (default: true)
---@field modifiable boolean? Allow buffer modifications (default: false)
---@field winhighlight string? Custom window highlight groups
---@field winblend number? Window transparency 0-100 (default: 0)
---@field cursorline boolean? Highlight cursor line (default: true)
---@field wrap boolean? Enable line wrapping (default: false)
---@field zindex number? Window layer ordering (default: 50)
---@field on_close function? Callback when window closes
---@field on_pre_filetype function? Callback before filetype is set
---@field style "minimal"|nil? Window style (default: "minimal")
---@field content_builder ContentBuilder? ContentBuilder instance for styled content with inputs
---@field enable_inputs boolean? Enable input field mode for the window
---@field scrollbar boolean? Show scrollbar when content exceeds window height (default: true)
---@field controls ControlsDefinition[]? Controls/keybindings to show in "?" popup
---@field win number? Parent window ID for relative='win' positioning

-- ============================================================================
-- Z-Index Layers
-- ============================================================================

---Z-index layers for proper window stacking
---@class ZIndexLayers
M.ZINDEX = {
  BASE = 50,        -- Base floating windows (multi-panel, standard floats)
  OVERLAY = 100,    -- Overlay windows (popups, tooltips, pickers)
  MODAL = 150,      -- Modal dialogs (confirmations, alerts)
  DROPDOWN = 200,   -- Dropdowns and menus (highest priority)
}

---Z-index layer boundaries for bring_to_front/send_to_back operations
local LAYER_BOUNDS = {
  { min = 0, max = 99, base = M.ZINDEX.BASE },
  { min = 100, max = 149, base = M.ZINDEX.OVERLAY },
  { min = 150, max = 199, base = M.ZINDEX.MODAL },
  { min = 200, max = 250, base = M.ZINDEX.DROPDOWN },
}

---Get the base z-index for the layer containing the given z-index
---@param zindex number Current z-index value
---@return number base The base z-index for this layer
function M.get_layer_base(zindex)
  for _, layer in ipairs(LAYER_BOUNDS) do
    if zindex >= layer.min and zindex <= layer.max then
      return layer.base
    end
  end
  return M.ZINDEX.BASE
end

---Get the maximum z-index for the layer containing the given z-index
---@param zindex number Current z-index value
---@return number max The maximum z-index for this layer
function M.get_layer_max(zindex)
  for _, layer in ipairs(LAYER_BOUNDS) do
    if zindex >= layer.min and zindex <= layer.max then
      return layer.max
    end
  end
  return 99
end

-- ============================================================================
-- Default Configuration
-- ============================================================================

---Apply default configuration values to a config table
---@param config FloatConfig Configuration to modify in-place
function M.apply_defaults(config)
  config.title_pos = config.title_pos or "center"
  config.footer_pos = config.footer_pos or "center"
  config.border = config.border or "rounded"
  config.max_width = config.max_width or (vim.o.columns - 4)
  config.max_height = config.max_height or (vim.o.lines - 6)
  config.relative = config.relative or "editor"
  config.centered = config.centered ~= false  -- Default true
  config.enter = config.enter ~= false  -- Default true
  config.focusable = config.focusable ~= false  -- Default true
  config.default_keymaps = config.default_keymaps ~= false  -- Default true
  config.buftype = config.buftype or "nofile"
  config.readonly = config.readonly ~= false  -- Default true
  config.modifiable = config.modifiable or false
  config.winblend = config.winblend or 0
  config.cursorline = config.cursorline ~= false  -- Default true
  config.wrap = config.wrap or false
  config.zindex = config.zindex or 50
  config.style = config.style or "minimal"
  config.scrollbar = config.scrollbar ~= false  -- Default true

  -- Default footer to "? = Controls" when controls are defined
  if not config.footer and config.controls and #config.controls > 0 then
    config.footer = "? = Controls"
  end
end

return M
