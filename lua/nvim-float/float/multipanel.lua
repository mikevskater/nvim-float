---@class MultiPanelModule
---Multi-panel floating window support with nested layouts
---@module nvim-float.float.multipanel
local MultiPanel = {}

local Debug = require('nvim-float.debug')
local FloatLayout = require('nvim-float.float.layout')
local Scrollbar = require('nvim-float.float.scrollbar')

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
  state:_create_junction_overlays(layouts)

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

---Focus a specific panel
---@param panel_name string Panel to focus
function MultiPanelWindow:focus_panel(panel_name)
  if self._closed then return end

  local panel = self.panels[panel_name]
  if not panel or panel.definition.focusable == false then
    return
  end

  -- Call blur on current panel
  local current_panel = self.panels[self.focused_panel]
  if current_panel and current_panel.definition.name ~= panel_name then
    -- Disable cursorline on previous panel
    if current_panel.float:is_valid() then
      vim.api.nvim_set_option_value('cursorline', false, { win = current_panel.float.winid })
    end
    if current_panel.definition.on_blur then
      current_panel.definition.on_blur(self)
    end
  end

  -- Update focused panel
  self.focused_panel = panel_name

  -- Focus the window and enable cursorline
  if panel.float:is_valid() then
    vim.api.nvim_set_current_win(panel.float.winid)
    if panel.definition.cursorline ~= false then
      vim.api.nvim_set_option_value('cursorline', true, { win = panel.float.winid })
    end
  end

  -- Call focus callback
  if panel.definition.on_focus then
    panel.definition.on_focus(self)
  end
end

---Focus next panel in order
function MultiPanelWindow:focus_next_panel()
  if self._closed then return end

  local current_idx = 1
  for i, name in ipairs(self.panel_order) do
    if name == self.focused_panel then
      current_idx = i
      break
    end
  end

  -- Find next focusable panel
  for offset = 1, #self.panel_order do
    local next_idx = ((current_idx - 1 + offset) % #self.panel_order) + 1
    local next_name = self.panel_order[next_idx]
    local next_panel = self.panels[next_name]
    if next_panel and next_panel.definition.focusable ~= false then
      self:focus_panel(next_name)
      return
    end
  end
end

---Focus previous panel in order
function MultiPanelWindow:focus_prev_panel()
  if self._closed then return end

  local current_idx = 1
  for i, name in ipairs(self.panel_order) do
    if name == self.focused_panel then
      current_idx = i
      break
    end
  end

  -- Find previous focusable panel
  for offset = 1, #self.panel_order do
    local prev_idx = ((current_idx - 1 - offset) % #self.panel_order) + 1
    local prev_name = self.panel_order[prev_idx]
    local prev_panel = self.panels[prev_name]
    if prev_panel and prev_panel.definition.focusable ~= false then
      self:focus_panel(prev_name)
      return
    end
  end
end

---Render a specific panel
---@param panel_name string Panel to render
---@param opts? { cursor_row?: number, cursor_col?: number } Optional cursor position to set after rendering completes
function MultiPanelWindow:render_panel(panel_name, opts)
  if self._closed then return end

  local panel = self.panels[panel_name]
  if not panel or not panel.float:is_valid() then return end

  local def = panel.definition
  if not def.on_render then return end

  -- Call render callback
  local lines, highlights = def.on_render(self)
  lines = lines or {}
  highlights = highlights or {}

  -- Helper to apply all highlights
  local function apply_all_highlights()
    vim.api.nvim_buf_clear_namespace(panel.float.bufnr, panel.namespace, 0, -1)
    for _, hl in ipairs(highlights) do
      -- Support both array format {line, col_start, col_end, hl_group}
      -- and named format {line=, col_start=, col_end=, hl_group=} from ContentBuilder
      local line = hl.line or hl[1]
      local col_start = hl.col_start or hl[2]
      local col_end = hl.col_end or hl[3]
      local hl_group = hl.hl_group or hl[4]

      if line and col_start and col_end and hl_group then
        vim.api.nvim_buf_add_highlight(
          panel.float.bufnr, panel.namespace,
          hl_group, line, col_start, col_end
        )
      end
    end
  end

  -- Always use synchronous single-pass rendering (simpler and more reliable)
  panel.float:update_lines(lines)
  apply_all_highlights()

  -- Set cursor position if specified
  if opts and opts.cursor_row then
    panel.float:set_cursor(opts.cursor_row, opts.cursor_col or 0)
  end
end

---Render all panels
function MultiPanelWindow:render_all()
  for name, _ in pairs(self.panels) do
    self:render_panel(name)
  end
end

---Update panel title
---@param panel_name string Panel name
---@param title string New title
function MultiPanelWindow:update_panel_title(panel_name, title)
  if self._closed then return end

  local panel = self.panels[panel_name]
  if not panel or not panel.float:is_valid() then
    return
  end

  vim.api.nvim_win_set_config(panel.float.winid, {
    title = string.format(" %s ", title),
    title_pos = "center",
  })
end

---Update panel footer
---@param panel_name string Panel name
---@param footer string New footer text
---@param footer_pos? "left"|"center"|"right" Footer position (default: "center")
function MultiPanelWindow:update_panel_footer(panel_name, footer, footer_pos)
  if self._closed then return end

  local panel = self.panels[panel_name]
  if not panel or not panel.float:is_valid() then
    return
  end

  vim.api.nvim_win_set_config(panel.float.winid, {
    footer = string.format(" %s ", footer),
    footer_pos = footer_pos or "center",
  })
end

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
  self:_update_junction_overlays(layouts)

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
-- Input Field Support for MultiPanelWindow
-- ============================================================================

---Setup input fields for a panel from a ContentBuilder
---@param panel_name string Panel name
---@param content_builder ContentBuilder ContentBuilder instance with inputs
---@param opts table? Options: { on_value_change?, on_input_enter?, on_input_exit?, on_dropdown_change?, on_multi_dropdown_change? }
function MultiPanelWindow:setup_inputs(panel_name, content_builder, opts)
  if self._closed then return end
  opts = opts or {}

  local panel = self.panels[panel_name]
  if not panel or not panel.float:is_valid() then return end

  local inputs = content_builder:get_inputs()
  local input_order = content_builder:get_input_order()
  local dropdowns = content_builder:get_dropdowns()
  local dropdown_order = content_builder:get_dropdown_order()
  local multi_dropdowns = content_builder:get_multi_dropdowns()
  local multi_dropdown_order = content_builder:get_multi_dropdown_order()

  -- Skip if no inputs or dropdowns
  local has_inputs = not vim.tbl_isempty(inputs)
  local has_dropdowns = not vim.tbl_isempty(dropdowns)
  local has_multi_dropdowns = not vim.tbl_isempty(multi_dropdowns)
  if not has_inputs and not has_dropdowns and not has_multi_dropdowns then return end

  -- Create input manager for this panel using FloatWindow's bufnr/winid
  local InputManager = require('nvim-float.input_manager')

  panel.input_manager = InputManager.new({
    bufnr = panel.float.bufnr,
    winid = panel.float.winid,
    inputs = inputs,
    input_order = input_order,
    dropdowns = dropdowns,
    dropdown_order = dropdown_order,
    multi_dropdowns = multi_dropdowns,
    multi_dropdown_order = multi_dropdown_order,
    on_value_change = opts.on_value_change,
    on_input_enter = opts.on_input_enter,
    on_input_exit = opts.on_input_exit,
  })

  -- Set up dropdown change callbacks
  if opts.on_dropdown_change then
    panel.input_manager.on_dropdown_change = opts.on_dropdown_change
    Debug.log(string.format("DEBUG setup_inputs: on_dropdown_change callback SET for panel '%s'", panel_name))
  else
    Debug.log(string.format("DEBUG setup_inputs: NO on_dropdown_change callback for panel '%s'", panel_name))
  end
  if opts.on_multi_dropdown_change then
    panel.input_manager.on_multi_dropdown_change = opts.on_multi_dropdown_change
    Debug.log(string.format("DEBUG setup_inputs: on_multi_dropdown_change callback SET for panel '%s'", panel_name))
  end

  panel.input_manager:setup()
end

---Get the value of an input field in a panel
---@param panel_name string Panel name
---@param input_key string Input key
---@return string? value
function MultiPanelWindow:get_input_value(panel_name, input_key)
  local panel = self.panels[panel_name]
  if panel and panel.input_manager then
    return panel.input_manager:get_value(input_key)
  end
  return nil
end

---Get all input values from a panel
---@param panel_name string Panel name
---@return table<string, string>? values Map of input key -> value
function MultiPanelWindow:get_all_input_values(panel_name)
  local panel = self.panels[panel_name]
  if panel and panel.input_manager then
    return panel.input_manager:get_all_values()
  end
  return nil
end

---Set the value of an input field in a panel
---@param panel_name string Panel name
---@param input_key string Input key
---@param value string New value
function MultiPanelWindow:set_input_value(panel_name, input_key, value)
  local panel = self.panels[panel_name]
  if panel and panel.input_manager then
    panel.input_manager:set_value(input_key, value)
  end
end

---Enter input mode for a specific input in a panel
---@param panel_name string Panel name
---@param input_key string Input key to activate
function MultiPanelWindow:enter_input(panel_name, input_key)
  local panel = self.panels[panel_name]
  if panel and panel.input_manager then
    -- Focus the panel first
    self:focus_panel(panel_name)
    panel.input_manager:enter_input_mode(input_key)
  end
end

---Focus a specific field in a panel (without activating it)
---@param panel_name string Panel name
---@param field_key string Field key to focus
function MultiPanelWindow:focus_field(panel_name, field_key)
  local panel = self.panels[panel_name]
  if panel and panel.input_manager then
    self:focus_panel(panel_name)
    panel.input_manager:focus_field(field_key)
  end
end

---Focus the first field in a panel
---@param panel_name string Panel name
function MultiPanelWindow:focus_first_field(panel_name)
  local panel = self.panels[panel_name]
  if panel and panel.input_manager then
    self:focus_panel(panel_name)
    panel.input_manager:focus_first_field()
  end
end

---Update input definitions for a panel (after re-render)
---@param panel_name string Panel name
---@param content_builder ContentBuilder New ContentBuilder with updated inputs
function MultiPanelWindow:update_inputs(panel_name, content_builder)
  local panel = self.panels[panel_name]
  if panel and panel.input_manager then
    local inputs = content_builder:get_inputs()
    local input_order = content_builder:get_input_order()
    local dropdowns = content_builder:get_dropdowns()
    local dropdown_order = content_builder:get_dropdown_order()
    local multi_dropdowns = content_builder:get_multi_dropdowns()
    local multi_dropdown_order = content_builder:get_multi_dropdown_order()

    panel.input_manager:update_inputs(
      inputs, input_order,
      dropdowns, dropdown_order,
      multi_dropdowns, multi_dropdown_order
    )
  end
end

-- ============================================================================
-- Element Tracking Support
-- ============================================================================

---Get element at cursor in the focused panel
---@return TrackedElement? element The element at cursor, or nil
function MultiPanelWindow:get_element_at_cursor()
  if self._closed then return nil end

  local panel = self.panels[self.focused_panel]
  if panel and panel.float then
    return panel.float:get_element_at_cursor()
  end
  return nil
end

---Get element by name from a specific panel
---@param panel_name string Panel name
---@param element_name string Element name
---@return TrackedElement? element
function MultiPanelWindow:get_element(panel_name, element_name)
  local panel = self.panels[panel_name]
  if panel and panel.float then
    return panel.float:get_element(element_name)
  end
  return nil
end

---Get all elements of a specific type from a panel
---@param panel_name string Panel name
---@param element_type string Element type to filter by
---@return TrackedElement[] elements
function MultiPanelWindow:get_elements_by_type(panel_name, element_type)
  local panel = self.panels[panel_name]
  if panel and panel.float then
    return panel.float:get_elements_by_type(element_type)
  end
  return {}
end

---Get all interactive elements from a panel
---@param panel_name string Panel name
---@return TrackedElement[] elements
function MultiPanelWindow:get_interactive_elements(panel_name)
  local panel = self.panels[panel_name]
  if panel and panel.float then
    return panel.float:get_interactive_elements()
  end
  return {}
end

---Interact with element at cursor in the focused panel
---@return boolean success Whether an element was interacted with
function MultiPanelWindow:interact_at_cursor()
  if self._closed then return false end

  local panel = self.panels[self.focused_panel]
  if not panel or not panel.float then return false end

  -- Get element at cursor
  local element = panel.float:get_element_at_cursor()
  if not element then return false end

  -- For input/dropdown/multi_dropdown elements, delegate to panel's InputManager
  if panel.input_manager then
    local element_type = element.type
    if element_type == "input" or element_type == "dropdown" or element_type == "multi_dropdown" then
      return panel.input_manager:activate_field(element.name)
    end
  end

  -- For other interactive elements, call their interact handler
  if element:is_interactive() then
    element:interact()
    return true
  end

  return false
end

---Focus next interactive element in the focused panel
---@return boolean success Whether focus moved to an element
function MultiPanelWindow:focus_next_element()
  if self._closed then return false end

  local panel = self.panels[self.focused_panel]
  if panel and panel.float then
    return panel.float:focus_next_element()
  end
  return false
end

---Focus previous interactive element in the focused panel
---@return boolean success Whether focus moved to an element
function MultiPanelWindow:focus_prev_element()
  if self._closed then return false end

  local panel = self.panels[self.focused_panel]
  if panel and panel.float then
    return panel.float:focus_prev_element()
  end
  return false
end

---Get the element registry from a panel's content builder
---@param panel_name string Panel name
---@return ElementRegistry?
function MultiPanelWindow:get_element_registry(panel_name)
  local panel = self.panels[panel_name]
  if panel and panel.float then
    return panel.float:get_element_registry()
  end
  return nil
end

---Check if a panel has any tracked elements
---@param panel_name string Panel name
---@return boolean
function MultiPanelWindow:has_elements(panel_name)
  local panel = self.panels[panel_name]
  if panel and panel.float then
    return panel.float:has_elements()
  end
  return false
end

---Associate a ContentBuilder with a panel for element tracking
---Call this after rendering with a ContentBuilder to enable element queries
---@param panel_name string Panel name
---@param content_builder ContentBuilder ContentBuilder instance
function MultiPanelWindow:set_panel_content_builder(panel_name, content_builder)
  local panel = self.panels[panel_name]
  if panel and panel.float then
    panel.float._content_builder = content_builder
  end
end

---Get the ContentBuilder associated with a panel
---@param panel_name string Panel name
---@return ContentBuilder?
function MultiPanelWindow:get_panel_content_builder(panel_name)
  local panel = self.panels[panel_name]
  if panel and panel.float then
    return panel.float:get_content_builder()
  end
  return nil
end

-- ============================================================================
-- Advanced Element Tracking (Hover, Focus/Blur Callbacks)
-- ============================================================================

---Enable element tracking for a specific panel
---@param panel_name string Panel name
---@param on_cursor_change fun(element: TrackedElement?)? Optional callback when cursor changes elements
function MultiPanelWindow:enable_element_tracking(panel_name, on_cursor_change)
  local panel = self.panels[panel_name]
  if panel and panel.float then
    panel.float:enable_element_tracking(on_cursor_change)
  end
end

---Disable element tracking for a specific panel
---@param panel_name string Panel name
function MultiPanelWindow:disable_element_tracking(panel_name)
  local panel = self.panels[panel_name]
  if panel and panel.float then
    panel.float:disable_element_tracking()
  end
end

---Enable element tracking for all panels
function MultiPanelWindow:enable_all_element_tracking()
  for name, _ in pairs(self.panels) do
    self:enable_element_tracking(name)
  end
end

---Disable element tracking for all panels
function MultiPanelWindow:disable_all_element_tracking()
  for name, _ in pairs(self.panels) do
    self:disable_element_tracking(name)
  end
end

---Focus a specific element by name in a panel
---@param panel_name string Panel name
---@param element_name string Element name
---@return boolean success
function MultiPanelWindow:focus_element(panel_name, element_name)
  local panel = self.panels[panel_name]
  if panel and panel.float then
    -- Focus the panel first
    self:focus_panel(panel_name)
    return panel.float:focus_element(element_name)
  end
  return false
end

---Check if cursor is on a specific element in the focused panel
---@param element_name string Element name
---@return boolean
function MultiPanelWindow:is_cursor_on(element_name)
  local panel = self.panels[self.focused_panel]
  if panel and panel.float then
    return panel.float:is_cursor_on(element_name)
  end
  return false
end

---Get the currently hovered element in a panel
---@param panel_name string Panel name
---@return TrackedElement?
function MultiPanelWindow:get_hovered_element(panel_name)
  local panel = self.panels[panel_name]
  if panel and panel.float then
    return panel.float:get_hovered_element()
  end
  return nil
end

---Create junction overlay windows for proper border intersections
---@param layouts PanelLayout[] Panel layouts
function MultiPanelWindow:_create_junction_overlays(layouts)
  local UiFloat = self._UiFloat

  -- Find all intersection points
  local intersections = FloatLayout.find_border_intersections(layouts)

  -- Create a small overlay window at each intersection
  for _, intersection in ipairs(intersections) do
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_option(buf, 'buftype', 'nofile')
    vim.api.nvim_buf_set_option(buf, 'bufhidden', 'wipe')
    vim.api.nvim_buf_set_option(buf, 'modifiable', true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {intersection.char})
    vim.api.nvim_buf_set_option(buf, 'modifiable', false)

    local win = vim.api.nvim_open_win(buf, false, {
      relative = "editor",
      width = 1,
      height = 1,
      row = intersection.y,
      col = intersection.x,
      style = "minimal",
      border = "none",
      focusable = false,
      zindex = UiFloat.ZINDEX.OVERLAY,  -- High z-index to be on top of panel borders
    })

    -- Style with border color
    vim.api.nvim_set_option_value('winhighlight', 'Normal:NvimFloatBorder', { win = win })

    table.insert(self._junction_overlays, {bufnr = buf, winid = win, x = intersection.x, y = intersection.y, char = intersection.char})
  end
end

---Close all junction overlay windows
function MultiPanelWindow:_close_junction_overlays()
  for _, overlay in ipairs(self._junction_overlays or {}) do
    if overlay.winid and vim.api.nvim_win_is_valid(overlay.winid) then
      pcall(vim.api.nvim_win_close, overlay.winid, true)
    end
    if overlay.bufnr and vim.api.nvim_buf_is_valid(overlay.bufnr) then
      pcall(vim.api.nvim_buf_delete, overlay.bufnr, { force = true })
    end
  end
  self._junction_overlays = {}
end

---Update junction overlays after layout recalculation
---@param layouts PanelLayout[] New panel layouts
function MultiPanelWindow:_update_junction_overlays(layouts)
  local UiFloat = self._UiFloat

  -- Find new intersection points
  local intersections = FloatLayout.find_border_intersections(layouts)

  -- Remove excess overlays
  while #self._junction_overlays > #intersections do
    local overlay = table.remove(self._junction_overlays)
    if overlay.winid and vim.api.nvim_win_is_valid(overlay.winid) then
      pcall(vim.api.nvim_win_close, overlay.winid, true)
    end
    if overlay.bufnr and vim.api.nvim_buf_is_valid(overlay.bufnr) then
      pcall(vim.api.nvim_buf_delete, overlay.bufnr, { force = true })
    end
  end

  -- Update existing overlays and create new ones if needed
  for i, intersection in ipairs(intersections) do
    if self._junction_overlays[i] then
      -- Update existing overlay
      local overlay = self._junction_overlays[i]
      if overlay.winid and vim.api.nvim_win_is_valid(overlay.winid) then
        vim.api.nvim_win_set_config(overlay.winid, {
          relative = "editor",
          row = intersection.y,
          col = intersection.x,
        })
        -- Update character if changed
        if overlay.char ~= intersection.char and overlay.bufnr and vim.api.nvim_buf_is_valid(overlay.bufnr) then
          vim.api.nvim_buf_set_option(overlay.bufnr, 'modifiable', true)
          vim.api.nvim_buf_set_lines(overlay.bufnr, 0, -1, false, {intersection.char})
          vim.api.nvim_buf_set_option(overlay.bufnr, 'modifiable', false)
          overlay.char = intersection.char
        end
        overlay.x = intersection.x
        overlay.y = intersection.y
      end
    else
      -- Create new overlay
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_option(buf, 'buftype', 'nofile')
      vim.api.nvim_buf_set_option(buf, 'bufhidden', 'wipe')
      vim.api.nvim_buf_set_option(buf, 'modifiable', true)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, {intersection.char})
      vim.api.nvim_buf_set_option(buf, 'modifiable', false)

      local win = vim.api.nvim_open_win(buf, false, {
        relative = "editor",
        width = 1,
        height = 1,
        row = intersection.y,
        col = intersection.x,
        style = "minimal",
        border = "none",
        focusable = false,
        zindex = UiFloat.ZINDEX.OVERLAY,
      })

      vim.api.nvim_set_option_value('winhighlight', 'Normal:NvimFloatBorder', { win = win })

      table.insert(self._junction_overlays, {bufnr = buf, winid = win, x = intersection.x, y = intersection.y, char = intersection.char})
    end
  end
end

---Close the multi-panel window
function MultiPanelWindow:close()
  if self._closed then return end
  self._closed = true

  -- Call on_close callback
  if self.config.on_close then
    pcall(self.config.on_close, self)
  end

  -- Close junction overlays
  self:_close_junction_overlays()

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
