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

---@class ContentBuilder
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
  return self
end

---Get current line count (0-indexed, useful for tracking line positions)
---@return number count Current number of lines
function ContentBuilder:line_count()
  return #self._lines
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

return ContentBuilder
