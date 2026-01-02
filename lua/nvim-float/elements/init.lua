---@module nvim-float.elements
---Element tracking system for nvim-float
---
---This module provides a unified system for tracking UI elements with:
--- - Position tracking (row/column or row-based)
--- - Element types with default behaviors
--- - Cursor-based element queries
--- - Interactive element support (buttons, inputs, dropdowns)

local ElementModule = require("nvim-float.elements.element")
local RegistryModule = require("nvim-float.elements.registry")
local TypesModule = require("nvim-float.elements.types")

local M = {}

-- Export classes
M.TrackedElement = ElementModule.TrackedElement
M.ElementRegistry = RegistryModule.ElementRegistry

-- Export element type constants
M.ElementType = ElementModule.ElementType

-- Export types module
M.Types = TypesModule

---Create a new TrackedElement
---@param opts table Element options
---@return TrackedElement
function M.create_element(opts)
  return ElementModule.TrackedElement.new(opts)
end

---Create a new ElementRegistry
---@return ElementRegistry
function M.create_registry()
  return RegistryModule.ElementRegistry.new()
end

---Get element type definition
---@param type_name string Type name
---@return ElementTypeDefinition?
function M.get_type(type_name)
  return TypesModule.get(type_name)
end

---Register a custom element type
---@param name string Type name
---@param definition ElementTypeDefinition Type definition
function M.register_type(name, definition)
  TypesModule.register(name, definition)
end

return M
