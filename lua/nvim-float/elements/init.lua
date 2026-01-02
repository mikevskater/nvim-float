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

local M = {}

-- Export classes
M.TrackedElement = ElementModule.TrackedElement
M.ElementRegistry = RegistryModule.ElementRegistry

-- Export element type constants
M.ElementType = ElementModule.ElementType

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

return M
