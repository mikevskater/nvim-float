---@module 'nvim-float.input.state'
---@brief Module-level state and field order management for InputManager

local M = {}

-- ============================================================================
-- Module-Level Globals (shared across all InputManager instances)
-- ============================================================================

-- Module-level cooldown to prevent dropdown re-opening across ALL InputManager instances
M.global_dropdown_close_cooldown = false

-- Flag to track if a dropdown is currently being opened
M.dropdown_opening = false

-- Timestamp of when last dropdown was opened
M.dropdown_open_time = 0

-- Flag to track if ANY dropdown is currently open
M.any_dropdown_open = false

-- Debounce delay for TextChangedI rendering (ms)
M.TEXT_CHANGED_DEBOUNCE_MS = 30

-- ============================================================================
-- Type Definitions (for documentation)
-- ============================================================================

---@class InputManagerConfig
---@field bufnr number Buffer number to manage
---@field winid number Window ID
---@field inputs table<string, InputField> Map of input key -> field info
---@field input_order string[] Ordered list of input keys
---@field dropdowns table<string, DropdownField>? Map of dropdown key -> field info
---@field dropdown_order string[]? Ordered list of dropdown keys
---@field multi_dropdowns table<string, MultiDropdownField>? Map of multi-dropdown key -> field info
---@field multi_dropdown_order string[]? Ordered list of multi-dropdown keys
---@field on_value_change fun(key: string, value: string)? Called when input value changes
---@field on_input_enter fun(key: string)? Called when entering input mode
---@field on_input_exit fun(key: string)? Called when exiting input mode
---@field on_dropdown_change fun(key: string, value: string)? Called when dropdown value changes
---@field on_multi_dropdown_change fun(key: string, values: string[])? Called when multi-dropdown values change

---@class InputField
---@field key string Unique identifier for the input
---@field line number 1-indexed line number
---@field col_start number 0-indexed start column of input value area
---@field col_end number 0-indexed end column of input value area
---@field width number Current effective width of input field
---@field default_width number Default/minimum display width
---@field min_width number? Minimum display width override
---@field value string Current value
---@field default string Default/initial value
---@field placeholder string Placeholder text when empty
---@field is_showing_placeholder boolean Whether currently displaying placeholder text
---@field value_type "text"|"integer"|"float"|nil Input value type for validation
---@field min_value number? Minimum numeric value
---@field max_value number? Maximum numeric value
---@field input_pattern string? Lua pattern for allowed characters
---@field allow_negative boolean? Whether to allow negative numbers
---@field prefix_len number? Length of label prefix

---@class DropdownField
---@field key string Unique identifier
---@field line number 1-indexed line number
---@field col_start number 0-indexed start column
---@field col_end number 0-indexed end column
---@field width number Display width
---@field text_width number Content width (excluding arrow)
---@field value string Current value
---@field options table[] Array of { value, label }
---@field placeholder string? Placeholder when no selection
---@field max_height number? Maximum dropdown height
---@field is_placeholder boolean Whether showing placeholder

---@class MultiDropdownField
---@field key string Unique identifier
---@field line number 1-indexed line number
---@field col_start number 0-indexed start column
---@field col_end number 0-indexed end column
---@field width number Display width
---@field text_width number Content width (excluding arrow)
---@field values string[] Currently selected values
---@field options table[] Array of { value, label }
---@field placeholder string? Placeholder when no selection
---@field max_height number? Maximum dropdown height
---@field select_all_option boolean? Show "Select All" option
---@field display_mode "count"|"list"? How to display selections
---@field is_placeholder boolean Whether showing placeholder

-- ============================================================================
-- Field Order Management
-- ============================================================================

---Build combined field order sorted by line number
---@param im InputManager The InputManager instance
function M.build_field_order(im)
  im._all_fields = {}

  -- Add inputs
  for _, key in ipairs(im.input_order) do
    local input = im.inputs[key]
    if input then
      table.insert(im._all_fields, {
        type = "input",
        key = key,
        line = input.line,
      })
    end
  end

  -- Add dropdowns
  for _, key in ipairs(im.dropdown_order) do
    local dropdown = im.dropdowns[key]
    if dropdown then
      table.insert(im._all_fields, {
        type = "dropdown",
        key = key,
        line = dropdown.line,
      })
    end
  end

  -- Add multi-dropdowns
  for _, key in ipairs(im.multi_dropdown_order) do
    local multi_dropdown = im.multi_dropdowns[key]
    if multi_dropdown then
      table.insert(im._all_fields, {
        type = "multi_dropdown",
        key = key,
        line = multi_dropdown.line,
      })
    end
  end

  -- Sort by line number
  table.sort(im._all_fields, function(a, b)
    return a.line < b.line
  end)

  -- Build ordered key list
  im._field_order = {}
  for _, field in ipairs(im._all_fields) do
    table.insert(im._field_order, field.key)
  end
end

---Get field info by key (input, dropdown, or multi-dropdown)
---@param im InputManager The InputManager instance
---@param key string Field key
---@return table? field_info { type = "input"|"dropdown"|"multi_dropdown", field = InputField|DropdownField|MultiDropdownField }
function M.get_field(im, key)
  if im.inputs[key] then
    return { type = "input", field = im.inputs[key] }
  elseif im.dropdowns[key] then
    return { type = "dropdown", field = im.dropdowns[key] }
  elseif im.multi_dropdowns[key] then
    return { type = "multi_dropdown", field = im.multi_dropdowns[key] }
  end
  return nil
end

---Initialize values from input/dropdown definitions
---@param im InputManager The InputManager instance
function M.init_values(im)
  -- Initialize input values
  for key, input in pairs(im.inputs) do
    if not im.values[key] then
      im.values[key] = input.value or ""
    end
    -- Track placeholder state
    local value = im.values[key] or ""
    input.is_showing_placeholder = (value == "" and (input.placeholder or "") ~= "")
  end

  -- Initialize dropdown values
  for key, dropdown in pairs(im.dropdowns) do
    if not im.dropdown_values[key] then
      im.dropdown_values[key] = dropdown.value or ""
    end
  end

  -- Initialize multi-dropdown values
  for key, multi_dropdown in pairs(im.multi_dropdowns) do
    if not im.multi_dropdown_values[key] then
      im.multi_dropdown_values[key] = vim.deepcopy(multi_dropdown.values or {})
    end
  end
end

---Update input definitions (preserving existing values)
---@param im InputManager The InputManager instance
---@param inputs table<string, InputField>? New input definitions
---@param input_order string[]? New input order
---@param dropdowns table<string, DropdownField>? New dropdown definitions
---@param dropdown_order string[]? New dropdown order
---@param multi_dropdowns table<string, MultiDropdownField>? New multi-dropdown definitions
---@param multi_dropdown_order string[]? New multi-dropdown order
function M.update_inputs(im, inputs, input_order, dropdowns, dropdown_order, multi_dropdowns, multi_dropdown_order)
  im.inputs = inputs or {}
  im.input_order = input_order or {}
  im.dropdowns = dropdowns or im.dropdowns or {}
  im.dropdown_order = dropdown_order or im.dropdown_order or {}
  im.multi_dropdowns = multi_dropdowns or im.multi_dropdowns or {}
  im.multi_dropdown_order = multi_dropdown_order or im.multi_dropdown_order or {}

  -- Preserve existing values and update placeholder state
  M.init_values(im)

  -- Rebuild field order
  M.build_field_order(im)
end

return M
