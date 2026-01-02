---@module 'nvim-float.content.fields.input'
---@brief Text input field methods for ContentBuilder

local Elements = require("nvim-float.elements")
local Styles = require("nvim-float.theme.styles")

local M = {}

-- ============================================================================
-- Text Input Fields
-- ============================================================================

---Add an input field
---@param cb ContentBuilder
---@param key string Unique identifier
---@param opts table Options
---@return ContentBuilder self For chaining
function M.input(cb, key, opts)
  opts = opts or {}
  local label = opts.label or ""
  local value = opts.value or ""
  local placeholder = opts.placeholder or ""
  local default_width = opts.width or 20
  local min_width = opts.min_width or default_width
  local label_style = opts.label_style or "label"
  local separator = opts.separator or ": "

  -- Build prefix
  local prefix = ""
  if label ~= "" then
    prefix = label .. separator
  end

  -- Display value or placeholder
  local display_text = value
  local is_placeholder = false
  if value == "" and placeholder ~= "" then
    display_text = placeholder
    is_placeholder = true
  end

  -- Calculate effective width
  local effective_width = math.max(default_width, min_width, #display_text)

  -- Pad display text
  if #display_text < effective_width then
    display_text = display_text .. string.rep(" ", effective_width - #display_text)
  end

  -- Build full line
  local input_start = #prefix
  local text = prefix .. "[" .. display_text .. "]"
  local input_value_start = input_start + 1
  local input_value_end = input_value_start + effective_width

  local line = {
    text = text,
    highlights = {},
  }

  -- Highlight label
  if label ~= "" and Styles.get(label_style) then
    table.insert(line.highlights, {
      col_start = 0,
      col_end = #label,
      style = label_style,
    })
  end

  -- Highlight brackets
  table.insert(line.highlights, {
    col_start = input_start,
    col_end = input_start + 1,
    style = "muted",
  })
  table.insert(line.highlights, {
    col_start = input_value_end,
    col_end = input_value_end + 1,
    style = "muted",
  })

  -- Highlight input value area
  local value_style = is_placeholder and "input_placeholder" or "input"
  table.insert(line.highlights, {
    col_start = input_value_start,
    col_end = input_value_end,
    style = value_style,
  })

  table.insert(cb._lines, line)

  -- Store input field info
  local line_num = #cb._lines
  cb._inputs[key] = {
    key = key,
    line = line_num,
    col_start = input_value_start,
    col_end = input_value_end,
    width = effective_width,
    default_width = default_width,
    min_width = min_width,
    value = value,
    default = value,
    placeholder = placeholder,
    is_showing_placeholder = is_placeholder,
    label = label,
    prefix_len = #prefix,
  }
  table.insert(cb._input_order, key)

  -- Register as tracked element
  local row = line_num - 1
  cb._registry:register({
    name = key,
    type = Elements.ElementType.INPUT,
    row = row,
    col_start = input_value_start,
    col_end = input_value_end,
    row_based = false,
    text = display_text,
    data = {
      label = label,
      placeholder = placeholder,
      default_width = default_width,
      min_width = min_width,
      prefix_len = #prefix,
    },
    style = is_placeholder and "input_placeholder" or "input",
    hover_style = "input_active",
    value = value,
    on_change = opts.on_change,
  })

  return cb
end

---Add an input field with label
---@param cb ContentBuilder
---@param arg1 string First argument (key or label)
---@param arg2 string Second argument (label or key)
---@param arg3 table|string|nil Third argument
---@param arg4 number? Fourth argument
---@return ContentBuilder self For chaining
function M.labeled_input(cb, arg1, arg2, arg3, arg4)
  local key, label, opts

  if type(arg3) == "table" then
    key = arg1
    label = arg2
    opts = arg3
  else
    label = arg1
    key = arg2
    opts = {
      value = arg3 or "",
      width = arg4,
    }
  end

  opts = opts or {}
  opts.label = label
  return M.input(cb, key, opts)
end

---Update an input field's value
---@param cb ContentBuilder
---@param key string Input key
---@param value string New value
---@return ContentBuilder self For chaining
function M.set_input_value(cb, key, value)
  local input_field = cb._inputs[key]
  if input_field then
    input_field.value = value
  end
  return cb
end

return M
