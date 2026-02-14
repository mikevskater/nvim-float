---@module 'nvim-float.window'
---@brief FloatWindow class and UiFloat module

local Config = require("nvim-float.window.config")
local Geometry = require("nvim-float.window.geometry")
local Elements = require("nvim-float.window.elements")

-- Lazy-load heavy dependencies
local _scrollbar, _dialogs, _multipanel, _container_manager, _virtual_container_manager

local function get_scrollbar()
  if not _scrollbar then _scrollbar = require("nvim-float.float.scrollbar") end
  return _scrollbar
end

local function get_dialogs()
  if not _dialogs then _dialogs = require("nvim-float.float.dialogs") end
  return _dialogs
end

local function get_multipanel()
  if not _multipanel then _multipanel = require("nvim-float.float.multipanel") end
  return _multipanel
end

local function get_container_manager()
  if not _container_manager then _container_manager = require("nvim-float.container.manager") end
  return _container_manager
end

local function get_virtual_container_manager()
  if not _virtual_container_manager then _virtual_container_manager = require("nvim-float.container.virtual_manager") end
  return _virtual_container_manager
end

---@class FloatWindow
---A floating window instance
local FloatWindow = {}
FloatWindow.__index = FloatWindow

---@class UiFloat
---Floating window utility module
local UiFloat = {}

-- Export ZINDEX from config
UiFloat.ZINDEX = Config.ZINDEX

-- ============================================================================
-- Factory
-- ============================================================================

---Create a new floating window
---@param lines string[]|FloatConfig? Initial content lines OR config
---@param config FloatConfig? Configuration options
---@return FloatWindow instance
function UiFloat.create(lines, config)
  -- Handle convenience call pattern
  if type(lines) == "table" and not vim.islist(lines) then
    config = lines
    lines = {}
  end

  lines = lines or {}
  config = config or {}

  -- Handle content_builder in config
  local content_builder = config.content_builder
  if content_builder == true then
    local ContentBuilder = require('nvim-float.content')
    content_builder = ContentBuilder.new()
    config.content_builder = content_builder
    lines = {""}
  elseif content_builder and type(content_builder) == "table" and content_builder.build_lines then
    lines = content_builder:build_lines()
  end

  local user_specified_width = config.width ~= nil
  local user_specified_height = config.height ~= nil

  local instance = setmetatable({
    bufnr = nil,
    winid = nil,
    config = config,
    lines = lines,
    _input_manager = nil,
    _content_builder = content_builder,
    _user_specified_width = user_specified_width,
    _user_specified_height = user_specified_height,
    _hovered_element = nil,
    _element_hover_ns = nil,
    _element_tracking_enabled = false,
    _container_manager = nil,
    _embedded_input_manager = nil,
    _virtual_manager = nil,
  }, FloatWindow)

  -- Apply defaults
  Config.apply_defaults(instance.config)

  -- Create buffer
  instance:_create_buffer()

  -- Calculate dimensions
  local width, height = Geometry.calculate_dimensions(instance)

  -- Calculate position
  local row, col = Geometry.calculate_position(instance, width, height)

  -- Open window
  instance:_open_window(width, height, row, col)

  -- Store geometry
  instance._win_row = row
  instance._win_col = col
  instance._win_width = width
  instance._win_height = height

  -- Setup
  instance:_setup_options()
  instance:_setup_keymaps()
  instance:_setup_autocmds()

  -- Scrollbar
  if instance.config.scrollbar then
    get_scrollbar().setup(instance)
  end

  -- Apply styled content
  if content_builder and instance:is_valid() then
    local ns_id = vim.api.nvim_create_namespace("nvim_float_content")
    content_builder:apply_to_buffer(instance.bufnr, ns_id)
    instance._content_ns = ns_id

    if config.enable_inputs then
      instance:_setup_input_manager(content_builder)
    end

    -- Create embedded containers from content builder
    if content_builder.get_containers and content_builder:get_containers() then
      instance:_create_containers_from_builder(content_builder)
      -- Setup scroll sync after containers are created
      require("nvim-float.container.scroll_sync").setup(instance)
    end
  end

  return instance
end

-- ============================================================================
-- Buffer and Window Creation
-- ============================================================================

function FloatWindow:_create_buffer()
  self.bufnr = vim.api.nvim_create_buf(false, true)

  vim.api.nvim_buf_set_option(self.bufnr, 'buftype', self.config.buftype)
  vim.api.nvim_buf_set_option(self.bufnr, 'bufhidden', 'wipe')
  vim.api.nvim_buf_set_option(self.bufnr, 'swapfile', false)

  if self.config.on_pre_filetype then
    self.config.on_pre_filetype(self.bufnr)
  end

  if self.config.filetype then
    vim.api.nvim_buf_set_option(self.bufnr, 'filetype', self.config.filetype)
  end

  vim.api.nvim_buf_set_lines(self.bufnr, 0, -1, false, self.lines)
  vim.api.nvim_buf_set_option(self.bufnr, 'modifiable', self.config.modifiable)
end

function FloatWindow:_open_window(width, height, row, col)
  local win_config = {
    relative = self.config.relative,
    width = width,
    height = height,
    row = row,
    col = col,
    style = self.config.style,
    border = self.config.border,
    focusable = self.config.focusable,
    zindex = self.config.zindex,
  }

  -- Support relative='win' by passing the parent window ID
  if self.config.relative == "win" and self.config.win then
    win_config.win = self.config.win
  end

  if self.config.title then
    win_config.title = string.format(" %s ", self.config.title)
    win_config.title_pos = self.config.title_pos
  end

  if self.config.footer then
    win_config.footer = string.format(" %s ", self.config.footer)
    win_config.footer_pos = self.config.footer_pos
  end

  self.winid = vim.api.nvim_open_win(self.bufnr, self.config.enter, win_config)
end

function FloatWindow:_setup_options()
  local winid = self.winid

  vim.api.nvim_set_option_value('wrap', self.config.wrap, { win = winid })
  vim.api.nvim_set_option_value('foldenable', false, { win = winid })
  vim.api.nvim_set_option_value('cursorline', self.config.cursorline, { win = winid })
  vim.api.nvim_set_option_value('number', false, { win = winid })
  vim.api.nvim_set_option_value('relativenumber', false, { win = winid })
  vim.api.nvim_set_option_value('signcolumn', 'no', { win = winid })
  vim.api.nvim_set_option_value('winblend', self.config.winblend, { win = winid })
  vim.api.nvim_set_option_value('scrolloff', 0, { win = winid })

  local default_winhighlight = 'Normal:Normal,FloatBorder:NvimFloatBorder,FloatTitle:NvimFloatTitle,CursorLine:NvimFloatSelected'
  local winhighlight = self.config.winhighlight or default_winhighlight
  vim.api.nvim_set_option_value('winhighlight', winhighlight, { win = winid })
end

function FloatWindow:_setup_keymaps()
  local bufnr = self.bufnr

  if self.config.default_keymaps then
    vim.keymap.set('n', 'q', function() self:close() end,
      { buffer = bufnr, noremap = true, silent = true, desc = "Close window" })
    vim.keymap.set('n', '<Esc>', function() self:close() end,
      { buffer = bufnr, noremap = true, silent = true, desc = "Close window" })
  end

  if self.config.controls and #self.config.controls > 0 then
    vim.keymap.set('n', '?', function() self:show_controls() end,
      { buffer = bufnr, noremap = true, silent = true, desc = "Show controls" })
  end

  if self.config.keymaps then
    for key, handler in pairs(self.config.keymaps) do
      if type(handler) == "function" or type(handler) == "string" then
        vim.keymap.set('n', key, handler, { buffer = bufnr, noremap = true, silent = true })
      end
    end
  end
end

function FloatWindow:_setup_autocmds()
  self._augroup = vim.api.nvim_create_augroup("nvim_float_" .. self.bufnr, { clear = true })

  if self.config.on_close then
    vim.api.nvim_create_autocmd("BufWipeout", {
      group = self._augroup,
      buffer = self.bufnr,
      once = true,
      callback = function()
        if self.config.on_close then
          self.config.on_close()
        end
      end,
    })
  end

  vim.api.nvim_create_autocmd("WinClosed", {
    group = self._augroup,
    pattern = tostring(self.winid),
    once = true,
    callback = function()
      self:close()
    end,
  })

  vim.api.nvim_create_autocmd("VimResized", {
    group = self._augroup,
    callback = function()
      if self:is_valid() then
        Geometry.recalculate_layout(self)
      end
    end,
  })
end

-- ============================================================================
-- Core Methods
-- ============================================================================

function FloatWindow:is_valid()
  return self.bufnr and vim.api.nvim_buf_is_valid(self.bufnr)
    and self.winid and vim.api.nvim_win_is_valid(self.winid)
end

function FloatWindow:close()
  if self._closing then return end
  self._closing = true

  -- Teardown scroll sync before closing containers
  require("nvim-float.container.scroll_sync").teardown(self)

  -- Close virtual containers first
  if self._virtual_manager then
    self._virtual_manager:close_all()
    self._virtual_manager = nil
  end

  -- Close embedded containers
  if self._container_manager then
    self._container_manager:close_all()
  end
  if self._embedded_input_manager then
    self._embedded_input_manager:close_all()
  end

  get_scrollbar().close(self)

  if self:is_valid() then
    if vim.api.nvim_buf_is_valid(self.bufnr) then
      vim.api.nvim_buf_delete(self.bufnr, { force = true })
    end
    self.winid = nil
    self.bufnr = nil
  end
end

function FloatWindow:focus()
  if self:is_valid() then
    vim.api.nvim_set_current_win(self.winid)
  end
end

function FloatWindow:show()
  self:focus()
end

function FloatWindow:get_cursor()
  if self:is_valid() then
    return unpack(vim.api.nvim_win_get_cursor(self.winid))
  end
  return 1, 0
end

function FloatWindow:set_cursor(row, col)
  if self:is_valid() then
    local line_count = vim.api.nvim_buf_line_count(self.bufnr)
    local clamped_row = math.max(1, math.min(row, line_count))
    vim.api.nvim_win_set_cursor(self.winid, { clamped_row, col })
  end
end

-- ============================================================================
-- Content Update
-- ============================================================================

function FloatWindow:update_lines(lines)
  if not self:is_valid() then return end

  self.lines = lines

  vim.api.nvim_buf_set_option(self.bufnr, 'modifiable', true)
  vim.api.nvim_buf_set_lines(self.bufnr, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(self.bufnr, 'modifiable', self.config.modifiable)

  if self.config.scrollbar then
    get_scrollbar().update(self)
  end
end

FloatWindow._chunked_state = nil

function FloatWindow:update_lines_chunked(lines, opts)
  if not self:is_valid() then
    if opts and opts.on_complete then opts.on_complete() end
    return
  end

  opts = opts or {}
  local chunk_size = opts.chunk_size or 100
  local on_progress = opts.on_progress
  local on_chunk = opts.on_chunk
  local on_complete = opts.on_complete
  local total_lines = #lines

  self:cancel_chunked_update()

  if total_lines <= chunk_size then
    self:update_lines(lines)
    if on_chunk then on_chunk(0, total_lines - 1) end
    if on_progress then on_progress(total_lines, total_lines) end
    if on_complete then on_complete() end
    return
  end

  self._chunked_state = { timer = nil, cancelled = false }

  local state = self._chunked_state
  local bufnr = self.bufnr
  local current_idx = 1
  local is_first_chunk = true
  local final_lines = lines
  local float_self = self

  vim.api.nvim_buf_set_option(bufnr, 'modifiable', true)

  local function write_next_chunk()
    if state.cancelled or not float_self:is_valid() then
      float_self._chunked_state = nil
      return
    end

    local end_idx = math.min(current_idx + chunk_size - 1, total_lines)
    local chunk = {}
    for i = current_idx, end_idx do
      table.insert(chunk, lines[i])
    end

    local chunk_start_line = current_idx - 1
    if is_first_chunk then
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, chunk)
      is_first_chunk = false
    else
      vim.api.nvim_buf_set_lines(bufnr, chunk_start_line, chunk_start_line, false, chunk)
    end

    if on_chunk then on_chunk(chunk_start_line, end_idx - 1) end
    if on_progress then on_progress(end_idx, total_lines) end

    current_idx = end_idx + 1

    if current_idx <= total_lines then
      state.timer = vim.fn.timer_start(0, function()
        state.timer = nil
        vim.schedule(write_next_chunk)
      end)
    else
      float_self.lines = final_lines
      vim.api.nvim_buf_set_option(bufnr, 'modifiable', float_self.config.modifiable)

      if float_self.config.scrollbar then
        get_scrollbar().update(float_self)
      end

      float_self._chunked_state = nil

      if on_complete then on_complete() end
    end
  end

  write_next_chunk()
end

function FloatWindow:cancel_chunked_update()
  if self._chunked_state then
    self._chunked_state.cancelled = true
    if self._chunked_state.timer then
      vim.fn.timer_stop(self._chunked_state.timer)
      self._chunked_state.timer = nil
    end
    if self:is_valid() then
      pcall(vim.api.nvim_buf_set_option, self.bufnr, 'modifiable', self.config.modifiable)
    end
    self._chunked_state = nil
  end
end

function FloatWindow:is_chunked_update_active()
  return self._chunked_state ~= nil and not self._chunked_state.cancelled
end

-- ============================================================================
-- Title/Footer Update
-- ============================================================================

function FloatWindow:update_title(title)
  if not self:is_valid() then return end
  local current_config = vim.api.nvim_win_get_config(self.winid)
  current_config.title = title
  vim.api.nvim_win_set_config(self.winid, current_config)
end

function FloatWindow:update_footer(footer)
  if not self:is_valid() then return end
  local current_config = vim.api.nvim_win_get_config(self.winid)
  current_config.footer = footer
  vim.api.nvim_win_set_config(self.winid, current_config)
end

-- ============================================================================
-- Z-Index Methods
-- ============================================================================

function FloatWindow:get_zindex()
  return self.config.zindex or UiFloat.ZINDEX.BASE
end

function FloatWindow:set_zindex(zindex)
  if not self:is_valid() then return end
  self.config.zindex = zindex
  vim.api.nvim_win_set_config(self.winid, { zindex = zindex })
  if self._scrollbar_winid and vim.api.nvim_win_is_valid(self._scrollbar_winid) then
    vim.api.nvim_win_set_config(self._scrollbar_winid, { zindex = zindex + 1 })
  end
end

function FloatWindow:bring_to_front()
  if not self:is_valid() then return end
  local current = self.config.zindex or UiFloat.ZINDEX.BASE
  local new_zindex = Config.get_layer_max(current)
  self:set_zindex(new_zindex)
end

function FloatWindow:send_to_back()
  if not self:is_valid() then return end
  local current = self.config.zindex or UiFloat.ZINDEX.BASE
  local layer_base = Config.get_layer_base(current)
  self:set_zindex(layer_base)
end

-- ============================================================================
-- Content Builder / Render
-- ============================================================================

function FloatWindow:get_content_builder()
  return self._content_builder
end

function FloatWindow:render()
  if not self:is_valid() then return end

  local cb = self._content_builder
  if not cb then return end

  -- Save cursor position before buffer changes (re-render may displace it)
  local saved_cursor
  pcall(function()
    saved_cursor = vim.api.nvim_win_get_cursor(self.winid)
  end)

  local lines = cb:build_lines()

  vim.api.nvim_buf_set_option(self.bufnr, 'modifiable', true)
  vim.api.nvim_buf_set_lines(self.bufnr, 0, -1, false, lines)

  local ns_id = self._content_ns or vim.api.nvim_create_namespace("nvim_float_content")
  self._content_ns = ns_id
  vim.api.nvim_buf_clear_namespace(self.bufnr, ns_id, 0, -1)
  cb:apply_to_buffer(self.bufnr, ns_id)

  if self.config.enable_inputs then
    self:_setup_input_manager(cb)
  end

  vim.api.nvim_buf_set_option(self.bufnr, 'modifiable', self.config.modifiable or false)

  self.lines = lines

  if self.config.scrollbar then
    get_scrollbar().update(self)
  end

  -- Recreate embedded containers
  if cb.get_containers and cb:get_containers() then
    -- Teardown scroll sync before closing old containers
    require("nvim-float.container.scroll_sync").teardown(self)
    -- Close virtual containers
    if self._virtual_manager then
      self._virtual_manager:close_all()
      self._virtual_manager = nil
    end
    -- Close existing containers before recreating
    if self._container_manager then
      self._container_manager:close_all()
    end
    if self._embedded_input_manager then
      self._embedded_input_manager:close_all()
    end
    self._navigation_regions = nil
    self:_create_containers_from_builder(cb)
    -- Setup scroll sync after new containers created
    require("nvim-float.container.scroll_sync").setup(self)
  end

  -- Restore cursor position (clamped to new buffer bounds)
  if saved_cursor and self:is_valid() then
    local line_count = vim.api.nvim_buf_line_count(self.bufnr)
    local row = math.min(saved_cursor[1], line_count)
    local line = vim.api.nvim_buf_get_lines(self.bufnr, row - 1, row, false)[1] or ""
    local col = math.min(saved_cursor[2], math.max(0, #line - 1))
    pcall(vim.api.nvim_win_set_cursor, self.winid, { row, col })
  end
end

-- ============================================================================
-- Element Tracking (delegated)
-- ============================================================================

function FloatWindow:get_element_registry()
  return Elements.get_registry(self)
end

function FloatWindow:get_element_at_cursor()
  return Elements.get_at_cursor(self)
end

function FloatWindow:get_element(name)
  return Elements.get_element(self, name)
end

function FloatWindow:get_elements_by_type(element_type)
  return Elements.get_by_type(self, element_type)
end

function FloatWindow:get_interactive_elements()
  return Elements.get_interactive(self)
end

function FloatWindow:interact_at_cursor()
  return Elements.interact_at_cursor(self)
end

function FloatWindow:focus_next_element()
  return Elements.focus_next(self)
end

function FloatWindow:focus_prev_element()
  return Elements.focus_prev(self)
end

function FloatWindow:has_elements()
  return Elements.has_elements(self)
end

function FloatWindow:enable_element_tracking(on_cursor_change)
  Elements.enable_tracking(self, on_cursor_change)
end

function FloatWindow:disable_element_tracking()
  Elements.disable_tracking(self)
end

function FloatWindow:_on_element_cursor_moved()
  Elements.on_cursor_moved(self)
end

function FloatWindow:_apply_element_hover(element)
  Elements.apply_hover(self, element)
end

function FloatWindow:_remove_element_hover(element)
  Elements.remove_hover(self, element)
end

function FloatWindow:_get_highlight_group(style)
  return Elements.get_highlight_group(style)
end

function FloatWindow:focus_element(name)
  return Elements.focus_element(self, name)
end

function FloatWindow:is_cursor_on(name)
  return Elements.is_cursor_on(self, name)
end

function FloatWindow:get_hovered_element()
  return Elements.get_hovered(self)
end

-- ============================================================================
-- Input Manager Support
-- ============================================================================

function FloatWindow:_setup_input_manager(content_builder)
  local InputManager = require('nvim-float.input')

  local inputs = content_builder:get_inputs()
  local input_order = content_builder:get_input_order()
  local dropdowns = content_builder:get_dropdowns()
  local dropdown_order = content_builder:get_dropdown_order()
  local multi_dropdowns = content_builder:get_multi_dropdowns()
  local multi_dropdown_order = content_builder:get_multi_dropdown_order()

  self._input_manager = InputManager.new({
    bufnr = self.bufnr,
    winid = self.winid,
    inputs = inputs,
    input_order = input_order,
    dropdowns = dropdowns,
    dropdown_order = dropdown_order,
    multi_dropdowns = multi_dropdowns,
    multi_dropdown_order = multi_dropdown_order,
  })

  self._input_manager:setup()
  self._input_manager:init_highlights()

  local first_field_key = self._input_manager._field_order[1]
  if first_field_key then
    local field_info = self._input_manager:_get_field(first_field_key)
    if field_info then
      vim.schedule(function()
        if vim.api.nvim_win_is_valid(self.winid) then
          vim.api.nvim_win_set_cursor(self.winid, {field_info.field.line, field_info.field.col_start})
        end
      end)
    end
  end
end

function FloatWindow:enter_input(key)
  if not self._input_manager then return end

  if key then
    self._input_manager:enter_input_mode(key)
  else
    local cursor = vim.api.nvim_win_get_cursor(self.winid)
    local row = cursor[1]
    local col = cursor[2]

    for input_key, input in pairs(self._input_manager.inputs) do
      if input.line == row and col >= input.col_start and col < input.col_end then
        self._input_manager:enter_input_mode(input_key)
        return
      end
    end
  end
end

function FloatWindow:next_input()
  if self._input_manager then self._input_manager:next_input() end
end

function FloatWindow:prev_input()
  if self._input_manager then self._input_manager:prev_input() end
end

function FloatWindow:get_input_value(key)
  if self._input_manager then return self._input_manager:get_value(key) end
  return nil
end

function FloatWindow:get_all_input_values()
  if self._input_manager then return self._input_manager:get_all_values() end
  return {}
end

function FloatWindow:set_input_value(key, value)
  if self._input_manager then self._input_manager:set_value(key, value) end
end

function FloatWindow:on_input_submit(callback)
  if self._input_manager then self._input_manager.on_submit = callback end
end

function FloatWindow:get_dropdown_value(key)
  if self._input_manager then return self._input_manager:get_dropdown_value(key) end
  return nil
end

function FloatWindow:set_dropdown_value(key, value)
  if self._input_manager then self._input_manager:set_dropdown_value(key, value) end
end

function FloatWindow:on_dropdown_change(callback)
  if self._input_manager then self._input_manager.on_dropdown_change = callback end
end

function FloatWindow:get_multi_dropdown_values(key)
  if self._input_manager then return self._input_manager:get_multi_dropdown_values(key) end
  return nil
end

function FloatWindow:set_multi_dropdown_values(key, values)
  if self._input_manager then self._input_manager:set_multi_dropdown_values(key, values) end
end

function FloatWindow:on_multi_dropdown_change(callback)
  if self._input_manager then self._input_manager.on_multi_dropdown_change = callback end
end

-- ============================================================================
-- Dialog Delegation
-- ============================================================================

function FloatWindow:show_controls(controls)
  controls = controls or self.config.controls
  get_dialogs().show_controls_popup(UiFloat, controls)
end

function FloatWindow:update_styled(content_builder)
  get_dialogs().update_styled(self, content_builder)
end

function UiFloat.confirm(message, on_confirm, on_cancel)
  return get_dialogs().confirm(UiFloat, message, on_confirm, on_cancel)
end

function UiFloat.info(message, title)
  return get_dialogs().info(UiFloat, message, title)
end

function UiFloat.select(items, on_select, title)
  return get_dialogs().select(UiFloat, items, on_select, title)
end

function UiFloat.create_styled(content_builder, config)
  return get_dialogs().create_styled(UiFloat, content_builder, config)
end

function UiFloat.ContentBuilder()
  return get_dialogs().ContentBuilder()
end

function UiFloat._show_controls_popup(controls)
  get_dialogs().show_controls_popup(UiFloat, controls)
end

-- ============================================================================
-- Container Support
-- ============================================================================

---Get or lazily create the container manager
---@return ContainerManager
function FloatWindow:_get_container_manager()
  if not self._container_manager then
    self._container_manager = get_container_manager().new(self)
  end
  return self._container_manager
end

---Add an embedded container to this window
---@param config EmbeddedContainerConfig
---@return EmbeddedContainer
function FloatWindow:add_container(config)
  config.parent_winid = self.winid
  config.parent_float = self
  return self:_get_container_manager():add(config)
end

---Remove an embedded container by name
---@param name string
function FloatWindow:remove_container(name)
  if self._container_manager then
    self._container_manager:remove(name)
  end
end

---Get an embedded container by name
---@param name string
---@return EmbeddedContainer?
function FloatWindow:get_container(name)
  if self._container_manager then
    return self._container_manager:get(name)
  end
  return nil
end

---Focus a container by name (transfer window focus to child).
---If name is nil, auto-detects which container the cursor is on.
---@param name string|nil
---@return boolean success
function FloatWindow:focus_container(name)
  -- Auto-detect: find the container under the cursor
  if name == nil and self._virtual_manager and self:is_valid() then
    local cursor = vim.api.nvim_win_get_cursor(self.winid)
    local row0 = cursor[1] - 1
    local col0 = cursor[2]
    local line = vim.api.nvim_buf_get_lines(self.bufnr, row0, row0 + 1, false)[1] or ""
    local dcol = vim.fn.strdisplaywidth(line:sub(1, col0))
    local vc = self._virtual_manager:find_container_at(row0, dcol)
    if vc then
      self._virtual_manager:activate(vc.name)
      return true
    end
    return false
  end

  -- Named lookup
  if name and self._virtual_manager then
    local vc = self._virtual_manager:get(name)
    if vc then
      self._virtual_manager:activate(name)
      return true
    end
  end
  if name and self._container_manager then
    return self._container_manager:focus(name)
  end
  return false
end

---Check if any container (virtual or real) is currently focused/active.
---@return boolean
function FloatWindow:has_active_container()
  if self._virtual_manager and self._virtual_manager._active_name then
    return true
  end
  if self._container_manager and self._container_manager._focused_name then
    return true
  end
  if self._embedded_input_manager and self._embedded_input_manager._focused_key then
    return true
  end
  return false
end

---Focus the next embedded field (Tab navigation)
function FloatWindow:focus_next_embedded()
  if self._virtual_manager then
    self._virtual_manager:focus_next()
  elseif self._embedded_input_manager then
    self._embedded_input_manager:focus_next()
  end
end

---Focus the previous embedded field (Shift-Tab navigation)
function FloatWindow:focus_prev_embedded()
  if self._virtual_manager then
    self._virtual_manager:focus_prev()
  elseif self._embedded_input_manager then
    self._embedded_input_manager:focus_prev()
  end
end

---Get the embedded input manager (lazily created)
---@return EmbeddedInputManager
function FloatWindow:_get_embedded_input_manager()
  if not self._embedded_input_manager then
    local EmbeddedInputManager = require("nvim-float.container.input_manager")
    self._embedded_input_manager = EmbeddedInputManager.new(self)
  end
  return self._embedded_input_manager
end

---Get all embedded input values
---@return table<string, string|string[]>
function FloatWindow:get_all_embedded_values()
  local values = {}
  if self._virtual_manager then
    values = self._virtual_manager:get_all_values()
  end
  if self._embedded_input_manager then
    local real_values = self._embedded_input_manager:get_all_values()
    for k, v in pairs(real_values) do
      values[k] = v
    end
  end
  return values
end

---Get a specific embedded input value
---@param key string
---@return string|string[]|nil
function FloatWindow:get_embedded_value(key)
  if self._virtual_manager then
    local val = self._virtual_manager:get_value(key)
    if val ~= nil then return val end
  end
  if self._embedded_input_manager then
    return self._embedded_input_manager:get_value(key)
  end
  return nil
end

---Set a specific embedded input value
---@param key string
---@param value string|string[]
function FloatWindow:set_embedded_value(key, value)
  if self._virtual_manager then
    local vc = self._virtual_manager:get(key)
    if vc then
      self._virtual_manager:set_value(key, value)
      return
    end
  end
  if self._embedded_input_manager then
    self._embedded_input_manager:set_value(key, value)
  end
end

---Compute the col position for a container within this parent window.
---If def.col is explicit, use it. Otherwise auto-center based on parent width.
---@param def table Container definition from ContentBuilder
---@param visual_width number The container's total visual width (border included)
---@return number col 0-indexed column offset within parent
function FloatWindow:_resolve_container_col(def, visual_width)
  if def.col then
    return def.col
  end
  -- Auto-center: border is inside the specified width, so visual_width IS the width
  local col = math.floor((self._win_width - visual_width) / 2)
  return math.max(0, col)
end

---Create containers from content builder definitions
---@param cb ContentBuilder
function FloatWindow:_create_containers_from_builder(cb)
  local containers = cb:get_containers()
  if not containers then return end

  local use_virtual = self.config.virtual_containers ~= false
  local has_virtual = false
  local has_real = false

  for name, def in pairs(containers) do
    if def.type == "container" and use_virtual then
      -- Virtual mode: route generic containers through virtual manager (no real window yet)
      if not self._virtual_manager then
        self._virtual_manager = get_virtual_container_manager().new(self)
      end
      local width = def.width or self._win_width
      local col = self:_resolve_container_col(def, width)
      local resolved_def = vim.tbl_extend('force', def, { col = col, width = width })
      self._virtual_manager:add_from_definition(name, resolved_def)
      has_virtual = true
    elseif def.type == "container" then
      -- Non-virtual: create real window immediately
      local visual_width = def.width or self._win_width
      local visual_height = def.height
      local border_rows = def.border_rows or 0
      local border_cols = def.border_cols or 0
      local content_width = math.max(1, visual_width - border_cols)
      local content_height = math.max(1, visual_height - border_rows)
      local col = self:_resolve_container_col(def, visual_width)
      self:add_container({
        name = name,
        row = def.row,
        col = col,
        width = content_width,
        height = content_height,
        parent_winid = self.winid,
        parent_float = self,
        zindex_offset = def.zindex_offset,
        border = def.border,
        focusable = def.focusable,
        scrollbar = def.scrollbar,
        content_builder = def.content_builder,
        on_focus = def.on_focus,
        on_blur = def.on_blur,
        winhighlight = def.winhighlight,
      })
      has_real = true
    elseif use_virtual and (def.type == "embedded_input" or def.type == "embedded_dropdown" or def.type == "embedded_multi_dropdown") then
      -- Virtual mode: add to virtual manager (no real window yet)
      if not self._virtual_manager then
        self._virtual_manager = get_virtual_container_manager().new(self)
      end
      -- Resolve col and width, passing resolved copy to avoid mutating ContentBuilder
      local width = def.width or self._win_width
      local col = self:_resolve_container_col(def, width)
      local resolved_def = vim.tbl_extend('force', def, { col = col, width = width })
      self._virtual_manager:add_from_definition(name, resolved_def)
      has_virtual = true
    elseif def.type == "embedded_input" then
      local width = def.width or self._win_width
      local col = self:_resolve_container_col(def, width)
      self:_get_embedded_input_manager():add_input({
        key = name,
        row = def.row,
        col = col,
        width = width,
        parent_winid = self.winid,
        parent_float = self,
        zindex_offset = def.zindex_offset,
        placeholder = def.placeholder,
        value = def.value,
        on_change = def.on_change,
        on_submit = def.on_submit,
        winhighlight = def.winhighlight,
        border = def.border,
      })
      has_real = true
    elseif def.type == "embedded_dropdown" then
      local width = def.width or self._win_width
      local col = self:_resolve_container_col(def, width)
      self:_get_embedded_input_manager():add_dropdown({
        key = name,
        row = def.row,
        col = col,
        width = width,
        parent_winid = self.winid,
        parent_float = self,
        zindex_offset = def.zindex_offset,
        options = def.options,
        selected = def.selected,
        placeholder = def.placeholder,
        max_height = def.max_height,
        on_change = def.on_change,
        winhighlight = def.winhighlight,
        border = def.border,
      })
      has_real = true
    elseif def.type == "embedded_multi_dropdown" then
      local width = def.width or self._win_width
      local col = self:_resolve_container_col(def, width)
      self:_get_embedded_input_manager():add_multi_dropdown({
        key = name,
        row = def.row,
        col = col,
        width = width,
        parent_winid = self.winid,
        parent_float = self,
        zindex_offset = def.zindex_offset,
        options = def.options,
        selected = def.selected,
        placeholder = def.placeholder,
        max_height = def.max_height,
        display_mode = def.display_mode,
        on_change = def.on_change,
        winhighlight = def.winhighlight,
        border = def.border,
      })
      has_real = true
    end
  end

  -- Render virtual containers as text and setup cursor tracking
  if has_virtual and self._virtual_manager then
    self._virtual_manager:render_all_virtual(true)
    self._virtual_manager:setup_cursor_tracking()
  end

  -- Setup spatial navigation for real containers (non-virtual path)
  if has_real then
    local nav_self = self
    vim.schedule(function()
      if nav_self:is_valid() then
        require("nvim-float.container.navigation").setup(nav_self)
      end
    end)
  end
end

-- ============================================================================
-- Multi-Panel Delegation
-- ============================================================================

function UiFloat.create_multi_panel(config)
  return get_multipanel().create(UiFloat, config)
end

return UiFloat
