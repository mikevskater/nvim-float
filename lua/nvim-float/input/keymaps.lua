---@module 'nvim-float.input.keymaps'
---@brief Keymap setup for InputManager

local State = require("nvim-float.input.state")
local Debug = require("nvim-float.debug")

local M = {}

-- Lazy-load modules to avoid circular dependencies
local _editing, _navigation, _dropdown, _multi_dropdown

local function get_editing()
  if not _editing then _editing = require("nvim-float.input.editing") end
  return _editing
end

local function get_navigation()
  if not _navigation then _navigation = require("nvim-float.input.navigation") end
  return _navigation
end

local function get_dropdown()
  if not _dropdown then _dropdown = require("nvim-float.input.dropdown") end
  return _dropdown
end

local function get_multi_dropdown()
  if not _multi_dropdown then _multi_dropdown = require("nvim-float.input.multi_dropdown") end
  return _multi_dropdown
end

-- ============================================================================
-- Main Keymap Setup
-- ============================================================================

---Setup keymaps for input navigation
---@param im InputManager The InputManager instance
function M.setup_input_keymaps(im)
  local opts = { buffer = im.bufnr, noremap = true, silent = true }

  -- Helper function to activate field at cursor position
  local function activate_field_at_cursor(source)
    local cursor = vim.api.nvim_win_get_cursor(im.winid)
    local row = cursor[1]
    local col = cursor[2]

    Debug.log(string.format("[DROPDOWN DEBUG] activate_field_at_cursor called from: %s, row=%d, col=%d", source or "unknown", row, col))

    -- First check if cursor is directly on an input
    for key, input in pairs(im.inputs) do
      if input.line == row and col >= input.col_start and col < input.col_end then
        Debug.log(string.format("[DROPDOWN DEBUG] Activating INPUT: %s", key))
        get_editing().enter_input_mode(im, key)
        return true
      end
    end

    -- Check if cursor is directly on a dropdown
    for key, dropdown in pairs(im.dropdowns) do
      if dropdown.line == row and col >= dropdown.col_start and col < dropdown.col_end then
        Debug.log(string.format("[DROPDOWN DEBUG] Activating DROPDOWN: %s", key))
        get_dropdown().open(im, key)
        return true
      end
    end

    -- Check if cursor is directly on a multi-dropdown
    for key, multi_dropdown in pairs(im.multi_dropdowns) do
      if multi_dropdown.line == row and col >= multi_dropdown.col_start and col < multi_dropdown.col_end then
        Debug.log(string.format("[DROPDOWN DEBUG] Activating MULTI-DROPDOWN: %s", key))
        get_multi_dropdown().open(im, key)
        return true
      end
    end

    Debug.log("[DROPDOWN DEBUG] No field found at cursor position")
    return false
  end

  -- Normal mode: Enter activates field under cursor (or at current index)
  vim.keymap.set('n', '<CR>', function()
    Debug.log("[DROPDOWN DEBUG] <CR> keymap triggered")
    if not activate_field_at_cursor("<CR> keymap") then
      -- Otherwise, activate the current tracked field
      if #im._field_order > 0 then
        local current_key = im._field_order[im.current_field_idx]
        if current_key then
          Debug.log(string.format("[DROPDOWN DEBUG] <CR> fallback to activate_field: %s", current_key))
          get_navigation().activate_field(im, current_key)
        end
      end
    end
  end, opts)

  -- Mouse click: activate field under mouse cursor
  vim.keymap.set('n', '<LeftRelease>', function()
    Debug.log(string.format("[DROPDOWN DEBUG] <LeftRelease> keymap triggered, cooldown=%s, any_open=%s, dropdown=%s, multi=%s",
      tostring(State.global_dropdown_close_cooldown), tostring(State.any_dropdown_open),
      tostring(im._dropdown_open), tostring(im._multi_dropdown_open)))

    -- If a dropdown is currently open on THIS InputManager, close it
    if im._dropdown_open then
      Debug.log("[DROPDOWN DEBUG] <LeftRelease> closing open dropdown")
      get_dropdown().close(im, true)
      return
    end
    if im._multi_dropdown_open then
      Debug.log("[DROPDOWN DEBUG] <LeftRelease> closing open multi-dropdown")
      get_multi_dropdown().close(im, true)
      return
    end

    -- If a dropdown is open on ANY InputManager, don't open a new one
    if State.any_dropdown_open then
      Debug.log("[DROPDOWN DEBUG] <LeftRelease> BLOCKED: dropdown open on another panel")
      return
    end

    -- Mouse click already moves cursor, so just activate field at cursor
    vim.schedule(function()
      if State.global_dropdown_close_cooldown then
        Debug.log("[DROPDOWN DEBUG] <LeftRelease> BLOCKED by global cooldown")
        return
      end
      activate_field_at_cursor("<LeftRelease> keymap (scheduled)")
    end)
  end, opts)

  -- Normal mode: j/Down moves to next input
  vim.keymap.set('n', 'j', function()
    get_navigation().next_input(im)
  end, opts)

  vim.keymap.set('n', '<Down>', function()
    get_navigation().next_input(im)
  end, opts)

  -- Normal mode: k/Up moves to previous input
  vim.keymap.set('n', 'k', function()
    get_navigation().prev_input(im)
  end, opts)

  vim.keymap.set('n', '<Up>', function()
    get_navigation().prev_input(im)
  end, opts)

  -- Normal mode Tab/Shift-Tab: also move between inputs
  vim.keymap.set('n', '<Tab>', function()
    get_navigation().next_input(im)
  end, opts)

  vim.keymap.set('n', '<S-Tab>', function()
    get_navigation().prev_input(im)
  end, opts)

  -- Insert mode Enter: confirm/exit input
  vim.keymap.set('i', '<CR>', function()
    vim.cmd("stopinsert")
    vim.schedule(function()
      if im.on_submit then
        im.on_submit()
      end
    end)
  end, opts)

  -- Insert mode Tab/Shift-Tab: move to next/prev input
  vim.keymap.set('i', '<Tab>', function()
    get_navigation().next_input(im)
  end, opts)

  vim.keymap.set('i', '<S-Tab>', function()
    get_navigation().prev_input(im)
  end, opts)

  -- Insert mode Escape: exit input mode
  vim.keymap.set('i', '<Esc>', function()
    vim.cmd("stopinsert")
  end, opts)

  -- Prevent cursor from leaving input bounds in insert mode
  vim.keymap.set('i', '<Left>', function()
    local cursor = vim.api.nvim_win_get_cursor(im.winid)
    local input = im.inputs[im.active_input]
    if input and cursor[2] > input.col_start then
      vim.api.nvim_win_set_cursor(im.winid, {cursor[1], cursor[2] - 1})
    end
  end, opts)

  vim.keymap.set('i', '<Right>', function()
    local cursor = vim.api.nvim_win_get_cursor(im.winid)
    local input = im.inputs[im.active_input]
    if input then
      local value = im.values[im.active_input] or ""
      local max_col = input.col_start + #value
      if cursor[2] < max_col then
        vim.api.nvim_win_set_cursor(im.winid, {cursor[1], cursor[2] + 1})
      end
    end
  end, opts)

  -- Prevent Home/End from going outside input
  vim.keymap.set('i', '<Home>', function()
    local input = im.inputs[im.active_input]
    if input then
      vim.api.nvim_win_set_cursor(im.winid, {input.line, input.col_start})
    end
  end, opts)

  vim.keymap.set('i', '<End>', function()
    local input = im.inputs[im.active_input]
    if input then
      local value = im.values[im.active_input] or ""
      vim.api.nvim_win_set_cursor(im.winid, {input.line, input.col_start + #value})
    end
  end, opts)

  -- Handle backspace at start of input
  vim.keymap.set('i', '<BS>', function()
    local cursor = vim.api.nvim_win_get_cursor(im.winid)
    local input = im.inputs[im.active_input]
    if input and cursor[2] > input.col_start then
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<BS>', true, false, true), 'n', false)
    end
  end, opts)
end

return M
