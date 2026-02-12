---@module 'nvim-float.container.multi_dropdown'
---@brief EmbeddedMultiDropdown - A multi-select dropdown implemented as an embedded container
---
---Display: shows count or comma-separated values
---Selection list has checkbox toggles (Space/Enter to toggle)

local EmbeddedContainer = require("nvim-float.container")

---@class EmbeddedMultiDropdownConfig
---@field key string Unique identifier
---@field row number 0-indexed row offset within parent content area
---@field col number 0-indexed col offset within parent content area
---@field width number Display width in columns
---@field parent_winid number Parent window ID
---@field parent_float FloatWindow Parent FloatWindow instance
---@field zindex_offset number? Added to parent zindex (default: 5)
---@field options EmbeddedDropdownOption[] Array of { value, label }
---@field selected string[]? Initially selected values
---@field placeholder string? Placeholder text when nothing selected
---@field max_height number? Maximum height for options list (default: 10)
---@field display_mode "count"|"list"? How to display selections (default: "count")
---@field on_change fun(key: string, values: string[])? Callback when selections change
---@field winhighlight string? Custom window highlight groups

---@class EmbeddedMultiDropdown
---A multi-select dropdown container
local EmbeddedMultiDropdown = {}
EmbeddedMultiDropdown.__index = EmbeddedMultiDropdown

local ARROW_CHAR = " \u{25BC}"  -- ▼
local ARROW_WIDTH = 2
local CHECK_ON = "\u{25C9} "    -- ◉
local CHECK_OFF = "\u{25CB} "   -- ○
local CHECK_WIDTH = 2

-- ============================================================================
-- Constructor
-- ============================================================================

---Create a new embedded multi-dropdown
---@param config EmbeddedMultiDropdownConfig
---@return EmbeddedMultiDropdown
function EmbeddedMultiDropdown.new(config)
  local self = setmetatable({}, EmbeddedMultiDropdown)

  self.key = config.key
  self._config = config
  self._values = vim.deepcopy(config.selected or {})
  self._options = config.options or {}
  self._placeholder = config.placeholder or "Select..."
  self._max_height = config.max_height or 10
  self._display_mode = config.display_mode or "count"
  self._list_open = false
  self._list_bufnr = nil
  self._list_winid = nil
  self._pending_values = nil
  self._list_autocmd_group = nil

  -- Create the display container (1 line showing current selection summary)
  self._container = EmbeddedContainer.new({
    name = "multi_dropdown_" .. config.key,
    row = config.row,
    col = config.col,
    width = config.width,
    height = 1,
    parent_winid = config.parent_winid,
    parent_float = config.parent_float,
    zindex_offset = config.zindex_offset,
    border = "none",
    focusable = true,
    scrollbar = false,
    modifiable = false,
    cursorline = false,
    winhighlight = config.winhighlight
      or 'Normal:NvimFloatInput,CursorLine:NvimFloatInput',
  })

  -- Setup keymaps on display container
  if self._container.bufnr and vim.api.nvim_buf_is_valid(self._container.bufnr) then
    vim.keymap.set('n', '<CR>', function()
      self:open_list()
    end, { buffer = self._container.bufnr, noremap = true, silent = true, desc = "Open multi-dropdown" })

    vim.keymap.set('n', '<Esc>', function()
      self._container:blur()
    end, { buffer = self._container.bufnr, noremap = true, silent = true, desc = "Exit multi-dropdown" })
  end

  -- Render initial display
  self:_render_display()

  return self
end

-- ============================================================================
-- Display Rendering
-- ============================================================================

function EmbeddedMultiDropdown:_render_display()
  if not self._container:is_valid() then return end

  local bufnr = self._container.bufnr
  local width = self._config.width
  local text_width = width - ARROW_WIDTH

  -- Build display text
  local display
  local is_placeholder = false

  if #self._values == 0 then
    display = self._placeholder
    is_placeholder = true
  elseif self._display_mode == "count" then
    display = string.format("%d selected", #self._values)
  else
    -- List mode: comma-separated labels
    local labels = {}
    for _, val in ipairs(self._values) do
      for _, opt in ipairs(self._options) do
        if opt.value == val then
          table.insert(labels, opt.label)
          break
        end
      end
    end
    display = table.concat(labels, ", ")
  end

  -- Truncate or pad
  if #display > text_width then
    display = display:sub(1, text_width)
  else
    display = display .. string.rep(" ", text_width - #display)
  end
  display = display .. ARROW_CHAR

  vim.api.nvim_set_option_value('modifiable', true, { buf = bufnr })
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { display })
  vim.api.nvim_set_option_value('modifiable', false, { buf = bufnr })

  -- Apply highlight
  local ns = vim.api.nvim_create_namespace("nvim_float_multi_dropdown_" .. self.key)
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  local hl_group = is_placeholder and "NvimFloatInputPlaceholder" or "NvimFloatInput"
  pcall(vim.api.nvim_buf_add_highlight, bufnr, ns, hl_group, 0, 0, text_width)
  pcall(vim.api.nvim_buf_add_highlight, bufnr, ns, "NvimFloatDropdownArrow", 0, text_width, #display)
end

-- ============================================================================
-- Options List
-- ============================================================================

---Open the selection list
function EmbeddedMultiDropdown:open_list()
  if self._list_open then return end
  self._list_open = true
  self._pending_values = vim.deepcopy(self._values)

  local list_height = math.min(#self._options, self._max_height)
  list_height = math.max(list_height, 1)

  -- Create list buffer
  self._list_bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value('buftype', 'nofile', { buf = self._list_bufnr })
  vim.api.nvim_set_option_value('bufhidden', 'wipe', { buf = self._list_bufnr })
  vim.api.nvim_set_option_value('swapfile', false, { buf = self._list_bufnr })

  -- Create list window anchored below the display container
  local Config = require("nvim-float.window.config")
  self._list_winid = vim.api.nvim_open_win(self._list_bufnr, true, {
    relative = "win",
    win = self._container.winid,
    row = 1,
    col = 0,
    width = self._config.width,
    height = list_height,
    zindex = Config.ZINDEX.DROPDOWN,
    border = "rounded",
    style = "minimal",
    focusable = true,
  })

  vim.api.nvim_set_option_value('cursorline', true, { win = self._list_winid })
  vim.api.nvim_set_option_value('wrap', false, { win = self._list_winid })
  vim.api.nvim_set_option_value('winhighlight',
    'Normal:Normal,FloatBorder:NvimFloatBorder,CursorLine:NvimFloatSelected',
    { win = self._list_winid })

  -- Render options
  self:_render_list()

  -- Setup keymaps
  self:_setup_list_keymaps()

  -- Auto-close on focus loss
  self._list_autocmd_group = vim.api.nvim_create_augroup(
    "NvimFloatEmbeddedMultiDropdownList_" .. self.key, { clear = true })

  vim.api.nvim_create_autocmd("BufLeave", {
    group = self._list_autocmd_group,
    buffer = self._list_bufnr,
    once = true,
    callback = function()
      vim.schedule(function()
        self:close_list(true)
      end)
    end,
  })
end

---Close the selection list
---@param cancel boolean? If true, discard pending changes
function EmbeddedMultiDropdown:close_list(cancel)
  if not self._list_open then return end
  self._list_open = false

  -- Clean up autocmds
  if self._list_autocmd_group then
    pcall(vim.api.nvim_del_augroup_by_id, self._list_autocmd_group)
    self._list_autocmd_group = nil
  end

  -- Close list window
  if self._list_winid and vim.api.nvim_win_is_valid(self._list_winid) then
    vim.api.nvim_win_close(self._list_winid, true)
  end
  self._list_winid = nil
  self._list_bufnr = nil

  if not cancel and self._pending_values then
    local old_values = vim.deepcopy(self._values)
    self._values = self._pending_values

    -- Check if values actually changed
    local changed = #old_values ~= #self._values
    if not changed then
      local old_set = {}
      for _, v in ipairs(old_values) do old_set[v] = true end
      for _, v in ipairs(self._values) do
        if not old_set[v] then changed = true; break end
      end
    end

    if changed and self._config.on_change then
      self._config.on_change(self.key, vim.deepcopy(self._values))
    end
  end
  self._pending_values = nil

  -- Return focus to display container
  if self._container:is_valid() then
    vim.api.nvim_set_current_win(self._container.winid)
  end

  self:_render_display()
end

---Confirm selections and close
function EmbeddedMultiDropdown:_confirm()
  self:close_list(false)
end

-- ============================================================================
-- List Rendering (private)
-- ============================================================================

function EmbeddedMultiDropdown:_render_list()
  if not self._list_bufnr or not vim.api.nvim_buf_is_valid(self._list_bufnr) then return end

  local lines = {}
  local width = self._config.width - 2 -- Account for border
  local pending_set = {}
  for _, v in ipairs(self._pending_values or {}) do
    pending_set[v] = true
  end

  for _, opt in ipairs(self._options) do
    local checked = pending_set[opt.value]
    local prefix = checked and CHECK_ON or CHECK_OFF
    local line = prefix .. opt.label
    if #line > width then
      line = line:sub(1, width)
    end
    table.insert(lines, line)
  end

  if #lines == 0 then
    lines = { " (no options)" }
  end

  vim.api.nvim_set_option_value('modifiable', true, { buf = self._list_bufnr })
  vim.api.nvim_buf_set_lines(self._list_bufnr, 0, -1, false, lines)
  vim.api.nvim_set_option_value('modifiable', false, { buf = self._list_bufnr })

  -- Highlights
  local ns = vim.api.nvim_create_namespace("nvim_float_multi_dropdown_list_" .. self.key)
  vim.api.nvim_buf_clear_namespace(self._list_bufnr, ns, 0, -1)
  for i, opt in ipairs(self._options) do
    if pending_set[opt.value] then
      pcall(vim.api.nvim_buf_add_highlight, self._list_bufnr, ns, "NvimFloatToggleOn", i - 1, 0, CHECK_WIDTH)
    else
      pcall(vim.api.nvim_buf_add_highlight, self._list_bufnr, ns, "NvimFloatToggleOff", i - 1, 0, CHECK_WIDTH)
    end
  end
end

-- ============================================================================
-- Toggle
-- ============================================================================

function EmbeddedMultiDropdown:_toggle_at_cursor()
  if not self._list_open or not self._pending_values then return end
  if not self._list_winid or not vim.api.nvim_win_is_valid(self._list_winid) then return end

  local cursor = vim.api.nvim_win_get_cursor(self._list_winid)
  local idx = cursor[1]
  local option = self._options[idx]
  if not option then return end

  -- Toggle in pending_values
  local found = false
  for i, v in ipairs(self._pending_values) do
    if v == option.value then
      table.remove(self._pending_values, i)
      found = true
      break
    end
  end
  if not found then
    table.insert(self._pending_values, option.value)
  end

  self:_render_list()
end

function EmbeddedMultiDropdown:_toggle_all()
  if not self._list_open or not self._pending_values then return end

  -- If all selected, deselect all. Otherwise select all.
  if #self._pending_values >= #self._options then
    self._pending_values = {}
  else
    self._pending_values = {}
    for _, opt in ipairs(self._options) do
      table.insert(self._pending_values, opt.value)
    end
  end

  self:_render_list()
end

-- ============================================================================
-- List Keymaps (private)
-- ============================================================================

function EmbeddedMultiDropdown:_setup_list_keymaps()
  if not self._list_bufnr or not vim.api.nvim_buf_is_valid(self._list_bufnr) then return end
  local bufnr = self._list_bufnr
  local opts = { buffer = bufnr, noremap = true, silent = true }

  -- Toggle with Space or Enter
  vim.keymap.set('n', '<Space>', function() self:_toggle_at_cursor() end,
    vim.tbl_extend('force', opts, { desc = "Toggle option" }))
  vim.keymap.set('n', '<CR>', function() self:_toggle_at_cursor() end,
    vim.tbl_extend('force', opts, { desc = "Toggle option" }))

  -- Ctrl+A to toggle all
  vim.keymap.set('n', '<C-a>', function() self:_toggle_all() end,
    vim.tbl_extend('force', opts, { desc = "Toggle all" }))

  -- Confirm with Ctrl+Enter or y
  vim.keymap.set('n', 'y', function() self:_confirm() end,
    vim.tbl_extend('force', opts, { desc = "Confirm selections" }))

  -- Cancel with Escape or q
  vim.keymap.set('n', '<Esc>', function() self:close_list(true) end,
    vim.tbl_extend('force', opts, { desc = "Cancel" }))
  vim.keymap.set('n', 'q', function() self:close_list(true) end,
    vim.tbl_extend('force', opts, { desc = "Cancel" }))

  -- Navigation with wrapping
  vim.keymap.set('n', 'j', function()
    if not self._list_winid or not vim.api.nvim_win_is_valid(self._list_winid) then return end
    local cursor = vim.api.nvim_win_get_cursor(self._list_winid)
    local line_count = vim.api.nvim_buf_line_count(self._list_bufnr)
    local next_row = cursor[1] < line_count and cursor[1] + 1 or 1
    vim.api.nvim_win_set_cursor(self._list_winid, { next_row, 0 })
  end, vim.tbl_extend('force', opts, { desc = "Next option" }))

  vim.keymap.set('n', 'k', function()
    if not self._list_winid or not vim.api.nvim_win_is_valid(self._list_winid) then return end
    local cursor = vim.api.nvim_win_get_cursor(self._list_winid)
    local line_count = vim.api.nvim_buf_line_count(self._list_bufnr)
    local prev_row = cursor[1] > 1 and cursor[1] - 1 or line_count
    vim.api.nvim_win_set_cursor(self._list_winid, { prev_row, 0 })
  end, vim.tbl_extend('force', opts, { desc = "Previous option" }))
end

-- ============================================================================
-- Value Management
-- ============================================================================

---Get the current selected values
---@return string[]
function EmbeddedMultiDropdown:get_values()
  return vim.deepcopy(self._values)
end

---Set the values programmatically
---@param values string[]
function EmbeddedMultiDropdown:set_values(values)
  self._values = vim.deepcopy(values or {})
  self:_render_display()
end

---Get the options
---@return EmbeddedDropdownOption[]
function EmbeddedMultiDropdown:get_options()
  return self._options
end

---Set new options
---@param options EmbeddedDropdownOption[]
function EmbeddedMultiDropdown:set_options(options)
  self._options = options
  self:_render_display()
end

-- ============================================================================
-- Delegation to Container
-- ============================================================================

---Check if valid
---@return boolean
function EmbeddedMultiDropdown:is_valid()
  return self._container:is_valid()
end

---Focus the multi-dropdown
function EmbeddedMultiDropdown:focus()
  self._container:focus()
end

---Blur the multi-dropdown
function EmbeddedMultiDropdown:blur()
  if self._list_open then
    self:close_list(true)
  end
  self._container:blur()
end

---Update position
---@param row number? New row
---@param col number? New col
---@param width number? New width
function EmbeddedMultiDropdown:update_region(row, col, width)
  self._container:update_region(row, col, width, 1)
  if width then
    self._config.width = width
    self:_render_display()
  end
end

---Close the multi-dropdown
function EmbeddedMultiDropdown:close()
  if self._list_open then
    self:close_list(true)
  end
  self._container:close()
end

---Get the underlying container
---@return EmbeddedContainer
function EmbeddedMultiDropdown:get_container()
  return self._container
end

return EmbeddedMultiDropdown
