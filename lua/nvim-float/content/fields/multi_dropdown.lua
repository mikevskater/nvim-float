---@module 'nvim-float.content.fields.multi_dropdown'
---@brief Multi-select dropdown field methods for ContentBuilder

local Elements = require("nvim-float.elements")
local Styles = require("nvim-float.theme.styles")

local M = {}

-- ============================================================================
-- Multi-Select Dropdown Fields
-- ============================================================================

---Add a multi-select dropdown field
---@param cb ContentBuilder
---@param key string Unique identifier
---@param opts table Options
---@return ContentBuilder self For chaining
function M.multi_dropdown(cb, key, opts)
  opts = opts or {}
  local label = opts.label or ""
  local options = opts.options or {}
  local values = opts.values or {}
  local placeholder = opts.placeholder or "(none selected)"
  local width = opts.width or 20
  local max_height = opts.max_height or 8
  local label_style = opts.label_style or "label"
  local separator = opts.separator or ": "
  local display_mode = opts.display_mode or "count"
  local select_all_option = opts.select_all_option ~= false
  local label_width = opts.label_width

  -- Build display text
  local display_text
  local is_placeholder = (#values == 0)

  if #values == 0 then
    display_text = placeholder
  elseif display_mode == "count" then
    if #values == #options then
      display_text = "All (" .. #values .. ")"
    else
      display_text = #values .. " selected"
    end
  else
    local labels = {}
    for _, v in ipairs(values) do
      for _, opt in ipairs(options) do
        if opt.value == v then
          table.insert(labels, opt.label)
          break
        end
      end
    end
    display_text = table.concat(labels, ", ")
  end

  -- Build prefix
  local prefix = ""
  if label ~= "" then
    prefix = label .. separator
    if label_width then
      local prefix_display_len = vim.fn.strdisplaywidth(prefix)
      if prefix_display_len < label_width then
        prefix = prefix .. string.rep(" ", label_width - prefix_display_len)
      end
    end
  end

  -- Cap width if max_width is set
  if cb._max_width then
    local prefix_display_len = vim.fn.strdisplaywidth(prefix)
    local available = cb._max_width - prefix_display_len - 2
    if available > 0 and width > available then
      width = available
    end
  end

  -- Arrow setup
  local arrow = " ▾"
  local arrow_byte_len = #arrow
  local arrow_display_len = 2

  local text_width = width - arrow_display_len
  text_width = math.max(text_width, 1)
  local effective_width = text_width + arrow_display_len

  -- Pad or truncate display text
  local display_len = vim.fn.strdisplaywidth(display_text)
  if display_len < text_width then
    display_text = display_text .. string.rep(" ", text_width - display_len)
  elseif display_len > text_width then
    local truncated = ""
    local current_width = 0
    local char_idx = 0
    while current_width < text_width - 1 do
      local char = vim.fn.strcharpart(display_text, char_idx, 1)
      if char == "" then break end
      local char_width = vim.fn.strdisplaywidth(char)
      if current_width + char_width > text_width - 1 then break end
      truncated = truncated .. char
      current_width = current_width + char_width
      char_idx = char_idx + 1
    end
    local pad_needed = text_width - 1 - vim.fn.strdisplaywidth(truncated)
    if pad_needed > 0 then
      truncated = truncated .. string.rep(" ", pad_needed)
    end
    display_text = truncated .. "..."
  end

  -- Build full line
  local input_start = #prefix
  local text = prefix .. "[" .. display_text .. arrow .. "]"
  local input_value_start = input_start + 1
  local display_text_bytes = #display_text
  local input_value_end = input_value_start + display_text_bytes + arrow_byte_len

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

  -- Highlight dropdown value
  local value_style = is_placeholder and "input_placeholder" or "dropdown"
  table.insert(line.highlights, {
    col_start = input_value_start,
    col_end = input_value_start + display_text_bytes,
    style = value_style,
  })

  -- Highlight arrow
  table.insert(line.highlights, {
    col_start = input_value_start + display_text_bytes,
    col_end = input_value_end,
    style = "dropdown_arrow",
  })

  table.insert(cb._lines, line)

  -- Store multi-dropdown field info
  local line_num = #cb._lines
  cb._multi_dropdowns[key] = {
    key = key,
    line = line_num,
    col_start = input_value_start,
    col_end = input_value_end,
    width = effective_width,
    text_width = text_width,
    values = vim.deepcopy(values),
    default = vim.deepcopy(values),
    options = options,
    max_height = max_height,
    label = label,
    prefix_len = #prefix,
    placeholder = placeholder,
    is_placeholder = is_placeholder,
    display_mode = display_mode,
    select_all_option = select_all_option,
  }
  table.insert(cb._multi_dropdown_order, key)

  -- Register as tracked element
  local row = line_num - 1
  cb._registry:register({
    name = key,
    type = Elements.ElementType.MULTI_DROPDOWN,
    row = row,
    col_start = input_value_start,
    col_end = input_value_end,
    row_based = false,
    text = display_text,
    data = {
      label = label,
      options = options,
      placeholder = placeholder,
      max_height = max_height,
      text_width = text_width,
      prefix_len = #prefix,
      display_mode = display_mode,
      select_all_option = select_all_option,
    },
    style = is_placeholder and "input_placeholder" or "dropdown",
    hover_style = "dropdown_active",
    value = vim.deepcopy(values),
    on_change = opts.on_change,
  })

  return cb
end

---Add a labeled multi-dropdown
---@param cb ContentBuilder
---@param key string Unique identifier
---@param label string Label text
---@param opts table Options
---@return ContentBuilder self For chaining
function M.labeled_multi_dropdown(cb, key, label, opts)
  opts = opts or {}
  opts.label = label
  return M.multi_dropdown(cb, key, opts)
end

---Update a multi-dropdown's values
---@param cb ContentBuilder
---@param key string Multi-dropdown key
---@param values string[] New selected values
---@return ContentBuilder self For chaining
function M.set_multi_dropdown_values(cb, key, values)
  local multi_dropdown = cb._multi_dropdowns[key]
  if multi_dropdown then
    multi_dropdown.values = vim.deepcopy(values)
    multi_dropdown.is_placeholder = (#values == 0)
  end
  return cb
end

return M
