---@module nvim-float.elements.element
---TrackedElement class - represents a tracked UI element with position and behavior

---@class TrackedElement
---@field name string Unique identifier for this element
---@field type string Element type (text, label, button, action, input, dropdown, etc.)
---@field row number 0-indexed row position
---@field col_start number 0-indexed column start (auto-calculated from text length)
---@field col_end number 0-indexed column end (auto-calculated from text length)
---@field row_based boolean If true, element owns entire row (default: false)
---@field text string? The rendered text content of this element
---@field data any? Arbitrary user data attached to element
---@field style string? Current style name
---@field hover_style string? Style when cursor is on element
---@field on_interact fun(self: TrackedElement)? Called on Enter/interact
---@field on_focus fun(self: TrackedElement)? Called when cursor enters element
---@field on_blur fun(self: TrackedElement)? Called when cursor leaves element
---@field on_change fun(self: TrackedElement, value: any)? Called when value changes (inputs/dropdowns)
---@field _registry ElementRegistry? Back-reference to parent registry
---@field _value any? Current value for input-type elements
local TrackedElement = {}
TrackedElement.__index = TrackedElement

---Element type constants
---@enum ElementType
local ElementType = {
  TEXT = "text",
  LABEL = "label",
  BUTTON = "button",
  ACTION = "action",
  TOGGLE = "toggle",
  LINK = "link",
  INPUT = "input",
  DROPDOWN = "dropdown",
  MULTI_DROPDOWN = "multi_dropdown",
  CONTAINER = "container",
  EMBEDDED_INPUT = "embedded_input",
}

---Create a new TrackedElement
---@param opts table Element options
---@return TrackedElement
function TrackedElement.new(opts)
  opts = opts or {}

  local self = setmetatable({
    name = opts.name or error("TrackedElement requires a name"),
    type = opts.type or ElementType.TEXT,
    row = opts.row or 0,
    col_start = opts.col_start or 0,
    col_end = opts.col_end or 0,
    row_based = opts.row_based or false,
    text = opts.text,
    data = opts.data,
    style = opts.style,
    hover_style = opts.hover_style,
    on_interact = opts.on_interact,
    on_focus = opts.on_focus,
    on_blur = opts.on_blur,
    on_change = opts.on_change,
    _registry = nil,
    _value = opts.value,
  }, TrackedElement)

  return self
end

---Get the element's name
---@return string
function TrackedElement:get_name()
  return self.name
end

---Get the element's type
---@return string
function TrackedElement:get_type()
  return self.type
end

---Get the element's data
---@return any?
function TrackedElement:get_data()
  return self.data
end

---Set the element's data
---@param data any
function TrackedElement:set_data(data)
  self.data = data
end

---Get the element's current value (for input-type elements)
---@return any?
function TrackedElement:get_value()
  return self._value
end

---Set the element's value (for input-type elements)
---@param value any
---@param trigger_callback boolean? Whether to trigger on_change (default: true)
function TrackedElement:set_value(value, trigger_callback)
  local old_value = self._value
  self._value = value

  if trigger_callback ~= false and self.on_change and old_value ~= value then
    self:on_change(value)
  end
end

---Check if this element is row-based (owns entire row)
---@return boolean
function TrackedElement:is_row_based()
  return self.row_based == true
end

---Check if a position is within this element's bounds
---@param row number 0-indexed row
---@param col number 0-indexed column
---@return boolean
function TrackedElement:contains_position(row, col)
  -- Row must match
  if row ~= self.row then
    return false
  end

  -- If row-based, any column on this row matches
  if self.row_based then
    return true
  end

  -- Column-based: check if col is within [col_start, col_end)
  return col >= self.col_start and col < self.col_end
end

---Get the column range for this element
---@return number col_start, number col_end
function TrackedElement:get_column_range()
  return self.col_start, self.col_end
end

---Get the row position
---@return number
function TrackedElement:get_row()
  return self.row
end

---Trigger the element's interact handler
---Falls back to type-specific default behavior if no handler defined
function TrackedElement:interact()
  -- If custom handler exists, use it
  if self.on_interact then
    self:on_interact()
    return
  end

  -- Default behavior based on element type
  local element_type = self.type

  if element_type == ElementType.TEXT or element_type == ElementType.LABEL then
    -- No default interaction for text/label
    return
  end

  if element_type == ElementType.BUTTON or element_type == ElementType.ACTION then
    -- Button/action without handler does nothing
    -- (handler should be provided)
    return
  end

  if element_type == ElementType.TOGGLE then
    -- Toggle the value
    local current = self._value
    if type(current) == "boolean" then
      self:set_value(not current)
    else
      self:set_value(true)
    end
    return
  end

  if element_type == ElementType.LINK then
    -- Open URL if data contains url
    if self.data and self.data.url then
      vim.ui.open(self.data.url)
    end
    return
  end

  -- INPUT, DROPDOWN, MULTI_DROPDOWN have special handling
  -- that will be implemented in their respective element type modules
end

---Trigger the element's focus handler
function TrackedElement:focus()
  if self.on_focus then
    self:on_focus()
  end
end

---Trigger the element's blur handler
function TrackedElement:blur()
  if self.on_blur then
    self:on_blur()
  end
end

---Check if this element is interactive (has default or custom interaction)
---@return boolean
function TrackedElement:is_interactive()
  -- Has custom handler
  if self.on_interact then
    return true
  end

  -- Type-based interactivity
  local interactive_types = {
    [ElementType.BUTTON] = true,
    [ElementType.ACTION] = true,
    [ElementType.TOGGLE] = true,
    [ElementType.LINK] = true,
    [ElementType.INPUT] = true,
    [ElementType.DROPDOWN] = true,
    [ElementType.MULTI_DROPDOWN] = true,
    [ElementType.CONTAINER] = true,
    [ElementType.EMBEDDED_INPUT] = true,
  }

  return interactive_types[self.type] or false
end

---Get a string representation for debugging
---@return string
function TrackedElement:__tostring()
  if self.row_based then
    return string.format("TrackedElement<%s:%s @row=%d (row-based)>",
      self.name, self.type, self.row)
  else
    return string.format("TrackedElement<%s:%s @row=%d col=%d-%d>",
      self.name, self.type, self.row, self.col_start, self.col_end)
  end
end

return {
  TrackedElement = TrackedElement,
  ElementType = ElementType,
}
