---@module 'nvim-float.content'
---@brief ContentBuilder - Build styled content for floating windows
---
---Supports:
--- - Semantic styles mapped to highlight groups
--- - Input fields, dropdowns, multi-dropdowns for forms
--- - Element tracking for cursor-based interactions
--- - Result table formatting with datatype coloring

local Elements = require("nvim-float.elements")
local Styles = require("nvim-float.theme.styles")

---@class ResultCellMap
---@field columns ResultColumnInfo[] Column boundary info (ordered by display position)
---@field header_lines {start_line: number, end_line: number}? Buffer lines for header row
---@field data_rows ResultRowInfo[] Data row boundary info (ordered by row index)
---@field row_num_column {start_col: number, end_col: number}? Row number column bounds (nil if not shown)

---@class ResultColumnInfo
---@field index number 1-based column index
---@field name string Column name
---@field start_col number 0-based start column in buffer
---@field end_col number 0-based end column in buffer (exclusive)

---@class ResultRowInfo
---@field index number 1-based data row index
---@field start_line number 1-based start line in buffer
---@field end_line number 1-based end line in buffer (for multi-line cells)

---@class ContentBuilder
---@field _result_cell_map ResultCellMap? Cell map for current result table
---Build styled content for floating windows using theme colors
local ContentBuilder = {}
ContentBuilder.__index = ContentBuilder

-- Import submodules (lazy-loaded for circular dependency safety)
local _lines, _highlights, _fields, _results

local function get_lines()
  if not _lines then _lines = require("nvim-float.content.lines") end
  return _lines
end

local function get_highlights()
  if not _highlights then _highlights = require("nvim-float.content.highlights") end
  return _highlights
end

local function get_fields()
  if not _fields then _fields = require("nvim-float.content.fields") end
  return _fields
end

local function get_results()
  if not _results then _results = require("nvim-float.content.results") end
  return _results
end

-- ============================================================================
-- Constructor and State Management
-- ============================================================================

---Create a new ContentBuilder instance
---@param opts? { max_width?: number } Optional configuration
---@return ContentBuilder
function ContentBuilder.new(opts)
  opts = opts or {}
  local self = setmetatable({}, ContentBuilder)
  self._lines = {}  -- Array of { text = string, highlights = {} }
  self._namespace = nil
  self._inputs = {}  -- Map of key -> InputField
  self._input_order = {}  -- Ordered list of input keys for Tab navigation
  self._dropdowns = {}  -- Map of key -> DropdownField
  self._dropdown_order = {}  -- Ordered list of dropdown keys
  self._multi_dropdowns = {}  -- Map of key -> MultiDropdownField
  self._multi_dropdown_order = {}  -- Ordered list of multi-dropdown keys
  self._max_width = opts.max_width  -- Optional: cap input widths to fit within this
  -- Element tracking
  self._registry = Elements.create_registry()  -- ElementRegistry for tracked elements
  return self
end

---Set maximum width for inputs (used to cap dropdowns to fit within panel)
---@param width number Maximum width in columns
---@return ContentBuilder self For chaining
function ContentBuilder:set_max_width(width)
  self._max_width = width
  return self
end

---Get the current max width setting
---@return number|nil max_width
function ContentBuilder:get_max_width()
  return self._max_width
end

---Clear all content, resetting the builder for reuse
---@return ContentBuilder self For chaining
function ContentBuilder:clear()
  self._lines = {}
  self._inputs = {}
  self._input_order = {}
  self._dropdowns = {}
  self._dropdown_order = {}
  self._multi_dropdowns = {}
  self._multi_dropdown_order = {}
  self._registry:clear()
  self._result_cell_map = nil
  self._containers = nil
  return self
end

---Get current line count (0-indexed, useful for tracking line positions)
---@return number count Current number of lines
function ContentBuilder:line_count()
  return #self._lines
end

-- ============================================================================
-- Result Cell Tracking
-- ============================================================================

---Start tracking a new result table (call before rendering)
---@return ContentBuilder self For chaining
function ContentBuilder:begin_result_table()
  self._result_cell_map = {
    columns = {},
    header_lines = nil,
    data_rows = {},
    row_num_column = nil,
  }
  return self
end

---Get the cell map for the most recently rendered result table
---@return ResultCellMap?
function ContentBuilder:get_result_cell_map()
  return self._result_cell_map
end

---Find which cell (if any) is at the given buffer position
---@param line number 1-based line number
---@param col number 0-based column number
---@return {row: number?, col: number?, is_header: boolean, is_row_num: boolean}?
function ContentBuilder:get_cell_at_position(line, col)
  local map = self._result_cell_map
  if not map then return nil end

  -- Check if in row number column
  local is_row_num = false
  if map.row_num_column then
    is_row_num = col >= map.row_num_column.start_col and col < map.row_num_column.end_col
  end

  -- Check if in header
  if map.header_lines and line >= map.header_lines.start_line and line <= map.header_lines.end_line then
    -- Find which column
    for _, col_info in ipairs(map.columns) do
      if col >= col_info.start_col and col < col_info.end_col then
        return { row = nil, col = col_info.index, is_header = true, is_row_num = is_row_num }
      end
    end
    if is_row_num then
      return { row = nil, col = nil, is_header = true, is_row_num = true }
    end
    return nil
  end

  -- Check data rows
  for _, row_info in ipairs(map.data_rows) do
    if line >= row_info.start_line and line <= row_info.end_line then
      -- Find which column
      for _, col_info in ipairs(map.columns) do
        if col >= col_info.start_col and col < col_info.end_col then
          return { row = row_info.index, col = col_info.index, is_header = false, is_row_num = is_row_num }
        end
      end
      if is_row_num then
        return { row = row_info.index, col = nil, is_header = false, is_row_num = true }
      end
      return nil
    end
  end

  return nil
end

---Get all cells within a rectangular selection
---@param start_line number 1-based start line
---@param start_col number 0-based start column
---@param end_line number 1-based end line
---@param end_col number 0-based end column
---@return {rows: number[], cols: number[], includes_header: boolean}?
function ContentBuilder:get_cells_in_range(start_line, start_col, end_line, end_col)
  local map = self._result_cell_map
  if not map then return nil end

  -- Normalize range (start <= end)
  if start_line > end_line then start_line, end_line = end_line, start_line end
  if start_col > end_col then start_col, end_col = end_col, start_col end

  local result = {
    rows = {},
    cols = {},
    includes_header = false,
  }

  -- Check if row number column is in range (selects all columns)
  local row_num_selected = false
  if map.row_num_column then
    row_num_selected = start_col < map.row_num_column.end_col and end_col >= map.row_num_column.start_col
  end

  -- Find columns in range
  local cols_set = {}
  if row_num_selected then
    -- Row number selected = all columns
    for _, col_info in ipairs(map.columns) do
      cols_set[col_info.index] = true
    end
  else
    for _, col_info in ipairs(map.columns) do
      -- Check if column overlaps with selection
      if start_col < col_info.end_col and end_col >= col_info.start_col then
        cols_set[col_info.index] = true
      end
    end
  end

  -- Convert to sorted array
  for col_idx in pairs(cols_set) do
    table.insert(result.cols, col_idx)
  end
  table.sort(result.cols)

  -- Check header
  if map.header_lines then
    if start_line <= map.header_lines.end_line and end_line >= map.header_lines.start_line then
      result.includes_header = true
    end
  end

  -- Find rows in range
  local rows_set = {}
  for _, row_info in ipairs(map.data_rows) do
    if start_line <= row_info.end_line and end_line >= row_info.start_line then
      rows_set[row_info.index] = true
    end
  end

  -- Convert to sorted array
  for row_idx in pairs(rows_set) do
    table.insert(result.rows, row_idx)
  end
  table.sort(result.rows)

  return result
end

-- ============================================================================
-- Style Mappings (delegates to theme.styles)
-- ============================================================================

---Get the highlight group for a style
---@param style string Style name
---@return string|nil group Highlight group name or nil for normal
function ContentBuilder.get_highlight(style)
  return Styles.get(style)
end

---Register additional style mappings
---@param styles table<string, string> Map of style name -> highlight group name
---@param override boolean? If true, allows overriding existing styles (default: false)
function ContentBuilder.register_styles(styles, override)
  if override then
    Styles.register(styles)
  else
    -- Only register if not already defined
    for style_name, hl_group in pairs(styles) do
      if not Styles.exists(style_name) then
        Styles.register({ [style_name] = hl_group })
      end
    end
  end
end

---Get all registered style mappings
---@return table<string, string> Copy of current style mappings
function ContentBuilder.get_style_mappings()
  return Styles.get_all()
end

---Get available style names
---@return string[] styles Array of available style names
function ContentBuilder.get_styles()
  return Styles.get_all_names()
end

---Debug: print all styles and their mappings
function ContentBuilder.print_styles()
  print("ContentBuilder Style Mappings:")
  print(string.rep("-", 40))
  local styles = ContentBuilder.get_styles()
  for _, name in ipairs(styles) do
    local group = Styles.get(name) or "(none)"
    print(string.format("  %-15s -> %s", name, group))
  end
end

-- ============================================================================
-- Element Tracking
-- ============================================================================

---Get the element registry
---@return ElementRegistry registry The element registry with all tracked elements
function ContentBuilder:get_registry()
  return self._registry
end

---Get a tracked element by name
---@param name string Element name
---@return TrackedElement? element The element or nil
function ContentBuilder:get_element(name)
  return self._registry:get(name)
end

---Get element at a specific position
---@param row number 0-indexed row
---@param col number 0-indexed column
---@return TrackedElement? element The element at position or nil
function ContentBuilder:get_element_at(row, col)
  return self._registry:get_at(row, col)
end

---Check if any elements are tracked
---@return boolean
function ContentBuilder:has_tracked_elements()
  return not self._registry:is_empty()
end

-- ============================================================================
-- Line Building Methods (delegated to content.lines)
-- ============================================================================

function ContentBuilder:line(text) return get_lines().line(self, text) end
function ContentBuilder:text(text) return get_lines().text(self, text) end
function ContentBuilder:blank() return get_lines().blank(self) end
function ContentBuilder:styled(text, style, opts) return get_lines().styled(self, text, style, opts) end
function ContentBuilder:header(text) return get_lines().header(self, text) end
function ContentBuilder:subheader(text) return get_lines().subheader(self, text) end
function ContentBuilder:section(text) return get_lines().section(self, text) end
function ContentBuilder:muted(text) return get_lines().muted(self, text) end
function ContentBuilder:bullet(text, style) return get_lines().bullet(self, text, style) end
function ContentBuilder:separator(char, width) return get_lines().separator(self, char, width) end
function ContentBuilder:label_value(label, value, opts) return get_lines().label_value(self, label, value, opts) end
function ContentBuilder:key_value(key, value) return get_lines().key_value(self, key, value) end
function ContentBuilder:spans(spans) return get_lines().spans(self, spans) end
function ContentBuilder:tracked(name, opts) return get_lines().tracked(self, name, opts) end
function ContentBuilder:button(text, opts) return get_lines().button(self, text, opts) end
function ContentBuilder:action(text, opts) return get_lines().action(self, text, opts) end
function ContentBuilder:toggle(text, opts) return get_lines().toggle(self, text, opts) end
function ContentBuilder:link(text, opts) return get_lines().link(self, text, opts) end
function ContentBuilder:status(status_type, text) return get_lines().status(self, status_type, text) end
function ContentBuilder:list_item(text, style, prefix) return get_lines().list_item(self, text, style, prefix) end
function ContentBuilder:table_row(columns) return get_lines().table_row(self, columns) end
function ContentBuilder:indent(text, level, style) return get_lines().indent(self, text, level, style) end

-- ============================================================================
-- Build and Render Methods (delegated to content.highlights)
-- ============================================================================

function ContentBuilder:build_lines() return get_highlights().build_lines(self) end
function ContentBuilder:build_highlights() return get_highlights().build_highlights(self) end
function ContentBuilder:build_raw_highlights() return get_highlights().build_raw_highlights(self) end
function ContentBuilder:apply_to_buffer(bufnr, ns_id) return get_highlights().apply_to_buffer(self, bufnr, ns_id) end
function ContentBuilder:render_to_buffer(bufnr, ns_id) return get_highlights().render_to_buffer(self, bufnr, ns_id) end
function ContentBuilder:render_to_buffer_chunked(bufnr, ns_id, opts) return get_highlights().render_to_buffer_chunked(self, bufnr, ns_id, opts) end

-- Static chunked render methods
ContentBuilder._chunked_state = {}
function ContentBuilder.cancel_chunked_render(bufnr) return get_highlights().cancel_chunked_render(bufnr) end
function ContentBuilder.is_chunked_render_active(bufnr) return get_highlights().is_chunked_render_active(bufnr) end

-- ============================================================================
-- Input Field Methods (delegated to content.fields)
-- ============================================================================

function ContentBuilder:input(key, opts) return get_fields().input(self, key, opts) end
function ContentBuilder:labeled_input(arg1, arg2, arg3, arg4) return get_fields().labeled_input(self, arg1, arg2, arg3, arg4) end
function ContentBuilder:get_inputs() return self._inputs end
function ContentBuilder:get_input_order() return self._input_order end
function ContentBuilder:get_input(key) return self._inputs[key] end
function ContentBuilder:set_input_value(key, value) return get_fields().set_input_value(self, key, value) end

function ContentBuilder:dropdown(key, opts) return get_fields().dropdown(self, key, opts) end
function ContentBuilder:labeled_dropdown(key, label, opts) return get_fields().labeled_dropdown(self, key, label, opts) end
function ContentBuilder:get_dropdowns() return self._dropdowns end
function ContentBuilder:get_dropdown_order() return self._dropdown_order end
function ContentBuilder:get_dropdown(key) return self._dropdowns[key] end
function ContentBuilder:set_dropdown_value(key, value) return get_fields().set_dropdown_value(self, key, value) end

function ContentBuilder:multi_dropdown(key, opts) return get_fields().multi_dropdown(self, key, opts) end
function ContentBuilder:labeled_multi_dropdown(key, label, opts) return get_fields().labeled_multi_dropdown(self, key, label, opts) end
function ContentBuilder:get_multi_dropdowns() return self._multi_dropdowns end
function ContentBuilder:get_multi_dropdown_order() return self._multi_dropdown_order end
function ContentBuilder:get_multi_dropdown(key) return self._multi_dropdowns[key] end
function ContentBuilder:set_multi_dropdown_values(key, values) return get_fields().set_multi_dropdown_values(self, key, values) end

-- ============================================================================
-- Result Table Methods (delegated to content.results)
-- ============================================================================

-- Static methods
ContentBuilder.datatype_to_style = function(datatype) return get_results().datatype_to_style(datatype) end
ContentBuilder.get_border_chars = function(style) return get_results().get_border_chars(style) end
ContentBuilder.wrap_text = function(text, max_width, mode, preserve_newlines) return get_results().wrap_text(text, max_width, mode, preserve_newlines) end
ContentBuilder.build_row_separator_with_rownum = function(columns, border_style, row_num_width) return get_results().build_row_separator_with_rownum(columns, border_style, row_num_width) end
ContentBuilder.calculate_column_positions = function(columns, row_num_width, border_style) return get_results().calculate_column_positions(columns, row_num_width, border_style) end

-- Instance methods
function ContentBuilder:result_header_row(columns, border_style) return get_results().result_header_row(self, columns, border_style) end
function ContentBuilder:result_top_border(columns, border_style) return get_results().result_top_border(self, columns, border_style) end
function ContentBuilder:result_separator(columns, border_style) return get_results().result_separator(self, columns, border_style) end
function ContentBuilder:result_bottom_border(columns, border_style) return get_results().result_bottom_border(self, columns, border_style) end
function ContentBuilder:result_data_row(values, color_mode, border_style, highlight_null) return get_results().result_data_row(self, values, color_mode, border_style, highlight_null) end
function ContentBuilder:result_message(text, style) return get_results().result_message(self, text, style) end
function ContentBuilder:result_row_separator(columns, border_style) return get_results().result_row_separator(self, columns, border_style) end
function ContentBuilder:result_multiline_data_row(cell_lines, color_mode, border_style, highlight_null, row_number, row_num_width) return get_results().result_multiline_data_row(self, cell_lines, color_mode, border_style, highlight_null, row_number, row_num_width) end
function ContentBuilder:result_header_row_with_rownum(columns, border_style, row_num_width) return get_results().result_header_row_with_rownum(self, columns, border_style, row_num_width) end
function ContentBuilder:result_top_border_with_rownum(columns, border_style, row_num_width) return get_results().result_top_border_with_rownum(self, columns, border_style, row_num_width) end
function ContentBuilder:result_separator_with_rownum(columns, border_style, row_num_width) return get_results().result_separator_with_rownum(self, columns, border_style, row_num_width) end
function ContentBuilder:result_bottom_border_with_rownum(columns, border_style, row_num_width) return get_results().result_bottom_border_with_rownum(self, columns, border_style, row_num_width) end
function ContentBuilder:result_row_separator_with_rownum(columns, border_style, row_num_width) return get_results().result_row_separator_with_rownum(self, columns, border_style, row_num_width) end
function ContentBuilder:add_cached_row_separator(separator_text) return get_results().add_cached_row_separator(self, separator_text) end

-- ============================================================================
-- Container Methods
-- ============================================================================

---Compute how many extra rows/cols a border adds
---@param border string|table|nil Border style
---@return number extra_rows Total extra rows (top + bottom)
---@return number extra_cols Total extra cols (left + right)
local function border_size(border)
  if not border or border == "none" then
    return 0, 0
  end
  -- All named borders ("single", "double", "rounded", "solid", "shadow")
  -- and table borders add 1 on each side
  return 2, 2
end

---Reserve space for an embedded container and record its definition
---The container will be created as a child window when the ContentBuilder is
---applied to a FloatWindow via UiFloat.create() or FloatWindow:render().
---@param name string Unique container name
---@param opts { height: number, width?: number, col?: number, border?: string|table, focusable?: boolean, scrollbar?: boolean, content_builder?: ContentBuilder, on_focus?: fun(), on_blur?: fun(), zindex_offset?: number, winhighlight?: string }
---@return ContentBuilder self For chaining
function ContentBuilder:container(name, opts)
  opts = opts or {}
  if not self._containers then
    self._containers = {}
  end

  -- Compute border size (border is INSIDE the specified dimensions)
  local border_rows, border_cols = border_size(opts.border)

  -- Record the start row (0-indexed line where container will be positioned)
  local start_row = #self._lines

  -- Reserve exactly opts.height lines - border is contained within
  for _ = 1, opts.height do
    table.insert(self._lines, { text = "", highlights = {} })
  end

  -- Store the container definition
  -- col = nil means "auto-center within parent"
  self._containers[name] = {
    type = "container",
    row = start_row,
    col = opts.col, -- nil = auto-center, number = explicit offset
    width = opts.width,
    height = opts.height,
    border = opts.border,
    border_rows = border_rows,
    border_cols = border_cols,
    focusable = opts.focusable,
    scrollbar = opts.scrollbar,
    content_builder = opts.content_builder,
    on_focus = opts.on_focus,
    on_blur = opts.on_blur,
    zindex_offset = opts.zindex_offset,
    winhighlight = opts.winhighlight,
  }

  return self
end

---Reserve space for an embedded text input and record its definition
---@param key string Unique input key
---@param opts { width: number, col?: number, placeholder?: string, value?: string, label?: string, on_change?: fun(key: string, value: string), on_submit?: fun(key: string, value: string), zindex_offset?: number, winhighlight?: string, border?: string|table }
---@return ContentBuilder self For chaining
function ContentBuilder:embedded_input(key, opts)
  opts = opts or {}
  if not self._containers then
    self._containers = {}
  end

  local container_row
  local container_col = opts.col

  if opts.label then
    get_lines().styled(self, opts.label, "label")
    container_row = #self._lines - 1 -- 0-indexed: the label line we just added
    if not container_col then
      container_col = #opts.label -- position container right after label text
    end
  else
    container_row = #self._lines -- 0-indexed: the blank line about to be added
    table.insert(self._lines, { text = "", highlights = {} })
  end

  self._containers[key] = {
    type = "embedded_input",
    row = container_row,
    col = container_col, -- nil = auto-center (only when no label)
    width = opts.width,
    placeholder = opts.placeholder,
    value = opts.value,
    on_change = opts.on_change,
    on_submit = opts.on_submit,
    zindex_offset = opts.zindex_offset,
    winhighlight = opts.winhighlight,
    border = opts.border,
  }

  return self
end

---Reserve space for an embedded dropdown and record its definition
---@param key string Unique dropdown key
---@param opts { width: number, col?: number, options: table[], selected?: string, label?: string, placeholder?: string, max_height?: number, on_change?: fun(key: string, value: string), zindex_offset?: number, winhighlight?: string, border?: string|table }
---@return ContentBuilder self For chaining
function ContentBuilder:embedded_dropdown(key, opts)
  opts = opts or {}
  if not self._containers then
    self._containers = {}
  end

  local container_row
  local container_col = opts.col

  if opts.label then
    get_lines().styled(self, opts.label, "label")
    container_row = #self._lines - 1 -- 0-indexed: the label line we just added
    if not container_col then
      container_col = #opts.label -- position container right after label text
    end
  else
    container_row = #self._lines -- 0-indexed: the blank line about to be added
    table.insert(self._lines, { text = "", highlights = {} })
  end

  self._containers[key] = {
    type = "embedded_dropdown",
    row = container_row,
    col = container_col, -- nil = auto-center (only when no label)
    width = opts.width,
    options = opts.options,
    selected = opts.selected,
    placeholder = opts.placeholder,
    max_height = opts.max_height,
    on_change = opts.on_change,
    zindex_offset = opts.zindex_offset,
    winhighlight = opts.winhighlight,
    border = opts.border,
  }

  return self
end

---Reserve space for an embedded multi-dropdown and record its definition
---@param key string Unique multi-dropdown key
---@param opts { width: number, col?: number, options: table[], selected?: string[], label?: string, placeholder?: string, max_height?: number, display_mode?: "count"|"list", on_change?: fun(key: string, values: string[]), zindex_offset?: number, winhighlight?: string, border?: string|table }
---@return ContentBuilder self For chaining
function ContentBuilder:embedded_multi_dropdown(key, opts)
  opts = opts or {}
  if not self._containers then
    self._containers = {}
  end

  local container_row
  local container_col = opts.col

  if opts.label then
    get_lines().styled(self, opts.label, "label")
    container_row = #self._lines - 1 -- 0-indexed: the label line we just added
    if not container_col then
      container_col = #opts.label -- position container right after label text
    end
  else
    container_row = #self._lines -- 0-indexed: the blank line about to be added
    table.insert(self._lines, { text = "", highlights = {} })
  end

  self._containers[key] = {
    type = "embedded_multi_dropdown",
    row = container_row,
    col = container_col, -- nil = auto-center (only when no label)
    width = opts.width,
    options = opts.options,
    selected = opts.selected,
    placeholder = opts.placeholder,
    max_height = opts.max_height,
    display_mode = opts.display_mode,
    on_change = opts.on_change,
    zindex_offset = opts.zindex_offset,
    winhighlight = opts.winhighlight,
    border = opts.border,
  }

  return self
end

---Get all container definitions (used by FloatWindow to create child windows)
---@return table<string, table>? containers Map of name -> container definition, or nil
function ContentBuilder:get_containers()
  if not self._containers or next(self._containers) == nil then
    return nil
  end
  return self._containers
end

---Get a specific container definition
---@param name string Container name
---@return table? definition
function ContentBuilder:get_container(name)
  if not self._containers then return nil end
  return self._containers[name]
end

return ContentBuilder
