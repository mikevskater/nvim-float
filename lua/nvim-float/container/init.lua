---@module 'nvim-float.container'
---@brief EmbeddedContainer - A child floating window positioned inside a parent

---@class EmbeddedContainerConfig
---@field name string Unique name for this container
---@field row number 0-indexed row offset within parent content area
---@field col number 0-indexed col offset within parent content area
---@field width number Container width in columns
---@field height number Container height in rows
---@field parent_winid number Parent window ID
---@field parent_float FloatWindow Parent FloatWindow instance
---@field zindex_offset number? Added to parent zindex (default: 5)
---@field border string|table? Border style (default: "none")
---@field focusable boolean? Whether container can receive focus (default: true)
---@field scrollbar boolean? Show scrollbar when content overflows (default: true)
---@field content_builder ContentBuilder? ContentBuilder for styled content
---@field on_focus fun()? Callback when container gains focus
---@field on_blur fun()? Callback when container loses focus
---@field winhighlight string? Custom window highlight groups
---@field modifiable boolean? Allow buffer modifications (default: false)
---@field cursorline boolean? Show cursor line (default: true)

---@class EmbeddedContainer
---A child floating window inside a parent FloatWindow
local EmbeddedContainer = {}
EmbeddedContainer.__index = EmbeddedContainer

-- Lazy-load scrollbar
local _scrollbar
local function get_scrollbar()
  if not _scrollbar then _scrollbar = require("nvim-float.float.scrollbar") end
  return _scrollbar
end

-- ============================================================================
-- Constructor
-- ============================================================================

---Create a new embedded container inside a parent window
---@param config EmbeddedContainerConfig
---@return EmbeddedContainer
function EmbeddedContainer.new(config)
  local self = setmetatable({}, EmbeddedContainer)

  self.name = config.name
  self._config = config
  self._parent_winid = config.parent_winid
  self._parent_float = config.parent_float
  self._focused = false
  self._content_builder = config.content_builder
  self._content_ns = nil

  -- Create buffer
  self.bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value('buftype', 'nofile', { buf = self.bufnr })
  vim.api.nvim_set_option_value('bufhidden', 'wipe', { buf = self.bufnr })
  vim.api.nvim_set_option_value('swapfile', false, { buf = self.bufnr })

  -- Set initial content
  local lines = {}
  if config.content_builder then
    lines = config.content_builder:build_lines()
  end
  if #lines == 0 then
    lines = { "" }
  end
  self.lines = lines
  vim.api.nvim_buf_set_lines(self.bufnr, 0, -1, false, lines)
  vim.api.nvim_set_option_value('modifiable', config.modifiable or false, { buf = self.bufnr })

  -- Calculate zindex
  local parent_zindex = config.parent_float:get_zindex()
  self._zindex = parent_zindex + (config.zindex_offset or 5)

  -- Create child window with relative='win'
  self.winid = vim.api.nvim_open_win(self.bufnr, false, {
    relative = "win",
    win = config.parent_winid,
    row = config.row,
    col = config.col,
    width = config.width,
    height = config.height,
    zindex = self._zindex,
    border = config.border or "none",
    style = "minimal",
    focusable = config.focusable ~= false,
  })

  -- Store geometry for scrollbar/reposition
  self._row = config.row
  self._col = config.col
  self._width = config.width
  self._height = config.height
  -- Alias fields expected by scrollbar module
  self._win_row = config.row
  self._win_col = config.col
  self._win_width = config.width
  self._win_height = config.height

  -- Stable buffer-relative position (set once at creation, never changes)
  self._buffer_row = config.row
  self._buffer_col = config.col
  self._original_width = config.width
  self._original_height = config.height

  -- Border offsets (computed once)
  local nav = require("nvim-float.container.navigation")
  local bt, bb, bl, br = nav.compute_border_offsets(config.border)
  self._border_top = bt
  self._border_bottom = bb
  self._border_left = bl
  self._border_right = br

  -- Scroll-sync state
  self._hidden = false
  self._last_clip_top = 0

  self.config = {
    zindex = self._zindex,
    scrollbar = config.scrollbar ~= false,
    winblend = config.parent_float.config.winblend or 0,
    modifiable = config.modifiable or false,
  }

  -- Window options
  vim.api.nvim_set_option_value('wrap', false, { win = self.winid })
  vim.api.nvim_set_option_value('foldenable', false, { win = self.winid })
  vim.api.nvim_set_option_value('cursorline', config.cursorline ~= false, { win = self.winid })
  vim.api.nvim_set_option_value('number', false, { win = self.winid })
  vim.api.nvim_set_option_value('relativenumber', false, { win = self.winid })
  vim.api.nvim_set_option_value('signcolumn', 'no', { win = self.winid })
  vim.api.nvim_set_option_value('winblend', config.parent_float.config.winblend or 0, { win = self.winid })
  vim.api.nvim_set_option_value('scrolloff', 0, { win = self.winid })

  local winhighlight = config.winhighlight
    or 'Normal:Normal,FloatBorder:NvimFloatBorder,CursorLine:NvimFloatSelected'
  vim.api.nvim_set_option_value('winhighlight', winhighlight, { win = self.winid })

  -- Apply styled content highlights
  if config.content_builder and self:is_valid() then
    local ns_id = vim.api.nvim_create_namespace("nvim_float_container_" .. self.name)
    config.content_builder:apply_to_buffer(self.bufnr, ns_id)
    self._content_ns = ns_id
  end

  -- Setup scrollbar if content overflows
  if self.config.scrollbar and #self.lines > self._height then
    self:_setup_scrollbar()
  end

  -- Setup keymaps for focus management
  self:_setup_keymaps()

  return self
end

-- ============================================================================
-- Validity
-- ============================================================================

---Check if the container is still valid
---@return boolean
function EmbeddedContainer:is_valid()
  return self.bufnr and vim.api.nvim_buf_is_valid(self.bufnr)
    and self.winid and vim.api.nvim_win_is_valid(self.winid)
end

-- ============================================================================
-- Focus Management
-- ============================================================================

---Focus this container (transfer actual window focus)
function EmbeddedContainer:focus()
  if not self:is_valid() then return end
  vim.api.nvim_set_current_win(self.winid)
  self._focused = true
  if self._config.on_focus then
    self._config.on_focus()
  end
end

---Blur this container (return focus to parent)
function EmbeddedContainer:blur()
  if not self:is_valid() then return end
  self._focused = false
  if self._config.on_blur then
    self._config.on_blur()
  end
  -- Return focus to parent
  if self._parent_winid and vim.api.nvim_win_is_valid(self._parent_winid) then
    vim.api.nvim_set_current_win(self._parent_winid)
  end
end

---Check if this container currently has focus
---@return boolean
function EmbeddedContainer:is_focused()
  return self._focused
end

-- ============================================================================
-- Scroll-Sync Visibility
-- ============================================================================

---Hide this container (keeps window/buffer intact, just toggles visibility)
function EmbeddedContainer:hide()
  if self._hidden then return end
  self._hidden = true
  if self.winid and vim.api.nvim_win_is_valid(self.winid) then
    vim.api.nvim_win_set_config(self.winid, { hide = true })
  end
  if self._scrollbar_winid and vim.api.nvim_win_is_valid(self._scrollbar_winid) then
    vim.api.nvim_win_set_config(self._scrollbar_winid, { hide = true })
  end
end

---Show this container (restore visibility)
function EmbeddedContainer:show()
  if not self._hidden then return end
  self._hidden = false
  if self.winid and vim.api.nvim_win_is_valid(self.winid) then
    vim.api.nvim_win_set_config(self.winid, { hide = false })
  end
  if self._scrollbar_winid and vim.api.nvim_win_is_valid(self._scrollbar_winid) then
    vim.api.nvim_win_set_config(self._scrollbar_winid, { hide = false })
  end
end

---Check if this container is hidden by scroll sync
---@return boolean
function EmbeddedContainer:is_hidden()
  return self._hidden
end

-- ============================================================================
-- Content Management
-- ============================================================================

---Update container content with a new ContentBuilder
---@param cb ContentBuilder The content builder with new content
function EmbeddedContainer:update_content(cb)
  if not self:is_valid() then return end

  self._content_builder = cb
  local lines = cb:build_lines()
  if #lines == 0 then lines = { "" } end
  self.lines = lines

  vim.api.nvim_set_option_value('modifiable', true, { buf = self.bufnr })
  vim.api.nvim_buf_set_lines(self.bufnr, 0, -1, false, lines)

  -- Re-apply highlights
  local ns_id = self._content_ns or vim.api.nvim_create_namespace("nvim_float_container_" .. self.name)
  self._content_ns = ns_id
  vim.api.nvim_buf_clear_namespace(self.bufnr, ns_id, 0, -1)
  cb:apply_to_buffer(self.bufnr, ns_id)

  vim.api.nvim_set_option_value('modifiable', self._config.modifiable or false, { buf = self.bufnr })

  -- Update scrollbar
  if self.config.scrollbar then
    if #lines > self._height then
      if self._scrollbar_winid and vim.api.nvim_win_is_valid(self._scrollbar_winid) then
        get_scrollbar().update(self)
      else
        self:_setup_scrollbar()
      end
    else
      self:_close_scrollbar()
    end
  end
end

---Render content from the current content builder
function EmbeddedContainer:render()
  if self._content_builder then
    self:update_content(self._content_builder)
  end
end

---Update buffer lines directly (without ContentBuilder)
---@param lines string[]
function EmbeddedContainer:update_lines(lines)
  if not self:is_valid() then return end

  if #lines == 0 then lines = { "" } end
  self.lines = lines

  vim.api.nvim_set_option_value('modifiable', true, { buf = self.bufnr })
  vim.api.nvim_buf_set_lines(self.bufnr, 0, -1, false, lines)
  vim.api.nvim_set_option_value('modifiable', self._config.modifiable or false, { buf = self.bufnr })

  -- Update scrollbar
  if self.config.scrollbar then
    if #lines > self._height then
      if self._scrollbar_winid and vim.api.nvim_win_is_valid(self._scrollbar_winid) then
        get_scrollbar().update(self)
      else
        self:_setup_scrollbar()
      end
    else
      self:_close_scrollbar()
    end
  end
end

-- ============================================================================
-- Geometry
-- ============================================================================

---Update the container's position and/or size
---@param row number? New row offset (0-indexed)
---@param col number? New col offset (0-indexed)
---@param width number? New width
---@param height number? New height
function EmbeddedContainer:update_region(row, col, width, height)
  if not self:is_valid() then return end

  self._row = row or self._row
  self._col = col or self._col
  self._width = width or self._width
  self._height = height or self._height

  -- Update scrollbar alias fields
  self._win_row = self._row
  self._win_col = self._col
  self._win_width = self._width
  self._win_height = self._height

  vim.api.nvim_win_set_config(self.winid, {
    relative = "win",
    win = self._parent_winid,
    row = self._row,
    col = self._col,
    width = self._width,
    height = self._height,
  })

  -- Reposition scrollbar
  if self._scrollbar_winid and vim.api.nvim_win_is_valid(self._scrollbar_winid) then
    self:_reposition_scrollbar()
  end
end

---Scroll to a specific line (1-indexed)
---@param line number Line number to scroll to
function EmbeddedContainer:scroll_to(line)
  if not self:is_valid() then return end
  local total = vim.api.nvim_buf_line_count(self.bufnr)
  line = math.max(1, math.min(line, total))
  vim.api.nvim_win_set_cursor(self.winid, { line, 0 })
end

---Get the container's current geometry
---@return { row: number, col: number, width: number, height: number }
function EmbeddedContainer:get_region()
  return {
    row = self._row,
    col = self._col,
    width = self._width,
    height = self._height,
  }
end

-- ============================================================================
-- Scrollbar (private)
-- ============================================================================

function EmbeddedContainer:_setup_scrollbar()
  if self._scrollbar_winid and vim.api.nvim_win_is_valid(self._scrollbar_winid) then
    return
  end

  -- Create scrollbar buffer
  self._scrollbar_bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value('buftype', 'nofile', { buf = self._scrollbar_bufnr })
  vim.api.nvim_set_option_value('bufhidden', 'wipe', { buf = self._scrollbar_bufnr })
  vim.api.nvim_set_option_value('swapfile', false, { buf = self._scrollbar_bufnr })
  vim.api.nvim_set_option_value('modifiable', true, { buf = self._scrollbar_bufnr })

  -- Position scrollbar at right edge of container, relative to container window
  self._scrollbar_winid = vim.api.nvim_open_win(self._scrollbar_bufnr, false, {
    relative = "win",
    win = self.winid,
    row = 0,
    col = self._width - 1,
    width = 1,
    height = self._height,
    style = "minimal",
    focusable = false,
    zindex = self._zindex + 1,
  })

  vim.api.nvim_set_option_value('winblend', self.config.winblend or 0, { win = self._scrollbar_winid })
  vim.api.nvim_set_option_value('winhighlight',
    'Normal:NvimFloatScrollbar,NormalFloat:NvimFloatScrollbar', { win = self._scrollbar_winid })

  get_scrollbar().update(self)

  -- Track scrolling
  self._scrollbar_autocmd = vim.api.nvim_create_autocmd(
    { "CursorMoved", "CursorMovedI", "WinScrolled" },
    {
      buffer = self.bufnr,
      callback = function()
        if self:is_valid() then
          get_scrollbar().update(self)
        end
      end,
    }
  )
end

function EmbeddedContainer:_close_scrollbar()
  if self._scrollbar_autocmd then
    pcall(vim.api.nvim_del_autocmd, self._scrollbar_autocmd)
    self._scrollbar_autocmd = nil
  end
  if self._scrollbar_winid and vim.api.nvim_win_is_valid(self._scrollbar_winid) then
    vim.api.nvim_win_close(self._scrollbar_winid, true)
  end
  self._scrollbar_winid = nil
  if self._scrollbar_bufnr and vim.api.nvim_buf_is_valid(self._scrollbar_bufnr) then
    vim.api.nvim_buf_delete(self._scrollbar_bufnr, { force = true })
  end
  self._scrollbar_bufnr = nil
  self._scrollbar_last_top = nil
  self._scrollbar_last_total = nil
  self._scrollbar_last_content = nil
end

function EmbeddedContainer:_reposition_scrollbar()
  if not self._scrollbar_winid or not vim.api.nvim_win_is_valid(self._scrollbar_winid) then
    return
  end
  vim.api.nvim_win_set_config(self._scrollbar_winid, {
    relative = "win",
    win = self.winid,
    row = 0,
    col = self._width - 1,
    width = 1,
    height = self._height,
  })
  get_scrollbar().update(self)
end

-- ============================================================================
-- Keymaps (private)
-- ============================================================================

function EmbeddedContainer:_setup_keymaps()
  if not self.bufnr or not vim.api.nvim_buf_is_valid(self.bufnr) then return end

  -- Escape to blur (return focus to parent)
  vim.keymap.set('n', '<Esc>', function()
    self:blur()
  end, { buffer = self.bufnr, noremap = true, silent = true, desc = "Exit container" })
end

-- ============================================================================
-- Cleanup
-- ============================================================================

---Close the container, cleaning up all resources
function EmbeddedContainer:close()
  -- Close scrollbar
  self:_close_scrollbar()

  -- Close child window and buffer
  if self.bufnr and vim.api.nvim_buf_is_valid(self.bufnr) then
    vim.api.nvim_buf_delete(self.bufnr, { force = true })
  end
  self.winid = nil
  self.bufnr = nil
  self._focused = false
end

return EmbeddedContainer
