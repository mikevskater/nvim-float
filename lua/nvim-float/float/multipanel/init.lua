---@class MultiPanelModule
---Multi-panel floating window support with nested layouts
---@module nvim-float.float.multipanel
local MultiPanel = {}

-- Lazy load submodules
local _FloatLayout = nil
local function get_FloatLayout()
  if not _FloatLayout then
    _FloatLayout = require('nvim-float.float.layout')
  end
  return _FloatLayout
end

local _Scrollbar = nil
local function get_Scrollbar()
  if not _Scrollbar then
    _Scrollbar = require('nvim-float.float.scrollbar')
  end
  return _Scrollbar
end

local _Focus = nil
local function get_Focus()
  if not _Focus then
    _Focus = require('nvim-float.float.multipanel.focus')
  end
  return _Focus
end

local _Render = nil
local function get_Render()
  if not _Render then
    _Render = require('nvim-float.float.multipanel.render')
  end
  return _Render
end

local _Input = nil
local function get_Input()
  if not _Input then
    _Input = require('nvim-float.float.multipanel.input')
  end
  return _Input
end

local _Elements = nil
local function get_Elements()
  if not _Elements then
    _Elements = require('nvim-float.float.multipanel.elements')
  end
  return _Elements
end

local _Junction = nil
local function get_Junction()
  if not _Junction then
    _Junction = require('nvim-float.float.multipanel.junction')
  end
  return _Junction
end

-- ============================================================================
-- Type Definitions
-- ============================================================================

---@class MultiPanelConfig
---Configuration for multi-panel floating window
---@field layout LayoutNode Root layout node defining panel structure
---@field total_width_ratio number? Total width as ratio of screen (default: 0.85)
---@field total_height_ratio number? Total height as ratio of screen (default: 0.75)
---@field footer string? Footer text (shown below all panels)
---@field on_close function? Callback when window closes
---@field initial_focus string? Panel name to focus initially
---@field augroup_name string? Name for autocmd group
---@field controls ControlsDefinition[]? Controls to show in "?" popup

---@class LayoutNode
---A node in the layout tree - either a split or a panel
---@field split "horizontal"|"vertical"? Split direction (nil = leaf panel)
---@field ratio number? Size ratio relative to siblings (default: 1.0)
---@field min_height number? Minimum height in lines (for vertical splits)
---@field min_width number? Minimum width in columns (for horizontal splits)
---@field children LayoutNode[]? Child nodes for splits
---@field name string? Panel name (required for leaf nodes)
---@field title string? Panel title
---@field filetype string? Filetype for syntax highlighting
---@field focusable boolean? Can this panel be focused (default: true)
---@field cursorline boolean? Show cursor line when focused (default: true)
---@field on_render fun(state: MultiPanelState): string[], table[]? Render callback
---@field on_focus fun(state: MultiPanelState)? Called when panel gains focus
---@field on_blur fun(state: MultiPanelState)? Called when panel loses focus

---@class MultiPanelState
---State object for multi-panel window
---@field panels table<string, PanelInfo> Map of panel name -> panel info
---@field panel_order string[] Ordered list of panel names (for tab navigation)
---@field focused_panel string Currently focused panel name
---@field footer_buf number? Footer buffer
---@field footer_win number? Footer window
---@field config MultiPanelConfig Original configuration
---@field data any Custom user data
---@field _augroup number? Autocmd group ID
---@field _closed boolean? Whether the window has been closed
---@field _layout_cache table? Cached layout calculations

---@class PanelInfo
---Information about a single panel
---@field float FloatWindow FloatWindow instance for this panel
---@field definition LayoutNode Panel definition
---@field rect LayoutRect Panel rectangle
---@field namespace number Highlight namespace (for panel-specific highlights)

-- ============================================================================
-- MultiPanelWindow Class
-- ============================================================================

---@class MultiPanelWindow
---Multi-panel floating window instance
local MultiPanelWindow = {}
MultiPanelWindow.__index = MultiPanelWindow

---Create a multi-panel floating window
---@param UiFloat table The UiFloat module (for create function and ZINDEX)
---@param config MultiPanelConfig Configuration
---@return MultiPanelState? state State object (nil if creation failed)
function MultiPanel.create(UiFloat, config)
  if not config.layout then
    vim.notify("nvim-float: Layout configuration is required", vim.log.levels.ERROR)
    return nil
  end

  local FloatLayout = get_FloatLayout()

  -- Calculate layouts
  local layouts, total_width, total_height, start_row, start_col = FloatLayout.calculate_full_layout(config)

  if #layouts == 0 then
    vim.notify("nvim-float: No panels defined in layout", vim.log.levels.ERROR)
    return nil
  end

  -- Collect panel names for tab navigation
  local panel_order = {}
  FloatLayout.collect_panel_names(config.layout, panel_order)

  -- Determine initial focus
  local initial_focus = config.initial_focus
  if not initial_focus and #panel_order > 0 then
    initial_focus = panel_order[1]
  end

  -- Create state
  local state = setmetatable({
    panels = {},
    panel_order = panel_order,
    focused_panel = initial_focus,
    footer_buf = nil,
    footer_win = nil,
    config = config,
    data = {},
    _closed = false,
    _layout_cache = {
      total_width = total_width,
      total_height = total_height,
      start_row = start_row,
      start_col = start_col,
    },
    _junction_overlays = {},  -- Array of {bufnr, winid} for junction overlay windows
    _UiFloat = UiFloat,  -- Store reference for internal use
  }, MultiPanelWindow)

  -- Create panels using FloatWindow
  -- Calculate z-index based on vertical position - lower panels get higher z-index
  -- so their top borders (with titles) render on top of bottom borders of panels above
  local base_zindex = UiFloat.ZINDEX.BASE
  for i, panel_layout in ipairs(layouts) do
    local def = panel_layout.definition
    local rect = panel_layout.rect
    local border = FloatLayout.create_panel_border(panel_layout.border_pos)

    -- Z-index increases with vertical position (rect.y) to ensure lower panels
    -- have their titles visible over upper panels' bottom borders
    local panel_zindex = base_zindex + math.floor(rect.y)

    -- Create FloatWindow for this panel with explicit positioning
    local float = UiFloat.create({}, {
      -- Explicit positioning (no auto-calc, no centering)
      centered = false,
      width = rect.width,
      height = rect.height,
      row = rect.y,
      col = rect.x,
      -- Panel configuration
      title = def.title,
      footer = def.footer,
      footer_pos = def.footer_pos,
      border = border,
      filetype = def.filetype,
      focusable = def.focusable ~= false,
      zindex = panel_zindex,
      -- Don't enter panel windows on create, don't add default keymaps
      enter = false,
      default_keymaps = false,
      -- Start with cursorline disabled (focus_panel will enable it)
      cursorline = false,
      -- Scrollbar support
      scrollbar = true,
      -- Standard panel options
      modifiable = false,
      readonly = true,
      -- Pre-filetype callback for setting buffer vars before autocmds trigger
      on_pre_filetype = def.on_pre_filetype,
    })

    -- Store panel info with FloatWindow instance
    state.panels[def.name] = {
      float = float,
      definition = def,
      rect = rect,
      namespace = vim.api.nvim_create_namespace("nvim_float_panel_" .. def.name),
    }

    -- Call on_create callback if provided (e.g., to set buffer variables)
    if def.on_create and float.bufnr then
      def.on_create(float.bufnr, float.winid)
    end
  end

  -- Create junction overlay windows for proper border intersections
  get_Junction().create_junction_overlays(state, layouts, UiFloat)

  -- Default footer to "? = Controls" when controls are defined
  local footer = config.footer
  if not footer and config.controls and #config.controls > 0 then
    footer = "? = Controls"
  end

  -- Create footer if specified
  if footer then
    state.footer_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_option(state.footer_buf, 'buftype', 'nofile')
    vim.api.nvim_buf_set_option(state.footer_buf, 'modifiable', false)

    -- Footer text with minimal padding
    local footer_text = " " .. footer .. " "
    local footer_width = vim.fn.strdisplaywidth(footer_text)
    -- Center the footer window within the total layout width
    local footer_col = start_col + math.floor((total_width - footer_width) / 2)

    vim.api.nvim_buf_set_option(state.footer_buf, 'modifiable', true)
    vim.api.nvim_buf_set_lines(state.footer_buf, 0, -1, false, {footer_text})
    vim.api.nvim_buf_set_option(state.footer_buf, 'modifiable', false)

    state.footer_win = vim.api.nvim_open_win(state.footer_buf, false, {
      relative = "editor",
      width = footer_width,
      height = 1,
      row = start_row + total_height + 1,  -- Position on bottom border
      col = footer_col,  -- Centered within the layout
      style = "minimal",
      border = "none",
      zindex = UiFloat.ZINDEX.OVERLAY + 10,  -- Above junction overlays
      focusable = false,
    })

    -- Style footer with themed hint color
    vim.api.nvim_set_option_value('winhighlight', 'Normal:NvimFloatHint', { win = state.footer_win })
  end

  -- Focus initial panel
  state:focus_panel(state.focused_panel)

  -- Setup autocmds
  state:_setup_autocmds()

  -- Setup "?" keymap for controls popup if controls are defined
  if config.controls and #config.controls > 0 then
    state:set_keymaps({
      ["?"] = function()
        state:show_controls()
      end,
    })
  end

  return state
end

-- ============================================================================
-- Focus Methods (delegated)
-- ============================================================================

function MultiPanelWindow:focus_panel(panel_name)
  get_Focus().focus_panel(self, panel_name)
end

function MultiPanelWindow:focus_next_panel()
  get_Focus().focus_next_panel(self)
end

function MultiPanelWindow:focus_prev_panel()
  get_Focus().focus_prev_panel(self)
end

-- ============================================================================
-- Render Methods (delegated)
-- ============================================================================

function MultiPanelWindow:render_panel(panel_name, opts)
  get_Render().render_panel(self, panel_name, opts)
end

function MultiPanelWindow:render_all()
  get_Render().render_all(self)
end

function MultiPanelWindow:update_panel_title(panel_name, title)
  get_Render().update_panel_title(self, panel_name, title)
end

function MultiPanelWindow:update_panel_footer(panel_name, footer, footer_pos)
  get_Render().update_panel_footer(self, panel_name, footer, footer_pos)
end

-- ============================================================================
-- Panel Access Methods
-- ============================================================================

---Get panel buffer
---@param panel_name string Panel name
---@return number? bufnr Buffer number or nil
function MultiPanelWindow:get_panel_buffer(panel_name)
  local panel = self.panels[panel_name]
  return panel and panel.float and panel.float.bufnr or nil
end

---Get panel window
---@param panel_name string Panel name
---@return number? winid Window ID or nil
function MultiPanelWindow:get_panel_window(panel_name)
  local panel = self.panels[panel_name]
  return panel and panel.float and panel.float.winid or nil
end

---Get the FloatWindow instance for a panel
---@param panel_name string Panel name
---@return FloatWindow? float FloatWindow instance or nil
function MultiPanelWindow:get_panel_float(panel_name)
  local panel = self.panels[panel_name]
  return panel and panel.float or nil
end

---Set cursor in panel
---@param panel_name string Panel name
---@param row number Row (1-indexed)
---@param col number? Column (0-indexed, default 0)
function MultiPanelWindow:set_cursor(panel_name, row, col)
  if self._closed then return end

  local panel = self.panels[panel_name]
  if panel and panel.float:is_valid() then
    panel.float:set_cursor(row, col or 0)
  end
end

---Get cursor position in panel
---@param panel_name string Panel name
---@return number row, number col
function MultiPanelWindow:get_cursor(panel_name)
  local panel = self.panels[panel_name]
  if panel and panel.float:is_valid() then
    return panel.float:get_cursor()
  end
  return 1, 0
end

-- ============================================================================
-- Keymap Methods
-- ============================================================================

---Setup keymaps for all panels
---@param keymaps table<string, function> Keymaps to set on all focusable panels
function MultiPanelWindow:set_keymaps(keymaps)
  for name, panel in pairs(self.panels) do
    if panel.definition.focusable ~= false and panel.float:is_valid() then
      for lhs, handler in pairs(keymaps) do
        vim.keymap.set('n', lhs, handler, {
          buffer = panel.float.bufnr,
          noremap = true,
          silent = true,
        })
      end
    end
  end
end

---Setup keymaps for a specific panel
---@param panel_name string Panel name
---@param keymaps table<string, function> Keymaps to set
function MultiPanelWindow:set_panel_keymaps(panel_name, keymaps)
  local panel = self.panels[panel_name]
  if not panel or not panel.float:is_valid() then return end

  for lhs, handler in pairs(keymaps) do
    vim.keymap.set('n', lhs, handler, {
      buffer = panel.float.bufnr,
      noremap = true,
      silent = true,
    })
  end
end

-- ============================================================================
-- Autocmds and Layout
-- ============================================================================

---Setup autocmds for cleanup and resize
function MultiPanelWindow:_setup_autocmds()
  local augroup_name = self.config.augroup_name or ("NvimFloatMultiPanel_" .. tostring(os.time()))
  self._augroup = vim.api.nvim_create_augroup(augroup_name, { clear = true })

  -- Close when any panel window is closed
  for name, panel in pairs(self.panels) do
    vim.api.nvim_create_autocmd("WinClosed", {
      group = self._augroup,
      pattern = tostring(panel.float.winid),
      once = true,
      callback = function()
        self:close()
      end,
    })
  end

  -- Handle terminal resize
  vim.api.nvim_create_autocmd("VimResized", {
    group = self._augroup,
    callback = function()
      if not self._closed then
        self:_recalculate_layout()
      end
    end,
  })
end

---Recalculate layout after resize
function MultiPanelWindow:_recalculate_layout()
  if self._closed then return end

  local UiFloat = self._UiFloat
  local FloatLayout = get_FloatLayout()
  local Scrollbar = get_Scrollbar()

  -- Calculate new layouts
  local layouts, total_width, total_height, start_row, start_col = FloatLayout.calculate_full_layout(self.config)

  -- Update cache
  self._layout_cache = {
    total_width = total_width,
    total_height = total_height,
    start_row = start_row,
    start_col = start_col,
  }

  -- Update panel windows
  local base_zindex = UiFloat.ZINDEX.BASE
  for _, panel_layout in ipairs(layouts) do
    local panel = self.panels[panel_layout.name]
    local rect = panel_layout.rect
    local border = FloatLayout.create_panel_border(panel_layout.border_pos)

    -- Z-index increases with vertical position (rect.y) to ensure lower panels
    -- have their titles visible over upper panels' bottom borders
    local panel_zindex = base_zindex + math.floor(rect.y)

    if panel and panel.float:is_valid() then
      -- Update stored rect
      panel.rect = rect
      -- Update FloatWindow's stored geometry for scrollbar
      panel.float._win_row = rect.y
      panel.float._win_col = rect.x
      panel.float._win_width = rect.width
      panel.float._win_height = rect.height

      vim.api.nvim_win_set_config(panel.float.winid, {
        relative = "editor",
        width = rect.width,
        height = rect.height,
        row = rect.y,
        col = rect.x,
        border = border,
        zindex = panel_zindex,
      })

      -- Reposition scrollbar after window geometry update
      if panel.float.config.scrollbar then
        Scrollbar.reposition(panel.float)
      end
    end
  end

  -- Update junction overlays
  get_Junction().update_junction_overlays(self, layouts, UiFloat)

  -- Update footer if present
  if self.footer_win and vim.api.nvim_win_is_valid(self.footer_win) then
    -- Recenter footer with minimal width
    local footer_text = " " .. (self.config.footer or "") .. " "
    local footer_width = vim.fn.strdisplaywidth(footer_text)
    local footer_col = start_col + math.floor((total_width - footer_width) / 2)

    if self.footer_buf and vim.api.nvim_buf_is_valid(self.footer_buf) then
      vim.api.nvim_buf_set_option(self.footer_buf, 'modifiable', true)
      vim.api.nvim_buf_set_lines(self.footer_buf, 0, -1, false, {footer_text})
      vim.api.nvim_buf_set_option(self.footer_buf, 'modifiable', false)
    end

    vim.api.nvim_win_set_config(self.footer_win, {
      relative = "editor",
      width = footer_width,
      height = 1,
      row = start_row + total_height + 1,  -- Position on bottom border
      col = footer_col,  -- Centered within the layout
    })
  end

  -- Re-render all panels so they can adjust to new dimensions
  self:render_all()
end

-- ============================================================================
-- State Methods
-- ============================================================================

---Check if multi-panel window is valid
---@return boolean
function MultiPanelWindow:is_valid()
  if self._closed then return false end

  -- Check if any panel FloatWindow is valid
  for _, panel in pairs(self.panels) do
    if panel.float and panel.float:is_valid() then
      return true
    end
  end
  return false
end

-- ============================================================================
-- Z-Index / Panel Ordering Methods
-- ============================================================================

---Bring entire multi-panel to front (highest z-index in current layer)
---Brings all panels to front while maintaining their relative order
function MultiPanelWindow:bring_to_front()
  if not self:is_valid() then return end
  for _, panel in pairs(self.panels) do
    if panel.float and panel.float:is_valid() then
      panel.float:bring_to_front()
    end
  end
  -- Also bring footer if exists
  if self.footer_win and vim.api.nvim_win_is_valid(self.footer_win) then
    local current = vim.api.nvim_win_get_config(self.footer_win).zindex or 50
    -- Footer should be at the same level as panels
    vim.api.nvim_win_set_config(self.footer_win, { zindex = current })
  end
end

---Send entire multi-panel to back (lowest z-index in current layer)
---Sends all panels to back while maintaining their relative order
function MultiPanelWindow:send_to_back()
  if not self:is_valid() then return end
  for _, panel in pairs(self.panels) do
    if panel.float and panel.float:is_valid() then
      panel.float:send_to_back()
    end
  end
end

---Set z-index for all panels in the multi-panel window
---@param zindex number New z-index value
function MultiPanelWindow:set_zindex(zindex)
  if not self:is_valid() then return end
  for _, panel in pairs(self.panels) do
    if panel.float and panel.float:is_valid() then
      panel.float:set_zindex(zindex)
    end
  end
  -- Also update footer if exists
  if self.footer_win and vim.api.nvim_win_is_valid(self.footer_win) then
    vim.api.nvim_win_set_config(self.footer_win, { zindex = zindex })
  end
end

-- ============================================================================
-- Input Field Support (delegated)
-- ============================================================================

function MultiPanelWindow:setup_inputs(panel_name, content_builder, opts)
  get_Input().setup_inputs(self, panel_name, content_builder, opts)
end

function MultiPanelWindow:get_input_value(panel_name, input_key)
  return get_Input().get_input_value(self, panel_name, input_key)
end

function MultiPanelWindow:get_all_input_values(panel_name)
  return get_Input().get_all_input_values(self, panel_name)
end

function MultiPanelWindow:set_input_value(panel_name, input_key, value)
  get_Input().set_input_value(self, panel_name, input_key, value)
end

function MultiPanelWindow:enter_input(panel_name, input_key)
  get_Input().enter_input(self, panel_name, input_key, get_Focus().focus_panel)
end

function MultiPanelWindow:focus_field(panel_name, field_key)
  get_Input().focus_field(self, panel_name, field_key, get_Focus().focus_panel)
end

function MultiPanelWindow:focus_first_field(panel_name)
  get_Input().focus_first_field(self, panel_name, get_Focus().focus_panel)
end

function MultiPanelWindow:update_inputs(panel_name, content_builder)
  get_Input().update_inputs(self, panel_name, content_builder)
end

-- ============================================================================
-- Element Tracking Support (delegated)
-- ============================================================================

function MultiPanelWindow:get_element_at_cursor()
  return get_Elements().get_element_at_cursor(self)
end

function MultiPanelWindow:get_element(panel_name, element_name)
  return get_Elements().get_element(self, panel_name, element_name)
end

function MultiPanelWindow:get_elements_by_type(panel_name, element_type)
  return get_Elements().get_elements_by_type(self, panel_name, element_type)
end

function MultiPanelWindow:get_interactive_elements(panel_name)
  return get_Elements().get_interactive_elements(self, panel_name)
end

function MultiPanelWindow:interact_at_cursor()
  return get_Elements().interact_at_cursor(self)
end

function MultiPanelWindow:focus_next_element()
  return get_Elements().focus_next_element(self)
end

function MultiPanelWindow:focus_prev_element()
  return get_Elements().focus_prev_element(self)
end

function MultiPanelWindow:get_element_registry(panel_name)
  return get_Elements().get_element_registry(self, panel_name)
end

function MultiPanelWindow:has_elements(panel_name)
  return get_Elements().has_elements(self, panel_name)
end

function MultiPanelWindow:set_panel_content_builder(panel_name, content_builder)
  get_Elements().set_panel_content_builder(self, panel_name, content_builder)
end

function MultiPanelWindow:get_panel_content_builder(panel_name)
  return get_Elements().get_panel_content_builder(self, panel_name)
end

function MultiPanelWindow:enable_element_tracking(panel_name, on_cursor_change)
  get_Elements().enable_element_tracking(self, panel_name, on_cursor_change)
end

function MultiPanelWindow:disable_element_tracking(panel_name)
  get_Elements().disable_element_tracking(self, panel_name)
end

function MultiPanelWindow:enable_all_element_tracking()
  get_Elements().enable_all_element_tracking(self)
end

function MultiPanelWindow:disable_all_element_tracking()
  get_Elements().disable_all_element_tracking(self)
end

function MultiPanelWindow:focus_element(panel_name, element_name)
  return get_Elements().focus_element(self, panel_name, element_name, get_Focus().focus_panel)
end

function MultiPanelWindow:is_cursor_on(element_name)
  return get_Elements().is_cursor_on(self, element_name)
end

function MultiPanelWindow:get_hovered_element(panel_name)
  return get_Elements().get_hovered_element(self, panel_name)
end

-- ============================================================================
-- Close and Controls
-- ============================================================================

---Close the multi-panel window
function MultiPanelWindow:close()
  if self._closed then return end
  self._closed = true

  -- Call on_close callback
  if self.config.on_close then
    pcall(self.config.on_close, self)
  end

  -- Close junction overlays
  get_Junction().close_junction_overlays(self)

  -- Cleanup input managers and close FloatWindows (handles scrollbar cleanup)
  for _, panel in pairs(self.panels) do
    if panel.input_manager then
      pcall(function() panel.input_manager:destroy() end)
    end
    -- Close FloatWindow (handles scrollbar and window cleanup)
    if panel.float then
      pcall(function() panel.float:close() end)
    end
  end

  -- Close footer
  if self.footer_win and vim.api.nvim_win_is_valid(self.footer_win) then
    pcall(vim.api.nvim_win_close, self.footer_win, true)
  end
  if self.footer_buf and vim.api.nvim_buf_is_valid(self.footer_buf) then
    pcall(vim.api.nvim_buf_delete, self.footer_buf, { force = true })
  end

  -- Clear autocmds
  if self._augroup then
    pcall(vim.api.nvim_del_augroup_by_id, self._augroup)
  end
end

---Show controls popup
---@param controls ControlsDefinition[]? Controls to show (uses config.controls if nil)
function MultiPanelWindow:show_controls(controls)
  controls = controls or self.config.controls
  if not controls or #controls == 0 then
    vim.notify("No controls defined", vim.log.levels.INFO)
    return
  end

  -- Use the shared helper from UiFloat
  self._UiFloat._show_controls_popup(controls)
end

return MultiPanel
