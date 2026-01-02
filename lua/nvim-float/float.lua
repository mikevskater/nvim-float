---@class ControlKeyDef
---@field key string The key or key combination
---@field desc string Description of what the key does

---@class ControlsDefinition
---@field header string? Section header text
---@field keys ControlKeyDef[] Array of key definitions

---@class FloatConfig
---Configuration for floating window creation
---@field title string? Window title text
---@field title_pos "left"|"center"|"right"? Title alignment (default: "center")
---@field footer string? Footer text
---@field footer_pos "left"|"center"|"right"? Footer alignment (default: "center")
---@field border "none"|"single"|"double"|"rounded"|"solid"|"shadow"|table? Border style (default: "rounded")
---@field width number? Fixed width in columns
---@field min_width number? Minimum width
---@field max_width number? Maximum width (default: vim.o.columns - 4)
---@field height number? Fixed height in rows
---@field min_height number? Minimum height
---@field max_height number? Maximum height (default: vim.o.lines - 6)
---@field relative "editor"|"cursor"|"win"? Position relative to (default: "editor")
---@field row number? Y position (for non-centered)
---@field col number? X position (for non-centered)
---@field centered boolean? Center window on screen (default: true)
---@field enter boolean? Enter window after creation (default: true)
---@field focusable boolean? Window can receive focus (default: true)
---@field keymaps table<string, function|string>? Key -> function/command mappings
---@field default_keymaps boolean? Include default close keys (q, <Esc>) (default: true)
---@field filetype string? Buffer filetype for syntax highlighting
---@field buftype string? Buffer type (default: "nofile")
---@field readonly boolean? Make buffer read-only (default: true)
---@field modifiable boolean? Allow buffer modifications (default: false)
---@field winhighlight string? Custom window highlight groups
---@field winblend number? Window transparency 0-100 (default: 0)
---@field cursorline boolean? Highlight cursor line (default: true)
---@field wrap boolean? Enable line wrapping (default: false)
---@field zindex number? Window layer ordering (default: 50)
---@field on_close function? Callback when window closes
---@field style "minimal"|nil? Window style (default: "minimal")
---@field content_builder ContentBuilder? ContentBuilder instance for styled content with inputs
---@field enable_inputs boolean? Enable input field mode for the window
---@field scrollbar boolean? Show scrollbar when content exceeds window height (default: true)
---@field controls ControlsDefinition[]? Controls/keybindings to show in "?" popup

---@class FloatWindow
---A floating window instance
---@field bufnr number Buffer handle
---@field winid number Window handle
---@field config FloatConfig Configuration used
---@field lines string[] Current content lines
---@field _scrollbar_winid number? Scrollbar window handle
---@field _scrollbar_bufnr number? Scrollbar buffer handle
---@field _scrollbar_autocmd number? Autocmd ID for scroll tracking
local FloatWindow = {}
FloatWindow.__index = FloatWindow

---@class UiFloat
---Floating window utility module
---@module nvim-float.float
local UiFloat = {}

local Debug = require('nvim-float.debug')
local FloatLayout = require('nvim-float.float.layout')
local Scrollbar = require('nvim-float.float.scrollbar')
local Dialogs = require('nvim-float.float.dialogs')
local MultiPanel = require('nvim-float.float.multipanel')

---Z-index layers for proper window stacking
---Scrollbars are automatically +1 above their parent window
---@class ZIndexLayers
UiFloat.ZINDEX = {
  BASE = 50,        -- Base floating windows (multi-panel, standard floats)
  OVERLAY = 100,    -- Overlay windows (popups, tooltips, pickers)
  MODAL = 150,      -- Modal dialogs (confirmations, alerts)
  DROPDOWN = 200,   -- Dropdowns and menus (highest priority)
}

-- ============================================================================
-- Z-Index Layer Helpers
-- ============================================================================

---Z-index layer boundaries for bring_to_front/send_to_back operations
local LAYER_BOUNDS = {
  { min = 0, max = 99, base = UiFloat.ZINDEX.BASE },        -- BASE layer
  { min = 100, max = 149, base = UiFloat.ZINDEX.OVERLAY },  -- OVERLAY layer
  { min = 150, max = 199, base = UiFloat.ZINDEX.MODAL },    -- MODAL layer
  { min = 200, max = 250, base = UiFloat.ZINDEX.DROPDOWN }, -- DROPDOWN layer
}

---Get the base z-index for the layer containing the given z-index
---@param zindex number Current z-index value
---@return number base The base z-index for this layer
local function get_layer_base(zindex)
  for _, layer in ipairs(LAYER_BOUNDS) do
    if zindex >= layer.min and zindex <= layer.max then
      return layer.base
    end
  end
  return UiFloat.ZINDEX.BASE
end

---Get the maximum z-index for the layer containing the given z-index
---@param zindex number Current z-index value
---@return number max The maximum z-index for this layer
local function get_layer_max(zindex)
  for _, layer in ipairs(LAYER_BOUNDS) do
    if zindex >= layer.min and zindex <= layer.max then
      return layer.max
    end
  end
  return 99
end

---Create a new floating window
---@param lines string[]|FloatConfig? Initial content lines OR config (for convenience)
---@param config FloatConfig? Configuration options
---@return FloatWindow instance
function UiFloat.create(lines, config)
  -- Handle convenience call pattern: UiFloat.create({ title = "...", ... })
  -- If first arg is a table with config keys (not an array), treat it as config
  if type(lines) == "table" and not vim.islist(lines) then
    config = lines
    lines = {}
  end

  lines = lines or {}
  config = config or {}

  -- Handle content_builder in config
  local content_builder = config.content_builder
  local content_builder_is_new = false

  if content_builder == true then
    -- Create a new ContentBuilder if boolean true passed
    -- Don't build lines yet - user will populate it and call render()
    local ContentBuilder = require('nvim-float.content_builder')
    content_builder = ContentBuilder.new()
    config.content_builder = content_builder
    content_builder_is_new = true
    -- Start with empty lines - will be populated on render()
    lines = {""}
  elseif content_builder and type(content_builder) == "table" and content_builder.build_lines then
    -- Pre-populated ContentBuilder was passed, use its lines
    lines = content_builder:build_lines()
  end

  -- Track whether user explicitly specified dimensions (vs auto-calculated)
  local user_specified_width = config.width ~= nil
  local user_specified_height = config.height ~= nil

  local instance = setmetatable({
    bufnr = nil,
    winid = nil,
    config = config,
    lines = lines,
    _input_manager = nil,
    _content_builder = content_builder,
    _user_specified_width = user_specified_width,
    _user_specified_height = user_specified_height,
    -- Element tracking state
    _hovered_element = nil,       -- Currently hovered element name
    _element_hover_ns = nil,      -- Namespace for hover highlights
    _element_tracking_enabled = false,
  }, FloatWindow)

  -- Apply defaults
  instance:_apply_defaults()

  -- Create buffer
  instance:_create_buffer()

  -- Calculate dimensions
  local width, height = instance:_calculate_dimensions()

  -- Calculate position
  local row, col = instance:_calculate_position(width, height)

  -- Open window
  instance:_open_window(width, height, row, col)

  -- Store window geometry for scrollbar
  instance._win_row = row
  instance._win_col = col
  instance._win_width = width
  instance._win_height = height

  -- Setup buffer and window options
  instance:_setup_options()

  -- Setup keymaps
  instance:_setup_keymaps()

  -- Setup autocmds
  instance:_setup_autocmds()

  -- Setup scrollbar if enabled and content exceeds window height
  if instance.config.scrollbar then
    Scrollbar.setup(instance)
  end

  -- Apply styled content if content_builder provided
  if content_builder and instance:is_valid() then
    local ns_id = vim.api.nvim_create_namespace("nvim_float_content")
    content_builder:apply_to_buffer(instance.bufnr, ns_id)
    instance._content_ns = ns_id

    -- Setup inputs if enabled
    if config.enable_inputs then
      instance:_setup_input_manager(content_builder)
    end
  end

  return instance
end

---Apply default configuration values
function FloatWindow:_apply_defaults()
  local c = self.config

  c.title_pos = c.title_pos or "center"
  c.footer_pos = c.footer_pos or "center"
  c.border = c.border or "rounded"
  c.max_width = c.max_width or (vim.o.columns - 4)
  c.max_height = c.max_height or (vim.o.lines - 6)
  c.relative = c.relative or "editor"
  c.centered = c.centered ~= false  -- Default true
  c.enter = c.enter ~= false  -- Default true
  c.focusable = c.focusable ~= false  -- Default true
  c.default_keymaps = c.default_keymaps ~= false  -- Default true
  c.buftype = c.buftype or "nofile"
  c.readonly = c.readonly ~= false  -- Default true
  c.modifiable = c.modifiable or false
  c.winblend = c.winblend or 0
  c.cursorline = c.cursorline ~= false  -- Default true
  c.wrap = c.wrap or false
  c.zindex = c.zindex or 50
  c.style = c.style or "minimal"
  c.scrollbar = c.scrollbar ~= false  -- Default true

  -- Default footer to "? = Controls" when controls are defined
  if not c.footer and c.controls and #c.controls > 0 then
    c.footer = "? = Controls"
  end
end

---Create the buffer
function FloatWindow:_create_buffer()
  self.bufnr = vim.api.nvim_create_buf(false, true)  -- unlisted, scratch

  -- Set buffer options
  vim.api.nvim_buf_set_option(self.bufnr, 'buftype', self.config.buftype)
  vim.api.nvim_buf_set_option(self.bufnr, 'bufhidden', 'wipe')
  vim.api.nvim_buf_set_option(self.bufnr, 'swapfile', false)

  -- Call on_pre_filetype callback if provided
  -- This allows setting buffer variables BEFORE filetype triggers autocmds
  if self.config.on_pre_filetype then
    self.config.on_pre_filetype(self.bufnr)
  end

  if self.config.filetype then
    vim.api.nvim_buf_set_option(self.bufnr, 'filetype', self.config.filetype)
  end

  -- Set initial content
  vim.api.nvim_buf_set_lines(self.bufnr, 0, -1, false, self.lines)

  -- Set modifiable
  vim.api.nvim_buf_set_option(self.bufnr, 'modifiable', self.config.modifiable)
end

---Calculate window dimensions
---@return number width, number height
function FloatWindow:_calculate_dimensions()
  local width = self.config.width
  local height = self.config.height

  -- If both width and height are explicitly set, use them directly (for raw positioning)
  if width and height then
    return width, height
  end

  -- Auto-calculate width if not specified
  if not width then
    width = self.config.min_width or 60

    -- Calculate content width
    local max_line_width = 0
    for _, line in ipairs(self.lines) do
      local line_width = vim.fn.strdisplaywidth(line)
      if line_width > max_line_width then
        max_line_width = line_width
      end
    end

    -- Use content width if larger than min
    if max_line_width > width then
      width = max_line_width
    end
  end

  -- Auto-calculate height if not specified
  if not height then
    height = #self.lines  -- Use content height, constraints applied below
  end

  -- Apply constraints
  if self.config.min_width then
    width = math.max(width, self.config.min_width)
  end
  if self.config.max_width then
    width = math.min(width, self.config.max_width)
  end
  if self.config.min_height then
    height = math.max(height, self.config.min_height)
  end
  if self.config.max_height then
    -- Ensure max_height doesn't exceed available screen space (account for borders + cmdline)
    local screen_max = vim.o.lines - 6
    local effective_max = math.min(self.config.max_height, screen_max)
    height = math.min(height, effective_max)
  end

  -- Account for title/footer if present
  if self.config.title then
    local title_width = vim.fn.strdisplaywidth(self.config.title) + 2  -- Add padding
    width = math.max(width, title_width)
  end
  if self.config.footer then
    local footer_width = vim.fn.strdisplaywidth(self.config.footer) + 2
    width = math.max(width, footer_width)
  end

  return width, height
end

---Calculate window position
---@param width number Window width
---@param height number Window height
---@return number row, number col
function FloatWindow:_calculate_position(width, height)
  local row, col

  -- If row and col are explicitly set with centered=false, use them directly (for raw positioning)
  if not self.config.centered and self.config.row and self.config.col then
    return self.config.row, self.config.col
  end

  if self.config.centered then
    -- Center on screen
    row = math.floor((vim.o.lines - height) / 2)
    col = math.floor((vim.o.columns - width) / 2)
  elseif self.config.relative == "cursor" then
    -- Position relative to cursor
    row = self.config.row or 1
    col = self.config.col or 0
  else
    -- Use specified position
    row = self.config.row or 0
    col = self.config.col or 0
  end

  -- Ensure window stays on screen (account for borders: 2 lines, cmdline: 2 lines)
  row = math.max(0, math.min(row, vim.o.lines - height - 4))
  col = math.max(0, math.min(col, vim.o.columns - width - 2))

  return row, col
end

---Open the floating window
---@param width number Window width
---@param height number Window height
---@param row number Y position
---@param col number X position
function FloatWindow:_open_window(width, height, row, col)
  local win_config = {
    relative = self.config.relative,
    width = width,
    height = height,
    row = row,
    col = col,
    style = self.config.style,
    border = self.config.border,
    focusable = self.config.focusable,
    zindex = self.config.zindex,
  }

  -- Add title if specified
  if self.config.title then
    win_config.title = string.format(" %s ", self.config.title)
    win_config.title_pos = self.config.title_pos
  end

  -- Add footer if specified
  if self.config.footer then
    win_config.footer = string.format(" %s ", self.config.footer)
    win_config.footer_pos = self.config.footer_pos
  end

  self.winid = vim.api.nvim_open_win(self.bufnr, self.config.enter, win_config)
end

---Setup window and buffer options
function FloatWindow:_setup_options()
  local winid = self.winid

  -- Window options
  vim.api.nvim_set_option_value('wrap', self.config.wrap, { win = winid })
  vim.api.nvim_set_option_value('foldenable', false, { win = winid })
  vim.api.nvim_set_option_value('cursorline', self.config.cursorline, { win = winid })
  vim.api.nvim_set_option_value('number', false, { win = winid })
  vim.api.nvim_set_option_value('relativenumber', false, { win = winid })
  vim.api.nvim_set_option_value('signcolumn', 'no', { win = winid })
  vim.api.nvim_set_option_value('winblend', self.config.winblend, { win = winid })
  vim.api.nvim_set_option_value('scrolloff', 0, { win = winid })

  -- Apply themed highlight groups (allow override via winhighlight config)
  local default_winhighlight = 'Normal:Normal,FloatBorder:NvimFloatBorder,FloatTitle:NvimFloatTitle,CursorLine:NvimFloatSelected'
  local winhighlight = self.config.winhighlight or default_winhighlight
  vim.api.nvim_set_option_value('winhighlight', winhighlight, { win = winid })
end

---Setup keymaps
function FloatWindow:_setup_keymaps()
  local bufnr = self.bufnr
  local winid = self.winid

  -- Default close keymaps
  if self.config.default_keymaps then
    vim.keymap.set('n', 'q', function()
      self:close()
    end, { buffer = bufnr, noremap = true, silent = true, desc = "Close window" })

    vim.keymap.set('n', '<Esc>', function()
      self:close()
    end, { buffer = bufnr, noremap = true, silent = true, desc = "Close window" })
  end

  -- Controls popup keymap (when controls are defined)
  if self.config.controls and #self.config.controls > 0 then
    vim.keymap.set('n', '?', function()
      self:show_controls()
    end, { buffer = bufnr, noremap = true, silent = true, desc = "Show controls" })
  end

  -- Custom keymaps
  if self.config.keymaps then
    for key, handler in pairs(self.config.keymaps) do
      if type(handler) == "function" then
        vim.keymap.set('n', key, handler, { buffer = bufnr, noremap = true, silent = true })
      elseif type(handler) == "string" then
        vim.keymap.set('n', key, handler, { buffer = bufnr, noremap = true, silent = true })
      end
    end
  end
end

---Setup autocmds for cleanup and resize handling
function FloatWindow:_setup_autocmds()
  -- Create augroup for this window
  self._augroup = vim.api.nvim_create_augroup("nvim_float_" .. self.bufnr, { clear = true })

  if self.config.on_close then
    vim.api.nvim_create_autocmd("BufWipeout", {
      group = self._augroup,
      buffer = self.bufnr,
      once = true,
      callback = function()
        if self.config.on_close then
          self.config.on_close()
        end
      end,
    })
  end

  -- Handle terminal resize
  vim.api.nvim_create_autocmd("VimResized", {
    group = self._augroup,
    callback = function()
      if self:is_valid() then
        self:_recalculate_layout()
      end
    end,
  })
end

---Recalculate layout after terminal resize
function FloatWindow:_recalculate_layout()
  if not self:is_valid() then return end

  -- Update max constraints based on current terminal size
  local screen_max_width = vim.o.columns - 4
  local screen_max_height = vim.o.lines - 6

  -- Always update max constraints to current screen size
  self.config.max_width = screen_max_width
  self.config.max_height = screen_max_height

  -- For auto-sized windows, recalculate dimensions based on content
  local width, height

  if self._user_specified_width then
    -- User specified width, keep it but constrain to screen
    width = math.min(self.config.width, screen_max_width)
  else
    -- Auto-calculate width based on content
    width = self.config.min_width or 60
    local max_line_width = 0
    for _, line in ipairs(self.lines) do
      local line_width = vim.fn.strdisplaywidth(line)
      if line_width > max_line_width then
        max_line_width = line_width
      end
    end
    if max_line_width > width then
      width = max_line_width
    end
    -- Apply constraints
    if self.config.min_width then
      width = math.max(width, self.config.min_width)
    end
    width = math.min(width, screen_max_width)
  end

  if self._user_specified_height then
    -- User specified height, keep it but constrain to screen
    height = math.min(self.config.height, screen_max_height)
  else
    -- Auto-calculate height based on content, up to screen max
    height = math.min(#self.lines, screen_max_height)
    if self.config.min_height then
      height = math.max(height, self.config.min_height)
    end
  end

  -- Recalculate position
  local row, col = self:_calculate_position(width, height)

  -- Store updated geometry
  self._win_row = row
  self._win_col = col
  self._win_width = width
  self._win_height = height

  -- Update window config
  vim.api.nvim_win_set_config(self.winid, {
    relative = self.config.relative,
    width = width,
    height = height,
    row = row,
    col = col,
  })

  -- Reposition scrollbar if enabled
  if self.config.scrollbar then
    Scrollbar.reposition(self)
  end
end

---Update window content
---@param lines string[] New content lines
function FloatWindow:update_lines(lines)
  if not self:is_valid() then
    return
  end

  self.lines = lines

  -- Make buffer modifiable temporarily
  vim.api.nvim_buf_set_option(self.bufnr, 'modifiable', true)
  vim.api.nvim_buf_set_lines(self.bufnr, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(self.bufnr, 'modifiable', self.config.modifiable)

  -- Update scrollbar if enabled
  if self.config.scrollbar then
    Scrollbar.update(self)
  end
end

---@class FloatChunkedUpdateOpts
---@field chunk_size number? Lines per chunk (default 100)
---@field on_progress fun(written: number, total: number)? Progress callback
---@field on_chunk fun(start_line: number, end_line: number)? Called after each chunk is written (0-indexed lines)
---@field on_complete fun()? Completion callback

---Active chunked update state
---@type { timer: number?, cancelled: boolean }?
FloatWindow._chunked_state = nil

---Update window content in chunks to avoid blocking UI
---For large line counts, writes lines in chunks with vim.schedule() between each
---@param lines string[] New content lines
---@param opts FloatChunkedUpdateOpts? Options for chunked update
function FloatWindow:update_lines_chunked(lines, opts)
  if not self:is_valid() then
    if opts and opts.on_complete then opts.on_complete() end
    return
  end

  opts = opts or {}
  local chunk_size = opts.chunk_size or 100
  local on_progress = opts.on_progress
  local on_chunk = opts.on_chunk
  local on_complete = opts.on_complete
  local total_lines = #lines

  -- Cancel any existing chunked update
  self:cancel_chunked_update()

  -- For small line counts, use sync update
  if total_lines <= chunk_size then
    self:update_lines(lines)
    if on_chunk then on_chunk(0, total_lines - 1) end
    if on_progress then on_progress(total_lines, total_lines) end
    if on_complete then on_complete() end
    return
  end

  -- Initialize chunked state
  self._chunked_state = {
    timer = nil,
    cancelled = false,
  }

  local state = self._chunked_state
  local bufnr = self.bufnr
  local current_idx = 1
  local is_first_chunk = true

  -- Store lines for later (will be set after all chunks written)
  local final_lines = lines

  -- Make buffer modifiable for the duration of chunked write
  vim.api.nvim_buf_set_option(bufnr, 'modifiable', true)

  -- NOTE: Don't clear buffer first - causes visible flash
  -- First chunk will replace entire buffer content instead

  local float_self = self

  local function write_next_chunk()
    -- Check if cancelled or buffer no longer valid
    if state.cancelled or not float_self:is_valid() then
      float_self._chunked_state = nil
      return
    end

    local end_idx = math.min(current_idx + chunk_size - 1, total_lines)

    -- Extract chunk of lines
    local chunk = {}
    for i = current_idx, end_idx do
      table.insert(chunk, lines[i])
    end

    -- Write chunk to buffer
    local chunk_start_line = current_idx - 1  -- 0-indexed start line
    if is_first_chunk then
      -- First chunk: replace entire buffer content (avoids flash from clearing first)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, chunk)
      is_first_chunk = false
    else
      -- Subsequent chunks: append at the correct position
      vim.api.nvim_buf_set_lines(bufnr, chunk_start_line, chunk_start_line, false, chunk)
    end

    -- Apply highlights for this chunk immediately (prevents flash)
    if on_chunk then
      on_chunk(chunk_start_line, end_idx - 1)  -- 0-indexed line range
    end

    -- Report progress
    if on_progress then
      on_progress(end_idx, total_lines)
    end

    current_idx = end_idx + 1

    if current_idx <= total_lines then
      -- Schedule next chunk
      state.timer = vim.fn.timer_start(0, function()
        state.timer = nil
        vim.schedule(write_next_chunk)
      end)
    else
      -- All chunks written - finalize
      float_self.lines = final_lines
      vim.api.nvim_buf_set_option(bufnr, 'modifiable', float_self.config.modifiable)

      -- Update scrollbar if enabled
      if float_self.config.scrollbar then
        Scrollbar.update(float_self)
      end

      float_self._chunked_state = nil

      if on_complete then
        on_complete()
      end
    end
  end

  -- Start writing first chunk
  write_next_chunk()
end

---Cancel any in-progress chunked update
function FloatWindow:cancel_chunked_update()
  if self._chunked_state then
    self._chunked_state.cancelled = true
    if self._chunked_state.timer then
      vim.fn.timer_stop(self._chunked_state.timer)
      self._chunked_state.timer = nil
    end
    -- Restore buffer to configured modifiable state if it exists
    if self:is_valid() then
      pcall(vim.api.nvim_buf_set_option, self.bufnr, 'modifiable', self.config.modifiable)
    end
    self._chunked_state = nil
  end
end

---Check if a chunked update is currently in progress
---@return boolean
function FloatWindow:is_chunked_update_active()
  return self._chunked_state ~= nil and not self._chunked_state.cancelled
end

---Close the floating window
function FloatWindow:close()
  -- Clean up scrollbar first
  Scrollbar.close(self)

  if self:is_valid() then
    if vim.api.nvim_buf_is_valid(self.bufnr) then
      vim.api.nvim_buf_delete(self.bufnr, { force = true })
    end
    self.winid = nil
    self.bufnr = nil
  end
end

---Check if window is still valid
---@return boolean
function FloatWindow:is_valid()
  return self.bufnr and vim.api.nvim_buf_is_valid(self.bufnr)
    and self.winid and vim.api.nvim_win_is_valid(self.winid)
end

---Focus the window
function FloatWindow:focus()
  if self:is_valid() then
    vim.api.nvim_set_current_win(self.winid)
  end
end

---Get current cursor position in window
---@return number row, number col (1-indexed)
function FloatWindow:get_cursor()
  if self:is_valid() then
    return unpack(vim.api.nvim_win_get_cursor(self.winid))
  end
  return 1, 0
end

---Set cursor position
---@param row number Row (1-indexed)
---@param col number Column (0-indexed)
function FloatWindow:set_cursor(row, col)
  if self:is_valid() then
    -- Clamp row to valid buffer range (handles chunked rendering case)
    local line_count = vim.api.nvim_buf_line_count(self.bufnr)
    local clamped_row = math.max(1, math.min(row, line_count))
    vim.api.nvim_win_set_cursor(self.winid, { clamped_row, col })
  end
end

---Update window title
---@param title string|table New title (string or { text, pos } table)
function FloatWindow:update_title(title)
  if not self:is_valid() then return end
  local current_config = vim.api.nvim_win_get_config(self.winid)
  current_config.title = title
  vim.api.nvim_win_set_config(self.winid, current_config)
end

---Update window footer
---@param footer string|table New footer (string or { text, pos } table)
function FloatWindow:update_footer(footer)
  if not self:is_valid() then return end
  local current_config = vim.api.nvim_win_get_config(self.winid)
  current_config.footer = footer
  vim.api.nvim_win_set_config(self.winid, current_config)
end

-- ============================================================================
-- Z-Index / Panel Ordering Methods
-- ============================================================================

---Get current z-index
---@return number zindex The current z-index value
function FloatWindow:get_zindex()
  return self.config.zindex or UiFloat.ZINDEX.BASE
end

---Set specific z-index
---@param zindex number New z-index value
function FloatWindow:set_zindex(zindex)
  if not self:is_valid() then return end
  self.config.zindex = zindex
  vim.api.nvim_win_set_config(self.winid, { zindex = zindex })
  -- Update scrollbar to stay above window
  if self._scrollbar_winid and vim.api.nvim_win_is_valid(self._scrollbar_winid) then
    vim.api.nvim_win_set_config(self._scrollbar_winid, { zindex = zindex + 1 })
  end
end

---Bring window to front (highest z-index in current layer)
---Operates within layer bounds to maintain proper stacking order
function FloatWindow:bring_to_front()
  if not self:is_valid() then return end
  local current = self.config.zindex or UiFloat.ZINDEX.BASE
  -- Set to layer max (within layer bounds)
  local new_zindex = get_layer_max(current)
  self:set_zindex(new_zindex)
end

---Send window to back (lowest z-index in current layer)
---Operates within layer bounds to maintain proper stacking order
function FloatWindow:send_to_back()
  if not self:is_valid() then return end
  local current = self.config.zindex or UiFloat.ZINDEX.BASE
  local layer_base = get_layer_base(current)
  self:set_zindex(layer_base)
end

---Get the content builder associated with this window
---@return ContentBuilder?
function FloatWindow:get_content_builder()
  return self._content_builder
end

-- ============================================================================
-- Element Tracking Support
-- ============================================================================

---Get the element registry from the content builder
---@return ElementRegistry?
function FloatWindow:get_element_registry()
  if self._content_builder then
    return self._content_builder:get_registry()
  end
  return nil
end

---Get element at current cursor position
---@return TrackedElement? element The element at cursor, or nil
function FloatWindow:get_element_at_cursor()
  if not self:is_valid() then return nil end

  local registry = self:get_element_registry()
  if not registry then return nil end

  local cursor = vim.api.nvim_win_get_cursor(self.winid)
  local row = cursor[1] - 1  -- Convert to 0-indexed
  local col = cursor[2]      -- Already 0-indexed

  return registry:get_at(row, col)
end

---Get element by name
---@param name string Element name
---@return TrackedElement? element
function FloatWindow:get_element(name)
  local registry = self:get_element_registry()
  if registry then
    return registry:get(name)
  end
  return nil
end

---Get all elements of a specific type
---@param element_type string Element type to filter by
---@return TrackedElement[] elements
function FloatWindow:get_elements_by_type(element_type)
  local registry = self:get_element_registry()
  if registry then
    return registry:get_by_type(element_type)
  end
  return {}
end

---Get all interactive elements
---@return TrackedElement[] elements
function FloatWindow:get_interactive_elements()
  local registry = self:get_element_registry()
  if registry then
    return registry:get_interactive()
  end
  return {}
end

---Interact with element at current cursor position
---@return boolean success Whether an element was interacted with
function FloatWindow:interact_at_cursor()
  local element = self:get_element_at_cursor()
  if not element then return false end

  -- For input/dropdown/multi_dropdown elements, delegate to InputManager
  if self._input_manager then
    local element_type = element.type
    if element_type == "input" or element_type == "dropdown" or element_type == "multi_dropdown" then
      -- Use the element name as the field key (they match)
      return self._input_manager:activate_field(element.name)
    end
  end

  -- For other interactive elements, call their interact handler
  if element:is_interactive() then
    element:interact()
    return true
  end

  return false
end

---Focus next interactive element
---@return boolean success Whether focus moved to an element
function FloatWindow:focus_next_element()
  local registry = self:get_element_registry()
  if not registry then return false end

  local current = self:get_element_at_cursor()
  local current_name = current and current.name or nil
  local next_el = registry:get_next_interactive(current_name)

  if next_el and self:is_valid() then
    -- Move cursor to element position (convert to 1-indexed row)
    local row = next_el.row + 1
    local col = next_el.col_start
    vim.api.nvim_win_set_cursor(self.winid, { row, col })
    return true
  end
  return false
end

---Focus previous interactive element
---@return boolean success Whether focus moved to an element
function FloatWindow:focus_prev_element()
  local registry = self:get_element_registry()
  if not registry then return false end

  local current = self:get_element_at_cursor()
  local current_name = current and current.name or nil
  local prev_el = registry:get_prev_interactive(current_name)

  if prev_el and self:is_valid() then
    -- Move cursor to element position (convert to 1-indexed row)
    local row = prev_el.row + 1
    local col = prev_el.col_start
    vim.api.nvim_win_set_cursor(self.winid, { row, col })
    return true
  end
  return false
end

---Check if window has any tracked elements
---@return boolean
function FloatWindow:has_elements()
  local registry = self:get_element_registry()
  return registry and not registry:is_empty() or false
end

---Enable element tracking (cursor-aware hover styles and focus/blur callbacks)
---Call this after rendering content to enable hover effects
---@param on_cursor_change fun(element: TrackedElement?)? Optional callback when cursor changes elements
function FloatWindow:enable_element_tracking(on_cursor_change)
  if self._element_tracking_enabled then return end
  if not self:is_valid() then return end

  self._element_tracking_enabled = true
  self._element_hover_ns = vim.api.nvim_create_namespace("nvim_float_element_hover")
  self._element_cursor_callback = on_cursor_change

  -- Setup CursorMoved autocmd
  vim.api.nvim_create_autocmd("CursorMoved", {
    group = self._augroup,
    buffer = self.bufnr,
    callback = function()
      self:_on_element_cursor_moved()
    end,
  })

  -- Trigger initial check
  self:_on_element_cursor_moved()
end

---Disable element tracking
function FloatWindow:disable_element_tracking()
  if not self._element_tracking_enabled then return end

  self._element_tracking_enabled = false

  -- Clear hover highlights
  if self._element_hover_ns and self.bufnr and vim.api.nvim_buf_is_valid(self.bufnr) then
    vim.api.nvim_buf_clear_namespace(self.bufnr, self._element_hover_ns, 0, -1)
  end

  -- Blur current element if any
  if self._hovered_element then
    local registry = self:get_element_registry()
    if registry then
      local element = registry:get(self._hovered_element)
      if element then
        element:blur()
      end
    end
    self._hovered_element = nil
  end
end

---Handle cursor movement for element tracking
---@private
function FloatWindow:_on_element_cursor_moved()
  if not self._element_tracking_enabled then return end
  if not self:is_valid() then return end

  local element = self:get_element_at_cursor()
  local new_name = element and element.name or nil
  local old_name = self._hovered_element

  -- No change
  if new_name == old_name then return end

  local registry = self:get_element_registry()
  if not registry then return end

  -- Blur old element
  if old_name then
    local old_element = registry:get(old_name)
    if old_element then
      self:_remove_element_hover(old_element)
      old_element:blur()
    end
  end

  -- Focus new element
  if new_name and element then
    self:_apply_element_hover(element)
    element:focus()
  end

  self._hovered_element = new_name

  -- Call user callback if provided
  if self._element_cursor_callback then
    self._element_cursor_callback(element)
  end
end

---Apply hover style to an element
---@param element TrackedElement
---@private
function FloatWindow:_apply_element_hover(element)
  if not element then return end
  if not self._element_hover_ns then return end
  if not self.bufnr or not vim.api.nvim_buf_is_valid(self.bufnr) then return end

  -- Get hover style from element or type defaults
  local hover_style = element.hover_style
  if not hover_style then
    local Types = require("nvim-float.elements.types")
    hover_style = Types.get_hover_style(element.type)
  end

  if not hover_style then return end

  -- Map style name to highlight group
  local hl_group = self:_get_highlight_group(hover_style)
  if not hl_group then return end

  -- Apply highlight using extmark
  local row = element.row
  local col_start = element.col_start
  local col_end = element.col_end

  if element.row_based then
    -- For row-based elements, highlight entire line
    local line = vim.api.nvim_buf_get_lines(self.bufnr, row, row + 1, false)[1]
    if line then
      col_end = #line
    end
  end

  vim.api.nvim_buf_set_extmark(self.bufnr, self._element_hover_ns, row, col_start, {
    end_row = row,
    end_col = col_end,
    hl_group = hl_group,
    priority = 200,  -- High priority to override base highlights
  })
end

---Remove hover style from an element
---@param element TrackedElement
---@private
function FloatWindow:_remove_element_hover(element)
  if not element then return end
  if not self._element_hover_ns then return end
  if not self.bufnr or not vim.api.nvim_buf_is_valid(self.bufnr) then return end

  -- Clear all extmarks in the hover namespace (simpler than tracking individual marks)
  vim.api.nvim_buf_clear_namespace(self.bufnr, self._element_hover_ns, 0, -1)
end

---Get highlight group for a style name
---@param style string Style name
---@return string? hl_group
---@private
function FloatWindow:_get_highlight_group(style)
  -- Map common style names to nvim-float highlight groups
  local style_to_hl = {
    -- Base styles
    normal = "NvimFloatNormal",
    border = "NvimFloatBorder",
    title = "NvimFloatTitle",
    selected = "NvimFloatSelected",
    hint = "NvimFloatHint",
    -- Text styles
    header = "NvimFloatHeader",
    subheader = "NvimFloatSubheader",
    section = "NvimFloatSection",
    label = "NvimFloatLabel",
    value = "NvimFloatValue",
    key = "NvimFloatKey",
    -- Emphasis
    emphasis = "NvimFloatEmphasis",
    strong = "NvimFloatStrong",
    muted = "NvimFloatMuted",
    dimmed = "NvimFloatDimmed",
    -- Status
    success = "NvimFloatSuccess",
    warning = "NvimFloatWarning",
    error = "NvimFloatError",
    -- Code
    code = "NvimFloatCode",
    code_keyword = "NvimFloatCodeKeyword",
    code_string = "NvimFloatCodeString",
    code_number = "NvimFloatCodeNumber",
    code_comment = "NvimFloatCodeComment",
    code_function = "NvimFloatCodeFunction",
    -- Input styles
    input = "NvimFloatInput",
    input_active = "NvimFloatInputActive",
    input_placeholder = "NvimFloatInputPlaceholder",
    dropdown = "NvimFloatDropdown",
    dropdown_active = "NvimFloatDropdownActive",
    dropdown_selected = "NvimFloatDropdownSelected",
  }

  return style_to_hl[style]
end

---Focus a specific element by name (move cursor to it)
---@param name string Element name
---@return boolean success
function FloatWindow:focus_element(name)
  local registry = self:get_element_registry()
  if not registry then return false end

  local element = registry:get(name)
  if not element then return false end

  if not self:is_valid() then return false end

  -- Move cursor to element position
  local row = element.row + 1  -- Convert to 1-indexed
  local col = element.col_start
  vim.api.nvim_win_set_cursor(self.winid, { row, col })

  return true
end

---Check if cursor is currently on a specific element
---@param name string Element name
---@return boolean
function FloatWindow:is_cursor_on(name)
  local element = self:get_element_at_cursor()
  return element and element.name == name or false
end

---Get the currently hovered element (if tracking is enabled)
---@return TrackedElement?
function FloatWindow:get_hovered_element()
  if not self._hovered_element then return nil end

  local registry = self:get_element_registry()
  if registry then
    return registry:get(self._hovered_element)
  end
  return nil
end

---Render/update content from content builder
---Call this after modifying the content builder to refresh the display
function FloatWindow:render()
  if not self:is_valid() then return end

  local cb = self._content_builder
  if not cb then return end

  -- Build lines from content builder
  local lines = cb:build_lines()

  -- Make buffer modifiable temporarily
  vim.api.nvim_buf_set_option(self.bufnr, 'modifiable', true)

  -- Set content
  vim.api.nvim_buf_set_lines(self.bufnr, 0, -1, false, lines)

  -- Apply highlights
  local ns_id = self._content_ns or vim.api.nvim_create_namespace("nvim_float_content")
  self._content_ns = ns_id
  vim.api.nvim_buf_clear_namespace(self.bufnr, ns_id, 0, -1)
  cb:apply_to_buffer(self.bufnr, ns_id)

  -- Setup inputs if enabled
  if self.config.enable_inputs then
    self:_setup_input_manager(cb)
  end

  -- Restore modifiable state
  vim.api.nvim_buf_set_option(self.bufnr, 'modifiable', self.config.modifiable or false)

  -- Update stored lines
  self.lines = lines

  -- Update scrollbar if enabled
  if self.config.scrollbar then
    Scrollbar.update(self)
  end
end

-- ============================================================================
-- Input Field Support for FloatWindow
-- ============================================================================

---Setup input manager from content builder
---@param content_builder ContentBuilder
function FloatWindow:_setup_input_manager(content_builder)
  local InputManager = require('nvim-float.input_manager')

  local inputs = content_builder:get_inputs()
  local input_order = content_builder:get_input_order()
  local dropdowns = content_builder:get_dropdowns()
  local dropdown_order = content_builder:get_dropdown_order()
  local multi_dropdowns = content_builder:get_multi_dropdowns()
  local multi_dropdown_order = content_builder:get_multi_dropdown_order()

  -- Create input manager with inputs, dropdowns, and multi-dropdowns
  self._input_manager = InputManager.new({
    bufnr = self.bufnr,
    winid = self.winid,
    inputs = inputs,
    input_order = input_order,
    dropdowns = dropdowns,
    dropdown_order = dropdown_order,
    multi_dropdowns = multi_dropdowns,
    multi_dropdown_order = multi_dropdown_order,
  })

  -- Setup input mode handling
  self._input_manager:setup()

  -- Initialize highlights for all fields (inputs and dropdowns)
  self._input_manager:init_highlights()

  -- Position cursor on first field if available (schedule to ensure window is ready)
  local first_field_key = self._input_manager._field_order[1]
  if first_field_key then
    local field_info = self._input_manager:_get_field(first_field_key)
    if field_info then
      vim.schedule(function()
        if vim.api.nvim_win_is_valid(self.winid) then
          vim.api.nvim_win_set_cursor(self.winid, {field_info.field.line, field_info.field.col_start})
        end
      end)
    end
  end
end

---Show the float (alias for focus)
function FloatWindow:show()
  self:focus()
end

---Enter input mode for a specific input or current input under cursor
---@param key string? Input key (optional - uses cursor position if not provided)
function FloatWindow:enter_input(key)
  if not self._input_manager then return end

  if key then
    self._input_manager:enter_input_mode(key)
  else
    -- Find input under cursor
    local cursor = vim.api.nvim_win_get_cursor(self.winid)
    local row = cursor[1]
    local col = cursor[2]

    for input_key, input in pairs(self._input_manager.inputs) do
      if input.line == row and col >= input.col_start and col < input.col_end then
        self._input_manager:enter_input_mode(input_key)
        return
      end
    end
  end
end

---Navigate to next input
function FloatWindow:next_input()
  if self._input_manager then
    self._input_manager:next_input()
  end
end

---Navigate to previous input
function FloatWindow:prev_input()
  if self._input_manager then
    self._input_manager:prev_input()
  end
end

---Get value of a specific input
---@param key string Input key
---@return string? value
function FloatWindow:get_input_value(key)
  if self._input_manager then
    return self._input_manager:get_value(key)
  end
  return nil
end

---Get all input values
---@return table<string, string> values Map of key -> value
function FloatWindow:get_all_input_values()
  if self._input_manager then
    return self._input_manager:get_all_values()
  end
  return {}
end

---Set value of a specific input
---@param key string Input key
---@param value string New value
function FloatWindow:set_input_value(key, value)
  if self._input_manager then
    self._input_manager:set_value(key, value)
  end
end

---Set callback for when input is submitted (Enter pressed in input mode)
---@param callback function Callback function to run on submit
function FloatWindow:on_input_submit(callback)
  if self._input_manager then
    self._input_manager.on_submit = callback
  end
end

---Get value of a specific dropdown
---@param key string Dropdown key
---@return string? value
function FloatWindow:get_dropdown_value(key)
  if self._input_manager then
    return self._input_manager:get_dropdown_value(key)
  end
  return nil
end

---Set value of a specific dropdown
---@param key string Dropdown key
---@param value string New value
function FloatWindow:set_dropdown_value(key, value)
  if self._input_manager then
    self._input_manager:set_dropdown_value(key, value)
  end
end

---Set callback for when dropdown value changes
---@param callback function Callback function (key, value)
function FloatWindow:on_dropdown_change(callback)
  if self._input_manager then
    self._input_manager.on_dropdown_change = callback
  end
end

---Get values of a specific multi-dropdown
---@param key string Multi-dropdown key
---@return string[]? values Array of selected values
function FloatWindow:get_multi_dropdown_values(key)
  if self._input_manager then
    return self._input_manager:get_multi_dropdown_values(key)
  end
  return nil
end

---Set values of a specific multi-dropdown
---@param key string Multi-dropdown key
---@param values string[] New selected values
function FloatWindow:set_multi_dropdown_values(key, values)
  if self._input_manager then
    self._input_manager:set_multi_dropdown_values(key, values)
  end
end

---Set callback for when multi-dropdown values change
---@param callback function Callback function (key, values)
function FloatWindow:on_multi_dropdown_change(callback)
  if self._input_manager then
    self._input_manager.on_multi_dropdown_change = callback
  end
end

---Create a simple confirmation dialog
---@param message string|string[] Message to display
---@param on_confirm function Callback on confirmation
---@param on_cancel function? Callback on cancel (optional)
---@return FloatWindow
function UiFloat.confirm(message, on_confirm, on_cancel)
  return Dialogs.confirm(UiFloat, message, on_confirm, on_cancel)
end

---Create a simple info dialog
---@param message string|string[] Message to display
---@param title string? Optional title
---@return FloatWindow
function UiFloat.info(message, title)
  return Dialogs.info(UiFloat, message, title)
end

---Create a selection menu
---@param items string[] List of items
---@param on_select function Callback with selected index
---@param title string? Optional title
---@return FloatWindow
function UiFloat.select(items, on_select, title)
  return Dialogs.select(UiFloat, items, on_select, title)
end

---Create a styled floating window using ContentBuilder
---@param content_builder ContentBuilder ContentBuilder instance with styled content
---@param config FloatConfig? Configuration options
---@return FloatWindow instance
function UiFloat.create_styled(content_builder, config)
  return Dialogs.create_styled(UiFloat, content_builder, config)
end

---Update a styled window with new ContentBuilder content
---@param content_builder ContentBuilder New styled content
function FloatWindow:update_styled(content_builder)
  Dialogs.update_styled(self, content_builder)
end

---Show controls popup
---@param controls ControlsDefinition[]? Controls to show (uses config.controls if nil)
function FloatWindow:show_controls(controls)
  controls = controls or self.config.controls
  Dialogs.show_controls_popup(UiFloat, controls)
end

---Get the ContentBuilder module for convenience
---@return ContentBuilder
function UiFloat.ContentBuilder()
  return Dialogs.ContentBuilder()
end

---Helper to show controls popup (shared by FloatWindow and MultiPanelWindow)
---@param controls ControlsDefinition[] Controls to display
function UiFloat._show_controls_popup(controls)
  Dialogs.show_controls_popup(UiFloat, controls)
end

-- ============================================================================
-- Multi-Panel Floating Window Support (delegates to multipanel.lua)
-- ============================================================================

---Create a multi-panel floating window
---@param config MultiPanelConfig Configuration
---@return MultiPanelState? state State object (nil if creation failed)
function UiFloat.create_multi_panel(config)
  return MultiPanel.create(UiFloat, config)
end

return UiFloat
