---@module 'nvim-float.window.elements'
---@brief Element tracking support for FloatWindow

local M = {}

-- Style to highlight group mapping
local STYLE_TO_HL = {
  normal = "NvimFloatNormal",
  border = "NvimFloatBorder",
  title = "NvimFloatTitle",
  selected = "NvimFloatSelected",
  hint = "NvimFloatHint",
  header = "NvimFloatHeader",
  subheader = "NvimFloatSubheader",
  section = "NvimFloatSection",
  label = "NvimFloatLabel",
  value = "NvimFloatValue",
  key = "NvimFloatKey",
  emphasis = "NvimFloatEmphasis",
  strong = "NvimFloatStrong",
  muted = "NvimFloatMuted",
  dimmed = "NvimFloatDimmed",
  success = "NvimFloatSuccess",
  warning = "NvimFloatWarning",
  error = "NvimFloatError",
  code = "NvimFloatCode",
  code_keyword = "NvimFloatCodeKeyword",
  code_string = "NvimFloatCodeString",
  code_number = "NvimFloatCodeNumber",
  code_comment = "NvimFloatCodeComment",
  code_function = "NvimFloatCodeFunction",
  input = "NvimFloatInput",
  input_active = "NvimFloatInputActive",
  input_placeholder = "NvimFloatInputPlaceholder",
  dropdown = "NvimFloatDropdown",
  dropdown_active = "NvimFloatDropdownActive",
  dropdown_selected = "NvimFloatDropdownSelected",
}

-- ============================================================================
-- Registry Access
-- ============================================================================

---Get the element registry from the content builder
---@param fw FloatWindow
---@return ElementRegistry?
function M.get_registry(fw)
  if fw._content_builder then
    return fw._content_builder:get_registry()
  end
  return nil
end

---Get element at current cursor position
---@param fw FloatWindow
---@return TrackedElement?
function M.get_at_cursor(fw)
  if not fw:is_valid() then return nil end

  local registry = M.get_registry(fw)
  if not registry then return nil end

  local cursor = vim.api.nvim_win_get_cursor(fw.winid)
  local row = cursor[1] - 1
  local col = cursor[2]

  return registry:get_at(row, col)
end

---Get element by name
---@param fw FloatWindow
---@param name string
---@return TrackedElement?
function M.get_element(fw, name)
  local registry = M.get_registry(fw)
  if registry then
    return registry:get(name)
  end
  return nil
end

---Get all elements of a specific type
---@param fw FloatWindow
---@param element_type string
---@return TrackedElement[]
function M.get_by_type(fw, element_type)
  local registry = M.get_registry(fw)
  if registry then
    return registry:get_by_type(element_type)
  end
  return {}
end

---Get all interactive elements
---@param fw FloatWindow
---@return TrackedElement[]
function M.get_interactive(fw)
  local registry = M.get_registry(fw)
  if registry then
    return registry:get_interactive()
  end
  return {}
end

---Check if window has any tracked elements
---@param fw FloatWindow
---@return boolean
function M.has_elements(fw)
  local registry = M.get_registry(fw)
  return registry and not registry:is_empty() or false
end

-- ============================================================================
-- Element Interaction
-- ============================================================================

---Interact with element at current cursor position
---@param fw FloatWindow
---@return boolean success
function M.interact_at_cursor(fw)
  local element = M.get_at_cursor(fw)
  if not element then return false end

  -- For input/dropdown elements, delegate to InputManager
  if fw._input_manager then
    local element_type = element.type
    if element_type == "input" or element_type == "dropdown" or element_type == "multi_dropdown" then
      return fw._input_manager:activate_field(element.name)
    end
  end

  -- For other interactive elements, call their handler
  if element:is_interactive() then
    element:interact()
    return true
  end

  return false
end

---Focus next interactive element
---@param fw FloatWindow
---@return boolean success
function M.focus_next(fw)
  local registry = M.get_registry(fw)
  if not registry then return false end

  local current = M.get_at_cursor(fw)
  local current_name = current and current.name or nil
  local next_el = registry:get_next_interactive(current_name)

  if next_el and fw:is_valid() then
    local row = next_el.row + 1
    local col = next_el.col_start
    vim.api.nvim_win_set_cursor(fw.winid, { row, col })
    return true
  end
  return false
end

---Focus previous interactive element
---@param fw FloatWindow
---@return boolean success
function M.focus_prev(fw)
  local registry = M.get_registry(fw)
  if not registry then return false end

  local current = M.get_at_cursor(fw)
  local current_name = current and current.name or nil
  local prev_el = registry:get_prev_interactive(current_name)

  if prev_el and fw:is_valid() then
    local row = prev_el.row + 1
    local col = prev_el.col_start
    vim.api.nvim_win_set_cursor(fw.winid, { row, col })
    return true
  end
  return false
end

---Focus a specific element by name
---@param fw FloatWindow
---@param name string
---@return boolean success
function M.focus_element(fw, name)
  local registry = M.get_registry(fw)
  if not registry then return false end

  local element = registry:get(name)
  if not element then return false end

  if not fw:is_valid() then return false end

  local row = element.row + 1
  local col = element.col_start
  vim.api.nvim_win_set_cursor(fw.winid, { row, col })

  return true
end

---Check if cursor is on a specific element
---@param fw FloatWindow
---@param name string
---@return boolean
function M.is_cursor_on(fw, name)
  local element = M.get_at_cursor(fw)
  return element and element.name == name or false
end

-- ============================================================================
-- Element Tracking (Hover Effects)
-- ============================================================================

---Enable element tracking
---@param fw FloatWindow
---@param on_cursor_change fun(element: TrackedElement?)?
function M.enable_tracking(fw, on_cursor_change)
  if fw._element_tracking_enabled then return end
  if not fw:is_valid() then return end

  fw._element_tracking_enabled = true
  fw._element_hover_ns = vim.api.nvim_create_namespace("nvim_float_element_hover")
  fw._element_cursor_callback = on_cursor_change

  vim.api.nvim_create_autocmd("CursorMoved", {
    group = fw._augroup,
    buffer = fw.bufnr,
    callback = function()
      M.on_cursor_moved(fw)
    end,
  })

  M.on_cursor_moved(fw)
end

---Disable element tracking
---@param fw FloatWindow
function M.disable_tracking(fw)
  if not fw._element_tracking_enabled then return end

  fw._element_tracking_enabled = false

  if fw._element_hover_ns and fw.bufnr and vim.api.nvim_buf_is_valid(fw.bufnr) then
    vim.api.nvim_buf_clear_namespace(fw.bufnr, fw._element_hover_ns, 0, -1)
  end

  if fw._hovered_element then
    local registry = M.get_registry(fw)
    if registry then
      local element = registry:get(fw._hovered_element)
      if element then
        element:blur()
      end
    end
    fw._hovered_element = nil
  end
end

---Handle cursor movement for element tracking
---@param fw FloatWindow
function M.on_cursor_moved(fw)
  if not fw._element_tracking_enabled then return end
  if not fw:is_valid() then return end

  local element = M.get_at_cursor(fw)
  local new_name = element and element.name or nil
  local old_name = fw._hovered_element

  if new_name == old_name then return end

  local registry = M.get_registry(fw)
  if not registry then return end

  -- Blur old element
  if old_name then
    local old_element = registry:get(old_name)
    if old_element then
      M.remove_hover(fw, old_element)
      old_element:blur()
    end
  end

  -- Focus new element
  if new_name and element then
    M.apply_hover(fw, element)
    element:focus()
  end

  fw._hovered_element = new_name

  if fw._element_cursor_callback then
    fw._element_cursor_callback(element)
  end
end

---Get the currently hovered element
---@param fw FloatWindow
---@return TrackedElement?
function M.get_hovered(fw)
  if not fw._hovered_element then return nil end

  local registry = M.get_registry(fw)
  if registry then
    return registry:get(fw._hovered_element)
  end
  return nil
end

-- ============================================================================
-- Hover Styling
-- ============================================================================

---Get highlight group for a style name
---@param style string
---@return string?
function M.get_highlight_group(style)
  return STYLE_TO_HL[style]
end

---Apply hover style to an element
---@param fw FloatWindow
---@param element TrackedElement
function M.apply_hover(fw, element)
  if not element then return end
  if not fw._element_hover_ns then return end
  if not fw.bufnr or not vim.api.nvim_buf_is_valid(fw.bufnr) then return end

  local hover_style = element.hover_style
  if not hover_style then
    local Types = require("nvim-float.elements.types")
    hover_style = Types.get_hover_style(element.type)
  end

  if not hover_style then return end

  local hl_group = M.get_highlight_group(hover_style)
  if not hl_group then return end

  local row = element.row
  local col_start = element.col_start
  local col_end = element.col_end

  if element.row_based then
    local line = vim.api.nvim_buf_get_lines(fw.bufnr, row, row + 1, false)[1]
    if line then
      col_end = #line
    end
  end

  vim.api.nvim_buf_set_extmark(fw.bufnr, fw._element_hover_ns, row, col_start, {
    end_row = row,
    end_col = col_end,
    hl_group = hl_group,
    priority = 200,
  })
end

---Remove hover style from an element
---@param fw FloatWindow
---@param element TrackedElement
function M.remove_hover(fw, element)
  if not element then return end
  if not fw._element_hover_ns then return end
  if not fw.bufnr or not vim.api.nvim_buf_is_valid(fw.bufnr) then return end

  vim.api.nvim_buf_clear_namespace(fw.bufnr, fw._element_hover_ns, 0, -1)
end

return M
