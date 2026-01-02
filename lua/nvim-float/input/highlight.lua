---@module 'nvim-float.input.highlight'
---@brief Highlight methods for InputManager fields

local M = {}

-- ============================================================================
-- Input Highlighting
-- ============================================================================

---Highlight an input field
---@param im InputManager The InputManager instance
---@param key string Input key
---@param active boolean Whether input is active/focused
function M.highlight_input(im, key, active)
  local input = im.inputs[key]
  if not input then return end

  -- Check if buffer is still valid
  if not im.bufnr or not vim.api.nvim_buf_is_valid(im.bufnr) then
    return
  end

  -- Clear existing highlights first
  vim.api.nvim_buf_clear_namespace(im.bufnr, im._namespace, input.line - 1, input.line)

  -- Determine highlight group based on state
  local hl_group
  if active then
    hl_group = "NvimFloatInputActive"
  elseif input.is_showing_placeholder then
    hl_group = "NvimFloatInputPlaceholder"
  else
    hl_group = "NvimFloatInput"
  end

  vim.api.nvim_buf_add_highlight(
    im.bufnr, im._namespace, hl_group,
    input.line - 1, input.col_start, input.col_end
  )
end

---Highlight the current input (for Tab navigation in normal mode)
---@param im InputManager The InputManager instance
---@param current_key string Key of currently focused input
function M.highlight_current_input(im, current_key)
  -- Check if buffer is still valid
  if not im.bufnr or not vim.api.nvim_buf_is_valid(im.bufnr) then
    return
  end

  -- Clear all and reapply with current highlighted
  vim.api.nvim_buf_clear_namespace(im.bufnr, im._namespace, 0, -1)

  for key, _ in pairs(im.inputs) do
    M.highlight_input(im, key, key == current_key)
  end
end

---Clear all input highlights
---@param im InputManager The InputManager instance
function M.clear_input_highlights(im)
  -- Check if buffer is still valid
  if not im.bufnr or not vim.api.nvim_buf_is_valid(im.bufnr) then
    return
  end

  vim.api.nvim_buf_clear_namespace(im.bufnr, im._namespace, 0, -1)

  -- Reapply inactive highlights to all inputs
  for key, _ in pairs(im.inputs) do
    M.highlight_input(im, key, false)
  end
end

-- ============================================================================
-- Dropdown Highlighting
-- ============================================================================

---Highlight a dropdown/multi-dropdown field (shared base)
---@param im InputManager The InputManager instance
---@param dropdown_type "dropdown"|"multi_dropdown"
---@param key string Field key
---@param active boolean Whether field is active/focused
function M.highlight_dropdown_base(im, dropdown_type, key, active)
  local field = dropdown_type == "dropdown" and im.dropdowns[key] or im.multi_dropdowns[key]
  if not field then return end

  -- Check if buffer is still valid
  if not im.bufnr or not vim.api.nvim_buf_is_valid(im.bufnr) then
    return
  end

  -- Determine highlight group based on state
  local hl_group
  if active then
    hl_group = "NvimFloatInputActive"
  elseif field.is_placeholder then
    hl_group = "NvimFloatInputPlaceholder"
  else
    hl_group = "NvimFloatInput"
  end

  -- Highlight the dropdown value area (excluding arrow)
  local arrow_len = 4  -- Both " ▼" and " ▾" are 4 bytes
  vim.api.nvim_buf_add_highlight(
    im.bufnr, im._namespace, hl_group,
    field.line - 1, field.col_start, field.col_end - arrow_len
  )

  -- Arrow always gets hint color
  vim.api.nvim_buf_add_highlight(
    im.bufnr, im._namespace, "NvimFloatHint",
    field.line - 1, field.col_end - arrow_len, field.col_end
  )
end

---Highlight a dropdown field
---@param im InputManager The InputManager instance
---@param key string Dropdown key
---@param active boolean Whether dropdown is active/focused
function M.highlight_dropdown(im, key, active)
  M.highlight_dropdown_base(im, "dropdown", key, active)
end

---Highlight a multi-dropdown field
---@param im InputManager The InputManager instance
---@param key string Multi-dropdown key
---@param active boolean Whether multi-dropdown is active/focused
function M.highlight_multi_dropdown(im, key, active)
  M.highlight_dropdown_base(im, "multi_dropdown", key, active)
end

-- ============================================================================
-- Combined Field Highlighting
-- ============================================================================

---Highlight a field (input, dropdown, or multi-dropdown)
---@param im InputManager The InputManager instance
---@param current_key string Key of currently focused field
function M.highlight_current_field(im, current_key)
  -- Check if buffer is still valid (may have been replaced by callback)
  if not im.bufnr or not vim.api.nvim_buf_is_valid(im.bufnr) then
    return
  end

  -- Clear all and reapply with current highlighted
  vim.api.nvim_buf_clear_namespace(im.bufnr, im._namespace, 0, -1)

  -- Highlight inputs
  for key, _ in pairs(im.inputs) do
    M.highlight_input(im, key, key == current_key)
  end

  -- Highlight dropdowns
  for key, _ in pairs(im.dropdowns) do
    M.highlight_dropdown(im, key, key == current_key)
  end

  -- Highlight multi-dropdowns
  for key, _ in pairs(im.multi_dropdowns) do
    M.highlight_multi_dropdown(im, key, key == current_key)
  end
end

---Initialize highlights for all fields (inputs and dropdowns)
---@param im InputManager The InputManager instance
function M.init_highlights(im)
  -- Highlight first field as current, others as inactive
  if #im._field_order > 0 then
    local first_key = im._field_order[1]
    M.highlight_current_field(im, first_key)
  end
end

return M
