---@module 'nvim-float.input.multi_dropdown'
---@brief Multi-dropdown handling for InputManager

local State = require("nvim-float.input.state")
local Highlight = require("nvim-float.input.highlight")
local Debug = require("nvim-float.debug")

local M = {}

-- ============================================================================
-- Display Update
-- ============================================================================

---Pad or truncate display text
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

---Update multi-dropdown display in parent buffer
---@param im InputManager The InputManager instance
---@param key string Multi-dropdown key
function M.update_display(im, key)
  local multi_dropdown = im.multi_dropdowns[key]
  if not multi_dropdown then return end

  if not im.bufnr or not vim.api.nvim_buf_is_valid(im.bufnr) then return end

  local values = im.multi_dropdown_values[key] or {}

  -- Build display text
  local display_text
  local is_placeholder = (#values == 0)

  if #values == 0 then
    display_text = multi_dropdown.placeholder or "(none selected)"
  elseif multi_dropdown.display_mode == "list" then
    local labels = {}
    for _, v in ipairs(values) do
      for _, opt in ipairs(multi_dropdown.options) do
        if opt.value == v then
          table.insert(labels, opt.label)
          break
        end
      end
    end
    display_text = table.concat(labels, ", ")
  else  -- "count" mode
    if #values == #multi_dropdown.options then
      display_text = "All (" .. #values .. ")"
    else
      display_text = #values .. " selected"
    end
  end

  local text_width = multi_dropdown.text_width or 18
  local padded_text = pad_or_truncate(display_text, text_width)

  -- Get current line
  local lines = vim.api.nvim_buf_get_lines(im.bufnr, multi_dropdown.line - 1, multi_dropdown.line, false)
  if #lines == 0 then return end

  local line = lines[1]
  local bracket_pos = line:find("%]", multi_dropdown.col_start + 1)
  if not bracket_pos then return end

  -- Reconstruct line
  local before = line:sub(1, multi_dropdown.col_start)
  local after = line:sub(bracket_pos + 1)
  local new_line = before .. padded_text .. " ▾]" .. after

  -- Update buffer
  local was_modifiable = vim.api.nvim_buf_get_option(im.bufnr, 'modifiable')
  vim.api.nvim_buf_set_option(im.bufnr, 'modifiable', true)
  vim.api.nvim_buf_set_lines(im.bufnr, multi_dropdown.line - 1, multi_dropdown.line, false, {new_line})
  vim.api.nvim_buf_set_option(im.bufnr, 'modifiable', was_modifiable)

  multi_dropdown.is_placeholder = is_placeholder
  local new_bracket_pos = new_line:find("%]", multi_dropdown.col_start + 1)
  if new_bracket_pos then
    multi_dropdown.col_end = new_bracket_pos
  end

  -- Re-apply highlights
  local hl_group = is_placeholder and "NvimFloatInputPlaceholder" or "NvimFloatInput"
  vim.api.nvim_buf_clear_namespace(im.bufnr, im._namespace, multi_dropdown.line - 1, multi_dropdown.line)

  local arrow_len = 4
  vim.api.nvim_buf_add_highlight(im.bufnr, im._namespace, hl_group,
    multi_dropdown.line - 1, multi_dropdown.col_start, multi_dropdown.col_end - arrow_len)
  vim.api.nvim_buf_add_highlight(im.bufnr, im._namespace, "NvimFloatHint",
    multi_dropdown.line - 1, multi_dropdown.col_end - arrow_len, multi_dropdown.col_end)
end

-- ============================================================================
-- Content Building
-- ============================================================================

---Build multi-dropdown content
---@param im InputManager The InputManager instance
---@return ContentBuilder cb
local function build_content(im)
  local ContentBuilder = require('nvim-float.content_builder')
  local cb = ContentBuilder.new()

  local key = im._multi_dropdown_key
  local multi_dropdown = im.multi_dropdowns[key]
  if not multi_dropdown then return cb end

  local pending = im._multi_dropdown_pending_values or {}
  local options = multi_dropdown.options

  local function is_selected(value)
    for _, v in ipairs(pending) do
      if v == value then return true end
    end
    return false
  end

  -- Calculate max label width
  local max_label_len = 0
  for _, opt in ipairs(options) do
    max_label_len = math.max(max_label_len, #opt.label)
  end
  if multi_dropdown.select_all_option then
    max_label_len = math.max(max_label_len, 10)
  end

  -- Select All option
  if multi_dropdown.select_all_option then
    local all_selected = (#pending == #options)
    local checkbox = all_selected and "[x]" or "[ ]"
    local label = "Select All"
    local padded = label .. string.rep(" ", max_label_len - #label)

    cb:spans({
      { text = " " .. checkbox .. " ", style = all_selected and "success" or "muted" },
      { text = padded, style = "emphasis" },
    })

    cb:styled(" " .. string.rep("─", max_label_len + 4), "muted")
  end

  -- Options
  for _, opt in ipairs(options) do
    local selected = is_selected(opt.value)
    local checkbox = selected and "[x]" or "[ ]"
    local padded = opt.label .. string.rep(" ", max_label_len - #opt.label)

    cb:spans({
      { text = " " .. checkbox .. " ", style = selected and "success" or "muted" },
      { text = padded, style = selected and "value" or "normal" },
    })
  end

  return cb
end

-- ============================================================================
-- Multi-Dropdown Operations
-- ============================================================================

---Open multi-dropdown window
---@param im InputManager The InputManager instance
---@param key string Multi-dropdown key
function M.open(im, key)
  Debug.log(string.format("[DROPDOWN DEBUG] multi open CALLED for key=%s", key))

  if State.dropdown_opening then
    Debug.log("[DROPDOWN DEBUG] multi open BLOCKED")
    return
  end

  local multi_dropdown = im.multi_dropdowns[key]
  if not multi_dropdown then return end

  State.dropdown_opening = true
  State.dropdown_open_time = vim.loop.now()
  State.any_dropdown_open = true

  im._multi_dropdown_original_values = vim.deepcopy(im.multi_dropdown_values[key] or {})
  im._multi_dropdown_pending_values = vim.deepcopy(im._multi_dropdown_original_values)
  im._multi_dropdown_key = key
  im._multi_dropdown_open = true
  im._multi_dropdown_cursor_idx = 1

  -- Calculate position
  local win_info = vim.fn.getwininfo(im.winid)[1]
  if not win_info then return end

  local parent_row = win_info.winrow
  local parent_col = win_info.wincol
  local dropdown_row = parent_row + multi_dropdown.line
  local dropdown_col = parent_col + multi_dropdown.col_start - 1

  local width = (multi_dropdown.text_width or multi_dropdown.width) + 4
  local option_count = #multi_dropdown.options
  if multi_dropdown.select_all_option then
    option_count = option_count + 2
  end
  local height = math.min(option_count, multi_dropdown.max_height or 8)

  local cb = build_content(im)
  local lines = cb:build_lines()

  local UiFloat = require('nvim-float.float')
  im._multi_dropdown_float = UiFloat.create(lines, {
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

  if not im._multi_dropdown_float or not im._multi_dropdown_float:is_valid() then
    im._multi_dropdown_open = false
    im._multi_dropdown_key = nil
    State.dropdown_opening = false
    return
  end

  im._multi_dropdown_ns = vim.api.nvim_create_namespace("nvim_float_multi_dropdown_content")
  cb:apply_to_buffer(im._multi_dropdown_float.bufnr, im._multi_dropdown_ns)

  im._multi_dropdown_float:set_cursor(1, 0)

  M.setup_keymaps(im)
  M.setup_autocmds(im)

  vim.defer_fn(function()
    State.dropdown_opening = false
  end, 50)
end

---Close multi-dropdown window
---@param im InputManager The InputManager instance
---@param cancel boolean Whether to cancel
function M.close(im, cancel)
  if not im._multi_dropdown_open then return end

  State.dropdown_opening = false
  State.any_dropdown_open = false

  local key = im._multi_dropdown_key

  if cancel and key and im._multi_dropdown_original_values then
    im.multi_dropdown_values[key] = vim.deepcopy(im._multi_dropdown_original_values)
  end

  if im._multi_dropdown_autocmd_group then
    pcall(vim.api.nvim_del_augroup_by_id, im._multi_dropdown_autocmd_group)
    im._multi_dropdown_autocmd_group = nil
  end

  if im._multi_dropdown_float then
    pcall(function() im._multi_dropdown_float:close() end)
  end

  im._multi_dropdown_open = false
  im._multi_dropdown_key = nil
  im._multi_dropdown_float = nil
  im._multi_dropdown_ns = nil
  im._multi_dropdown_cursor_idx = 1
  im._multi_dropdown_original_values = nil
  im._multi_dropdown_pending_values = nil

  State.global_dropdown_close_cooldown = true
  vim.defer_fn(function()
    State.global_dropdown_close_cooldown = false
  end, 200)

  if vim.api.nvim_win_is_valid(im.winid) then
    vim.api.nvim_set_current_win(im.winid)
  end

  if key then
    Highlight.highlight_current_field(im, key)
  end
end

---Confirm selection
---@param im InputManager The InputManager instance
function M.confirm(im)
  if not im._multi_dropdown_open or not im._multi_dropdown_key then return end

  local key = im._multi_dropdown_key
  local old_values = vim.deepcopy(im.multi_dropdown_values[key] or {})

  im.multi_dropdown_values[key] = vim.deepcopy(im._multi_dropdown_pending_values or {})
  M.update_display(im, key)

  if im.on_multi_dropdown_change then
    local new_values = im.multi_dropdown_values[key]
    local changed = (#old_values ~= #new_values)
    if not changed then
      for i, v in ipairs(old_values) do
        if new_values[i] ~= v then
          changed = true
          break
        end
      end
    end
    if changed then
      im.on_multi_dropdown_change(key, new_values)
    end
  end

  M.close(im, false)
end

---Toggle option at current cursor
---@param im InputManager The InputManager instance
function M.toggle_option(im)
  if not im._multi_dropdown_open or not im._multi_dropdown_key then return end

  local multi_dropdown = im.multi_dropdowns[im._multi_dropdown_key]
  if not multi_dropdown then return end

  local cursor_idx = im._multi_dropdown_cursor_idx
  local has_select_all = multi_dropdown.select_all_option

  if has_select_all then
    if cursor_idx == 1 then
      M.toggle_select_all(im)
      return
    elseif cursor_idx == 2 then
      return  -- Separator
    else
      cursor_idx = cursor_idx - 2
    end
  end

  local opt = multi_dropdown.options[cursor_idx]
  if not opt then return end

  local pending = im._multi_dropdown_pending_values or {}
  local found_idx = nil
  for i, v in ipairs(pending) do
    if v == opt.value then
      found_idx = i
      break
    end
  end

  if found_idx then
    table.remove(pending, found_idx)
  else
    table.insert(pending, opt.value)
  end

  im._multi_dropdown_pending_values = pending
  M.render(im)
end

---Toggle select all
---@param im InputManager The InputManager instance
function M.toggle_select_all(im)
  if not im._multi_dropdown_open or not im._multi_dropdown_key then return end

  local multi_dropdown = im.multi_dropdowns[im._multi_dropdown_key]
  if not multi_dropdown then return end

  local pending = im._multi_dropdown_pending_values or {}
  local all_selected = (#pending == #multi_dropdown.options)

  if all_selected then
    im._multi_dropdown_pending_values = {}
  else
    im._multi_dropdown_pending_values = {}
    for _, opt in ipairs(multi_dropdown.options) do
      table.insert(im._multi_dropdown_pending_values, opt.value)
    end
  end

  M.render(im)
end

---Navigate selection
---@param im InputManager The InputManager instance
---@param direction number 1 for down, -1 for up
function M.navigate(im, direction)
  if not im._multi_dropdown_open then return end

  local multi_dropdown = im.multi_dropdowns[im._multi_dropdown_key]
  if not multi_dropdown then return end

  local total_lines = #multi_dropdown.options
  if multi_dropdown.select_all_option then
    total_lines = total_lines + 2
  end

  im._multi_dropdown_cursor_idx = im._multi_dropdown_cursor_idx + direction

  -- Skip separator
  if multi_dropdown.select_all_option and im._multi_dropdown_cursor_idx == 2 then
    im._multi_dropdown_cursor_idx = im._multi_dropdown_cursor_idx + direction
  end

  -- Wrap
  if im._multi_dropdown_cursor_idx < 1 then
    im._multi_dropdown_cursor_idx = total_lines
  elseif im._multi_dropdown_cursor_idx > total_lines then
    im._multi_dropdown_cursor_idx = 1
  end

  if im._multi_dropdown_float and im._multi_dropdown_float:is_valid() then
    im._multi_dropdown_float:set_cursor(im._multi_dropdown_cursor_idx, 0)
  end
end

---Render content
---@param im InputManager The InputManager instance
function M.render(im)
  if not im._multi_dropdown_float or not im._multi_dropdown_float:is_valid() then return end

  local cb = build_content(im)
  local lines = cb:build_lines()

  im._multi_dropdown_float:update_lines(lines)

  if im._multi_dropdown_ns then
    cb:apply_to_buffer(im._multi_dropdown_float.bufnr, im._multi_dropdown_ns)
  end
end

-- ============================================================================
-- Keymaps and Autocmds
-- ============================================================================

---Setup keymaps
---@param im InputManager The InputManager instance
function M.setup_keymaps(im)
  if not im._multi_dropdown_float or not im._multi_dropdown_float:is_valid() then return end

  local bufnr = im._multi_dropdown_float.bufnr
  local opts = { buffer = bufnr, noremap = true, silent = true, nowait = true }

  vim.keymap.set('n', 'j', function() M.navigate(im, 1) end, opts)
  vim.keymap.set('n', 'k', function() M.navigate(im, -1) end, opts)
  vim.keymap.set('n', '<Down>', function() M.navigate(im, 1) end, opts)
  vim.keymap.set('n', '<Up>', function() M.navigate(im, -1) end, opts)
  vim.keymap.set('n', '<Space>', function() M.toggle_option(im) end, opts)
  vim.keymap.set('n', 'x', function() M.toggle_option(im) end, opts)

  vim.keymap.set('n', '<LeftRelease>', function()
    vim.schedule(function()
      local cursor = vim.api.nvim_win_get_cursor(0)
      local row = cursor[1]
      local multi_dropdown = im.multi_dropdowns[im._multi_dropdown_key]
      if not multi_dropdown then return end

      local has_select_all = multi_dropdown.select_all_option
      local header_rows = has_select_all and 2 or 0
      local max_row = #multi_dropdown.options + header_rows

      if row >= 1 and row <= max_row then
        im._multi_dropdown_cursor_idx = row
        M.toggle_option(im)

        -- Auto-apply
        local key = im._multi_dropdown_key
        if key then
          local old_values = vim.deepcopy(im.multi_dropdown_values[key] or {})
          im.multi_dropdown_values[key] = vim.deepcopy(im._multi_dropdown_pending_values or {})
          im._multi_dropdown_original_values = vim.deepcopy(im._multi_dropdown_pending_values or {})
          M.update_display(im, key)

          if im.on_multi_dropdown_change then
            local new_values = im.multi_dropdown_values[key]
            local changed = (#old_values ~= #new_values)
            if not changed then
              for i, v in ipairs(old_values) do
                if new_values[i] ~= v then
                  changed = true
                  break
                end
              end
            end
            if changed then
              im.on_multi_dropdown_change(key, new_values)
            end
          end
        end
      end
    end)
  end, opts)

  vim.keymap.set('n', 'a', function() M.toggle_select_all(im) end, opts)
  vim.keymap.set('n', '<CR>', function() M.confirm(im) end, opts)
  vim.keymap.set('n', '<Esc>', function() M.close(im, true) end, opts)
  vim.keymap.set('n', 'q', function() M.close(im, true) end, opts)
end

---Setup autocmds
---@param im InputManager The InputManager instance
function M.setup_autocmds(im)
  if not im._multi_dropdown_float or not im._multi_dropdown_float:is_valid() then return end

  local bufnr = im._multi_dropdown_float.bufnr
  local autocmd_group = vim.api.nvim_create_augroup("NvimFloatMultiDropdown_" .. bufnr, { clear = true })
  im._multi_dropdown_autocmd_group = autocmd_group

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

---Get values
---@param im InputManager The InputManager instance
---@param key string Multi-dropdown key
---@return string[]? values
function M.get_values(im, key)
  return im.multi_dropdown_values[key]
end

---Set values
---@param im InputManager The InputManager instance
---@param key string Multi-dropdown key
---@param values string[] New values
function M.set_values(im, key, values)
  local multi_dropdown = im.multi_dropdowns[key]
  if not multi_dropdown then return end

  im.multi_dropdown_values[key] = vim.deepcopy(values)
  M.update_display(im, key)
end

return M
