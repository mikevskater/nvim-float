---@module 'nvim-float.container.dropdown'
---@brief EmbeddedDropdown - A single-select dropdown implemented as an embedded container
---
---Display: tiny embedded window showing `selected_value ▼`
---On Enter: opens a selection list (itself an embedded container) anchored below

local EmbeddedContainer = require("nvim-float.container")

---@class EmbeddedDropdownOption
---@field value string The value to store
---@field label string The display text

---@class EmbeddedDropdownConfig
---@field key string Unique identifier
---@field row number 0-indexed row offset within parent content area
---@field col number 0-indexed col offset within parent content area
---@field width number Display width in columns
---@field parent_winid number Parent window ID
---@field parent_float FloatWindow Parent FloatWindow instance
---@field zindex_offset number? Added to parent zindex (default: 5)
---@field options EmbeddedDropdownOption[] Array of { value, label }
---@field selected string? Initially selected value
---@field placeholder string? Placeholder text when nothing selected
---@field max_height number? Maximum height for options list (default: 10)
---@field on_change fun(key: string, value: string)? Callback when selection changes
---@field winhighlight string? Custom window highlight groups

---@class EmbeddedDropdown
---A single-select dropdown container
local EmbeddedDropdown = {}
EmbeddedDropdown.__index = EmbeddedDropdown

local ARROW_CHAR = " \u{25BC}"  -- ▼
local ARROW_WIDTH = 2

-- ============================================================================
-- Constructor
-- ============================================================================

---Create a new embedded dropdown
---@param config EmbeddedDropdownConfig
---@return EmbeddedDropdown
function EmbeddedDropdown.new(config)
  local self = setmetatable({}, EmbeddedDropdown)

  self.key = config.key
  self._config = config
  self._value = config.selected or ""
  self._options = config.options or {}
  self._placeholder = config.placeholder or "Select..."
  self._max_height = config.max_height or 10
  self._list_open = false
  self._list_container = nil
  self._list_bufnr = nil
  self._list_winid = nil
  self._selected_idx = 1
  self._filter_text = ""
  self._filtered_options = vim.deepcopy(self._options)
  self._list_autocmd_group = nil

  -- Find initial selected index
  for i, opt in ipairs(self._options) do
    if opt.value == self._value then
      self._selected_idx = i
      break
    end
  end

  -- Create the display container (1 line showing current selection)
  self._container = EmbeddedContainer.new({
    name = "dropdown_" .. config.key,
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
    end, { buffer = self._container.bufnr, noremap = true, silent = true, desc = "Open dropdown" })

    vim.keymap.set('n', '<Esc>', function()
      self._container:blur()
    end, { buffer = self._container.bufnr, noremap = true, silent = true, desc = "Exit dropdown" })
  end

  -- Render initial display
  self:_render_display()

  return self
end

-- ============================================================================
-- Display Rendering
-- ============================================================================

function EmbeddedDropdown:_render_display()
  if not self._container:is_valid() then return end

  local bufnr = self._container.bufnr
  local width = self._config.width
  local text_width = width - ARROW_WIDTH

  -- Get display label
  local display = self._placeholder
  local is_placeholder = true
  for _, opt in ipairs(self._options) do
    if opt.value == self._value then
      display = opt.label
      is_placeholder = false
      break
    end
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
  local ns = vim.api.nvim_create_namespace("nvim_float_dropdown_" .. self.key)
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  local hl_group = is_placeholder and "NvimFloatInputPlaceholder" or "NvimFloatInput"
  pcall(vim.api.nvim_buf_add_highlight, bufnr, ns, hl_group, 0, 0, text_width)
  pcall(vim.api.nvim_buf_add_highlight, bufnr, ns, "NvimFloatDropdownArrow", 0, text_width, #display)
end

-- ============================================================================
-- Options List
-- ============================================================================

---Open the selection list
function EmbeddedDropdown:open_list()
  if self._list_open then return end
  self._list_open = true
  self._filter_text = ""
  self._filtered_options = vim.deepcopy(self._options)

  -- Find current selection in filtered list
  self._selected_idx = 1
  for i, opt in ipairs(self._filtered_options) do
    if opt.value == self._value then
      self._selected_idx = i
      break
    end
  end

  local list_height = math.min(#self._filtered_options, self._max_height)
  list_height = math.max(list_height, 1)

  -- Create list buffer
  self._list_bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value('buftype', 'nofile', { buf = self._list_bufnr })
  vim.api.nvim_set_option_value('bufhidden', 'wipe', { buf = self._list_bufnr })
  vim.api.nvim_set_option_value('swapfile', false, { buf = self._list_bufnr })

  -- Create list window anchored below the display container
  -- Use DROPDOWN zindex to be above everything
  local Config = require("nvim-float.window.config")
  self._list_winid = vim.api.nvim_open_win(self._list_bufnr, true, {
    relative = "win",
    win = self._container.winid,
    row = 1, -- Just below the display
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

  -- Position cursor at selected item
  if self._selected_idx > 0 and self._selected_idx <= #self._filtered_options then
    vim.api.nvim_win_set_cursor(self._list_winid, { self._selected_idx, 0 })
  end

  -- Setup list keymaps
  self:_setup_list_keymaps()

  -- Setup autocmd to close on focus loss
  self._list_autocmd_group = vim.api.nvim_create_augroup(
    "NvimFloatEmbeddedDropdownList_" .. self.key, { clear = true })

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
---@param cancel boolean? If true, restore original value
function EmbeddedDropdown:close_list(cancel)
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

  -- Return focus to display container
  if self._container:is_valid() then
    vim.api.nvim_set_current_win(self._container.winid)
  end

  self:_render_display()
end

---Select the currently highlighted option
function EmbeddedDropdown:_select_current()
  if not self._list_open then return end
  if #self._filtered_options == 0 then return end

  local cursor = vim.api.nvim_win_get_cursor(self._list_winid)
  local idx = cursor[1]
  local option = self._filtered_options[idx]

  if option then
    local old_value = self._value
    self._value = option.value
    self:close_list()

    if old_value ~= self._value and self._config.on_change then
      self._config.on_change(self.key, self._value)
    end
  end
end

-- ============================================================================
-- List Rendering (private)
-- ============================================================================

function EmbeddedDropdown:_render_list()
  if not self._list_bufnr or not vim.api.nvim_buf_is_valid(self._list_bufnr) then return end

  local lines = {}
  local width = self._config.width - 2 -- Account for border

  for _, opt in ipairs(self._filtered_options) do
    local line = opt.label
    if #line > width then
      line = line:sub(1, width)
    end
    table.insert(lines, line)
  end

  if #lines == 0 then
    lines = { " (no matches)" }
  end

  vim.api.nvim_set_option_value('modifiable', true, { buf = self._list_bufnr })
  vim.api.nvim_buf_set_lines(self._list_bufnr, 0, -1, false, lines)
  vim.api.nvim_set_option_value('modifiable', false, { buf = self._list_bufnr })

  -- Highlight selected value
  local ns = vim.api.nvim_create_namespace("nvim_float_dropdown_list_" .. self.key)
  vim.api.nvim_buf_clear_namespace(self._list_bufnr, ns, 0, -1)
  for i, opt in ipairs(self._filtered_options) do
    if opt.value == self._value then
      pcall(vim.api.nvim_buf_add_highlight, self._list_bufnr, ns, "NvimFloatSelected", i - 1, 0, -1)
    end
  end
end

-- ============================================================================
-- Filtering
-- ============================================================================

function EmbeddedDropdown:_apply_filter(char)
  if char then
    self._filter_text = self._filter_text .. char
  end

  if self._filter_text == "" then
    self._filtered_options = vim.deepcopy(self._options)
  else
    self._filtered_options = {}
    local pattern = self._filter_text:lower()
    for _, opt in ipairs(self._options) do
      if opt.label:lower():find(pattern, 1, true) then
        table.insert(self._filtered_options, opt)
      end
    end
  end

  self:_render_list()

  -- Resize list window
  if self._list_winid and vim.api.nvim_win_is_valid(self._list_winid) then
    local new_height = math.min(math.max(#self._filtered_options, 1), self._max_height)
    vim.api.nvim_win_set_config(self._list_winid, {
      relative = "win",
      win = self._container.winid,
      row = 1,
      col = 0,
      width = self._config.width,
      height = new_height,
    })

    -- Clamp cursor
    local line_count = vim.api.nvim_buf_line_count(self._list_bufnr)
    if line_count > 0 then
      local cursor = vim.api.nvim_win_get_cursor(self._list_winid)
      if cursor[1] > line_count then
        vim.api.nvim_win_set_cursor(self._list_winid, { line_count, 0 })
      end
    end
  end
end

function EmbeddedDropdown:_clear_filter()
  self._filter_text = ""
  self:_apply_filter()
end

-- ============================================================================
-- List Keymaps (private)
-- ============================================================================

function EmbeddedDropdown:_setup_list_keymaps()
  if not self._list_bufnr or not vim.api.nvim_buf_is_valid(self._list_bufnr) then return end
  local bufnr = self._list_bufnr
  local opts = { buffer = bufnr, noremap = true, silent = true }

  -- Select
  vim.keymap.set('n', '<CR>', function() self:_select_current() end,
    vim.tbl_extend('force', opts, { desc = "Select option" }))

  -- Cancel
  vim.keymap.set('n', '<Esc>', function() self:close_list(true) end,
    vim.tbl_extend('force', opts, { desc = "Cancel" }))
  vim.keymap.set('n', 'q', function() self:close_list(true) end,
    vim.tbl_extend('force', opts, { desc = "Cancel" }))

  -- Navigation (j/k are default, add wrapping)
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

  -- Type-to-filter: printable characters
  for c = 32, 126 do
    local char = string.char(c)
    if char ~= ' ' then -- Skip space, it might conflict
      vim.keymap.set('n', char, function()
        self:_apply_filter(char)
      end, { buffer = bufnr, noremap = true, silent = true })
    end
  end

  -- Backspace to clear filter
  vim.keymap.set('n', '<BS>', function()
    if #self._filter_text > 0 then
      self._filter_text = self._filter_text:sub(1, -2)
      self:_apply_filter()
    end
  end, vim.tbl_extend('force', opts, { desc = "Clear filter character" }))
end

-- ============================================================================
-- Value Management
-- ============================================================================

---Get the current selected value
---@return string
function EmbeddedDropdown:get_value()
  return self._value
end

---Set the value programmatically
---@param value string
function EmbeddedDropdown:set_value(value)
  self._value = value or ""
  self:_render_display()
end

---Get the options
---@return EmbeddedDropdownOption[]
function EmbeddedDropdown:get_options()
  return self._options
end

---Set new options
---@param options EmbeddedDropdownOption[]
function EmbeddedDropdown:set_options(options)
  self._options = options
  self._filtered_options = vim.deepcopy(options)
  self:_render_display()
end

-- ============================================================================
-- Delegation to Container
-- ============================================================================

---Check if the dropdown is valid
---@return boolean
function EmbeddedDropdown:is_valid()
  return self._container:is_valid()
end

---Focus the dropdown
function EmbeddedDropdown:focus()
  self._container:focus()
end

---Blur the dropdown
function EmbeddedDropdown:blur()
  if self._list_open then
    self:close_list(true)
  end
  self._container:blur()
end

---Update position
---@param row number? New row
---@param col number? New col
---@param width number? New width
function EmbeddedDropdown:update_region(row, col, width)
  self._container:update_region(row, col, width, 1)
  if width then
    self._config.width = width
    self:_render_display()
  end
end

---Close the dropdown
function EmbeddedDropdown:close()
  if self._list_open then
    self:close_list(true)
  end
  self._container:close()
end

---Get the underlying container
---@return EmbeddedContainer
function EmbeddedDropdown:get_container()
  return self._container
end

return EmbeddedDropdown
