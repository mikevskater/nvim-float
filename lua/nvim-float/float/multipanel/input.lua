---@module 'nvim-float.float.multipanel.input'
---@brief Input field support for MultiPanelWindow

local M = {}

local Debug = require('nvim-float.debug')

-- Lazy load InputManager
local _InputManager = nil
local function get_InputManager()
  if not _InputManager then
    _InputManager = require('nvim-float.input')
  end
  return _InputManager
end

-- ============================================================================
-- Input Field Support
-- ============================================================================

---Setup input fields for a panel from a ContentBuilder
---@param state MultiPanelState
---@param panel_name string Panel name
---@param content_builder ContentBuilder ContentBuilder instance with inputs
---@param opts table? Options: { on_value_change?, on_input_enter?, on_input_exit?, on_dropdown_change?, on_multi_dropdown_change? }
function M.setup_inputs(state, panel_name, content_builder, opts)
  if state._closed then return end
  opts = opts or {}

  local panel = state.panels[panel_name]
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
  local InputManager = get_InputManager()

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
---@param state MultiPanelState
---@param panel_name string Panel name
---@param input_key string Input key
---@return string? value
function M.get_input_value(state, panel_name, input_key)
  local panel = state.panels[panel_name]
  if panel and panel.input_manager then
    return panel.input_manager:get_value(input_key)
  end
  return nil
end

---Get all input values from a panel
---@param state MultiPanelState
---@param panel_name string Panel name
---@return table<string, string>? values Map of input key -> value
function M.get_all_input_values(state, panel_name)
  local panel = state.panels[panel_name]
  if panel and panel.input_manager then
    return panel.input_manager:get_all_values()
  end
  return nil
end

---Set the value of an input field in a panel
---@param state MultiPanelState
---@param panel_name string Panel name
---@param input_key string Input key
---@param value string New value
function M.set_input_value(state, panel_name, input_key, value)
  local panel = state.panels[panel_name]
  if panel and panel.input_manager then
    panel.input_manager:set_value(input_key, value)
  end
end

---Enter input mode for a specific input in a panel
---@param state MultiPanelState
---@param panel_name string Panel name
---@param input_key string Input key to activate
---@param focus_func function Function to focus the panel
function M.enter_input(state, panel_name, input_key, focus_func)
  local panel = state.panels[panel_name]
  if panel and panel.input_manager then
    -- Focus the panel first
    focus_func(state, panel_name)
    panel.input_manager:enter_input_mode(input_key)
  end
end

---Focus a specific field in a panel (without activating it)
---@param state MultiPanelState
---@param panel_name string Panel name
---@param field_key string Field key to focus
---@param focus_func function Function to focus the panel
function M.focus_field(state, panel_name, field_key, focus_func)
  local panel = state.panels[panel_name]
  if panel and panel.input_manager then
    focus_func(state, panel_name)
    panel.input_manager:focus_field(field_key)
  end
end

---Focus the first field in a panel
---@param state MultiPanelState
---@param panel_name string Panel name
---@param focus_func function Function to focus the panel
function M.focus_first_field(state, panel_name, focus_func)
  local panel = state.panels[panel_name]
  if panel and panel.input_manager then
    focus_func(state, panel_name)
    panel.input_manager:focus_first_field()
  end
end

---Update input definitions for a panel (after re-render)
---@param state MultiPanelState
---@param panel_name string Panel name
---@param content_builder ContentBuilder New ContentBuilder with updated inputs
function M.update_inputs(state, panel_name, content_builder)
  local panel = state.panels[panel_name]
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

return M
