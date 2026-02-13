---@module 'nvim-float.container.input_manager'
---@brief EmbeddedInputManager - Manages all embedded input-type containers within a parent
---
---Tracks inputs, dropdowns, and multi-dropdowns as a unified collection.
---Provides Tab navigation across all field types and value management.

---@class EmbeddedInputManager
---Manages all embedded input-type containers within a parent FloatWindow
local EmbeddedInputManager = {}
EmbeddedInputManager.__index = EmbeddedInputManager

-- Lazy-load input types
local _EmbeddedInput, _EmbeddedDropdown, _EmbeddedMultiDropdown

local function get_EmbeddedInput()
  if not _EmbeddedInput then _EmbeddedInput = require("nvim-float.container.input") end
  return _EmbeddedInput
end

local function get_EmbeddedDropdown()
  if not _EmbeddedDropdown then _EmbeddedDropdown = require("nvim-float.container.dropdown") end
  return _EmbeddedDropdown
end

local function get_EmbeddedMultiDropdown()
  if not _EmbeddedMultiDropdown then _EmbeddedMultiDropdown = require("nvim-float.container.multi_dropdown") end
  return _EmbeddedMultiDropdown
end

-- ============================================================================
-- Constructor
-- ============================================================================

---Create a new EmbeddedInputManager
---@param parent_float FloatWindow Parent FloatWindow instance
---@return EmbeddedInputManager
function EmbeddedInputManager.new(parent_float)
  local self = setmetatable({}, EmbeddedInputManager)
  self._parent_float = parent_float
  self._inputs = {}              -- Map of key -> EmbeddedInput
  self._dropdowns = {}           -- Map of key -> EmbeddedDropdown
  self._multi_dropdowns = {}     -- Map of key -> EmbeddedMultiDropdown
  self._field_order = {}         -- Ordered list of { type, key } for Tab navigation
  self._current_field_idx = 0    -- Current focused field index (0 = none)
  self._focused_key = nil        -- Currently focused field key
  return self
end

-- ============================================================================
-- Add Fields
-- ============================================================================

---Add an embedded text input
---@param config EmbeddedInputConfig
---@return EmbeddedInput
function EmbeddedInputManager:add_input(config)
  config.parent_winid = config.parent_winid or self._parent_float.winid
  config.parent_float = config.parent_float or self._parent_float

  local input = get_EmbeddedInput().new(config)
  self._inputs[config.key] = input
  table.insert(self._field_order, { type = "input", key = config.key })
  return input
end

---Add an embedded dropdown
---@param config EmbeddedDropdownConfig
---@return EmbeddedDropdown
function EmbeddedInputManager:add_dropdown(config)
  config.parent_winid = config.parent_winid or self._parent_float.winid
  config.parent_float = config.parent_float or self._parent_float

  local dropdown = get_EmbeddedDropdown().new(config)
  self._dropdowns[config.key] = dropdown
  table.insert(self._field_order, { type = "dropdown", key = config.key })
  return dropdown
end

---Add an embedded multi-dropdown
---@param config EmbeddedMultiDropdownConfig
---@return EmbeddedMultiDropdown
function EmbeddedInputManager:add_multi_dropdown(config)
  config.parent_winid = config.parent_winid or self._parent_float.winid
  config.parent_float = config.parent_float or self._parent_float

  local multi_dropdown = get_EmbeddedMultiDropdown().new(config)
  self._multi_dropdowns[config.key] = multi_dropdown
  table.insert(self._field_order, { type = "multi_dropdown", key = config.key })
  return multi_dropdown
end

-- ============================================================================
-- Field Access
-- ============================================================================

---Get a field by key (any type)
---@param key string
---@return EmbeddedInput|EmbeddedDropdown|EmbeddedMultiDropdown|nil
function EmbeddedInputManager:get_field(key)
  return self._inputs[key] or self._dropdowns[key] or self._multi_dropdowns[key]
end

---Get the type of a field
---@param key string
---@return string? type "input"|"dropdown"|"multi_dropdown" or nil
function EmbeddedInputManager:get_field_type(key)
  if self._inputs[key] then return "input" end
  if self._dropdowns[key] then return "dropdown" end
  if self._multi_dropdowns[key] then return "multi_dropdown" end
  return nil
end

-- ============================================================================
-- Navigation
-- ============================================================================

---Focus the next field in order
function EmbeddedInputManager:focus_next()
  if #self._field_order == 0 then return end

  local next_idx = (self._current_field_idx % #self._field_order) + 1
  self:_focus_at_index(next_idx)
end

---Focus the previous field in order
function EmbeddedInputManager:focus_prev()
  if #self._field_order == 0 then return end

  local prev_idx = ((self._current_field_idx - 2) % #self._field_order) + 1
  self:_focus_at_index(prev_idx)
end

---Focus a specific field by key
---@param key string
---@return boolean success
function EmbeddedInputManager:focus_field(key)
  for i, entry in ipairs(self._field_order) do
    if entry.key == key then
      self:_focus_at_index(i)
      return true
    end
  end
  return false
end

---Focus the first field
function EmbeddedInputManager:focus_first()
  if #self._field_order > 0 then
    self:_focus_at_index(1)
  end
end

---Blur the currently focused field
function EmbeddedInputManager:blur_current()
  if self._focused_key then
    local field = self:get_field(self._focused_key)
    if field then
      field:blur()
    end
    self._focused_key = nil
  end
end

---Internal: focus a field at the given index
---@param idx number 1-based index in _field_order
function EmbeddedInputManager:_focus_at_index(idx)
  -- Blur current
  if self._focused_key then
    local current = self:get_field(self._focused_key)
    if current and current.is_valid and current:is_valid() then
      -- For inputs, exit edit mode without blurring to parent
      if self._inputs[self._focused_key] then
        self._inputs[self._focused_key]:exit_edit()
      end
    end
  end

  self._current_field_idx = idx
  local entry = self._field_order[idx]
  if not entry then return end

  self._focused_key = entry.key
  local field = self:get_field(entry.key)
  if field and field:is_valid() then
    field:focus()
  end
end

-- ============================================================================
-- Value Management
-- ============================================================================

---Get a value by key (works for all field types)
---@param key string
---@return string|string[]|nil
function EmbeddedInputManager:get_value(key)
  if self._inputs[key] then
    return self._inputs[key]:get_value()
  elseif self._dropdowns[key] then
    return self._dropdowns[key]:get_value()
  elseif self._multi_dropdowns[key] then
    return self._multi_dropdowns[key]:get_values()
  end
  return nil
end

---Set a value by key
---@param key string
---@param value string|string[]
function EmbeddedInputManager:set_value(key, value)
  if self._inputs[key] then
    self._inputs[key]:set_value(value)
  elseif self._dropdowns[key] then
    self._dropdowns[key]:set_value(value)
  elseif self._multi_dropdowns[key] then
    if type(value) == "table" then
      self._multi_dropdowns[key]:set_values(value)
    end
  end
end

---Get all values as a map
---@return table<string, string|string[]>
function EmbeddedInputManager:get_all_values()
  local values = {}
  for key, input in pairs(self._inputs) do
    values[key] = input:get_value()
  end
  for key, dropdown in pairs(self._dropdowns) do
    values[key] = dropdown:get_value()
  end
  for key, multi_dropdown in pairs(self._multi_dropdowns) do
    values[key] = multi_dropdown:get_values()
  end
  return values
end

-- ============================================================================
-- Iteration
-- ============================================================================

---Iterate all fields in order, calling callback(key, field, type) for each
---@param callback fun(key: string, field: EmbeddedInput|EmbeddedDropdown|EmbeddedMultiDropdown, type: string)
function EmbeddedInputManager:for_each_field(callback)
  for _, entry in ipairs(self._field_order) do
    local field = self:get_field(entry.key)
    if field then
      callback(entry.key, field, entry.type)
    end
  end
end

-- ============================================================================
-- Cleanup
-- ============================================================================

---Close all managed fields
function EmbeddedInputManager:close_all()
  for _, input in pairs(self._inputs) do
    input:close()
  end
  for _, dropdown in pairs(self._dropdowns) do
    dropdown:close()
  end
  for _, multi_dropdown in pairs(self._multi_dropdowns) do
    multi_dropdown:close()
  end
  self._inputs = {}
  self._dropdowns = {}
  self._multi_dropdowns = {}
  self._field_order = {}
  self._current_field_idx = 0
  self._focused_key = nil
end

---Get count of all managed fields
---@return number
function EmbeddedInputManager:count()
  return #self._field_order
end

return EmbeddedInputManager
