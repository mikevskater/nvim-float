---@module nvim-float.elements.registry
---ElementRegistry class - stores and queries tracked elements

local ElementModule = require("nvim-float.elements.element")
local TrackedElement = ElementModule.TrackedElement

---@class ElementRegistry
---@field _elements table<string, TrackedElement> Elements indexed by name
---@field _by_row table<number, TrackedElement[]> Elements indexed by row
---@field _element_order string[] Ordered list of element names (for Tab navigation)
---@field _focused_element string? Currently focused element name
local ElementRegistry = {}
ElementRegistry.__index = ElementRegistry

---Create a new ElementRegistry
---@return ElementRegistry
function ElementRegistry.new()
  local self = setmetatable({
    _elements = {},
    _by_row = {},
    _element_order = {},
    _focused_element = nil,
  }, ElementRegistry)

  return self
end

---Register an element in the registry
---@param element TrackedElement|table Element instance or options table
---@return TrackedElement element The registered element
function ElementRegistry:register(element)
  -- If passed options table, create TrackedElement
  if getmetatable(element) ~= TrackedElement then
    element = TrackedElement.new(element)
  end

  local name = element.name

  -- Remove old element with same name if exists
  if self._elements[name] then
    self:unregister(name)
  end

  -- Store element
  self._elements[name] = element
  element._registry = self

  -- Index by row
  local row = element.row
  if not self._by_row[row] then
    self._by_row[row] = {}
  end
  table.insert(self._by_row[row], element)

  -- Add to order list (for Tab navigation)
  table.insert(self._element_order, name)

  return element
end

---Unregister an element from the registry
---@param name string Element name
---@return boolean success Whether element was found and removed
function ElementRegistry:unregister(name)
  local element = self._elements[name]
  if not element then
    return false
  end

  -- Remove from elements table
  self._elements[name] = nil
  element._registry = nil

  -- Remove from row index
  local row = element.row
  if self._by_row[row] then
    for i, el in ipairs(self._by_row[row]) do
      if el.name == name then
        table.remove(self._by_row[row], i)
        break
      end
    end
    -- Clean up empty row
    if #self._by_row[row] == 0 then
      self._by_row[row] = nil
    end
  end

  -- Remove from order list
  for i, el_name in ipairs(self._element_order) do
    if el_name == name then
      table.remove(self._element_order, i)
      break
    end
  end

  -- Clear focused if this was focused
  if self._focused_element == name then
    self._focused_element = nil
  end

  return true
end

---Get an element by name
---@param name string Element name
---@return TrackedElement?
function ElementRegistry:get(name)
  return self._elements[name]
end

---Get element at a specific position
---@param row number 0-indexed row
---@param col number 0-indexed column
---@return TrackedElement? element The element at position, or nil
function ElementRegistry:get_at(row, col)
  local elements_on_row = self._by_row[row]
  if not elements_on_row then
    return nil
  end

  -- Check each element on this row
  -- For column-based elements, find the one containing this column
  -- For row-based elements, return the first one found
  for _, element in ipairs(elements_on_row) do
    if element:contains_position(row, col) then
      return element
    end
  end

  return nil
end

---Get all elements on a specific row
---@param row number 0-indexed row
---@return TrackedElement[] elements
function ElementRegistry:get_all_at_row(row)
  return self._by_row[row] or {}
end

---Get all elements of a specific type
---@param element_type string Element type to filter by
---@return TrackedElement[] elements
function ElementRegistry:get_by_type(element_type)
  local result = {}
  for _, element in pairs(self._elements) do
    if element.type == element_type then
      table.insert(result, element)
    end
  end
  return result
end

---Get all interactive elements
---@return TrackedElement[] elements
function ElementRegistry:get_interactive()
  local result = {}
  for _, name in ipairs(self._element_order) do
    local element = self._elements[name]
    if element and element:is_interactive() then
      table.insert(result, element)
    end
  end
  return result
end

---Get all elements in order
---@return TrackedElement[] elements
function ElementRegistry:get_ordered()
  local result = {}
  for _, name in ipairs(self._element_order) do
    local element = self._elements[name]
    if element then
      table.insert(result, element)
    end
  end
  return result
end

---Get all element names
---@return string[] names
function ElementRegistry:get_names()
  return vim.tbl_keys(self._elements)
end

---Get element count
---@return number
function ElementRegistry:count()
  return #self._element_order
end

---Check if registry is empty
---@return boolean
function ElementRegistry:is_empty()
  return #self._element_order == 0
end

---Clear all elements from registry
function ElementRegistry:clear()
  -- Clear back-references
  for _, element in pairs(self._elements) do
    element._registry = nil
  end

  self._elements = {}
  self._by_row = {}
  self._element_order = {}
  self._focused_element = nil
end

---Get the currently focused element
---@return TrackedElement?
function ElementRegistry:get_focused()
  if self._focused_element then
    return self._elements[self._focused_element]
  end
  return nil
end

---Set the focused element
---@param name string? Element name (nil to clear focus)
function ElementRegistry:set_focused(name)
  -- Blur previous
  local prev = self:get_focused()
  if prev and prev.name ~= name then
    prev:blur()
  end

  self._focused_element = name

  -- Focus new
  local new = self:get_focused()
  if new then
    new:focus()
  end
end

---Get the next interactive element after the given one
---@param current_name string? Current element name (nil = get first)
---@return TrackedElement? next_element
function ElementRegistry:get_next_interactive(current_name)
  local interactive = self:get_interactive()
  if #interactive == 0 then
    return nil
  end

  if not current_name then
    return interactive[1]
  end

  -- Find current index
  local current_idx = nil
  for i, el in ipairs(interactive) do
    if el.name == current_name then
      current_idx = i
      break
    end
  end

  if not current_idx then
    return interactive[1]
  end

  -- Get next (wrap around)
  local next_idx = (current_idx % #interactive) + 1
  return interactive[next_idx]
end

---Get the previous interactive element before the given one
---@param current_name string? Current element name (nil = get last)
---@return TrackedElement? prev_element
function ElementRegistry:get_prev_interactive(current_name)
  local interactive = self:get_interactive()
  if #interactive == 0 then
    return nil
  end

  if not current_name then
    return interactive[#interactive]
  end

  -- Find current index
  local current_idx = nil
  for i, el in ipairs(interactive) do
    if el.name == current_name then
      current_idx = i
      break
    end
  end

  if not current_idx then
    return interactive[#interactive]
  end

  -- Get previous (wrap around)
  local prev_idx = ((current_idx - 2) % #interactive) + 1
  return interactive[prev_idx]
end

---Iterate over all elements
---@return fun(): string?, TrackedElement? iterator
function ElementRegistry:iter()
  local names = self._element_order
  local i = 0
  return function()
    i = i + 1
    local name = names[i]
    if name then
      return name, self._elements[name]
    end
    return nil, nil
  end
end

---Get a string representation for debugging
---@return string
function ElementRegistry:__tostring()
  return string.format("ElementRegistry<%d elements>", self:count())
end

return {
  ElementRegistry = ElementRegistry,
}
