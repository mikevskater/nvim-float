---@module 'nvim-float.input.navigation'
---@brief Field navigation for InputManager

local State = require("nvim-float.input.state")
local Highlight = require("nvim-float.input.highlight")

local M = {}

-- Lazy-load to avoid circular dependency
local _editing
local function get_editing()
  if not _editing then
    _editing = require("nvim-float.input.editing")
  end
  return _editing
end

-- ============================================================================
-- Cursor Position Check
-- ============================================================================

---Check if cursor is on an input field and update highlighting
---@param im InputManager The InputManager instance
function M.check_cursor_on_input(im)
  local cursor = vim.api.nvim_win_get_cursor(im.winid)
  local row = cursor[1]  -- 1-indexed
  local col = cursor[2]  -- 0-indexed

  -- Find input at cursor position
  for i, key in ipairs(im.input_order) do
    local input = im.inputs[key]
    if input and input.line == row and col >= input.col_start and col < input.col_end then
      -- Cursor is on this input - update index and highlight
      im.current_input_idx = i
      Highlight.highlight_current_input(im, key)
      return
    end
  end

  -- Not on any input - keep current input highlighted
  if #im.input_order > 0 then
    local current_key = im.input_order[im.current_input_idx]
    Highlight.highlight_current_input(im, current_key)
  end
end

-- ============================================================================
-- Field Navigation
-- ============================================================================

---Focus a field (input or dropdown) without activating it
---@param im InputManager The InputManager instance
---@param key string Field key
function M.focus_field_internal(im, key)
  local field_info = State.get_field(im, key)
  if not field_info then return end

  local field = field_info.field
  vim.api.nvim_win_set_cursor(im.winid, {field.line, field.col_start})
  Highlight.highlight_current_field(im, key)
end

---Focus a specific field by key (public API)
---@param im InputManager The InputManager instance
---@param key string Field key to focus
function M.focus_field(im, key)
  -- Find the field index
  for i, k in ipairs(im._field_order) do
    if k == key then
      im.current_field_idx = i
      break
    end
  end
  M.focus_field_internal(im, key)
end

---Focus the first field in the panel
---@param im InputManager The InputManager instance
function M.focus_first_field(im)
  if #im._field_order > 0 then
    im.current_field_idx = 1
    M.focus_field_internal(im, im._field_order[1])
  end
end

---Navigate to next field (input or dropdown)
---@param im InputManager The InputManager instance
function M.next_input(im)
  if #im._field_order == 0 then return end

  -- Find next field index
  local next_idx = (im.current_field_idx % #im._field_order) + 1
  local next_key = im._field_order[next_idx]

  -- Update tracked index
  im.current_field_idx = next_idx

  -- Exit current input mode if active
  if im.in_input_mode then
    vim.cmd("stopinsert")
    vim.schedule(function()
      M.focus_field_internal(im, next_key)
    end)
  else
    M.focus_field_internal(im, next_key)
  end
end

---Navigate to previous field (input or dropdown)
---@param im InputManager The InputManager instance
function M.prev_input(im)
  if #im._field_order == 0 then return end

  -- Find previous field index
  local prev_idx = ((im.current_field_idx - 2) % #im._field_order) + 1
  local prev_key = im._field_order[prev_idx]

  -- Update tracked index
  im.current_field_idx = prev_idx

  -- Exit current input mode if active
  if im.in_input_mode then
    vim.cmd("stopinsert")
    vim.schedule(function()
      M.focus_field_internal(im, prev_key)
    end)
  else
    M.focus_field_internal(im, prev_key)
  end
end

-- ============================================================================
-- Field Activation
-- ============================================================================

---Activate a field (enter input mode or open dropdown)
---@param im InputManager The InputManager instance
---@param key string Field key
function M.activate_field(im, key)
  local field_info = State.get_field(im, key)
  if not field_info then return end

  if field_info.type == "input" then
    get_editing().enter_input_mode(im, key)
  elseif field_info.type == "dropdown" then
    -- Lazy-load dropdown module
    local Dropdown = require("nvim-float.input.dropdown")
    Dropdown.open(im, key)
  elseif field_info.type == "multi_dropdown" then
    -- Lazy-load multi-dropdown module
    local MultiDropdown = require("nvim-float.input.multi_dropdown")
    MultiDropdown.open(im, key)
  elseif field_info.type == "container" or field_info.type == "embedded_input" then
    -- Container-based fields: transfer focus to child window
    -- The parent FloatWindow's container/input manager handles this
    -- This path is for forward compatibility when container fields are
    -- registered in the traditional InputManager field order
  end
end

---Public API: Activate a field by key (for element tracking integration)
---@param im InputManager The InputManager instance
---@param key string Field key (input, dropdown, or multi-dropdown)
---@return boolean success Whether the field was activated
function M.activate_field_public(im, key)
  local field_info = State.get_field(im, key)
  if not field_info then return false end
  M.activate_field(im, key)
  return true
end

return M
