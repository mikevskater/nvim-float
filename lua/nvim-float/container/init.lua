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

  -- Original border (for scroll-sync dynamic clipping)
  self._original_border = config.border or "none"

  -- Separate border windows (created lazily on first scroll sync)
  self._border_top_winid = nil
  self._border_top_bufnr = nil
  self._border_bottom_winid = nil
  self._border_bottom_bufnr = nil
  self._border_left_winid = nil
  self._border_left_bufnr = nil
  self._border_right_winid = nil
  self._border_right_bufnr = nil
  self._border_windows_initialized = false
  self._content_hidden = false

  -- Arrow overlay window (for dropdowns)
  self._arrow_winid = nil
  self._arrow_bufnr = nil

  -- Scroll-sync state
  self._hidden = false
  self._last_clip_top = 0
  self._last_clip_bottom = 0
  self._last_clip_left = 0
  self._last_clip_right = 0

  self.config = {
    zindex = self._zindex,
    scrollbar = config.scrollbar ~= false,
    winblend = config.parent_float.config.winblend or 0,
    modifiable = config.modifiable or false,
  }

  -- Window options
  vim.api.nvim_set_option_value('wrap', false, { win = self.winid })
  vim.api.nvim_set_option_value('foldenable', false, { win = self.winid })
  vim.api.nvim_set_option_value('cursorline', false, { win = self.winid })
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
  if self._config.cursorline ~= false then
    vim.api.nvim_set_option_value('cursorline', true, { win = self.winid })
  end
  if self._config.on_focus then
    self._config.on_focus()
  end
end

---Blur this container (return focus to parent)
function EmbeddedContainer:blur()
  if not self:is_valid() then return end
  self._focused = false
  if self.winid and vim.api.nvim_win_is_valid(self.winid) then
    vim.api.nvim_set_option_value('cursorline', false, { win = self.winid })
  end
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

---@private
local function win_hide(winid)
  if winid and vim.api.nvim_win_is_valid(winid) then
    vim.api.nvim_win_set_config(winid, { hide = true })
  end
end

---@private
local function win_show(winid)
  if winid and vim.api.nvim_win_is_valid(winid) then
    vim.api.nvim_win_set_config(winid, { hide = false })
  end
end

---Hide this container (all components: content + borders + scrollbar)
function EmbeddedContainer:hide()
  if self._hidden then return end
  self._hidden = true
  self:hide_content()
  self:hide_border_top()
  self:hide_border_bottom()
  self:hide_border_left()
  self:hide_border_right()
  win_hide(self._scrollbar_winid)
  win_hide(self._arrow_winid)
end

---Show this container (all components)
function EmbeddedContainer:show()
  if not self._hidden then return end
  self._hidden = false
  self:show_content()
  self:show_border_top()
  self:show_border_bottom()
  self:show_border_left()
  self:show_border_right()
  win_show(self._scrollbar_winid)
  win_show(self._arrow_winid)
end

---Check if this container is hidden by scroll sync
---@return boolean
function EmbeddedContainer:is_hidden()
  return self._hidden
end

-- ── Per-component hide/show ───────────────────────────────────────────

function EmbeddedContainer:hide_content()
  if self._content_hidden then return end
  self._content_hidden = true
  win_hide(self.winid)
  win_hide(self._scrollbar_winid)
  win_hide(self._arrow_winid)
end

function EmbeddedContainer:show_content()
  if not self._content_hidden then return end
  self._content_hidden = false
  win_show(self.winid)
  win_show(self._scrollbar_winid)
  win_show(self._arrow_winid)
end

function EmbeddedContainer:hide_border_top()
  win_hide(self._border_top_winid)
end

function EmbeddedContainer:show_border_top()
  win_show(self._border_top_winid)
end

function EmbeddedContainer:hide_border_bottom()
  win_hide(self._border_bottom_winid)
end

function EmbeddedContainer:show_border_bottom()
  win_show(self._border_bottom_winid)
end

function EmbeddedContainer:hide_border_left()
  win_hide(self._border_left_winid)
end

function EmbeddedContainer:show_border_left()
  win_show(self._border_left_winid)
end

function EmbeddedContainer:hide_border_right()
  win_hide(self._border_right_winid)
end

function EmbeddedContainer:show_border_right()
  win_show(self._border_right_winid)
end

-- ── Per-component reposition ──────────────────────────────────────────

---Reposition and rebuild top border window.
---@param row number Row relative to parent
---@param col number Col relative to parent
---@param inner_width number Content width for the fill chars
---@param include_left_corner boolean
---@param include_right_corner boolean
function EmbeddedContainer:reposition_border_top(row, col, inner_width, include_left_corner, include_right_corner)
  local winid = self._border_top_winid
  if not winid or not vim.api.nvim_win_is_valid(winid) then return end
  local chars = self._border_chars
  if not chars then return end

  local line = self:_build_border_line(chars, "top", inner_width, include_left_corner, include_right_corner)
  local display_w = vim.fn.strdisplaywidth(line)
  if display_w < 1 then display_w = 1 end

  local bufnr = self._border_top_bufnr
  vim.api.nvim_set_option_value('modifiable', true, { buf = bufnr })
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { line })
  vim.api.nvim_set_option_value('modifiable', false, { buf = bufnr })

  vim.api.nvim_win_set_config(winid, {
    relative = "win",
    win = self._parent_winid,
    row = row,
    col = col,
    width = display_w,
    height = 1,
  })
end

---Reposition and rebuild bottom border window.
---@param row number Row relative to parent
---@param col number Col relative to parent
---@param inner_width number Content width for the fill chars
---@param include_left_corner boolean
---@param include_right_corner boolean
function EmbeddedContainer:reposition_border_bottom(row, col, inner_width, include_left_corner, include_right_corner)
  local winid = self._border_bottom_winid
  if not winid or not vim.api.nvim_win_is_valid(winid) then return end
  local chars = self._border_chars
  if not chars then return end

  local line = self:_build_border_line(chars, "bottom", inner_width, include_left_corner, include_right_corner)
  local display_w = vim.fn.strdisplaywidth(line)
  if display_w < 1 then display_w = 1 end

  local bufnr = self._border_bottom_bufnr
  vim.api.nvim_set_option_value('modifiable', true, { buf = bufnr })
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { line })
  vim.api.nvim_set_option_value('modifiable', false, { buf = bufnr })

  vim.api.nvim_win_set_config(winid, {
    relative = "win",
    win = self._parent_winid,
    row = row,
    col = col,
    width = display_w,
    height = 1,
  })
end

---Reposition and rebuild left border window.
---@param row number Row relative to parent
---@param col number Col relative to parent
---@param height number New visible height
function EmbeddedContainer:reposition_border_left(row, col, height)
  local winid = self._border_left_winid
  if not winid or not vim.api.nvim_win_is_valid(winid) then return end
  local chars = self._border_chars
  if not chars then return end

  local lines = self:_build_side_border_lines(chars, "left", height)

  local bufnr = self._border_left_bufnr
  vim.api.nvim_set_option_value('modifiable', true, { buf = bufnr })
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.api.nvim_set_option_value('modifiable', false, { buf = bufnr })

  vim.api.nvim_win_set_config(winid, {
    relative = "win",
    win = self._parent_winid,
    row = row,
    col = col,
    width = 1,
    height = height,
  })
end

---Reposition and rebuild right border window.
---@param row number Row relative to parent
---@param col number Col relative to parent
---@param height number New visible height
function EmbeddedContainer:reposition_border_right(row, col, height)
  local winid = self._border_right_winid
  if not winid or not vim.api.nvim_win_is_valid(winid) then return end
  local chars = self._border_chars
  if not chars then return end

  local lines = self:_build_side_border_lines(chars, "right", height)

  local bufnr = self._border_right_bufnr
  vim.api.nvim_set_option_value('modifiable', true, { buf = bufnr })
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.api.nvim_set_option_value('modifiable', false, { buf = bufnr })

  vim.api.nvim_win_set_config(winid, {
    relative = "win",
    win = self._parent_winid,
    row = row,
    col = col,
    width = 1,
    height = height,
  })
end

-- ============================================================================
-- Border Window Helpers (private)
-- ============================================================================

---Get the border character from a border element (handles {char, hl} tables)
---@param elem string|table
---@return string
local function border_char(elem)
  if type(elem) == "table" then return elem[1] or "" end
  return elem or ""
end

---Build a single-line string for top or bottom border window.
---@param chars table 8-element border character table
---@param side "top"|"bottom"
---@param inner_width number Width of content area (excluding corners)
---@param include_left_corner boolean Whether to include the left corner char
---@param include_right_corner boolean Whether to include the right corner char
---@return string
function EmbeddedContainer:_build_border_line(chars, side, inner_width, include_left_corner, include_right_corner)
  local left_corner, fill, right_corner
  if side == "top" then
    left_corner = border_char(chars[1])
    fill = border_char(chars[2])
    right_corner = border_char(chars[3])
  else
    left_corner = border_char(chars[7])
    fill = border_char(chars[6])
    right_corner = border_char(chars[5])
  end
  local result = ""
  if include_left_corner then result = result .. left_corner end
  result = result .. string.rep(fill, inner_width)
  if include_right_corner then result = result .. right_corner end
  return result
end

---Build multi-line content for left or right border window.
---@param chars table 8-element border character table
---@param side "left"|"right"
---@param height number Number of rows
---@return string[]
function EmbeddedContainer:_build_side_border_lines(chars, side, height)
  local ch
  if side == "left" then
    ch = border_char(chars[8])
  else
    ch = border_char(chars[4])
  end
  local lines = {}
  for _ = 1, height do
    table.insert(lines, ch)
  end
  return lines
end

---Extract the FloatBorder highlight group from winhighlight string.
---@return string The highlight group name for borders
function EmbeddedContainer:_extract_border_hl()
  local whl = self._config.winhighlight or ""
  local hl = whl:match("FloatBorder:([^,]+)")
  return hl or "NvimFloatBorder"
end

-- ============================================================================
-- Border Window Lifecycle (private)
-- ============================================================================

---Helper to create a single border window with its buffer.
---@param lines string[] Buffer content lines
---@param row number Row relative to parent
---@param col number Col relative to parent
---@param width number Window width
---@param height number Window height
---@param border_hl string Highlight group for border chars
---@return number winid
---@return number bufnr
function EmbeddedContainer:_create_border_win(lines, row, col, width, height, border_hl)
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value('buftype', 'nofile', { buf = bufnr })
  vim.api.nvim_set_option_value('bufhidden', 'wipe', { buf = bufnr })
  vim.api.nvim_set_option_value('swapfile', false, { buf = bufnr })
  vim.api.nvim_set_option_value('modifiable', true, { buf = bufnr })
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.api.nvim_set_option_value('modifiable', false, { buf = bufnr })

  local winid = vim.api.nvim_open_win(bufnr, false, {
    relative = "win",
    win = self._parent_winid,
    row = row,
    col = col,
    width = width,
    height = height,
    zindex = self._zindex,
    border = "none",
    style = "minimal",
    focusable = false,
  })

  vim.api.nvim_set_option_value('wrap', false, { win = winid })
  vim.api.nvim_set_option_value('winblend', self.config.winblend or 0, { win = winid })
  vim.api.nvim_set_option_value('winhighlight',
    'Normal:' .. border_hl .. ',NormalFloat:' .. border_hl, { win = winid })

  return winid, bufnr
end

---Create all 4 border windows. Called lazily by scroll_sync on first sync.
function EmbeddedContainer:_setup_border_windows()
  if self._border_windows_initialized then return end

  local scroll_sync = require("nvim-float.container.scroll_sync")
  local chars = scroll_sync.border_to_table(self._original_border)
  if not chars then return end

  local border_hl = self:_extract_border_hl()
  local orig_w = self._original_width
  local orig_h = self._original_height
  local buf_row = self._buffer_row
  local buf_col = self._buffer_col
  local bt = self._border_top
  local bl = self._border_left

  -- Store resolved chars for later reposition calls
  self._border_chars = chars

  -- Top border: 1 row × (orig_w + left + right corners)
  local top_line = self:_build_border_line(chars, "top", orig_w, true, true)
  local top_w = vim.fn.strdisplaywidth(top_line)
  self._border_top_winid, self._border_top_bufnr = self:_create_border_win(
    { top_line }, buf_row, buf_col, top_w, 1, border_hl)

  -- Bottom border: 1 row × (orig_w + left + right corners)
  local bot_line = self:_build_border_line(chars, "bottom", orig_w, true, true)
  local bot_w = vim.fn.strdisplaywidth(bot_line)
  self._border_bottom_winid, self._border_bottom_bufnr = self:_create_border_win(
    { bot_line }, buf_row + bt + orig_h, buf_col, bot_w, 1, border_hl)

  -- Left border: orig_h rows × 1 col
  if bl > 0 then
    local left_lines = self:_build_side_border_lines(chars, "left", orig_h)
    self._border_left_winid, self._border_left_bufnr = self:_create_border_win(
      left_lines, buf_row + bt, buf_col, 1, orig_h, border_hl)
  end

  -- Right border: orig_h rows × 1 col
  local br = self._border_right
  if br > 0 then
    local right_lines = self:_build_side_border_lines(chars, "right", orig_h)
    self._border_right_winid, self._border_right_bufnr = self:_create_border_win(
      right_lines, buf_row + bt, buf_col + bl + orig_w, 1, orig_h, border_hl)
  end

  -- Reconfigure content window to borderless and reposition
  vim.api.nvim_win_set_config(self.winid, {
    relative = "win",
    win = self._parent_winid,
    row = buf_row + bt,
    col = buf_col + bl,
    width = orig_w,
    height = orig_h,
    border = "none",
  })

  self._border_windows_initialized = true
end

---Close all 4 border windows and their buffers.
function EmbeddedContainer:_close_border_windows()
  local wins = {
    { winid = "_border_top_winid", bufnr = "_border_top_bufnr" },
    { winid = "_border_bottom_winid", bufnr = "_border_bottom_bufnr" },
    { winid = "_border_left_winid", bufnr = "_border_left_bufnr" },
    { winid = "_border_right_winid", bufnr = "_border_right_bufnr" },
  }
  for _, w in ipairs(wins) do
    if self[w.winid] and vim.api.nvim_win_is_valid(self[w.winid]) then
      vim.api.nvim_win_close(self[w.winid], true)
    end
    self[w.winid] = nil
    if self[w.bufnr] and vim.api.nvim_buf_is_valid(self[w.bufnr]) then
      vim.api.nvim_buf_delete(self[w.bufnr], { force = true })
    end
    self[w.bufnr] = nil
  end
  self._border_windows_initialized = false
  self._border_chars = nil
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
---@param border string|table? Border override (for dynamic clipping)
function EmbeddedContainer:update_region(row, col, width, height, border)
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

  local win_config = {
    relative = "win",
    win = self._parent_winid,
    row = self._row,
    col = self._col,
    width = self._width,
    height = self._height,
  }
  if border ~= nil then
    win_config.border = border
  end
  vim.api.nvim_win_set_config(self.winid, win_config)

  -- Reposition scrollbar
  if self._scrollbar_winid and vim.api.nvim_win_is_valid(self._scrollbar_winid) then
    self:_reposition_scrollbar()
  end

  -- Reposition arrow
  self:_reposition_arrow()
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
  -- Invalidate cache so update() regenerates content for the new height
  self._scrollbar_last_top = nil
  self._scrollbar_last_total = nil
  self._scrollbar_last_content = nil
  get_scrollbar().update(self)
end

-- ============================================================================
-- Arrow Overlay Window (private)
-- ============================================================================

---Create a 1×1 non-focusable window showing ▼ at the last column of this container.
---Used by dropdown/multi-dropdown so the arrow doesn't occupy buffer space.
function EmbeddedContainer:_setup_arrow()
  if self._arrow_winid and vim.api.nvim_win_is_valid(self._arrow_winid) then
    return
  end

  -- Create buffer with arrow glyph
  self._arrow_bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value('buftype', 'nofile', { buf = self._arrow_bufnr })
  vim.api.nvim_set_option_value('bufhidden', 'wipe', { buf = self._arrow_bufnr })
  vim.api.nvim_set_option_value('swapfile', false, { buf = self._arrow_bufnr })
  vim.api.nvim_set_option_value('modifiable', true, { buf = self._arrow_bufnr })
  vim.api.nvim_buf_set_lines(self._arrow_bufnr, 0, -1, false, { "\u{25BC}" })
  vim.api.nvim_set_option_value('modifiable', false, { buf = self._arrow_bufnr })

  -- Open 1×1 window at last column, relative to this container's window
  self._arrow_winid = vim.api.nvim_open_win(self._arrow_bufnr, false, {
    relative = "win",
    win = self.winid,
    row = 0,
    col = self._width - 1,
    width = 1,
    height = 1,
    style = "minimal",
    focusable = false,
    zindex = self._zindex + 1,
  })

  vim.api.nvim_set_option_value('wrap', false, { win = self._arrow_winid })
  vim.api.nvim_set_option_value('winblend', self.config.winblend or 0, { win = self._arrow_winid })
  vim.api.nvim_set_option_value('winhighlight',
    'Normal:NvimFloatDropdownArrow,NormalFloat:NvimFloatDropdownArrow', { win = self._arrow_winid })
end

---Close the arrow overlay window and its buffer.
function EmbeddedContainer:_close_arrow()
  if self._arrow_winid and vim.api.nvim_win_is_valid(self._arrow_winid) then
    vim.api.nvim_win_close(self._arrow_winid, true)
  end
  self._arrow_winid = nil
  if self._arrow_bufnr and vim.api.nvim_buf_is_valid(self._arrow_bufnr) then
    vim.api.nvim_buf_delete(self._arrow_bufnr, { force = true })
  end
  self._arrow_bufnr = nil
end

---Reposition the arrow overlay to track container width changes.
function EmbeddedContainer:_reposition_arrow()
  if not self._arrow_winid or not vim.api.nvim_win_is_valid(self._arrow_winid) then
    return
  end
  vim.api.nvim_win_set_config(self._arrow_winid, {
    relative = "win",
    win = self.winid,
    row = 0,
    col = self._width - 1,
    width = 1,
    height = 1,
  })
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
  -- Close border windows
  self:_close_border_windows()

  -- Close arrow
  self:_close_arrow()

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
