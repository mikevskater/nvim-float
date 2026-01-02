---@module 'nvim-float.input'
---@brief InputManager - Manages input fields within floating windows

local StateModule = require("nvim-float.input.state")

---@class InputManager
---Manages input fields within floating windows
local InputManager = {}
InputManager.__index = InputManager

-- Lazy-load submodules
local _highlight, _editing, _navigation, _keymaps, _dropdown, _multi_dropdown

local function get_highlight()
  if not _highlight then _highlight = require("nvim-float.input.highlight") end
  return _highlight
end

local function get_editing()
  if not _editing then _editing = require("nvim-float.input.editing") end
  return _editing
end

local function get_navigation()
  if not _navigation then _navigation = require("nvim-float.input.navigation") end
  return _navigation
end

local function get_keymaps()
  if not _keymaps then _keymaps = require("nvim-float.input.keymaps") end
  return _keymaps
end

local function get_dropdown()
  if not _dropdown then _dropdown = require("nvim-float.input.dropdown") end
  return _dropdown
end

local function get_multi_dropdown()
  if not _multi_dropdown then _multi_dropdown = require("nvim-float.input.multi_dropdown") end
  return _multi_dropdown
end

-- ============================================================================
-- Constructor
-- ============================================================================

---Create a new InputManager
---@param config InputManagerConfig
---@return InputManager
function InputManager.new(config)
  local self = setmetatable({}, InputManager)

  self.bufnr = config.bufnr
  self.winid = config.winid
  self.inputs = config.inputs or {}
  self.input_order = config.input_order or {}
  self.dropdowns = config.dropdowns or {}
  self.dropdown_order = config.dropdown_order or {}
  self.multi_dropdowns = config.multi_dropdowns or {}
  self.multi_dropdown_order = config.multi_dropdown_order or {}
  self.on_value_change = config.on_value_change
  self.on_input_enter = config.on_input_enter
  self.on_input_exit = config.on_input_exit
  self.on_dropdown_change = config.on_dropdown_change
  self.on_multi_dropdown_change = config.on_multi_dropdown_change

  -- Combined field order
  self._all_fields = {}
  self._field_order = {}

  -- State
  self.in_input_mode = false
  self.active_input = nil
  self.current_field_idx = 1
  self.current_input_idx = 1
  self.values = {}
  self.dropdown_values = {}
  self.multi_dropdown_values = {}
  self._namespace = vim.api.nvim_create_namespace("nvim_float_input_manager")
  self._autocmd_group = nil
  self._text_changed_timer = nil

  -- Dropdown state
  self._dropdown_open = false
  self._dropdown_key = nil
  self._dropdown_float = nil
  self._dropdown_ns = nil
  self._dropdown_selected_idx = 1
  self._dropdown_original_value = nil
  self._dropdown_filtered_options = nil
  self._dropdown_filter_text = ""
  self._dropdown_autocmd_group = nil

  -- Multi-dropdown state
  self._multi_dropdown_open = false
  self._multi_dropdown_key = nil
  self._multi_dropdown_float = nil
  self._multi_dropdown_ns = nil
  self._multi_dropdown_cursor_idx = 1
  self._multi_dropdown_original_values = nil
  self._multi_dropdown_pending_values = nil
  self._multi_dropdown_autocmd_group = nil

  -- Initialize values and build field order
  StateModule.init_values(self)
  StateModule.build_field_order(self)

  return self
end

-- ============================================================================
-- Setup and Cleanup
-- ============================================================================

---Setup input mode handling for the buffer
function InputManager:setup()
  self._autocmd_group = vim.api.nvim_create_augroup(
    "NvimFloatInputManager_" .. self.bufnr,
    { clear = true }
  )

  -- Cursor movement detection
  vim.api.nvim_create_autocmd("CursorMoved", {
    group = self._autocmd_group,
    buffer = self.bufnr,
    callback = function()
      if not self.in_input_mode then
        get_navigation().check_cursor_on_input(self)
      end
    end,
  })

  -- InsertLeave to exit input mode
  vim.api.nvim_create_autocmd("InsertLeave", {
    group = self._autocmd_group,
    buffer = self.bufnr,
    callback = function()
      if self.in_input_mode then
        get_editing().exit_input_mode(self)
      end
    end,
  })

  -- Text changes in insert mode
  vim.api.nvim_create_autocmd("TextChangedI", {
    group = self._autocmd_group,
    buffer = self.bufnr,
    callback = function()
      if self.in_input_mode and self.active_input then
        get_editing().sync_input_value(self)

        if self._text_changed_timer then
          vim.fn.timer_stop(self._text_changed_timer)
        end
        local active_key = self.active_input
        self._text_changed_timer = vim.fn.timer_start(StateModule.TEXT_CHANGED_DEBOUNCE_MS, function()
          self._text_changed_timer = nil
          vim.schedule(function()
            if self.in_input_mode and self.active_input == active_key then
              get_editing().render_input_realtime(self, active_key)
            end
          end)
        end)
      end
    end,
  })

  -- Filter characters during input
  vim.api.nvim_create_autocmd("InsertCharPre", {
    group = self._autocmd_group,
    buffer = self.bufnr,
    callback = function()
      if self.in_input_mode and self.active_input then
        local char = vim.v.char
        if not get_editing().is_char_allowed(self, char) then
          vim.v.char = ""
        end
      end
    end,
  })

  get_keymaps().setup_input_keymaps(self)
end

---Cleanup the input manager
function InputManager:destroy()
  if self._dropdown_open then
    get_dropdown().close(self, true)
  end

  if self._multi_dropdown_open then
    get_multi_dropdown().close(self, true)
  end

  if self._text_changed_timer then
    vim.fn.timer_stop(self._text_changed_timer)
    self._text_changed_timer = nil
  end

  if self._autocmd_group then
    pcall(vim.api.nvim_del_augroup_by_id, self._autocmd_group)
  end

  if vim.api.nvim_buf_is_valid(self.bufnr) then
    vim.api.nvim_buf_clear_namespace(self.bufnr, self._namespace, 0, -1)
  end
end

-- ============================================================================
-- Delegated Methods - State
-- ============================================================================

function InputManager:_build_field_order()
  StateModule.build_field_order(self)
end

function InputManager:_get_field(key)
  return StateModule.get_field(self, key)
end

function InputManager:update_inputs(inputs, input_order, dropdowns, dropdown_order, multi_dropdowns, multi_dropdown_order)
  StateModule.update_inputs(self, inputs, input_order, dropdowns, dropdown_order, multi_dropdowns, multi_dropdown_order)
end

-- ============================================================================
-- Delegated Methods - Highlight
-- ============================================================================

function InputManager:_highlight_input(key, active)
  get_highlight().highlight_input(self, key, active)
end

function InputManager:_highlight_current_input(current_key)
  get_highlight().highlight_current_input(self, current_key)
end

function InputManager:_clear_input_highlights()
  get_highlight().clear_input_highlights(self)
end

function InputManager:_highlight_current_field(current_key)
  get_highlight().highlight_current_field(self, current_key)
end

function InputManager:_highlight_dropdown(key, active)
  get_highlight().highlight_dropdown(self, key, active)
end

function InputManager:_highlight_multi_dropdown(key, active)
  get_highlight().highlight_multi_dropdown(self, key, active)
end

function InputManager:init_highlights()
  get_highlight().init_highlights(self)
end

-- ============================================================================
-- Delegated Methods - Editing
-- ============================================================================

function InputManager:enter_input_mode(key)
  get_editing().enter_input_mode(self, key)
end

function InputManager:_exit_input_mode()
  get_editing().exit_input_mode(self)
end

function InputManager:_clear_input_to_spaces(key)
  get_editing().clear_input_to_spaces(self, key)
end

function InputManager:_sync_input_value()
  get_editing().sync_input_value(self)
end

function InputManager:get_value(key)
  return get_editing().get_value(self, key)
end

function InputManager:get_all_values()
  return get_editing().get_all_values(self)
end

function InputManager:set_value(key, value)
  get_editing().set_value(self, key, value)
end

function InputManager:_render_input(key)
  get_editing().render_input(self, key)
end

function InputManager:_render_input_realtime(key)
  get_editing().render_input_realtime(self, key)
end

function InputManager:update_input_settings(key, settings)
  get_editing().update_input_settings(self, key, settings)
end

function InputManager:update_all_input_settings(settings_map)
  get_editing().update_all_input_settings(self, settings_map)
end

function InputManager:validate_input_value(key, value)
  return get_editing().validate_input_value(self, key, value)
end

function InputManager:is_char_allowed(char)
  return get_editing().is_char_allowed(self, char)
end

function InputManager:get_validated_value(key)
  return get_editing().get_validated_value(self, key)
end

-- ============================================================================
-- Delegated Methods - Navigation
-- ============================================================================

function InputManager:_check_cursor_on_input()
  get_navigation().check_cursor_on_input(self)
end

function InputManager:_focus_field(key)
  get_navigation().focus_field_internal(self, key)
end

function InputManager:focus_field(key)
  get_navigation().focus_field(self, key)
end

function InputManager:focus_first_field()
  get_navigation().focus_first_field(self)
end

function InputManager:next_input()
  get_navigation().next_input(self)
end

function InputManager:prev_input()
  get_navigation().prev_input(self)
end

function InputManager:_activate_field(key)
  get_navigation().activate_field(self, key)
end

function InputManager:activate_field(key)
  return get_navigation().activate_field_public(self, key)
end

-- ============================================================================
-- Delegated Methods - Dropdown
-- ============================================================================

function InputManager:_open_dropdown(key)
  get_dropdown().open(self, key)
end

function InputManager:_close_dropdown(cancel)
  get_dropdown().close(self, cancel)
end

function InputManager:_select_dropdown()
  get_dropdown().select(self)
end

function InputManager:_navigate_dropdown(direction)
  get_dropdown().navigate(self, direction)
end

function InputManager:_filter_dropdown(char)
  get_dropdown().filter(self, char)
end

function InputManager:_clear_dropdown_filter()
  get_dropdown().clear_filter(self)
end

function InputManager:_render_dropdown()
  get_dropdown().render(self)
end

function InputManager:_update_dropdown_display(key)
  get_dropdown().update_display(self, key)
end

function InputManager:get_dropdown_value(key)
  return get_dropdown().get_value(self, key)
end

function InputManager:set_dropdown_value(key, value)
  get_dropdown().set_value(self, key, value)
end

-- ============================================================================
-- Delegated Methods - Multi-Dropdown
-- ============================================================================

function InputManager:_open_multi_dropdown(key)
  get_multi_dropdown().open(self, key)
end

function InputManager:_close_multi_dropdown(cancel)
  get_multi_dropdown().close(self, cancel)
end

function InputManager:_confirm_multi_dropdown()
  get_multi_dropdown().confirm(self)
end

function InputManager:_toggle_multi_dropdown_option()
  get_multi_dropdown().toggle_option(self)
end

function InputManager:_toggle_select_all_multi_dropdown()
  get_multi_dropdown().toggle_select_all(self)
end

function InputManager:_navigate_multi_dropdown(direction)
  get_multi_dropdown().navigate(self, direction)
end

function InputManager:_render_multi_dropdown()
  get_multi_dropdown().render(self)
end

function InputManager:_update_multi_dropdown_display(key)
  get_multi_dropdown().update_display(self, key)
end

function InputManager:get_multi_dropdown_values(key)
  return get_multi_dropdown().get_values(self, key)
end

function InputManager:set_multi_dropdown_values(key, values)
  get_multi_dropdown().set_values(self, key, values)
end

return InputManager
