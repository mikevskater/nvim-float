---@module 'nvim-float.container.virtual'
---@brief VirtualContainer - Holds container state, renders as text in parent buffer
---
---At rest, all container types (input/dropdown/multi-dropdown/generic container)
---are rendered as styled text directly in the parent buffer. Only when the user
---activates a field does a real window get created (materialized). At most 1
---container is real at a time.

local EmbeddedInput = require("nvim-float.container.input")
local EmbeddedDropdown = require("nvim-float.container.dropdown")
local EmbeddedMultiDropdown = require("nvim-float.container.multi_dropdown")
local EmbeddedContainer = require("nvim-float.container")

---Convert a 0-indexed display (cell) column to a 0-indexed byte column.
---@param line string Buffer line text
---@param dcol number 0-indexed display column
---@return number 0-indexed byte offset
local function displaycol_to_byte(line, dcol)
  if dcol <= 0 or #line == 0 then return 0 end
  local n = vim.fn.strchars(line)
  local width_so_far = 0
  for i = 0, n - 1 do
    if width_so_far >= dcol then
      return vim.fn.byteidx(line, i)
    end
    local byte_start = vim.fn.byteidx(line, i)
    local byte_end = vim.fn.byteidx(line, i + 1)
    if byte_end < 0 then byte_end = #line end
    local ch = line:sub(byte_start + 1, byte_end)
    width_so_far = width_so_far + vim.fn.strdisplaywidth(ch)
  end
  return #line
end

---@class VirtualContainer
---@field name string Unique key for this container
---@field type "embedded_input"|"embedded_dropdown"|"embedded_multi_dropdown"|"container"
---@field _definition table Raw definition from ContentBuilder._containers
---@field _parent_float FloatWindow
---@field _state table { value: string, options: table[], values: string[], selected: string, scroll_offset: number }
---@field _materialized boolean Whether a real window currently exists
---@field _real_field EmbeddedInput|EmbeddedDropdown|EmbeddedMultiDropdown|EmbeddedContainer|nil
---@field _ns number Extmark namespace for virtual rendering
---@field _row number 0-indexed row in parent buffer
---@field _col number 0-indexed col in parent buffer
---@field _width number Display width (visual, border-inclusive)
---@field _height number 1 for inputs/dropdowns, multi-line for containers
---@field _border_chars table|nil Resolved 8-char border table (container type)
---@field _border_top number Border top offset (container type)
---@field _border_bottom number Border bottom offset (container type)
---@field _border_left number Border left offset (container type)
---@field _border_right number Border right offset (container type)
---@field _inner_width number Content width inside borders (container type)
---@field _inner_height number Content height inside borders (container type)
---@field _content_builder ContentBuilder|nil Nested content builder (container type)
---@field _content_lines string[] Cached build_lines() output (container type)
---@field _content_highlights table[] Cached highlights (container type)
---@field _total_content_lines number Total lines in content_builder (container type)
local VirtualContainer = {}
VirtualContainer.__index = VirtualContainer

-- ============================================================================
-- Constructor
-- ============================================================================

---Create a new VirtualContainer from a ContentBuilder definition
---@param name string Field key
---@param def table Container definition from ContentBuilder
---@param parent_float FloatWindow
---@return VirtualContainer
function VirtualContainer.new(name, def, parent_float)
  local self = setmetatable({}, VirtualContainer)

  self.name = name
  self.type = def.type
  self._definition = def
  self._parent_float = parent_float
  self._materialized = false
  self._real_field = nil
  self._ns = vim.api.nvim_create_namespace("nvim_float_virtual_" .. name)
  self._dirty = true  -- Needs initial render
  self._suppress_content = false  -- When true, render_virtual skips content (frame only)
  self._row = def.row or 0
  self._width = def.width or parent_float._win_width
  self._height = 1

  -- Resolve column (same logic as FloatWindow:_resolve_container_col)
  if def.col then
    self._col = def.col
  else
    local col = math.floor((parent_float._win_width - self._width) / 2)
    self._col = math.max(0, col)
  end

  -- Initialize state from definition
  if def.type == "embedded_input" then
    self._state = {
      value = def.value or "",
    }
  elseif def.type == "embedded_dropdown" then
    self._state = {
      value = def.selected or "",
      options = def.options or {},
    }
  elseif def.type == "embedded_multi_dropdown" then
    self._state = {
      values = vim.deepcopy(def.selected or {}),
      options = def.options or {},
      display_mode = def.display_mode or "count",
    }
  elseif def.type == "container" then
    self._height = def.height
    -- Compute border offsets
    local scroll_sync = require("nvim-float.container.scroll_sync")
    self._border_chars = scroll_sync.border_to_table(def.border)
    local nav = require("nvim-float.container.navigation")
    local bt, bb, bl, br = nav.compute_border_offsets(def.border)
    self._border_top = bt
    self._border_bottom = bb
    self._border_left = bl
    self._border_right = br
    self._inner_width = math.max(1, self._width - bl - br)
    self._inner_height = math.max(1, self._height - bt - bb)
    -- Pre-build content lines from nested content_builder
    self._content_builder = def.content_builder
    self._content_lines = {}
    self._content_highlights = {}
    if def.content_builder then
      self._content_lines = def.content_builder:build_lines()
      local highlights_mod = require("nvim-float.content.highlights")
      self._content_highlights = highlights_mod.build_highlights(def.content_builder)
    end
    self._total_content_lines = #self._content_lines
    self._state = {
      scroll_offset = 0,
    }
  end

  return self
end

-- ============================================================================
-- Virtual Rendering
-- ============================================================================

---Render this container as styled text directly in the parent buffer.
---Writes into the parent buffer at [_row, _col:_col+_width].
---Note: _col and _width are in display columns. Since ContentBuilder reserves
---blank lines (ASCII only) for containers, display cols == byte offsets here.
function VirtualContainer:render_virtual()
  self._dirty = false

  -- When suppressed, skip rendering entirely for input/dropdown types.
  -- For generic containers, render borders only (content area blank).
  if self._suppress_content then
    if self.type == "container" then
      return self:_render_virtual_container_frame_only()
    end
    return
  end

  if self.type == "container" then
    return self:_render_virtual_container()
  end

  local fw = self._parent_float
  if not fw or not fw:is_valid() then return end

  local bufnr = fw.bufnr
  local row = self._row
  local col = self._col   -- Display column (= byte offset for ASCII-padded lines)
  local width = self._width

  -- Build display text and highlight group
  local display, hl_group = self:_build_display_text()

  -- Pad/truncate to exact width (display columns)
  local display_width = vim.fn.strdisplaywidth(display)
  if display_width < width then
    display = display .. string.rep(" ", width - display_width)
  elseif display_width > width then
    display = self:_truncate_to_width(display, width)
  end

  -- Get current line content
  local lines = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)
  local line = lines[1] or ""

  -- ContentBuilder reserves blank/label lines for containers.
  -- These lines are ASCII, so byte length == display width.
  -- Ensure line is long enough for our col position.
  if #line < col then
    line = line .. string.rep(" ", col - #line)
  end

  -- Build new line: [before_col][display_text][after_end]
  -- Use display-width arithmetic to find the after boundary, since the
  -- previous render may have left multi-byte chars with different byte lengths.
  local before = line:sub(1, col)
  local after_start = displaycol_to_byte(line, col + width)
  local after = ""
  if after_start < #line then
    after = line:sub(after_start + 1)
  end

  local new_line = before .. display .. after
  local end_byte = col + #display  -- byte offset after rendered display text

  -- Write the line
  vim.api.nvim_set_option_value('modifiable', true, { buf = bufnr })
  vim.api.nvim_buf_set_lines(bufnr, row, row + 1, false, { new_line })
  vim.api.nvim_set_option_value('modifiable', fw.config.modifiable or false, { buf = bufnr })

  -- Apply highlight via extmark (clear entire namespace to remove any stale
  -- extmarks that may have drifted to adjacent rows during buffer rewrites)
  vim.api.nvim_buf_clear_namespace(bufnr, self._ns, 0, -1)
  pcall(vim.api.nvim_buf_add_highlight, bufnr, self._ns, hl_group, row, col, end_byte)

  -- For dropdowns, add arrow indicator at end of field region
  if self.type == "embedded_dropdown" or self.type == "embedded_multi_dropdown" then
    local arrow_dcol = width - 2
    if arrow_dcol > 0 then
      -- Convert display column within the rendered text to byte offset
      local arrow_byte_in_display = displaycol_to_byte(display, arrow_dcol)
      pcall(vim.api.nvim_buf_set_extmark, bufnr, self._ns, row, col + arrow_byte_in_display, {
        virt_text = { { "\u{25BC}", "NvimFloatInputPlaceholder" } },  -- ▼
        virt_text_pos = "overlay",
      })
    end
  end
end

-- ============================================================================
-- Container Virtual Rendering (multi-line)
-- ============================================================================

---Render a generic container as multi-line styled text in the parent buffer.
---Draws borders, content lines with scroll offset, highlights, and scrollbar.
function VirtualContainer:_render_virtual_container()
  local fw = self._parent_float
  if not fw or not fw:is_valid() then return end

  local bufnr = fw.bufnr
  local col = self._col
  local width = self._width
  local height = self._height
  local bt = self._border_top or 0
  local bb = self._border_bottom or 0
  local bl = self._border_left or 0
  local br = self._border_right or 0
  local inner_w = self._inner_width
  local inner_h = self._inner_height
  local chars = self._border_chars
  local scroll_offset = self._state.scroll_offset

  -- Clear previous extmarks for all rows
  vim.api.nvim_buf_clear_namespace(bufnr, self._ns, self._row, self._row + height)

  -- Build all rendered lines and track border highlights
  local rendered_lines = {}
  local border_highlights = {}  -- { visual_row, byte_start, byte_end, hl_group }

  for visual_row = 0, height - 1 do
    local line_text

    if bt > 0 and visual_row == 0 and chars then
      -- Top border row
      line_text = self:_build_border_text_line(chars, "top", inner_w)
      table.insert(border_highlights, { visual_row, 0, #line_text, "NvimFloatBorder" })

    elseif bb > 0 and visual_row == height - 1 and chars then
      -- Bottom border row
      line_text = self:_build_border_text_line(chars, "bottom", inner_w)
      table.insert(border_highlights, { visual_row, 0, #line_text, "NvimFloatBorder" })

    else
      -- Content row (with optional side borders)
      local content_idx = visual_row - bt + scroll_offset + 1  -- 1-indexed
      local content_text = ""
      if self._content_lines and content_idx >= 1 and content_idx <= self._total_content_lines then
        content_text = self._content_lines[content_idx]
      end

      -- Pad/truncate content to inner_width
      local cw = vim.fn.strdisplaywidth(content_text)
      if cw < inner_w then
        content_text = content_text .. string.rep(" ", inner_w - cw)
      elseif cw > inner_w then
        content_text = self:_truncate_to_width(content_text, inner_w)
      end

      local left_char = ""
      local right_char = ""
      if bl > 0 and chars then
        left_char = self:_get_border_char(chars[8])
      end
      if br > 0 and chars then
        right_char = self:_get_border_char(chars[4])
      end

      line_text = left_char .. content_text .. right_char

      -- Border highlights for side chars
      if bl > 0 then
        table.insert(border_highlights, { visual_row, 0, #left_char, "NvimFloatBorder" })
      end
      if br > 0 then
        local rc_start = #left_char + #content_text
        table.insert(border_highlights, { visual_row, rc_start, rc_start + #right_char, "NvimFloatBorder" })
      end
    end

    table.insert(rendered_lines, line_text or "")
  end

  -- Splice each rendered line into the parent buffer
  vim.api.nvim_set_option_value('modifiable', true, { buf = bufnr })

  for i, rendered in ipairs(rendered_lines) do
    local row = self._row + (i - 1)
    local lines = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)
    local line = lines[1] or ""

    -- Ensure line is long enough
    if #line < col then
      line = line .. string.rep(" ", col - #line)
    end

    -- Pad rendered text to full width
    local rw = vim.fn.strdisplaywidth(rendered)
    if rw < width then
      rendered = rendered .. string.rep(" ", width - rw)
    end

    -- Splice: [before_col][rendered_text][after_end]
    -- Use display-width boundary to find after, since previous render may
    -- have left multi-byte chars with different byte lengths.
    local before = line:sub(1, col)
    local after = ""
    local after_start = displaycol_to_byte(line, col + width)
    if after_start < #line then
      after = line:sub(after_start + 1)
    end

    vim.api.nvim_buf_set_lines(bufnr, row, row + 1, false, { before .. rendered .. after })
  end

  vim.api.nvim_set_option_value('modifiable', fw.config.modifiable or false, { buf = bufnr })

  -- Apply border highlights
  for _, hl in ipairs(border_highlights) do
    local row = self._row + hl[1]
    pcall(vim.api.nvim_buf_add_highlight, bufnr, self._ns, hl[4], row, col + hl[2], col + hl[3])
  end

  -- Apply content highlights from nested content_builder
  self:_apply_virtual_container_highlights()

  -- Render scrollbar indicator if content overflows
  if self._total_content_lines > inner_h then
    self:_render_virtual_scrollbar_indicator()
  end
end

---Render only the border frame of a generic container (no content, no scrollbar).
---Used when the container is about to be re-materialized so the real window
---covers the content area. Avoids flashing by not drawing virtual content
---that would be immediately replaced.
function VirtualContainer:_render_virtual_container_frame_only()
  local fw = self._parent_float
  if not fw or not fw:is_valid() then return end

  local bufnr = fw.bufnr
  local col = self._col
  local width = self._width
  local height = self._height
  local bt = self._border_top or 0
  local bb = self._border_bottom or 0
  local bl = self._border_left or 0
  local br = self._border_right or 0
  local inner_w = self._inner_width
  local chars = self._border_chars

  -- Clear previous extmarks
  vim.api.nvim_buf_clear_namespace(bufnr, self._ns, self._row, self._row + height)

  local rendered_lines = {}
  local border_highlights = {}

  for visual_row = 0, height - 1 do
    local line_text

    if bt > 0 and visual_row == 0 and chars then
      line_text = self:_build_border_text_line(chars, "top", inner_w)
      table.insert(border_highlights, { visual_row, 0, #line_text, "NvimFloatBorder" })

    elseif bb > 0 and visual_row == height - 1 and chars then
      line_text = self:_build_border_text_line(chars, "bottom", inner_w)
      table.insert(border_highlights, { visual_row, 0, #line_text, "NvimFloatBorder" })

    else
      -- Content row: borders + blank content (real window will cover this)
      local left_char = ""
      local right_char = ""
      if bl > 0 and chars then
        left_char = self:_get_border_char(chars[8])
      end
      if br > 0 and chars then
        right_char = self:_get_border_char(chars[4])
      end
      line_text = left_char .. string.rep(" ", inner_w) .. right_char

      if bl > 0 then
        table.insert(border_highlights, { visual_row, 0, #left_char, "NvimFloatBorder" })
      end
      if br > 0 then
        local rc_start = #left_char + inner_w
        table.insert(border_highlights, { visual_row, rc_start, rc_start + #right_char, "NvimFloatBorder" })
      end
    end

    table.insert(rendered_lines, line_text or "")
  end

  -- Splice into parent buffer
  vim.api.nvim_set_option_value('modifiable', true, { buf = bufnr })

  for i, rendered in ipairs(rendered_lines) do
    local row = self._row + (i - 1)
    local lines = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)
    local line = lines[1] or ""

    if #line < col then
      line = line .. string.rep(" ", col - #line)
    end

    local rw = vim.fn.strdisplaywidth(rendered)
    if rw < width then
      rendered = rendered .. string.rep(" ", width - rw)
    end

    local before = line:sub(1, col)
    local after = ""
    local after_start = displaycol_to_byte(line, col + width)
    if after_start < #line then
      after = line:sub(after_start + 1)
    end

    vim.api.nvim_buf_set_lines(bufnr, row, row + 1, false, { before .. rendered .. after })
  end

  vim.api.nvim_set_option_value('modifiable', fw.config.modifiable or false, { buf = bufnr })

  -- Apply border highlights only
  for _, hl in ipairs(border_highlights) do
    local row = self._row + hl[1]
    pcall(vim.api.nvim_buf_add_highlight, bufnr, self._ns, hl[4], row, col + hl[2], col + hl[3])
  end

  -- Render scrollbar indicator (part of the visual frame, not content).
  -- This ensures the scrollbar is visible when the container is about to be
  -- re-materialized, since the real window is created with scrollbar=false.
  if self._total_content_lines > self._inner_height then
    self:_render_virtual_scrollbar_indicator()
  end
end

---Extract a character from a border element (handles {char, hl} tables)
---@param elem string|table
---@return string
function VirtualContainer:_get_border_char(elem)
  if type(elem) == "table" then return elem[1] or "" end
  return elem or ""
end

---Build a single-line string for top or bottom border.
---@param chars table 8-element border character table
---@param side "top"|"bottom"
---@param inner_width number Width of content area
---@return string
function VirtualContainer:_build_border_text_line(chars, side, inner_width)
  local left_corner, fill, right_corner
  if side == "top" then
    left_corner = self:_get_border_char(chars[1])
    fill = self:_get_border_char(chars[2])
    right_corner = self:_get_border_char(chars[3])
  else
    left_corner = self:_get_border_char(chars[7])
    fill = self:_get_border_char(chars[6])
    right_corner = self:_get_border_char(chars[5])
  end
  return left_corner .. string.rep(fill, inner_width) .. right_corner
end

---Apply content highlights from the nested content_builder to the parent buffer.
---Offsets highlight positions by container row/col and accounts for scroll.
---Uses byte widths of border chars (not display columns) for correct positioning.
function VirtualContainer:_apply_virtual_container_highlights()
  if not self._content_highlights or #self._content_highlights == 0 then return end

  local fw = self._parent_float
  if not fw or not fw:is_valid() then return end

  local bufnr = fw.bufnr
  local base_col = self._col
  local bt = self._border_top or 0
  local inner_h = self._inner_height
  local scroll_offset = self._state.scroll_offset

  -- Compute byte width of left border char (not display columns)
  local bl_bytes = 0
  if (self._border_left or 0) > 0 and self._border_chars then
    bl_bytes = #self:_get_border_char(self._border_chars[8])
  end

  for _, hl in ipairs(self._content_highlights) do
    -- hl.line is 0-indexed content line
    local content_line = hl.line
    if content_line >= scroll_offset and content_line < scroll_offset + inner_h then
      local visual_row = content_line - scroll_offset
      local parent_row = self._row + bt + visual_row
      local col_start = base_col + bl_bytes + (hl.col_start or 0)
      local col_end = base_col + bl_bytes + (hl.col_end or col_start)
      if col_end > col_start then
        pcall(vim.api.nvim_buf_add_highlight, bufnr, self._ns, hl.hl_group, parent_row, col_start, col_end)
      end
    end
  end
end

---Render a text-based scrollbar using overlay extmarks at the right edge.
---Tracks extmark IDs in _scrollbar_extmark_ids so callers can update the
---scrollbar incrementally (e.g. during materialized scroll) without clearing
---the entire namespace.
function VirtualContainer:_render_virtual_scrollbar_indicator()
  local fw = self._parent_float
  if not fw or not fw:is_valid() then return end

  local bufnr = fw.bufnr
  local bt = self._border_top or 0
  local br = self._border_right or 0
  local inner_h = self._inner_height
  local total = self._total_content_lines
  local scroll_offset = self._state.scroll_offset

  if total <= inner_h or inner_h <= 0 then return end

  -- Remove previous scrollbar extmarks (allows incremental re-render)
  if self._scrollbar_extmark_ids then
    for _, id in ipairs(self._scrollbar_extmark_ids) do
      pcall(vim.api.nvim_buf_del_extmark, bufnr, self._ns, id)
    end
  end
  self._scrollbar_extmark_ids = {}

  -- Calculate thumb position and size
  local thumb_size = math.max(1, math.floor(inner_h * inner_h / total + 0.5))
  local max_offset = total - inner_h
  local thumb_pos = 0
  if max_offset > 0 then
    thumb_pos = math.floor(scroll_offset * (inner_h - thumb_size) / max_offset + 0.5)
  end
  thumb_pos = math.max(0, math.min(thumb_pos, inner_h - thumb_size))

  -- Scrollbar display column: on border char if present, else last content col
  local target_dcol
  if br > 0 then
    target_dcol = self._col + self._width - br
  else
    target_dcol = self._col + self._width - 1
  end

  for i = 0, inner_h - 1 do
    local row = self._row + bt + i
    local char, hl
    if i >= thumb_pos and i < thumb_pos + thumb_size then
      char = "\u{2588}"  -- █
      hl = "NvimFloatScrollbar"
    else
      char = "\u{2591}"  -- ░
      hl = "NvimFloatBorder"
    end
    -- Convert display column to byte offset using actual buffer line content
    local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""
    local byte_col = displaycol_to_byte(line, target_dcol)
    local ok, id = pcall(vim.api.nvim_buf_set_extmark, bufnr, self._ns, row, byte_col, {
      virt_text = { { char, hl } },
      virt_text_pos = "overlay",
    })
    if ok and id then
      table.insert(self._scrollbar_extmark_ids, id)
    end
  end
end

---Build the display text and highlight group for virtual rendering.
---@return string display_text
---@return string highlight_group
function VirtualContainer:_build_display_text()
  if self.type == "embedded_input" then
    local value = self._state.value
    if value == "" then
      local placeholder = self._definition.placeholder or ""
      return placeholder, "NvimFloatInputPlaceholder"
    end
    return value, "NvimFloatInput"

  elseif self.type == "embedded_dropdown" then
    local value = self._state.value
    if value == "" then
      local placeholder = self._definition.placeholder or "Select..."
      return placeholder, "NvimFloatInputPlaceholder"
    end
    -- Find label for current value
    for _, opt in ipairs(self._state.options) do
      if opt.value == value then
        return opt.label, "NvimFloatInput"
      end
    end
    return value, "NvimFloatInput"

  elseif self.type == "embedded_multi_dropdown" then
    local values = self._state.values
    if #values == 0 then
      local placeholder = self._definition.placeholder or "Select..."
      return placeholder, "NvimFloatInputPlaceholder"
    end
    if self._state.display_mode == "list" then
      local labels = {}
      for _, val in ipairs(values) do
        for _, opt in ipairs(self._state.options) do
          if opt.value == val then
            table.insert(labels, opt.label)
            break
          end
        end
      end
      return table.concat(labels, ", "), "NvimFloatInput"
    end
    return string.format("%d selected", #values), "NvimFloatInput"
  end

  return "", "Normal"
end

---Truncate a string to fit within a display width
---@param text string
---@param max_width number
---@return string
function VirtualContainer:_truncate_to_width(text, max_width)
  local n = vim.fn.strchars(text)
  for i = n, 1, -1 do
    local sub = vim.fn.strcharpart(text, 0, i)
    if vim.fn.strdisplaywidth(sub) <= max_width then
      return sub .. string.rep(" ", max_width - vim.fn.strdisplaywidth(sub))
    end
  end
  return string.rep(" ", max_width)
end

-- ============================================================================
-- Materialize / Dematerialize
-- ============================================================================

---Create a real container window for this field.
---@param on_deactivate fun()? Callback when user exits the field (Esc)
function VirtualContainer:materialize(on_deactivate)
  if self._materialized then return end

  local fw = self._parent_float
  if not fw or not fw:is_valid() then return end

  self._materialized = true

  -- Convert buffer row to viewport-relative row for child window placement.
  -- relative='win' positions are relative to the window viewport, not the buffer.
  local topline = vim.fn.line('w0', fw.winid)
  local scroll_adj = topline - 1

  -- For input types, clear virtual rendering (real window covers the region).
  -- For generic containers, keep virtual border/scrollbar extmarks visible
  -- so the transition is seamless.
  if self.type ~= "container" then
    vim.api.nvim_buf_clear_namespace(fw.bufnr, self._ns, self._row, self._row + self._height)
  end

  -- Build config common to all field types
  local config = {
    key = self.name,
    row = self._row - scroll_adj,
    col = self._col,
    width = self._width,
    parent_winid = fw.winid,
    parent_float = fw,
    zindex_offset = self._definition.zindex_offset,
    winhighlight = self._definition.winhighlight,
    border = self._definition.border,
  }

  -- Create the real field with restored state
  if self.type == "embedded_input" then
    config.placeholder = self._definition.placeholder
    config.value = self._state.value
    config.on_change = self._definition.on_change
    config.on_submit = self._definition.on_submit
    self._real_field = EmbeddedInput.new(config)

  elseif self.type == "embedded_dropdown" then
    config.options = self._state.options
    config.selected = self._state.value
    config.placeholder = self._definition.placeholder
    config.max_height = self._definition.max_height
    config.on_change = function(key, value)
      self._state.value = value
      if self._definition.on_change then
        self._definition.on_change(key, value)
      end
    end
    self._real_field = EmbeddedDropdown.new(config)

  elseif self.type == "embedded_multi_dropdown" then
    config.options = self._state.options
    config.selected = self._state.values
    config.placeholder = self._definition.placeholder
    config.max_height = self._definition.max_height
    config.display_mode = self._state.display_mode
    config.on_change = function(key, values)
      self._state.values = vim.deepcopy(values)
      if self._definition.on_change then
        self._definition.on_change(key, values)
      end
    end
    self._real_field = EmbeddedMultiDropdown.new(config)

  elseif self.type == "container" then
    -- Create borderless real container at content area only.
    -- Virtual border text and scrollbar extmarks stay visible in parent buffer
    -- for seamless appearance during activation.
    local def = self._definition
    local bt = self._border_top or 0
    local bl = self._border_left or 0

    -- Viewport clamping: clamp dimensions to fit within parent window.
    -- relative='win' windows are NOT clipped by Neovim, so we must do it manually.
    local viewport_row = self._row + bt - scroll_adj
    local viewport_col = self._col + bl
    local parent_h = fw._win_height
    local parent_w = fw._win_width

    local clip_top = math.max(0, -viewport_row)
    local clip_bottom = math.max(0, (viewport_row + self._inner_height) - parent_h)
    local clip_right = math.max(0, (viewport_col + self._inner_width) - parent_w)
    local clamped_h = math.max(1, self._inner_height - clip_top - clip_bottom)
    local clamped_w = math.max(1, self._inner_width - clip_right)
    local clamped_row = math.max(0, viewport_row)

    -- Abort if container is fully off-screen
    if self._inner_height - clip_top - clip_bottom < 1
      or self._inner_width - clip_right < 1 then
      self._materialized = false
      return
    end

    -- Derive winhighlight: match parent's Normal background for seamless blend
    local container_whl = def.winhighlight
    if not container_whl then
      local parent_whl = fw.config.winhighlight or 'Normal:Normal'
      local parent_normal = parent_whl:match('Normal:([^,]+)') or 'Normal'
      container_whl = 'Normal:' .. parent_normal .. ',CursorLine:NvimFloatSelected'
    end

    self._real_field = EmbeddedContainer.new({
      name = self.name,
      row = clamped_row,
      col = viewport_col,
      width = clamped_w,
      height = clamped_h,
      parent_winid = fw.winid,
      parent_float = fw,
      zindex_offset = def.zindex_offset,
      border = "none",
      focusable = def.focusable,
      scrollbar = false,
      content_builder = def.content_builder,
      on_focus = def.on_focus,
      on_blur = def.on_blur,
      winhighlight = container_whl,
      cursorline = false,
    })

    -- Store scroll-sync fields so WinScrolled sync computes correct deltas
    if self._real_field then
      self._real_field._buffer_row = self._row + bt
      self._real_field._buffer_col = self._col + bl
      self._real_field._original_width = self._inner_width
      self._real_field._original_height = self._inner_height
      self._real_field._last_clip_top = clip_top
      self._real_field._last_clip_bottom = clip_bottom
      self._real_field._last_clip_right = clip_right
    end

    -- Restore scroll position, adjusted for top clipping
    local adjusted_scroll = (self._state.scroll_offset or 0) + clip_top
    if adjusted_scroll > 0 and self._real_field:is_valid() then
      pcall(vim.api.nvim_win_call, self._real_field.winid, function()
        vim.cmd("normal! " .. (adjusted_scroll + 1) .. "zt")
      end)
    end

    -- Setup real-time scrollbar: update virtual scrollbar extmarks as user scrolls
    if self._total_content_lines > self._inner_height and self._real_field:is_valid() then
      local augroup = vim.api.nvim_create_augroup("nvim_float_vscroll_" .. self.name, { clear = true })
      self._scroll_augroup = augroup
      local vself = self
      local function update_scrollbar()
        if not vself._real_field or not vself._real_field:is_valid() then return end
        if not vself._parent_float or not vself._parent_float:is_valid() then return end
        local topline = vim.fn.line('w0', vself._real_field.winid)
        vself._state.scroll_offset = topline - 1
        vself:_render_virtual_scrollbar_indicator()
      end
      vim.api.nvim_create_autocmd("CursorMoved", {
        group = augroup,
        buffer = self._real_field.bufnr,
        callback = function()
          vim.schedule(update_scrollbar)
        end,
      })
      vim.api.nvim_create_autocmd("WinScrolled", {
        group = augroup,
        callback = function()
          if not vself._real_field or not vself._real_field:is_valid() then return end
          local winid_str = tostring(vself._real_field.winid)
          if vim.v.event and vim.v.event[winid_str] then
            vim.schedule(update_scrollbar)
          end
        end,
      })
    end
  end

  -- Setup Esc keymap to deactivate
  if self._real_field and on_deactivate then
    local container = self:get_container()
    if container and container.bufnr and vim.api.nvim_buf_is_valid(container.bufnr) then
      vim.keymap.set('n', '<Esc>', function()
        on_deactivate()
      end, { buffer = container.bufnr, noremap = true, silent = true, desc = "Deactivate virtual container" })
    end
  end
end

---Sync state from real field, destroy it, re-render as virtual text.
function VirtualContainer:dematerialize()
  if not self._materialized then return end

  -- Clean up scroll-tracking autocmds
  if self._scroll_augroup then
    pcall(vim.api.nvim_del_augroup_by_id, self._scroll_augroup)
    self._scroll_augroup = nil
  end

  -- Sync state from real field
  if self._real_field then
    if self.type == "embedded_input" then
      self._state.value = self._real_field:get_value()
    elseif self.type == "embedded_dropdown" then
      self._state.value = self._real_field:get_value()
    elseif self.type == "embedded_multi_dropdown" then
      self._state.values = self._real_field:get_values()
    elseif self.type == "container" then
      -- Save scroll position from real window
      if self._real_field:is_valid() then
        local topline = vim.fn.line('w0', self._real_field.winid)
        self._state.scroll_offset = topline - 1
      end
    end

    -- Close real field (destroys buffer, window, autocmds, keymaps)
    self._real_field:close()
    self._real_field = nil
  end

  self._materialized = false
  self._suppress_content = false

  -- Re-render as virtual text
  self:render_virtual()
end

-- ============================================================================
-- Value Access
-- ============================================================================

---Get the current value
---@return string|string[]|nil
function VirtualContainer:get_value()
  if self.type == "container" then return nil end

  if self._materialized and self._real_field then
    if self.type == "embedded_input" then
      return self._real_field:get_value()
    elseif self.type == "embedded_dropdown" then
      return self._real_field:get_value()
    elseif self.type == "embedded_multi_dropdown" then
      return self._real_field:get_values()
    end
  end

  -- Read from cached state
  if self.type == "embedded_multi_dropdown" then
    return vim.deepcopy(self._state.values)
  end
  return self._state.value
end

---Set the value programmatically
---@param value string|string[]
function VirtualContainer:set_value(value)
  if self.type == "container" then return end

  if self.type == "embedded_multi_dropdown" then
    self._state.values = vim.deepcopy(type(value) == "table" and value or {})
    if self._materialized and self._real_field then
      self._real_field:set_values(self._state.values)
    end
  else
    self._state.value = type(value) == "string" and value or ""
    if self._materialized and self._real_field then
      self._real_field:set_value(self._state.value)
    end
  end

  -- Update virtual rendering if not materialized
  if not self._materialized then
    self._dirty = true
    self:render_virtual()
  end
end

-- ============================================================================
-- Query
-- ============================================================================

---Mark this container as needing re-render
function VirtualContainer:mark_dirty()
  self._dirty = true
end

---Check if this container needs re-rendering
---@return boolean
function VirtualContainer:is_dirty()
  return self._dirty
end

---Check if this virtual container is currently materialized (has a real window)
---@return boolean
function VirtualContainer:is_materialized()
  return self._materialized
end

---Get the real field instance (only valid when materialized)
---@return EmbeddedInput|EmbeddedDropdown|EmbeddedMultiDropdown|EmbeddedContainer|nil
function VirtualContainer:get_real_field()
  return self._real_field
end

---Get the underlying EmbeddedContainer (only valid when materialized)
---@return EmbeddedContainer|nil
function VirtualContainer:get_container()
  if self.type == "container" then
    return self._real_field  -- _real_field IS the EmbeddedContainer
  end
  if self._real_field then
    return self._real_field:get_container()
  end
  return nil
end

---Check if a dropdown list is currently open on this field
---@return boolean
function VirtualContainer:is_list_open()
  if not self._materialized or not self._real_field then return false end
  if self.type == "embedded_dropdown" or self.type == "embedded_multi_dropdown" then
    return self._real_field._list_open == true
  end
  return false
end

---Close the virtual container, cleaning up all resources
function VirtualContainer:close()
  if self._materialized then
    self:dematerialize()
  end
  -- Clear any remaining extmarks
  local fw = self._parent_float
  if fw and fw:is_valid() then
    pcall(vim.api.nvim_buf_clear_namespace, fw.bufnr, self._ns, 0, -1)
  end
end

return VirtualContainer
