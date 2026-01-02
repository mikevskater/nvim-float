---@module 'nvim-float.input.dropdown'
---@brief Single dropdown handling for InputManager

local State = require("nvim-float.input.state")
local Highlight = require("nvim-float.input.highlight")
local Debug = require("nvim-float.debug")

local M = {}

-- ============================================================================
-- Display Update
-- ============================================================================

---Pad or truncate display text to target width
---@param text string Display text
---@param target_width number Target display width
---@return string padded_text
local function pad_or_truncate(text, target_width)
  local display_len = vim.fn.strdisplaywidth(text)
  if display_len < target_width then
    return text .. string.rep(" ", target_width - display_len)
  elseif display_len > target_width then
    local truncated = ""
    local current_width = 0
    local char_idx = 0
    while current_width < target_width - 1 do
      local char = vim.fn.strcharpart(text, char_idx, 1)
      if char == "" then break end
      local char_width = vim.fn.strdisplaywidth(char)
      if current_width + char_width > target_width - 1 then break end
      truncated = truncated .. char
      current_width = current_width + char_width
      char_idx = char_idx + 1
    end
    local pad_needed = target_width - 1 - vim.fn.strdisplaywidth(truncated)
    if pad_needed > 0 then
      truncated = truncated .. string.rep(" ", pad_needed)
    end
    return truncated .. "…"
  end
  return text
end

---Update dropdown display in parent buffer
---@param im InputManager The InputManager instance
---@param key string Dropdown key
function M.update_display(im, key)
  local dropdown = im.dropdowns[key]
  if not dropdown then return end

  -- Check if buffer is still valid
  if not im.bufnr or not vim.api.nvim_buf_is_valid(im.bufnr) then return end

  local value = im.dropdown_values[key]

  -- Find label for value
  local display_text = dropdown.placeholder or "(select)"
  local is_placeholder = true
  for _, opt in ipairs(dropdown.options) do
    if opt.value == value then
      display_text = opt.label
      is_placeholder = false
      break
    end
  end

  local text_width = dropdown.text_width or 18
  local padded_text = pad_or_truncate(display_text, text_width)

  -- Get current line
  local lines = vim.api.nvim_buf_get_lines(im.bufnr, dropdown.line - 1, dropdown.line, false)
  if #lines == 0 then return end

  local line = lines[1]
  local bracket_pos = line:find("%]", dropdown.col_start + 1)
  if not bracket_pos then return end

  -- Reconstruct line
  local before = line:sub(1, dropdown.col_start)
  local after = line:sub(bracket_pos + 1)
  local new_line = before .. padded_text .. " ▼]" .. after

  -- Update buffer
  local was_modifiable = vim.api.nvim_buf_get_option(im.bufnr, 'modifiable')
  vim.api.nvim_buf_set_option(im.bufnr, 'modifiable', true)
  vim.api.nvim_buf_set_lines(im.bufnr, dropdown.line - 1, dropdown.line, false, {new_line})
  vim.api.nvim_buf_set_option(im.bufnr, 'modifiable', was_modifiable)

  -- Update placeholder state and col_end
  dropdown.is_placeholder = is_placeholder
  local new_bracket_pos = new_line:find("%]", dropdown.col_start + 1)
  if new_bracket_pos then
    dropdown.col_end = new_bracket_pos
  end

  -- Re-apply highlights
  local hl_group = is_placeholder and "NvimFloatInputPlaceholder" or "NvimFloatInput"
  vim.api.nvim_buf_clear_namespace(im.bufnr, im._namespace, dropdown.line - 1, dropdown.line)

  local arrow_len = 4
  vim.api.nvim_buf_add_highlight(im.bufnr, im._namespace, hl_group,
    dropdown.line - 1, dropdown.col_start, dropdown.col_end - arrow_len)
  vim.api.nvim_buf_add_highlight(im.bufnr, im._namespace, "NvimFloatHint",
    dropdown.line - 1, dropdown.col_end - arrow_len, dropdown.col_end)
end

-- ============================================================================
-- Content Building
-- ============================================================================

---Build dropdown content using ContentBuilder
---@param im InputManager The InputManager instance
---@return ContentBuilder cb
local function build_content(im)
  local ContentBuilder = require('nvim-float.content')
  local cb = ContentBuilder.new()

  local key = im._dropdown_key
  local dropdown = im.dropdowns[key]
  if not dropdown then return cb end

  local filtered = im._dropdown_filtered_options or dropdown.options

  -- Calculate max label width
  local max_label_len = 0
  for _, opt in ipairs(filtered) do
    max_label_len = math.max(max_label_len, #opt.label)
  end

  for _, opt in ipairs(filtered) do
    local is_original = (opt.value == im._dropdown_original_value)
    local padded_label = opt.label .. string.rep(" ", max_label_len - #opt.label)

    if is_original then
      cb:spans({
        { text = " ", style = "normal" },
        { text = padded_label, style = "emphasis" },
        { text = " *", style = "success" },
      })
    else
      cb:spans({
        { text = " ", style = "normal" },
        { text = padded_label, style = "value" },
      })
    end
  end

  if #filtered == 0 then
    cb:styled(" (no matches)", "muted")
  end

  return cb
end

-- ============================================================================
-- Dropdown Operations
-- ============================================================================

---Open dropdown window
---@param im InputManager The InputManager instance
---@param key string Dropdown key
function M.open(im, key)
  Debug.log(string.format("[DROPDOWN DEBUG] open CALLED for key=%s", key))

  if State.dropdown_opening then
    Debug.log("[DROPDOWN DEBUG] open BLOCKED: another dropdown opening")
    return
  end

  local dropdown = im.dropdowns[key]
  if not dropdown then return end

  -- Set opening flags
  State.dropdown_opening = true
  State.dropdown_open_time = vim.loop.now()
  State.any_dropdown_open = true

  -- Store state
  im._dropdown_original_value = im.dropdown_values[key]
  im._dropdown_key = key
  im._dropdown_open = true
  im._dropdown_filter_text = ""
  im._dropdown_filtered_options = vim.deepcopy(dropdown.options)

  -- Find selected index
  im._dropdown_selected_idx = 1
  for i, opt in ipairs(dropdown.options) do
    if opt.value == im._dropdown_original_value then
      im._dropdown_selected_idx = i
      break
    end
  end

  -- Calculate position
  local win_info = vim.fn.getwininfo(im.winid)[1]
  if not win_info then return end

  local parent_row = win_info.winrow
  local parent_col = win_info.wincol
  local dropdown_row = parent_row + dropdown.line
  local dropdown_col = parent_col + dropdown.col_start - 1

  local width = (dropdown.text_width or dropdown.width) + 2
  local height = math.min(#dropdown.options, dropdown.max_height or 6)

  -- Build content
  local cb = build_content(im)
  local lines = cb:build_lines()

  -- Create float
  local UiFloat = require('nvim-float.window')
  im._dropdown_float = UiFloat.create(lines, {
    centered = false,
    relative = "editor",
    row = dropdown_row,
    col = dropdown_col,
    width = width,
    height = height,
    border = "rounded",
    zindex = UiFloat.ZINDEX.DROPDOWN,
    cursorline = true,
    focusable = true,
    enter = true,
    wrap = false,
    default_keymaps = false,
    scrollbar = true,
  })

  if not im._dropdown_float or not im._dropdown_float:is_valid() then
    im._dropdown_open = false
    im._dropdown_key = nil
    State.dropdown_opening = false
    return
  end

  -- Apply highlights
  im._dropdown_ns = vim.api.nvim_create_namespace("nvim_float_dropdown_content")
  cb:apply_to_buffer(im._dropdown_float.bufnr, im._dropdown_ns)

  -- Setup keymaps and autocmds
  M.setup_keymaps(im)
  M.setup_autocmds(im)

  -- Position cursor
  local selected_idx = im._dropdown_selected_idx
  local dropdown_float = im._dropdown_float
  vim.schedule(function()
    if dropdown_float and dropdown_float:is_valid() and selected_idx <= height then
      dropdown_float:set_cursor(selected_idx, 0)
      vim.cmd('redraw')
    end
  end)

  -- Clear opening flag
  vim.defer_fn(function()
    State.dropdown_opening = false
  end, 50)
end

---Close dropdown window
---@param im InputManager The InputManager instance
---@param cancel boolean Whether to cancel
function M.close(im, cancel)
  if not im._dropdown_open then return end

  State.dropdown_opening = false
  State.any_dropdown_open = false

  local key = im._dropdown_key

  -- Restore original value if cancelled
  if cancel and key and im._dropdown_original_value ~= nil then
    im.dropdown_values[key] = im._dropdown_original_value
    M.update_display(im, key)
  end

  -- Cleanup autocmds
  if im._dropdown_autocmd_group then
    pcall(vim.api.nvim_del_augroup_by_id, im._dropdown_autocmd_group)
    im._dropdown_autocmd_group = nil
  end

  -- Close float
  if im._dropdown_float then
    pcall(function() im._dropdown_float:close() end)
  end

  -- Reset state
  im._dropdown_open = false
  im._dropdown_key = nil
  im._dropdown_float = nil
  im._dropdown_ns = nil
  im._dropdown_selected_idx = 1
  im._dropdown_original_value = nil
  im._dropdown_filtered_options = nil
  im._dropdown_filter_text = ""

  -- Set cooldown
  State.global_dropdown_close_cooldown = true
  vim.defer_fn(function()
    State.global_dropdown_close_cooldown = false
  end, 200)

  -- Return focus
  if vim.api.nvim_win_is_valid(im.winid) then
    vim.api.nvim_set_current_win(im.winid)
  end

  if key then
    Highlight.highlight_current_field(im, key)
  end
end

---Select current option
---@param im InputManager The InputManager instance
function M.select(im)
  if not im._dropdown_open or not im._dropdown_key then return end

  local key = im._dropdown_key
  local dropdown = im.dropdowns[key]
  if not dropdown then return end

  local filtered = im._dropdown_filtered_options or dropdown.options
  local selected_opt = filtered[im._dropdown_selected_idx]

  if selected_opt then
    local original_value = im._dropdown_original_value
    im.dropdown_values[key] = selected_opt.value

    if im.on_dropdown_change and selected_opt.value ~= original_value then
      im.on_dropdown_change(key, selected_opt.value)
    end
  end

  M.close(im, false)
end

---Navigate dropdown selection
---@param im InputManager The InputManager instance
---@param direction number 1 for down, -1 for up
function M.navigate(im, direction)
  if not im._dropdown_open then return end

  local filtered = im._dropdown_filtered_options or {}
  if #filtered == 0 then return end

  im._dropdown_selected_idx = im._dropdown_selected_idx + direction

  -- Wrap around
  if im._dropdown_selected_idx < 1 then
    im._dropdown_selected_idx = #filtered
  elseif im._dropdown_selected_idx > #filtered then
    im._dropdown_selected_idx = 1
  end

  -- Move cursor
  if im._dropdown_float and im._dropdown_float:is_valid() then
    im._dropdown_float:set_cursor(im._dropdown_selected_idx, 0)
  end

  -- Live preview
  local selected_opt = filtered[im._dropdown_selected_idx]
  if selected_opt and im._dropdown_key then
    im.dropdown_values[im._dropdown_key] = selected_opt.value
    M.update_display(im, im._dropdown_key)
  end
end

---Filter dropdown options
---@param im InputManager The InputManager instance
---@param char string Character to add
function M.filter(im, char)
  if not im._dropdown_open or not im._dropdown_key then return end

  local dropdown = im.dropdowns[im._dropdown_key]
  if not dropdown then return end

  im._dropdown_filter_text = im._dropdown_filter_text .. char
  local filter_lower = im._dropdown_filter_text:lower()

  im._dropdown_filtered_options = {}
  for _, opt in ipairs(dropdown.options) do
    if opt.label:lower():find(filter_lower, 1, true) then
      table.insert(im._dropdown_filtered_options, opt)
    end
  end

  im._dropdown_selected_idx = 1
  M.render(im)

  -- Update window height
  local height = math.min(#im._dropdown_filtered_options, dropdown.max_height or 6)
  height = math.max(height, 1)

  if im._dropdown_float and im._dropdown_float:is_valid() then
    vim.api.nvim_win_set_config(im._dropdown_float.winid, { height = height })

    if #im._dropdown_filtered_options > 0 then
      im._dropdown_float:set_cursor(1, 0)
      local first_opt = im._dropdown_filtered_options[1]
      if first_opt then
        im.dropdown_values[im._dropdown_key] = first_opt.value
        M.update_display(im, im._dropdown_key)
      end
    end
  end
end

---Clear dropdown filter
---@param im InputManager The InputManager instance
function M.clear_filter(im)
  if not im._dropdown_open or not im._dropdown_key then return end

  local dropdown = im.dropdowns[im._dropdown_key]
  if not dropdown then return end

  im._dropdown_filter_text = ""
  im._dropdown_filtered_options = vim.deepcopy(dropdown.options)
  im._dropdown_selected_idx = 1

  M.render(im)

  local height = math.min(#dropdown.options, dropdown.max_height or 6)
  if im._dropdown_float and im._dropdown_float:is_valid() then
    vim.api.nvim_win_set_config(im._dropdown_float.winid, { height = height })
    im._dropdown_float:set_cursor(1, 0)
  end
end

---Render dropdown content
---@param im InputManager The InputManager instance
function M.render(im)
  if not im._dropdown_float or not im._dropdown_float:is_valid() then return end

  local cb = build_content(im)
  local lines = cb:build_lines()

  im._dropdown_float:update_lines(lines)

  if im._dropdown_ns then
    cb:apply_to_buffer(im._dropdown_float.bufnr, im._dropdown_ns)
  end
end

-- ============================================================================
-- Keymaps and Autocmds
-- ============================================================================

---Setup keymaps for dropdown
---@param im InputManager The InputManager instance
function M.setup_keymaps(im)
  if not im._dropdown_float or not im._dropdown_float:is_valid() then return end

  local bufnr = im._dropdown_float.bufnr
  local opts = { buffer = bufnr, noremap = true, silent = true, nowait = true }

  vim.keymap.set('n', 'j', function() M.navigate(im, 1) end, opts)
  vim.keymap.set('n', 'k', function() M.navigate(im, -1) end, opts)
  vim.keymap.set('n', '<Down>', function() M.navigate(im, 1) end, opts)
  vim.keymap.set('n', '<Up>', function() M.navigate(im, -1) end, opts)
  vim.keymap.set('n', '<CR>', function() M.select(im) end, opts)

  vim.keymap.set('n', '<LeftRelease>', function()
    vim.schedule(function()
      local cursor = vim.api.nvim_win_get_cursor(0)
      local row = cursor[1]
      local dropdown = im.dropdowns[im._dropdown_key]
      local filtered = im._dropdown_filtered_options or (dropdown and dropdown.options or {})
      if row >= 1 and row <= #filtered then
        im._dropdown_selected_idx = row
        M.select(im)
      end
    end)
  end, opts)

  vim.keymap.set('n', '<Esc>', function() M.close(im, true) end, opts)
  vim.keymap.set('n', 'q', function() M.close(im, true) end, opts)
  vim.keymap.set('n', '<BS>', function() M.clear_filter(im) end, opts)

  -- Type-to-filter
  local skip_chars = {
    j = true, k = true, h = true, l = true, w = true, b = true, e = true,
    ['0'] = true, ['$'] = true, ['^'] = true, q = true,
  }
  for char_code = 32, 126 do
    local char = string.char(char_code)
    if not skip_chars[char] then
      vim.keymap.set('n', char, function() M.filter(im, char) end, opts)
    end
  end
end

---Setup autocmds for focus-lost detection
---@param im InputManager The InputManager instance
function M.setup_autocmds(im)
  if not im._dropdown_float or not im._dropdown_float:is_valid() then return end

  local bufnr = im._dropdown_float.bufnr
  local autocmd_group = vim.api.nvim_create_augroup("NvimFloatDropdown_" .. bufnr, { clear = true })
  im._dropdown_autocmd_group = autocmd_group

  local SETTLE_TIME_MS = 150

  vim.api.nvim_create_autocmd("WinLeave", {
    group = autocmd_group,
    buffer = bufnr,
    callback = function()
      local elapsed = vim.loop.now() - State.dropdown_open_time
      if elapsed < SETTLE_TIME_MS then return end

      vim.schedule(function()
        local current_win = vim.api.nvim_get_current_win()
        if current_win ~= im.winid then
          M.close(im, true)
        end
      end)
    end,
  })

  vim.api.nvim_create_autocmd("BufLeave", {
    group = autocmd_group,
    buffer = bufnr,
    callback = function()
      local elapsed = vim.loop.now() - State.dropdown_open_time
      if elapsed < SETTLE_TIME_MS then return end

      vim.schedule(function()
        M.close(im, true)
      end)
    end,
  })
end

-- ============================================================================
-- Value Access
-- ============================================================================

---Get dropdown value
---@param im InputManager The InputManager instance
---@param key string Dropdown key
---@return string? value
function M.get_value(im, key)
  return im.dropdown_values[key]
end

---Set dropdown value
---@param im InputManager The InputManager instance
---@param key string Dropdown key
---@param value string New value
function M.set_value(im, key, value)
  local dropdown = im.dropdowns[key]
  if not dropdown then return end

  im.dropdown_values[key] = value
  M.update_display(im, key)
end

return M
