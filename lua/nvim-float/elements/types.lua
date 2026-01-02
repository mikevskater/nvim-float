---@module nvim-float.elements.types
---Element type definitions with default behaviors

local M = {}

---@class ElementTypeDefinition
---@field name string Type name
---@field default_style string? Default style for this type
---@field hover_style string? Default hover style
---@field interactive boolean Whether this type is interactive by default
---@field on_interact fun(element: TrackedElement)? Default interact handler

---Built-in element type definitions
---@type table<string, ElementTypeDefinition>
local TYPE_DEFINITIONS = {
  -- Static text element (no interaction)
  text = {
    name = "text",
    default_style = nil,
    hover_style = nil,
    interactive = false,
    on_interact = nil,
  },

  -- Label element (no interaction, typically styled)
  label = {
    name = "label",
    default_style = "label",
    hover_style = nil,
    interactive = false,
    on_interact = nil,
  },

  -- Button element (clickable with visual feedback)
  button = {
    name = "button",
    default_style = "strong",
    hover_style = "emphasis",
    interactive = true,
    on_interact = function(element)
      -- Default: call the element's callback if set
      if element.data and element.data.callback then
        element.data.callback(element)
      end
    end,
  },

  -- Action element (inline action like [Edit], [Delete])
  action = {
    name = "action",
    default_style = "emphasis",
    hover_style = "strong",
    interactive = true,
    on_interact = function(element)
      -- Default: call the element's callback if set
      if element.data and element.data.callback then
        element.data.callback(element)
      end
    end,
  },

  -- Toggle element (boolean on/off)
  toggle = {
    name = "toggle",
    default_style = "value",
    hover_style = "emphasis",
    interactive = true,
    on_interact = function(element)
      -- Toggle the value
      local current = element:get_value()
      if type(current) == "boolean" then
        element:set_value(not current)
      else
        element:set_value(true)
      end
    end,
  },

  -- Link element (clickable URL or navigation)
  link = {
    name = "link",
    default_style = "emphasis",
    hover_style = "strong",
    interactive = true,
    on_interact = function(element)
      -- Open URL if data contains url
      if element.data and element.data.url then
        vim.ui.open(element.data.url)
      elseif element.data and element.data.callback then
        element.data.callback(element)
      end
    end,
  },

  -- Input element (text input field)
  input = {
    name = "input",
    default_style = "input",
    hover_style = "input_active",
    interactive = true,
    on_interact = function(element)
      -- Input interaction is handled by InputManager
      -- This is a placeholder for the element type
    end,
  },

  -- Dropdown element (single-select dropdown)
  dropdown = {
    name = "dropdown",
    default_style = "dropdown",
    hover_style = "dropdown_active",
    interactive = true,
    on_interact = function(element)
      -- Dropdown interaction is handled by InputManager
      -- This is a placeholder for the element type
    end,
  },

  -- Multi-dropdown element (multi-select dropdown)
  multi_dropdown = {
    name = "multi_dropdown",
    default_style = "dropdown",
    hover_style = "dropdown_active",
    interactive = true,
    on_interact = function(element)
      -- Multi-dropdown interaction is handled by InputManager
      -- This is a placeholder for the element type
    end,
  },
}

---Custom element types registered by plugins
---@type table<string, ElementTypeDefinition>
local custom_types = {}

---Get an element type definition
---@param type_name string Type name
---@return ElementTypeDefinition? definition
function M.get(type_name)
  return custom_types[type_name] or TYPE_DEFINITIONS[type_name]
end

---Register a custom element type
---@param name string Type name
---@param definition ElementTypeDefinition Type definition
function M.register(name, definition)
  definition.name = name
  custom_types[name] = definition
end

---Check if a type is interactive
---@param type_name string Type name
---@return boolean
function M.is_interactive(type_name)
  local def = M.get(type_name)
  return def and def.interactive or false
end

---Get the default style for a type
---@param type_name string Type name
---@return string? style
function M.get_default_style(type_name)
  local def = M.get(type_name)
  return def and def.default_style
end

---Get the hover style for a type
---@param type_name string Type name
---@return string? style
function M.get_hover_style(type_name)
  local def = M.get(type_name)
  return def and def.hover_style
end

---Get the default interact handler for a type
---@param type_name string Type name
---@return function? handler
function M.get_default_handler(type_name)
  local def = M.get(type_name)
  return def and def.on_interact
end

---Get all registered type names
---@return string[]
function M.get_all_types()
  local types = {}
  for name in pairs(TYPE_DEFINITIONS) do
    table.insert(types, name)
  end
  for name in pairs(custom_types) do
    if not TYPE_DEFINITIONS[name] then
      table.insert(types, name)
    end
  end
  table.sort(types)
  return types
end

return M
