---@module 'nvim-float.input.editing'
---@brief Text editing, value management, and validation for InputManager

local Highlight = require("nvim-float.input.highlight")

local M = {}

-- ============================================================================
-- Input Mode Entry/Exit
-- ============================================================================

---Enter input mode for a specific input field
---@param im InputManager The InputManager instance
---@param key string Input key to activate
function M.enter_input_mode(im, key)
  local input = im.inputs[key]
  if not input then return end

  im.in_input_mode = true
  im.active_input = key

  -- Update current_input_idx to match activated input
  for i, k in ipairs(im.input_order) do
    if k == key then
      im.current_input_idx = i
      break
    end
  end

  -- Make buffer modifiable
  vim.api.nvim_buf_set_option(im.bufnr, 'modifiable', true)

  -- Disable autocompletion in input buffer
  vim.b[im.bufnr].cmp_enabled = false      -- nvim-cmp
  vim.b[im.bufnr].blink_cmp_enable = false -- blink.cmp
  vim.b[im.bufnr].completion = false       -- generic

  -- If showing placeholder, clear it to blank spaces for editing
  local value = im.values[key] or ""
  if input.is_showing_placeholder then
    -- Clear the placeholder - replace with spaces
    M.clear_input_to_spaces(im, key)
    value = ""
    im.values[key] = ""
    input.is_showing_placeholder = false
  end

  -- Position cursor at end of current value (or start if empty)
  local cursor_col = input.col_start + #value
  cursor_col = math.min(cursor_col, input.col_end - 1)

  vim.api.nvim_win_set_cursor(im.winid, {input.line, cursor_col})

  -- Highlight active input
  Highlight.highlight_current_input(im, key)

  -- Enter insert mode
  vim.cmd("startinsert")

  -- Callback
  if im.on_input_enter then
    im.on_input_enter(key)
  end
end

---Exit input mode
---@param im InputManager The InputManager instance
function M.exit_input_mode(im)
  if not im.in_input_mode then return end

  local exited_key = im.active_input

  -- Sync final value
  M.sync_input_value(im)

  im.in_input_mode = false
  im.active_input = nil

  -- Always re-render to normalize width (removes extra spaces, restores placeholder if empty)
  if exited_key then
    local input = im.inputs[exited_key]
    local value = im.values[exited_key] or ""
    if input then
      -- Track placeholder state
      if value == "" and (input.placeholder or "") ~= "" then
        input.is_showing_placeholder = true
      else
        input.is_showing_placeholder = false
      end
      -- Re-render to normalize display width
      M.render_input(im, exited_key)
    end
  end

  -- Make buffer non-modifiable again
  vim.api.nvim_buf_set_option(im.bufnr, 'modifiable', false)

  -- Keep the current input highlighted (not all cleared)
  if exited_key then
    Highlight.highlight_current_input(im, exited_key)
  end

  -- Callback
  if im.on_input_exit and exited_key then
    im.on_input_exit(exited_key)
  end
end

-- ============================================================================
-- Value Management
-- ============================================================================

---Clear an input field to blank spaces (for placeholder clearing)
---@param im InputManager The InputManager instance
---@param key string Input key
function M.clear_input_to_spaces(im, key)
  local input = im.inputs[key]
  if not input then return end

  local default_width = input.default_width or input.width or 20
  local min_width = input.min_width or default_width
  local effective_width = math.max(default_width, min_width)

  -- Replace with spaces at default width
  local blank_text = string.rep(" ", effective_width)

  -- Get current line
  local lines = vim.api.nvim_buf_get_lines(im.bufnr, input.line - 1, input.line, false)
  if #lines == 0 then return end

  local line = lines[1]

  -- Find the actual closing bracket position
  local bracket_pos = line:find("%]", input.col_start + 1)
  if not bracket_pos then return end

  -- Reconstruct line with blank content at default width
  local before = line:sub(1, input.col_start)  -- Up to and including "["
  local after = line:sub(bracket_pos + 1)  -- Everything after "]"

  -- Build new line and update col_end
  local new_line = before .. blank_text .. "]" .. after
  input.col_end = input.col_start + effective_width
  input.width = effective_width

  -- Update buffer (already modifiable when entering input mode)
  vim.api.nvim_buf_set_lines(im.bufnr, input.line - 1, input.line, false, {new_line})
end

---Sync the current input's value from the buffer
---@param im InputManager The InputManager instance
function M.sync_input_value(im)
  if not im.active_input then return end

  local input = im.inputs[im.active_input]
  if not input then return end

  -- Read the line from buffer
  local lines = vim.api.nvim_buf_get_lines(im.bufnr, input.line - 1, input.line, false)
  if #lines == 0 then return end

  local line_text = lines[1]

  -- Find the closing bracket to determine actual input end
  local bracket_pos = line_text:find("%]", input.col_start + 1)
  local actual_col_end = bracket_pos and (bracket_pos - 1) or input.col_end

  -- Extract value from input area (between col_start and closing bracket)
  local raw_value = line_text:sub(input.col_start + 1, actual_col_end)

  -- Trim trailing spaces (but preserve leading spaces if user wants them)
  local value = raw_value:gsub("%s+$", "")

  -- Update stored value and col_end
  local old_value = im.values[im.active_input]
  im.values[im.active_input] = value

  -- Update col_end based on new content
  local default_width = input.default_width or input.width or 20
  local min_width = input.min_width or default_width
  local effective_width = math.max(default_width, min_width, #value)
  input.col_end = input.col_start + effective_width
  input.width = effective_width

  -- Callback if changed
  if im.on_value_change and value ~= old_value then
    im.on_value_change(im.active_input, value)
  end
end

---Get the current value of an input
---@param im InputManager The InputManager instance
---@param key string Input key
---@return string? value
function M.get_value(im, key)
  return im.values[key]
end

---Get all input values
---@param im InputManager The InputManager instance
---@return table<string, string> values Map of key -> value
function M.get_all_values(im)
  return vim.deepcopy(im.values)
end

---Set the value of an input
---@param im InputManager The InputManager instance
---@param key string Input key
---@param value string New value
function M.set_value(im, key, value)
  local input = im.inputs[key]
  if not input then return end

  im.values[key] = value or ""

  -- Update buffer content if buffer is valid
  if vim.api.nvim_buf_is_valid(im.bufnr) then
    M.render_input(im, key)
  end
end

-- ============================================================================
-- Rendering
-- ============================================================================

---Render an input field's value to the buffer (with dynamic width support)
---@param im InputManager The InputManager instance
---@param key string Input key
function M.render_input(im, key)
  local input = im.inputs[key]
  if not input then return end

  local value = im.values[key] or ""
  local placeholder = input.placeholder or ""
  local default_width = input.default_width or input.width or 20
  local min_width = input.min_width or default_width

  -- Determine display text and track placeholder state
  local display_text = value
  if value == "" and placeholder ~= "" then
    display_text = placeholder
    input.is_showing_placeholder = true
  else
    input.is_showing_placeholder = false
  end

  -- Calculate effective width: at least default_width, but expands for longer text
  local effective_width = math.max(default_width, min_width, #display_text)

  -- Pad to effective width (no truncation - expands if needed)
  if #display_text < effective_width then
    display_text = display_text .. string.rep(" ", effective_width - #display_text)
  end

  -- Get current line
  local lines = vim.api.nvim_buf_get_lines(im.bufnr, input.line - 1, input.line, false)
  if #lines == 0 then return end

  local line = lines[1]

  -- Find the actual closing bracket position in the current line
  local bracket_pos = line:find("%]", input.col_start + 1)
  if not bracket_pos then return end

  -- Update input's col_end and width for dynamic sizing
  input.col_end = input.col_start + effective_width
  input.width = effective_width

  -- Reconstruct the line with new input content
  local before = line:sub(1, input.col_start)  -- Everything up to and including "["
  local after = line:sub(bracket_pos + 1)  -- Everything after the "]"

  -- Build new line: before + display_text + "]" + after
  local new_line = before .. display_text .. "]" .. after

  -- Update buffer
  local was_modifiable = vim.api.nvim_buf_get_option(im.bufnr, 'modifiable')
  vim.api.nvim_buf_set_option(im.bufnr, 'modifiable', true)
  vim.api.nvim_buf_set_lines(im.bufnr, input.line - 1, input.line, false, {new_line})
  vim.api.nvim_buf_set_option(im.bufnr, 'modifiable', was_modifiable)

  -- Re-apply highlight for this input after width change
  local current_key = im.input_order[im.current_input_idx]
  Highlight.highlight_input(im, key, key == current_key)
end

---Render an input field in real-time while typing (preserves cursor position)
---@param im InputManager The InputManager instance
---@param key string Input key
function M.render_input_realtime(im, key)
  local input = im.inputs[key]
  if not input then return end

  local value = im.values[key] or ""
  local default_width = input.default_width or input.width or 20
  local min_width = input.min_width or default_width

  -- Calculate effective width: at least default_width, but expands for longer text
  local effective_width = math.max(default_width, min_width, #value)

  -- Pad value with spaces to effective width
  local display_text = value
  if #display_text < effective_width then
    display_text = display_text .. string.rep(" ", effective_width - #display_text)
  end

  -- Save cursor position (relative to input start)
  local cursor = vim.api.nvim_win_get_cursor(im.winid)
  local cursor_offset = cursor[2] - input.col_start

  -- Get current line
  local lines = vim.api.nvim_buf_get_lines(im.bufnr, input.line - 1, input.line, false)
  if #lines == 0 then return end

  local line = lines[1]

  -- Find the actual closing bracket position in the current line
  local bracket_pos = line:find("%]", input.col_start + 1)
  if not bracket_pos then return end

  -- Update input's col_end and width for dynamic sizing
  input.col_end = input.col_start + effective_width
  input.width = effective_width

  -- Reconstruct the line with new input content
  local before = line:sub(1, input.col_start)
  local after = line:sub(bracket_pos + 1)

  -- Build new line: before + display_text + "]" + after
  local new_line = before .. display_text .. "]" .. after

  -- Update buffer (already modifiable in insert mode)
  vim.api.nvim_buf_set_lines(im.bufnr, input.line - 1, input.line, false, {new_line})

  -- Restore cursor position
  local new_cursor_col = input.col_start + cursor_offset
  -- Clamp cursor to valid range (don't go past end of actual value)
  new_cursor_col = math.min(new_cursor_col, input.col_start + #value)
  new_cursor_col = math.max(new_cursor_col, input.col_start)
  vim.api.nvim_win_set_cursor(im.winid, {cursor[1], new_cursor_col})

  -- Re-apply highlight
  Highlight.highlight_input(im, key, true)
end

-- ============================================================================
-- Validation
-- ============================================================================

---Update validation settings for a specific input
---@param im InputManager The InputManager instance
---@param key string Input key
---@param settings table Validation settings
function M.update_input_settings(im, key, settings)
  local input = im.inputs[key]
  if not input then return end

  if settings.value_type ~= nil then
    input.value_type = settings.value_type
  end
  if settings.min_value ~= nil then
    input.min_value = settings.min_value
  end
  if settings.max_value ~= nil then
    input.max_value = settings.max_value
  end
  if settings.input_pattern ~= nil then
    input.input_pattern = settings.input_pattern
  end
  if settings.allow_negative ~= nil then
    input.allow_negative = settings.allow_negative
  end
end

---Update validation settings for multiple inputs at once
---@param im InputManager The InputManager instance
---@param settings_map table<string, table> Map of input key -> settings
function M.update_all_input_settings(im, settings_map)
  for key, settings in pairs(settings_map) do
    M.update_input_settings(im, key, settings)
  end
end

---Validate and clamp a value according to input settings
---@param im InputManager The InputManager instance
---@param key string Input key
---@param value string Raw input value
---@return string validated_value The validated/clamped value
function M.validate_input_value(im, key, value)
  local input = im.inputs[key]
  if not input then return value end

  -- If no validation settings, return as-is
  if not input.value_type or input.value_type == "text" then
    return value
  end

  -- Extract numeric value
  local num = nil
  if input.value_type == "integer" then
    local sign = ""
    if input.allow_negative ~= false and value:match("^%-") then
      sign = "-"
    end
    local digits = value:gsub("[^%d]", "")
    if digits ~= "" then
      num = tonumber(sign .. digits)
    end
  elseif input.value_type == "float" then
    local sign = ""
    if input.allow_negative ~= false and value:match("^%-") then
      sign = "-"
    end
    local cleaned = value:gsub("[^%d%.]", "")
    local first_dot = cleaned:find("%.")
    if first_dot then
      local before = cleaned:sub(1, first_dot)
      local after = cleaned:sub(first_dot + 1):gsub("%.", "")
      cleaned = before .. after
    end
    if cleaned ~= "" and cleaned ~= "." then
      num = tonumber(sign .. cleaned)
    end
  end

  -- If we couldn't parse a number, return empty
  if num == nil then
    return ""
  end

  -- Clamp to min/max
  if input.min_value ~= nil and num < input.min_value then
    num = input.min_value
  end
  if input.max_value ~= nil and num > input.max_value then
    num = input.max_value
  end

  -- Format output
  if input.value_type == "integer" then
    return tostring(math.floor(num + 0.5))
  else
    if num == math.floor(num) then
      return tostring(math.floor(num))
    else
      return string.format("%.2f", num):gsub("%.?0+$", "")
    end
  end
end

---Check if a character is allowed for the current input
---@param im InputManager The InputManager instance
---@param char string Single character to check
---@return boolean allowed Whether the character is allowed
function M.is_char_allowed(im, char)
  if not im.active_input then return true end

  local input = im.inputs[im.active_input]
  if not input then return true end

  -- Check custom pattern first
  if input.input_pattern then
    return char:match(input.input_pattern) ~= nil
  end

  -- Check based on value_type
  if input.value_type == "integer" then
    if char:match("[%d]") then return true end
    if input.allow_negative ~= false and char == "-" then
      local current = im.values[im.active_input] or ""
      return current == "" or current == input.placeholder
    end
    return false
  elseif input.value_type == "float" then
    if char:match("[%d]") then return true end
    if char == "." then
      local current = im.values[im.active_input] or ""
      return not current:find("%.")
    end
    if input.allow_negative ~= false and char == "-" then
      local current = im.values[im.active_input] or ""
      return current == "" or current == input.placeholder
    end
    return false
  end

  -- Default: allow all
  return true
end

---Get validated value for an input (call this on commit)
---@param im InputManager The InputManager instance
---@param key string Input key
---@return string value Validated value
function M.get_validated_value(im, key)
  local raw = im.values[key] or ""
  return M.validate_input_value(im, key, raw)
end

return M
