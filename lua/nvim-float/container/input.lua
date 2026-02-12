---@module 'nvim-float.container.input'
---@brief EmbeddedInput - A text input implemented as an embedded container
---
---Each input is its own tiny window/buffer, eliminating column-tracking extmarks.
---The user edits freely in a small buffer instead of within extmark boundaries.

local EmbeddedContainer = require("nvim-float.container")

---@class EmbeddedInputConfig
---@field key string Unique identifier for this input
---@field row number 0-indexed row offset within parent content area
---@field col number 0-indexed col offset within parent content area
---@field width number Input width in columns
---@field parent_winid number Parent window ID
---@field parent_float FloatWindow Parent FloatWindow instance
---@field zindex_offset number? Added to parent zindex (default: 5)
---@field placeholder string? Placeholder text when empty
---@field value string? Initial value
---@field on_change fun(key: string, value: string)? Callback when value changes
---@field on_submit fun(key: string, value: string)? Callback when Enter is pressed
---@field winhighlight string? Custom window highlight groups

---@class EmbeddedInput
---A text input container - the entire child buffer IS the input
local EmbeddedInput = {}
EmbeddedInput.__index = EmbeddedInput

-- ============================================================================
-- Constructor
-- ============================================================================

---Create a new embedded input
---@param config EmbeddedInputConfig
---@return EmbeddedInput
function EmbeddedInput.new(config)
  local self = setmetatable({}, EmbeddedInput)

  self.key = config.key
  self._config = config
  self._value = config.value or ""
  self._placeholder = config.placeholder or ""
  self._showing_placeholder = false
  self._in_edit = false
  self._autocmd_group = nil

  -- Create the underlying container
  self._container = EmbeddedContainer.new({
    name = "input_" .. config.key,
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
    modifiable = true, -- Inputs need to be modifiable
    cursorline = false,
    winhighlight = config.winhighlight
      or 'Normal:NvimFloatInput,CursorLine:NvimFloatInput',
    on_focus = function() self:enter_edit() end,
    on_blur = function() self:exit_edit() end,
  })

  -- Override the container's Escape keymap - on Esc exit edit mode
  if self._container.bufnr and vim.api.nvim_buf_is_valid(self._container.bufnr) then
    vim.keymap.set('n', '<Esc>', function()
      self:exit_edit()
      self._container:blur()
    end, { buffer = self._container.bufnr, noremap = true, silent = true, desc = "Exit input" })

    -- Normal mode Enter: enter edit mode
    vim.keymap.set('n', '<CR>', function()
      self:enter_edit()
    end, { buffer = self._container.bufnr, noremap = true, silent = true, desc = "Edit input" })

    -- Normal mode i: enter edit mode
    vim.keymap.set('n', 'i', function()
      self:enter_edit()
    end, { buffer = self._container.bufnr, noremap = true, silent = true, desc = "Edit input" })

    -- Insert mode Enter: confirm and exit edit mode
    vim.keymap.set('i', '<CR>', function()
      self:exit_edit()
      vim.cmd("stopinsert")
    end, { buffer = self._container.bufnr, noremap = true, silent = true, desc = "Confirm input" })
  end

  -- Display initial content
  self:_render_display()

  return self
end

-- ============================================================================
-- Edit Mode
-- ============================================================================

---Enter edit mode - make buffer modifiable and enter insert mode
function EmbeddedInput:enter_edit()
  if self._in_edit then return end
  if not self._container:is_valid() then return end

  self._in_edit = true
  local bufnr = self._container.bufnr

  -- Show actual value (not placeholder)
  vim.api.nvim_set_option_value('modifiable', true, { buf = bufnr })
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { self._value })
  self._showing_placeholder = false

  -- Update highlight to active
  if vim.api.nvim_win_is_valid(self._container.winid) then
    vim.api.nvim_set_option_value('winhighlight',
      'Normal:NvimFloatInputActive,CursorLine:NvimFloatInputActive',
      { win = self._container.winid })
  end

  -- Enter insert mode at end of text
  vim.cmd("startinsert!")

  -- Setup autocmds for tracking changes
  self._autocmd_group = vim.api.nvim_create_augroup(
    "NvimFloatEmbeddedInput_" .. self.key, { clear = true })

  vim.api.nvim_create_autocmd("TextChangedI", {
    group = self._autocmd_group,
    buffer = bufnr,
    callback = function()
      self:_sync_value()
    end,
  })

  vim.api.nvim_create_autocmd("InsertLeave", {
    group = self._autocmd_group,
    buffer = bufnr,
    callback = function()
      self:exit_edit()
    end,
  })
end

---Exit edit mode - sync value and show display
function EmbeddedInput:exit_edit()
  if not self._in_edit then return end
  self._in_edit = false

  -- Clean up autocmds
  if self._autocmd_group then
    pcall(vim.api.nvim_del_augroup_by_id, self._autocmd_group)
    self._autocmd_group = nil
  end

  -- Sync final value
  self:_sync_value()

  -- Restore normal highlight
  if self._container:is_valid() and vim.api.nvim_win_is_valid(self._container.winid) then
    vim.api.nvim_set_option_value('winhighlight',
      self._config.winhighlight or 'Normal:NvimFloatInput,CursorLine:NvimFloatInput',
      { win = self._container.winid })
  end

  -- Re-render display (may show placeholder)
  self:_render_display()
end

-- ============================================================================
-- Value Management
-- ============================================================================

---Get the current value
---@return string
function EmbeddedInput:get_value()
  return self._value
end

---Set the value programmatically
---@param value string
function EmbeddedInput:set_value(value)
  self._value = value or ""
  if not self._in_edit then
    self:_render_display()
  else
    -- Update buffer directly if in edit mode
    if self._container:is_valid() then
      vim.api.nvim_buf_set_lines(self._container.bufnr, 0, -1, false, { self._value })
    end
  end
end

---Sync value from buffer content
function EmbeddedInput:_sync_value()
  if not self._container:is_valid() then return end
  local lines = vim.api.nvim_buf_get_lines(self._container.bufnr, 0, 1, false)
  local new_value = lines[1] or ""

  if new_value ~= self._value then
    self._value = new_value
    if self._config.on_change then
      self._config.on_change(self.key, new_value)
    end
  end
end

-- ============================================================================
-- Display (private)
-- ============================================================================

---Render the display text (value or placeholder)
function EmbeddedInput:_render_display()
  if not self._container:is_valid() then return end

  local bufnr = self._container.bufnr
  local display_text

  vim.api.nvim_set_option_value('modifiable', true, { buf = bufnr })

  if self._value == "" and self._placeholder ~= "" then
    -- Show placeholder
    display_text = self._placeholder
    self._showing_placeholder = true

    -- Pad or truncate to width
    if #display_text > self._config.width then
      display_text = display_text:sub(1, self._config.width)
    end

    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { display_text })

    -- Apply placeholder highlight
    local ns = vim.api.nvim_create_namespace("nvim_float_input_ph_" .. self.key)
    vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
    pcall(vim.api.nvim_buf_add_highlight, bufnr, ns, "NvimFloatInputPlaceholder", 0, 0, #display_text)
  else
    -- Show value
    display_text = self._value
    self._showing_placeholder = false
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { display_text })

    -- Clear placeholder highlight
    local ns = vim.api.nvim_create_namespace("nvim_float_input_ph_" .. self.key)
    vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  end

  if not self._in_edit then
    vim.api.nvim_set_option_value('modifiable', false, { buf = bufnr })
  end
end

-- ============================================================================
-- Delegation to Container
-- ============================================================================

---Check if the input is valid
---@return boolean
function EmbeddedInput:is_valid()
  return self._container:is_valid()
end

---Focus the input (enters edit mode via on_focus callback)
function EmbeddedInput:focus()
  self._container:focus()
end

---Blur the input (exits edit mode via on_blur callback)
function EmbeddedInput:blur()
  self._container:blur()
end

---Update position
---@param row number? New row
---@param col number? New col
---@param width number? New width
function EmbeddedInput:update_region(row, col, width)
  self._container:update_region(row, col, width, 1)
  if width then
    self._config.width = width
  end
end

---Close the input
function EmbeddedInput:close()
  if self._autocmd_group then
    pcall(vim.api.nvim_del_augroup_by_id, self._autocmd_group)
    self._autocmd_group = nil
  end
  self._container:close()
end

---Get the underlying container
---@return EmbeddedContainer
function EmbeddedInput:get_container()
  return self._container
end

return EmbeddedInput
