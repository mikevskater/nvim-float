---@module 'nvim-float.content.fields'
---@brief Field building methods for ContentBuilder
---
---Re-exports all field methods from submodules:
---  - input.lua: Text input fields
---  - dropdown.lua: Single dropdown fields
---  - multi_dropdown.lua: Multi-select dropdown fields

local Input = require("nvim-float.content.fields.input")
local Dropdown = require("nvim-float.content.fields.dropdown")
local MultiDropdown = require("nvim-float.content.fields.multi_dropdown")

local M = {}

-- ============================================================================
-- Text Input Fields
-- ============================================================================

M.input = Input.input
M.labeled_input = Input.labeled_input
M.set_input_value = Input.set_input_value

-- ============================================================================
-- Dropdown Fields
-- ============================================================================

M.dropdown = Dropdown.dropdown
M.labeled_dropdown = Dropdown.labeled_dropdown
M.set_dropdown_value = Dropdown.set_dropdown_value

-- ============================================================================
-- Multi-Select Dropdown Fields
-- ============================================================================

M.multi_dropdown = MultiDropdown.multi_dropdown
M.labeled_multi_dropdown = MultiDropdown.labeled_multi_dropdown
M.set_multi_dropdown_values = MultiDropdown.set_multi_dropdown_values

return M
