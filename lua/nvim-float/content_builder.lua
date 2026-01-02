---@class ContentBuilder
---Build styled content for floating windows using theme colors
---Maps semantic content types to highlight groups
---Supports input fields for interactive forms
---Supports element tracking for cursor-based queries
---@module nvim-float.content_builder
local ContentBuilder = {}
ContentBuilder.__index = ContentBuilder

-- Import element tracking module
local Elements = require("nvim-float.elements")

---Semantic style mappings to nvim-float highlight groups
---These map user-friendly style names to actual theme groups
---Plugins can register additional styles via ContentBuilder.register_styles()
local STYLE_MAPPINGS = {
  -- Headers and titles
  header = "NvimFloatHeader",
  title = "NvimFloatHeader",
  subheader = "NvimFloatSubheader",
  section = "NvimFloatSection",

  -- Labels and values
  label = "NvimFloatLabel",
  value = "NvimFloatValue",
  key = "NvimFloatKey",

  -- Emphasis styles
  emphasis = "NvimFloatEmphasis",
  strong = "NvimFloatStrong",
  highlight = "NvimFloatHighlight",
  search_match = "NvimFloatSearchMatch",

  -- Status styles
  success = "NvimFloatSuccess",
  warning = "NvimFloatWarning",
  error = "NvimFloatError",

  -- Muted/subtle styles
  muted = "NvimFloatMuted",
  dim = "NvimFloatDim",
  comment = "NvimFloatComment",

  -- Code/syntax styles
  keyword = "NvimFloatKeyword",
  string = "NvimFloatString",
  number = "NvimFloatNumber",
  operator = "NvimFloatOperator",
  func = "NvimFloatFunction",
  type = "NvimFloatType",

  -- Input field styles
  input = "NvimFloatInput",
  input_active = "NvimFloatInputActive",
  input_placeholder = "NvimFloatInputPlaceholder",

  -- Dropdown field styles
  dropdown = "NvimFloatDropdown",
  dropdown_active = "NvimFloatInputActive",
  dropdown_arrow = "NvimFloatHint",

  -- Special
  normal = nil,
  none = nil,
}

---Register additional style mappings
---Allows plugins to add their own semantic styles that map to highlight groups
---@param styles table<string, string> Map of style name -> highlight group name
---@param override boolean? If true, allows overriding existing styles (default: false)
function ContentBuilder.register_styles(styles, override)
  for style_name, hl_group in pairs(styles) do
    if override or STYLE_MAPPINGS[style_name] == nil then
      STYLE_MAPPINGS[style_name] = hl_group
    end
  end
end

---Get all registered style mappings
---@return table<string, string> Copy of current style mappings
function ContentBuilder.get_style_mappings()
  return vim.tbl_extend("force", {}, STYLE_MAPPINGS)
end

---@class ContentLine
---@field text string The line text
---@field highlights ContentHighlight[] Array of highlights for this line

---@class ContentHighlight
---@field col_start number 0-indexed start column
---@field col_end number 0-indexed end column
---@field style string Style name from STYLE_MAPPINGS

---@class InputField
---@field key string Unique identifier for the input
---@field line number 1-indexed line number
---@field col_start number 0-indexed start column of input value area
---@field col_end number 0-indexed end column of input value area (dynamic, updates based on content)
---@field width number Current effective width of input field
---@field default_width number Default/minimum display width (pads with spaces, expands if text longer)
---@field min_width number? Minimum display width override
---@field value string Current value
---@field default string Default/initial value
---@field placeholder string Placeholder text when empty
---@field is_showing_placeholder boolean Whether currently displaying placeholder text
---@field label string? Optional label text before input
---@field prefix_len number Length of label prefix (for line reconstruction)

---@class DropdownOption
---@field value string The value to store when selected
---@field label string The display text shown in dropdown

---@class DropdownField
---@field key string Unique identifier for the dropdown
---@field line number 1-indexed line number
---@field col_start number 0-indexed start column of dropdown value area
---@field col_end number 0-indexed end column of dropdown value area
---@field width number Display width of dropdown field
---@field value string Current selected value
---@field default string Default/initial value
---@field options DropdownOption[] Available options
---@field max_height number Maximum visible items in dropdown (default: 6)
---@field label string? Optional label text before dropdown
---@field prefix_len number Length of label prefix (for line reconstruction)
---@field placeholder string? Placeholder text when no selection

---@class MultiDropdownField
---@field key string Unique identifier for the multi-dropdown
---@field line number 1-indexed line number
---@field col_start number 0-indexed start column of dropdown value area
---@field col_end number 0-indexed end column of dropdown value area
---@field width number Display width of dropdown field
---@field values string[] Currently selected values (array)
---@field default string[] Default/initial values
---@field options DropdownOption[] Available options
---@field max_height number Maximum visible items in dropdown (default: 6)
---@field label string? Optional label text before dropdown
---@field prefix_len number Length of label prefix (for line reconstruction)
---@field placeholder string? Placeholder text when no selection
---@field display_mode string? How to show selections: "count" (default) or "list"
---@field select_all_option boolean? Whether to show "Select All" option (default: true)

---@class ContentBuilderState
---@field lines ContentLine[] Built content lines
---@field namespace number|nil Highlight namespace
---@field inputs table<string, InputField> Map of input key -> field info

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

---Get the highlight group for a style
---@param style string Style name
---@return string|nil group Highlight group name or nil for normal
function ContentBuilder.get_highlight(style)
  return STYLE_MAPPINGS[style]
end

---Add a plain text line (no special highlighting)
---@param text string Line text
---@return ContentBuilder self For chaining
function ContentBuilder:line(text)
  table.insert(self._lines, {
    text = text or "",
    highlights = {},
  })
  return self
end

---Alias for line() - add plain text
---@param text string Text content
---@return ContentBuilder self For chaining
function ContentBuilder:text(text)
  return self:line(text)
end

---Add an empty line
---@return ContentBuilder self For chaining
function ContentBuilder:blank()
  return self:line("")
end

---Add a styled line (entire line has one style)
---@param text string Line text
---@param style string Style name from STYLE_MAPPINGS
---@param opts? { track?: string|table } Optional tracking: string for name only, or table for full options
---@return ContentBuilder self For chaining
function ContentBuilder:styled(text, style, opts)
  local line = {
    text = text or "",
    highlights = {},
  }
  if style and STYLE_MAPPINGS[style] then
    table.insert(line.highlights, {
      col_start = 0,
      col_end = #text,
      style = style,
    })
  end
  table.insert(self._lines, line)

  -- Handle element tracking
  if opts and opts.track then
    local track = opts.track
    local track_opts = type(track) == "string" and { name = track } or track

    -- Register element with auto-calculated positions
    local row = #self._lines - 1  -- 0-indexed
    self._registry:register({
      name = track_opts.name,
      type = track_opts.type or Elements.ElementType.TEXT,
      row = row,
      col_start = 0,
      col_end = #(text or ""),
      row_based = track_opts.row_based or false,
      text = text,
      data = track_opts.data,
      style = style,
      hover_style = track_opts.hover_style,
      on_interact = track_opts.on_interact,
      on_focus = track_opts.on_focus,
      on_blur = track_opts.on_blur,
      on_change = track_opts.on_change,
      value = track_opts.value,
    })
  end

  return self
end

---Add a header line (styled as header)
---@param text string Header text
---@return ContentBuilder self For chaining
function ContentBuilder:header(text)
  return self:styled(text, "header")
end

---Add a subheader line
---@param text string Subheader text
---@return ContentBuilder self For chaining
function ContentBuilder:subheader(text)
  return self:styled(text, "subheader")
end

---Add a section header (styled as section)
---@param text string Section text
---@return ContentBuilder self For chaining
function ContentBuilder:section(text)
  return self:styled(text, "section")
end

---Add muted text
---@param text string Muted text
---@return ContentBuilder self For chaining
function ContentBuilder:muted(text)
  return self:styled(text, "muted")
end

---Add a bullet point
---@param text string Bullet text
---@param style string? Optional style for the text
---@return ContentBuilder self For chaining
function ContentBuilder:bullet(text, style)
  local prefix = "  - "
  if style then
    return self:spans({
      { text = prefix, style = "muted" },
      { text = text, style = style },
    })
  else
    return self:line(prefix .. text)
  end
end

---Add a separator line
---@param char string? Character to repeat (default: "-")
---@param width number? Width (default: 50)
---@return ContentBuilder self For chaining
function ContentBuilder:separator(char, width)
  char = char or "-"
  width = width or 50
  return self:styled(string.rep(char, width), "muted")
end

---Add a label: value line
---@param label string Label text
---@param value any Value (will be tostring'd)
---@param opts table? Options: { label_style = "label", value_style = "value", separator = ": " }
---@return ContentBuilder self For chaining
function ContentBuilder:label_value(label, value, opts)
  opts = opts or {}
  local label_style = opts.label_style or "label"
  local value_style = opts.value_style or "value"
  local sep = opts.separator or ": "

  local value_str = tostring(value)
  local text = label .. sep .. value_str

  local line = {
    text = text,
    highlights = {},
  }

  -- Highlight label
  if STYLE_MAPPINGS[label_style] then
    table.insert(line.highlights, {
      col_start = 0,
      col_end = #label,
      style = label_style,
    })
  end

  -- Highlight value
  if STYLE_MAPPINGS[value_style] then
    table.insert(line.highlights, {
      col_start = #label + #sep,
      col_end = #text,
      style = value_style,
    })
  end

  table.insert(self._lines, line)
  return self
end

---Add a key: value line (like label_value but with key styling)
---@param key string Key text
---@param value any Value
---@return ContentBuilder self For chaining
function ContentBuilder:key_value(key, value)
  return self:label_value(key, value, { label_style = "key", value_style = "value" })
end

---Add a line with mixed styles using spans
---@param spans table[] Array of { text = string, style = string?, track = string|table? }
---@return ContentBuilder self For chaining
function ContentBuilder:spans(spans)
  local text_parts = {}
  local highlights = {}
  local tracked_elements = {}  -- Collect elements to register after line is added
  local pos = 0

  for _, span in ipairs(spans) do
    local span_text = span.text or ""
    table.insert(text_parts, span_text)

    -- Support both style (mapped) and hl_group (direct)
    if span.hl_group then
      -- Direct highlight group (bypasses STYLE_MAPPINGS)
      table.insert(highlights, {
        col_start = pos,
        col_end = pos + #span_text,
        hl_group = span.hl_group,
      })
    elseif span.style and STYLE_MAPPINGS[span.style] then
      -- Mapped style
      table.insert(highlights, {
        col_start = pos,
        col_end = pos + #span_text,
        style = span.style,
      })
    end

    -- Collect tracking info for this span
    if span.track then
      local track = span.track
      local track_opts = type(track) == "string" and { name = track } or track

      table.insert(tracked_elements, {
        name = track_opts.name,
        type = track_opts.type or Elements.ElementType.TEXT,
        col_start = pos,
        col_end = pos + #span_text,
        row_based = track_opts.row_based or false,
        text = span_text,
        data = track_opts.data,
        style = span.style,
        hover_style = track_opts.hover_style,
        on_interact = track_opts.on_interact,
        on_focus = track_opts.on_focus,
        on_blur = track_opts.on_blur,
        on_change = track_opts.on_change,
        value = track_opts.value,
      })
    end

    pos = pos + #span_text
  end

  table.insert(self._lines, {
    text = table.concat(text_parts, ""),
    highlights = highlights,
  })

  -- Register tracked elements now that we know the row
  local row = #self._lines - 1  -- 0-indexed
  for _, elem in ipairs(tracked_elements) do
    elem.row = row
    self._registry:register(elem)
  end

  return self
end

-- ============================================================================
-- Element Tracking
-- ============================================================================

---Add a tracked row element (row-based by default)
---This is a convenience method for adding content that owns its entire row
---@param name string Element name
---@param opts table Options: { type?, row_based?, data?, on_interact?, on_focus?, on_blur?, on_change?, value?, style?, hover_style?, text? }
---@return ContentBuilder self For chaining
function ContentBuilder:tracked(name, opts)
  opts = opts or {}

  -- If text is provided, add it as a styled line
  local text = opts.text or ""
  local style = opts.style

  local line = {
    text = text,
    highlights = {},
  }

  if style and STYLE_MAPPINGS[style] then
    table.insert(line.highlights, {
      col_start = 0,
      col_end = #text,
      style = style,
    })
  end

  table.insert(self._lines, line)

  -- Register the element (row-based by default for tracked())
  local row = #self._lines - 1  -- 0-indexed
  self._registry:register({
    name = name,
    type = opts.type or Elements.ElementType.TEXT,
    row = row,
    col_start = 0,
    col_end = #text,
    row_based = opts.row_based ~= false,  -- Default to true for tracked()
    text = text,
    data = opts.data,
    style = style,
    hover_style = opts.hover_style,
    on_interact = opts.on_interact,
    on_focus = opts.on_focus,
    on_blur = opts.on_blur,
    on_change = opts.on_change,
    value = opts.value,
  })

  return self
end

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

---Add an input field
---@param key string Unique identifier for retrieving the value
---@param opts table Options: { label = string?, value = string?, placeholder = string?, width = number?, min_width = number?, label_style = string? }
---@return ContentBuilder self For chaining
function ContentBuilder:input(key, opts)
  opts = opts or {}
  local label = opts.label or ""
  local value = opts.value or ""
  local placeholder = opts.placeholder or ""
  local default_width = opts.width or 20  -- Default/minimum display width
  local min_width = opts.min_width or default_width
  local label_style = opts.label_style or "label"
  local separator = opts.separator or ": "

  -- Build the line text
  local prefix = ""
  if label ~= "" then
    prefix = label .. separator
  end

  -- Display value or placeholder
  local display_text = value
  local is_placeholder = false
  if value == "" and placeholder ~= "" then
    display_text = placeholder
    is_placeholder = true
  end

  -- Calculate effective width: at least default_width, but expands for longer text
  local effective_width = math.max(default_width, min_width, #display_text)

  -- Pad display text to effective width (no truncation - expands if needed)
  if #display_text < effective_width then
    display_text = display_text .. string.rep(" ", effective_width - #display_text)
  end

  -- Build full line: "Label: [value_______]"
  local input_start = #prefix
  local text = prefix .. "[" .. display_text .. "]"
  local input_value_start = input_start + 1  -- After "["
  local input_value_end = input_value_start + effective_width  -- Before "]"

  local line = {
    text = text,
    highlights = {},
  }

  -- Highlight label
  if label ~= "" and STYLE_MAPPINGS[label_style] then
    table.insert(line.highlights, {
      col_start = 0,
      col_end = #label,
      style = label_style,
    })
  end

  -- Highlight brackets
  table.insert(line.highlights, {
    col_start = input_start,
    col_end = input_start + 1,
    style = "muted",
  })
  table.insert(line.highlights, {
    col_start = input_value_end,
    col_end = input_value_end + 1,
    style = "muted",
  })

  -- Highlight input value area
  local value_style = is_placeholder and "input_placeholder" or "input"
  table.insert(line.highlights, {
    col_start = input_value_start,
    col_end = input_value_end,
    style = value_style,
  })

  table.insert(self._lines, line)

  -- Store input field info
  local line_num = #self._lines
  self._inputs[key] = {
    key = key,
    line = line_num,
    col_start = input_value_start,
    col_end = input_value_end,
    width = effective_width,  -- Current effective width
    default_width = default_width,  -- Minimum display width (for padding)
    min_width = min_width,
    value = value,
    default = value,
    placeholder = placeholder,
    is_showing_placeholder = is_placeholder,
    label = label,
    prefix_len = #prefix,  -- Store prefix length for line reconstruction
  }
  table.insert(self._input_order, key)

  return self
end

---Add an input field with label on same line
---Supports two call patterns:
---  labeled_input(key, label, opts) -- original pattern
---  labeled_input(label, key, value, width) -- convenience pattern
---@param arg1 string First argument (key or label)
---@param arg2 string Second argument (label or key)
---@param arg3 table|string|nil Third argument (opts table, value string, or nil)
---@param arg4 number? Fourth argument (width, only for convenience pattern)
---@return ContentBuilder self For chaining
function ContentBuilder:labeled_input(arg1, arg2, arg3, arg4)
  local key, label, opts

  -- Detect which call pattern is being used
  if type(arg3) == "table" then
    -- Original pattern: labeled_input(key, label, opts)
    key = arg1
    label = arg2
    opts = arg3
  else
    -- Convenience pattern: labeled_input(label, key, value, width)
    label = arg1
    key = arg2
    opts = {
      value = arg3 or "",
      width = arg4,
    }
  end

  opts = opts or {}
  opts.label = label
  return self:input(key, opts)
end

---Get all input field definitions
---@return table<string, InputField> inputs Map of key -> InputField
function ContentBuilder:get_inputs()
  return self._inputs
end

---Get ordered list of input keys (for Tab navigation)
---@return string[] keys Ordered input keys
function ContentBuilder:get_input_order()
  return self._input_order
end

---Get a specific input field
---@param key string Input key
---@return InputField? field Input field or nil
function ContentBuilder:get_input(key)
  return self._inputs[key]
end

---Update an input field's value (for re-rendering)
---@param key string Input key
---@param value string New value
---@return ContentBuilder self For chaining
function ContentBuilder:set_input_value(key, value)
  local input = self._inputs[key]
  if input then
    input.value = value
  end
  return self
end

---Add a dropdown field
---@param key string Unique identifier for retrieving the value
---@param opts table Options: { label = string?, options = DropdownOption[], value = string?, placeholder = string?, width = number?, max_height = number?, label_style = string?, label_width = number? }
---@return ContentBuilder self For chaining
function ContentBuilder:dropdown(key, opts)
  opts = opts or {}
  local label = opts.label or ""
  local options = opts.options or {}
  local value = opts.value or ""
  local placeholder = opts.placeholder or "(select)"
  local width = opts.width or 20
  local max_height = opts.max_height or 6
  local label_style = opts.label_style or "label"
  local separator = opts.separator or ": "
  local label_width = opts.label_width  -- Optional: pad label to this width

  -- Find the label for the current value
  local display_text = placeholder
  local is_placeholder = true
  for _, opt in ipairs(options) do
    if opt.value == value then
      display_text = opt.label
      is_placeholder = false
      break
    end
  end

  -- Build the line text
  local prefix = ""
  if label ~= "" then
    prefix = label .. separator
    -- Pad after separator to label_width if specified (e.g., "Types:     " not "Types    :")
    if label_width then
      local prefix_display_len = vim.fn.strdisplaywidth(prefix)
      if prefix_display_len < label_width then
        prefix = prefix .. string.rep(" ", label_width - prefix_display_len)
      end
    end
  end

  -- Cap width to fit within max_width if set
  -- Total line: prefix + "[" + content + "]" = prefix + 2 + width
  if self._max_width then
    local prefix_display_len = vim.fn.strdisplaywidth(prefix)
    local available = self._max_width - prefix_display_len - 2  -- 2 for brackets
    if available > 0 and width > available then
      width = available
    end
  end

  -- Calculate effective width (fixed to specified width)
  -- Arrow takes 4 bytes: " ▼" (space + 3-byte unicode char)
  local arrow = " ▼"
  local arrow_byte_len = #arrow  -- 4 bytes
  local arrow_display_len = 2    -- 2 display columns (space + arrow)

  -- text_width is the area for the label text (excluding arrow)
  local text_width = width - arrow_display_len
  text_width = math.max(text_width, 1)  -- At least 1 char for text

  local effective_width = text_width + arrow_display_len

  -- Pad or truncate display text to fit text_width
  local display_len = vim.fn.strdisplaywidth(display_text)
  if display_len < text_width then
    display_text = display_text .. string.rep(" ", text_width - display_len)
  elseif display_len > text_width then
    -- Truncate with ellipsis - use vim.fn.strcharpart for proper UTF-8 handling
    local truncated = ""
    local current_width = 0
    local char_idx = 0
    while current_width < text_width - 1 do
      local char = vim.fn.strcharpart(display_text, char_idx, 1)
      if char == "" then break end
      local char_width = vim.fn.strdisplaywidth(char)
      if current_width + char_width > text_width - 1 then
        break
      end
      truncated = truncated .. char
      current_width = current_width + char_width
      char_idx = char_idx + 1
    end
    -- Pad to exact width and add ellipsis
    local pad_needed = text_width - 1 - vim.fn.strdisplaywidth(truncated)
    if pad_needed > 0 then
      truncated = truncated .. string.rep(" ", pad_needed)
    end
    display_text = truncated .. "..."
  end

  -- Build full line: "Label: [Selected Value ▼]"
  local input_start = #prefix  -- Byte position
  local text = prefix .. "[" .. display_text .. arrow .. "]"
  local input_value_start = input_start + 1  -- After "[" (byte position)

  -- Calculate byte lengths for highlight positions
  local display_text_bytes = #display_text
  local input_value_end = input_value_start + display_text_bytes + arrow_byte_len  -- Before "]"

  local line = {
    text = text,
    highlights = {},
  }

  -- Highlight label
  if label ~= "" and STYLE_MAPPINGS[label_style] then
    table.insert(line.highlights, {
      col_start = 0,
      col_end = #label,
      style = label_style,
    })
  end

  -- Highlight brackets
  table.insert(line.highlights, {
    col_start = input_start,
    col_end = input_start + 1,
    style = "muted",
  })
  table.insert(line.highlights, {
    col_start = input_value_end,
    col_end = input_value_end + 1,
    style = "muted",
  })

  -- Highlight dropdown value area (excluding arrow)
  local value_style = is_placeholder and "input_placeholder" or "dropdown"
  table.insert(line.highlights, {
    col_start = input_value_start,
    col_end = input_value_start + display_text_bytes,
    style = value_style,
  })

  -- Highlight arrow separately
  table.insert(line.highlights, {
    col_start = input_value_start + display_text_bytes,
    col_end = input_value_end,
    style = "dropdown_arrow",
  })

  table.insert(self._lines, line)

  -- Store dropdown field info
  local line_num = #self._lines
  self._dropdowns[key] = {
    key = key,
    line = line_num,
    col_start = input_value_start,      -- Byte position after "["
    col_end = input_value_end,          -- Byte position before "]"
    width = effective_width,            -- Display width (text + arrow)
    text_width = text_width,            -- Display width for text only (excluding arrow)
    value = value,
    default = value,
    options = options,
    max_height = max_height,
    label = label,
    prefix_len = #prefix,
    placeholder = placeholder,
    is_placeholder = is_placeholder,
  }
  table.insert(self._dropdown_order, key)

  return self
end

---Add a dropdown field with label on same line (convenience method)
---@param key string Unique identifier
---@param label string Label text
---@param opts table Options (same as dropdown)
---@return ContentBuilder self For chaining
function ContentBuilder:labeled_dropdown(key, label, opts)
  opts = opts or {}
  opts.label = label
  return self:dropdown(key, opts)
end

---Get all dropdown field definitions
---@return table<string, DropdownField> dropdowns Map of key -> DropdownField
function ContentBuilder:get_dropdowns()
  return self._dropdowns
end

---Get ordered list of dropdown keys
---@return string[] keys Ordered dropdown keys
function ContentBuilder:get_dropdown_order()
  return self._dropdown_order
end

---Get a specific dropdown field
---@param key string Dropdown key
---@return DropdownField? field Dropdown field or nil
function ContentBuilder:get_dropdown(key)
  return self._dropdowns[key]
end

---Update a dropdown field's value
---@param key string Dropdown key
---@param value string New value
---@return ContentBuilder self For chaining
function ContentBuilder:set_dropdown_value(key, value)
  local dropdown = self._dropdowns[key]
  if dropdown then
    dropdown.value = value
    -- Update placeholder state
    dropdown.is_placeholder = false
    for _, opt in ipairs(dropdown.options) do
      if opt.value == value then
        dropdown.is_placeholder = false
        break
      end
    end
  end
  return self
end

---Add a multi-select dropdown field
---@param key string Unique identifier for retrieving the values
---@param opts table Options: { label = string?, options = DropdownOption[], values = string[]?, placeholder = string?, width = number?, max_height = number?, display_mode = string?, select_all_option = boolean?, label_width = number? }
---@return ContentBuilder self For chaining
function ContentBuilder:multi_dropdown(key, opts)
  opts = opts or {}
  local label = opts.label or ""
  local options = opts.options or {}
  local values = opts.values or {}  -- Array of selected values
  local placeholder = opts.placeholder or "(none selected)"
  local width = opts.width or 20
  local max_height = opts.max_height or 8
  local label_style = opts.label_style or "label"
  local separator = opts.separator or ": "
  local display_mode = opts.display_mode or "count"  -- "count" or "list"
  local select_all_option = opts.select_all_option ~= false  -- Default true
  local label_width = opts.label_width  -- Optional: pad label to this width

  -- Build display text based on selection count
  local display_text
  local is_placeholder = (#values == 0)

  if #values == 0 then
    display_text = placeholder
  elseif display_mode == "count" then
    if #values == #options then
      display_text = "All (" .. #values .. ")"
    else
      display_text = #values .. " selected"
    end
  else  -- "list" mode
    local labels = {}
    for _, v in ipairs(values) do
      for _, opt in ipairs(options) do
        if opt.value == v then
          table.insert(labels, opt.label)
          break
        end
      end
    end
    display_text = table.concat(labels, ", ")
  end

  -- Build the line text
  local prefix = ""
  if label ~= "" then
    prefix = label .. separator
    -- Pad after separator to label_width if specified (e.g., "Types:     " not "Types    :")
    if label_width then
      local prefix_display_len = vim.fn.strdisplaywidth(prefix)
      if prefix_display_len < label_width then
        prefix = prefix .. string.rep(" ", label_width - prefix_display_len)
      end
    end
  end

  -- Cap width to fit within max_width if set
  -- Total line: prefix + "[" + content + "]" = prefix + 2 + width
  if self._max_width then
    local prefix_display_len = vim.fn.strdisplaywidth(prefix)
    local available = self._max_width - prefix_display_len - 2  -- 2 for brackets
    if available > 0 and width > available then
      width = available
    end
  end

  -- Arrow indicator for multi-dropdown uses different symbol
  local arrow = " ▾"  -- Smaller triangle to differentiate from single dropdown
  local arrow_byte_len = #arrow
  local arrow_display_len = 2

  -- text_width is the area for the label text (excluding arrow)
  local text_width = width - arrow_display_len
  text_width = math.max(text_width, 1)

  local effective_width = text_width + arrow_display_len

  -- Pad or truncate display text
  local display_len = vim.fn.strdisplaywidth(display_text)
  if display_len < text_width then
    display_text = display_text .. string.rep(" ", text_width - display_len)
  elseif display_len > text_width then
    -- Truncate with ellipsis
    local truncated = ""
    local current_width = 0
    local char_idx = 0
    while current_width < text_width - 1 do
      local char = vim.fn.strcharpart(display_text, char_idx, 1)
      if char == "" then break end
      local char_width = vim.fn.strdisplaywidth(char)
      if current_width + char_width > text_width - 1 then
        break
      end
      truncated = truncated .. char
      current_width = current_width + char_width
      char_idx = char_idx + 1
    end
    local pad_needed = text_width - 1 - vim.fn.strdisplaywidth(truncated)
    if pad_needed > 0 then
      truncated = truncated .. string.rep(" ", pad_needed)
    end
    display_text = truncated .. "..."
  end

  -- Build full line
  local input_start = #prefix
  local text = prefix .. "[" .. display_text .. arrow .. "]"
  local input_value_start = input_start + 1

  local display_text_bytes = #display_text
  local input_value_end = input_value_start + display_text_bytes + arrow_byte_len

  local line = {
    text = text,
    highlights = {},
  }

  -- Highlight label
  if label ~= "" and STYLE_MAPPINGS[label_style] then
    table.insert(line.highlights, {
      col_start = 0,
      col_end = #label,
      style = label_style,
    })
  end

  -- Highlight brackets
  table.insert(line.highlights, {
    col_start = input_start,
    col_end = input_start + 1,
    style = "muted",
  })
  table.insert(line.highlights, {
    col_start = input_value_end,
    col_end = input_value_end + 1,
    style = "muted",
  })

  -- Highlight dropdown value area
  local value_style = is_placeholder and "input_placeholder" or "dropdown"
  table.insert(line.highlights, {
    col_start = input_value_start,
    col_end = input_value_start + display_text_bytes,
    style = value_style,
  })

  -- Highlight arrow
  table.insert(line.highlights, {
    col_start = input_value_start + display_text_bytes,
    col_end = input_value_end,
    style = "dropdown_arrow",
  })

  table.insert(self._lines, line)

  -- Store multi-dropdown field info
  local line_num = #self._lines
  self._multi_dropdowns[key] = {
    key = key,
    line = line_num,
    col_start = input_value_start,
    col_end = input_value_end,
    width = effective_width,
    text_width = text_width,
    values = vim.deepcopy(values),
    default = vim.deepcopy(values),
    options = options,
    max_height = max_height,
    label = label,
    prefix_len = #prefix,
    placeholder = placeholder,
    is_placeholder = is_placeholder,
    display_mode = display_mode,
    select_all_option = select_all_option,
  }
  table.insert(self._multi_dropdown_order, key)

  return self
end

---Add a multi-dropdown field with label (convenience method)
---@param key string Unique identifier
---@param label string Label text
---@param opts table Options (same as multi_dropdown)
---@return ContentBuilder self For chaining
function ContentBuilder:labeled_multi_dropdown(key, label, opts)
  opts = opts or {}
  opts.label = label
  return self:multi_dropdown(key, opts)
end

---Get all multi-dropdown field definitions
---@return table<string, MultiDropdownField> multi_dropdowns
function ContentBuilder:get_multi_dropdowns()
  return self._multi_dropdowns
end

---Get ordered list of multi-dropdown keys
---@return string[] keys
function ContentBuilder:get_multi_dropdown_order()
  return self._multi_dropdown_order
end

---Get a specific multi-dropdown field
---@param key string Multi-dropdown key
---@return MultiDropdownField? field
function ContentBuilder:get_multi_dropdown(key)
  return self._multi_dropdowns[key]
end

---Update a multi-dropdown field's values
---@param key string Multi-dropdown key
---@param values string[] New selected values
---@return ContentBuilder self For chaining
function ContentBuilder:set_multi_dropdown_values(key, values)
  local multi_dropdown = self._multi_dropdowns[key]
  if multi_dropdown then
    multi_dropdown.values = vim.deepcopy(values)
    multi_dropdown.is_placeholder = (#values == 0)
  end
  return self
end

---Add a status line with icon
---@param status "success"|"warning"|"error"|"muted" Status type
---@param text string Status text
---@return ContentBuilder self For chaining
function ContentBuilder:status(status, text)
  local icons = {
    success = "ok",
    warning = "!",
    error = "x",
    muted = "-",
  }
  local icon = icons[status] or "-"
  return self:spans({
    { text = "[" .. icon .. "] ", style = status },
    { text = text, style = status },
  })
end

---Add a list item with optional style
---@param text string Item text
---@param style string? Style for the text
---@param prefix string? Prefix (default: "  - ")
---@return ContentBuilder self For chaining
function ContentBuilder:list_item(text, style, prefix)
  prefix = prefix or "  - "
  if style then
    return self:spans({
      { text = prefix, style = "muted" },
      { text = text, style = style },
    })
  else
    return self:line(prefix .. text)
  end
end

---Add a table row with columns
---@param columns table[] Array of { text = string, width = number?, style = string? }
---@return ContentBuilder self For chaining
function ContentBuilder:table_row(columns)
  local spans = {}
  for i, col in ipairs(columns) do
    local text = col.text or ""
    local width = col.width

    -- Pad or truncate to width
    if width then
      if #text < width then
        text = text .. string.rep(" ", width - #text)
      elseif #text > width then
        text = text:sub(1, width - 1) .. "..."
      end
    end

    -- Add separator between columns
    if i > 1 then
      table.insert(spans, { text = " ", style = nil })
    end

    table.insert(spans, { text = text, style = col.style })
  end

  return self:spans(spans)
end

---Add indented content
---@param text string Text to indent
---@param level number? Indent level (default: 1)
---@param style string? Style for the text
---@return ContentBuilder self For chaining
function ContentBuilder:indent(text, level, style)
  level = level or 1
  local prefix = string.rep("  ", level)
  if style then
    return self:spans({
      { text = prefix },
      { text = text, style = style },
    })
  else
    return self:line(prefix .. text)
  end
end

---Get current line count (0-indexed, useful for tracking line positions)
---@return number count Current number of lines
function ContentBuilder:line_count()
  return #self._lines
end

---Build and return the plain text lines (for buffer content)
---@return string[] lines Array of text lines
function ContentBuilder:build_lines()
  local lines = {}
  for _, line in ipairs(self._lines) do
    table.insert(lines, line.text)
  end
  return lines
end

---Build and return highlight data (mapped styles only)
---@return table[] highlights Array of { line = number, col_start = number, col_end = number, hl_group = string }
function ContentBuilder:build_highlights()
  local highlights = {}
  for line_idx, line in ipairs(self._lines) do
    for _, hl in ipairs(line.highlights) do
      -- Use direct hl_group if set, otherwise map from style
      local hl_group = hl.hl_group or STYLE_MAPPINGS[hl.style]
      if hl_group then
        table.insert(highlights, {
          line = line_idx - 1,  -- 0-indexed
          col_start = hl.col_start,
          col_end = hl.col_end,
          hl_group = hl_group,
        })
      end
    end
  end
  return highlights
end

---Build and return highlight data (alias for build_highlights)
---Supports both mapped styles and direct hl_group values
---@return table[] highlights Array of { line = number, col_start = number, col_end = number, hl_group = string }
function ContentBuilder:build_raw_highlights()
  return self:build_highlights()
end

---Apply highlights to a buffer
---@param bufnr number Buffer number
---@param ns_id number? Namespace ID (creates one if nil)
---@return number ns_id The namespace ID used
function ContentBuilder:apply_to_buffer(bufnr, ns_id)
  ns_id = ns_id or vim.api.nvim_create_namespace("nvim_float_content_builder")

  -- Clear existing highlights in namespace
  vim.api.nvim_buf_clear_namespace(bufnr, ns_id, 0, -1)

  -- Apply new highlights
  local highlights = self:build_highlights()
  for _, hl in ipairs(highlights) do
    pcall(vim.api.nvim_buf_add_highlight, bufnr, ns_id, hl.hl_group, hl.line, hl.col_start, hl.col_end)
  end

  return ns_id
end

---Build everything and apply to a buffer in one call
---@param bufnr number Buffer number
---@param ns_id number? Namespace ID
---@return string[] lines The lines that were set
---@return number ns_id The namespace ID used
function ContentBuilder:render_to_buffer(bufnr, ns_id)
  local lines = self:build_lines()

  -- Set buffer content
  vim.api.nvim_set_option_value('modifiable', true, { buf = bufnr })
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.api.nvim_set_option_value('modifiable', false, { buf = bufnr })

  -- Apply highlights
  ns_id = self:apply_to_buffer(bufnr, ns_id)

  return lines, ns_id
end

---@class ChunkedRenderOpts
---@field chunk_size number? Lines per chunk (default 100)
---@field on_progress fun(written: number, total: number)? Progress callback
---@field on_complete fun(lines: string[], ns_id: number)? Completion callback

---Active chunked render state (per buffer)
---@type table<number, { timer: number?, cancelled: boolean }>
ContentBuilder._chunked_state = {}

---Build everything and apply to a buffer in chunks to avoid blocking UI
---For large line counts, this writes lines and applies highlights in chunks
---@param bufnr number Buffer number
---@param ns_id number? Namespace ID
---@param opts ChunkedRenderOpts? Options for chunked rendering
function ContentBuilder:render_to_buffer_chunked(bufnr, ns_id, opts)
  local lines = self:build_lines()
  local highlights = self:build_highlights()

  opts = opts or {}
  local chunk_size = opts.chunk_size or 100
  local on_progress = opts.on_progress
  local on_complete = opts.on_complete
  local total_lines = #lines

  ns_id = ns_id or vim.api.nvim_create_namespace("nvim_float_content_builder")

  -- Cancel any existing chunked render for this buffer
  ContentBuilder.cancel_chunked_render(bufnr)

  -- For small line counts, use sync render
  if total_lines <= chunk_size then
    self:render_to_buffer(bufnr, ns_id)
    if on_progress then on_progress(total_lines, total_lines) end
    if on_complete then on_complete(lines, ns_id) end
    return
  end

  -- Initialize chunked state for this buffer
  ContentBuilder._chunked_state[bufnr] = {
    timer = nil,
    cancelled = false,
  }

  local state = ContentBuilder._chunked_state[bufnr]
  local current_idx = 1
  local is_first_chunk = true

  -- Make buffer modifiable for the duration of chunked write
  vim.api.nvim_set_option_value('modifiable', true, { buf = bufnr })

  -- Clear existing highlights (but NOT the buffer content yet - avoid flash)
  vim.api.nvim_buf_clear_namespace(bufnr, ns_id, 0, -1)

  local function write_next_chunk()
    -- Check if cancelled or buffer no longer valid
    if state.cancelled or not vim.api.nvim_buf_is_valid(bufnr) then
      ContentBuilder._chunked_state[bufnr] = nil
      return
    end

    local end_idx = math.min(current_idx + chunk_size - 1, total_lines)

    -- Extract chunk of lines
    local chunk = {}
    for i = current_idx, end_idx do
      table.insert(chunk, lines[i])
    end

    -- Write chunk to buffer
    if is_first_chunk then
      -- First chunk: replace entire buffer content (avoids flash from clearing first)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, chunk)
      is_first_chunk = false
    else
      -- Subsequent chunks: append at the correct position
      local append_start = current_idx - 1  -- 0-indexed
      vim.api.nvim_buf_set_lines(bufnr, append_start, append_start, false, chunk)
    end

    -- Apply highlights for lines in this chunk
    for _, hl in ipairs(highlights) do
      local line_0idx = hl.line
      local line_1idx = line_0idx + 1  -- Convert to 1-indexed for comparison
      if line_1idx >= current_idx and line_1idx <= end_idx then
        pcall(vim.api.nvim_buf_add_highlight, bufnr, ns_id, hl.hl_group, line_0idx, hl.col_start, hl.col_end)
      end
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
      vim.api.nvim_set_option_value('modifiable', false, { buf = bufnr })
      ContentBuilder._chunked_state[bufnr] = nil

      if on_complete then
        on_complete(lines, ns_id)
      end
    end
  end

  -- Start writing first chunk
  write_next_chunk()
end

---Cancel any in-progress chunked render for a buffer
---@param bufnr number Buffer number
function ContentBuilder.cancel_chunked_render(bufnr)
  local state = ContentBuilder._chunked_state[bufnr]
  if state then
    state.cancelled = true
    if state.timer then
      vim.fn.timer_stop(state.timer)
      state.timer = nil
    end
    -- Restore buffer to non-modifiable state if it exists
    if vim.api.nvim_buf_is_valid(bufnr) then
      pcall(vim.api.nvim_set_option_value, 'modifiable', false, { buf = bufnr })
    end
    ContentBuilder._chunked_state[bufnr] = nil
  end
end

---Check if a chunked render is currently in progress for a buffer
---@param bufnr number Buffer number
---@return boolean
function ContentBuilder.is_chunked_render_active(bufnr)
  local state = ContentBuilder._chunked_state[bufnr]
  return state ~= nil and not state.cancelled
end

---Get available style names
---@return string[] styles Array of available style names
function ContentBuilder.get_styles()
  local styles = {}
  for name, _ in pairs(STYLE_MAPPINGS) do
    table.insert(styles, name)
  end
  table.sort(styles)
  return styles
end

---Debug: print all styles and their mappings
function ContentBuilder.print_styles()
  print("ContentBuilder Style Mappings:")
  print(string.rep("-", 40))
  local styles = ContentBuilder.get_styles()
  for _, name in ipairs(styles) do
    local group = STYLE_MAPPINGS[name] or "(none)"
    print(string.format("  %-15s -> %s", name, group))
  end
end

-- ============================================================================
-- Result Buffer Formatting
-- ============================================================================

---SQL datatype to style mappings (covers SQL Server, PostgreSQL, MySQL, SQLite)
local DATATYPE_STYLES = {
  -- String types (SQL Server, PostgreSQL, MySQL)
  varchar = "result_string", nvarchar = "result_string",
  char = "result_string", nchar = "result_string",
  text = "result_string", ntext = "result_string",
  xml = "result_string",
  -- MySQL string types
  var_string = "result_string", string = "result_string",
  enum = "result_string", set = "result_string",
  geometry = "result_string",
  -- JSON types (PostgreSQL, MySQL)
  json = "result_string", jsonb = "result_string",

  -- Numeric types (SQL Server)
  int = "result_number", bigint = "result_number",
  smallint = "result_number", tinyint = "result_number",
  decimal = "result_number", numeric = "result_number",
  float = "result_number", real = "result_number",
  money = "result_number", smallmoney = "result_number",
  -- PostgreSQL numeric types
  integer = "result_number",
  ["double precision"] = "result_number",
  -- MySQL numeric types
  tiny = "result_number", short = "result_number",
  long = "result_number", longlong = "result_number",
  int24 = "result_number", double = "result_number",
  newdecimal = "result_number",

  -- Date/time types (SQL Server)
  date = "result_date", time = "result_date",
  datetime = "result_date", datetime2 = "result_date",
  smalldatetime = "result_date", datetimeoffset = "result_date",
  timestamp = "result_date",
  -- PostgreSQL date/time types
  timestamptz = "result_date",
  -- MySQL date/time types
  year = "result_date",

  -- Boolean (SQL Server, PostgreSQL)
  bit = "result_bool", boolean = "result_bool",

  -- Binary (SQL Server)
  binary = "result_binary", varbinary = "result_binary",
  image = "result_binary",
  -- MySQL binary types
  blob = "result_binary", tiny_blob = "result_binary",
  medium_blob = "result_binary", long_blob = "result_binary",

  -- GUID/UUID (SQL Server, PostgreSQL)
  uniqueidentifier = "result_guid", uuid = "result_guid",
}

---Border character sets for result tables
local BORDER_CHARS = {
  box = {
    top_left = "+", top_right = "+",
    bottom_left = "+", bottom_right = "+",
    horizontal = "-", vertical = "|",
    t_down = "+", t_up = "+",
    t_right = "+", t_left = "+",
    cross = "+",
  },
  ascii = {
    top_left = "╭", top_right = "╮",
    bottom_left = "╰", bottom_right = "╯",
    horizontal = "─", vertical = "│",
    t_down = "┬", t_up = "┴",
    t_right = "┤", t_left = "├",
    cross = "┼",
  },
}

---Map SQL datatype to style name
---@param datatype string SQL datatype (e.g., "varchar", "int", "datetime")
---@return string style Style name for ContentBuilder
function ContentBuilder.datatype_to_style(datatype)
  if not datatype then return "value" end
  -- Normalize: lowercase and strip size info like "varchar(50)"
  local normalized = datatype:lower():match("^([a-z_]+)")
  return DATATYPE_STYLES[normalized] or "value"
end

---Get border characters for a style
---@param style string Border style: "box" or "ascii"
---@return table chars Border character set
function ContentBuilder.get_border_chars(style)
  return BORDER_CHARS[style] or BORDER_CHARS.box
end

---Add a result table header row with borders
---@param columns table[] Array of { name: string, width: number }
---@param border_style string "box" or "ascii"
---@return ContentBuilder self
function ContentBuilder:result_header_row(columns, border_style)
  local chars = ContentBuilder.get_border_chars(border_style)
  local line = { text = "", highlights = {} }
  local pos = 0

  -- Build header line: | col1 | col2 | col3 |
  line.text = chars.vertical
  pos = #chars.vertical
  table.insert(line.highlights, { col_start = 0, col_end = pos, style = "result_border" })

  for _, col in ipairs(columns) do
    local padded = " " .. tostring(col.name) .. string.rep(" ", col.width - #tostring(col.name)) .. " "
    local col_start = pos
    pos = pos + #padded

    -- Highlight column name
    table.insert(line.highlights, { col_start = col_start, col_end = pos, style = "result_header" })

    line.text = line.text .. padded .. chars.vertical
    local border_start = pos
    pos = pos + #chars.vertical
    table.insert(line.highlights, { col_start = border_start, col_end = pos, style = "result_border" })
  end

  table.insert(self._lines, line)
  return self
end

---Add a result table top border row
---@param columns table[] Array of { width: number }
---@param border_style string "box" or "ascii"
---@return ContentBuilder self
function ContentBuilder:result_top_border(columns, border_style)
  local chars = ContentBuilder.get_border_chars(border_style)
  local parts = { chars.top_left }

  for i, col in ipairs(columns) do
    -- Width + 2 for padding spaces
    table.insert(parts, string.rep(chars.horizontal, col.width + 2))
    if i < #columns then
      table.insert(parts, chars.t_down)
    end
  end
  table.insert(parts, chars.top_right)

  local text = table.concat(parts, "")
  local line = {
    text = text,
    highlights = {{ col_start = 0, col_end = #text, style = "result_border" }},
  }
  table.insert(self._lines, line)
  return self
end

---Add a result table separator row (between header and data)
---@param columns table[] Array of { width: number }
---@param border_style string "box" or "ascii"
---@return ContentBuilder self
function ContentBuilder:result_separator(columns, border_style)
  local chars = ContentBuilder.get_border_chars(border_style)
  local parts = { chars.t_left }

  for i, col in ipairs(columns) do
    table.insert(parts, string.rep(chars.horizontal, col.width + 2))
    if i < #columns then
      table.insert(parts, chars.cross)
    end
  end
  table.insert(parts, chars.t_right)

  local text = table.concat(parts, "")
  local line = {
    text = text,
    highlights = {{ col_start = 0, col_end = #text, style = "result_border" }},
  }
  table.insert(self._lines, line)
  return self
end

---Add a result table bottom border row
---@param columns table[] Array of { width: number }
---@param border_style string "box" or "ascii"
---@return ContentBuilder self
function ContentBuilder:result_bottom_border(columns, border_style)
  local chars = ContentBuilder.get_border_chars(border_style)
  local parts = { chars.bottom_left }

  for i, col in ipairs(columns) do
    table.insert(parts, string.rep(chars.horizontal, col.width + 2))
    if i < #columns then
      table.insert(parts, chars.t_up)
    end
  end
  table.insert(parts, chars.bottom_right)

  local text = table.concat(parts, "")
  local line = {
    text = text,
    highlights = {{ col_start = 0, col_end = #text, style = "result_border" }},
  }
  table.insert(self._lines, line)
  return self
end

---Add a result data row with datatype coloring
---@param values table[] Array of { value: any, width: number, datatype: string?, is_null: boolean? }
---@param color_mode string "datatype" | "uniform" | "none"
---@param border_style string "box" or "ascii"
---@param highlight_null boolean Whether to highlight NULL values distinctly
---@return ContentBuilder self
function ContentBuilder:result_data_row(values, color_mode, border_style, highlight_null)
  local chars = ContentBuilder.get_border_chars(border_style)
  local line = { text = "", highlights = {} }
  local pos = 0

  -- Build data row: | val1 | val2 | val3 |
  line.text = chars.vertical
  pos = #chars.vertical
  table.insert(line.highlights, { col_start = 0, col_end = pos, style = "result_border" })

  for _, val in ipairs(values) do
    local value_str = tostring(val.value or "")
    -- Replace newlines with space for display
    value_str = value_str:gsub("\n", " ")

    local padded = " " .. value_str .. string.rep(" ", val.width - #value_str) .. " "
    local col_start = pos
    pos = pos + #padded

    -- Determine style based on color mode
    local style = nil
    if color_mode ~= "none" then
      if highlight_null and val.is_null then
        style = "result_null"
      elseif color_mode == "datatype" and val.datatype then
        style = ContentBuilder.datatype_to_style(val.datatype)
      elseif color_mode == "uniform" then
        style = "value"
      end
    end

    if style then
      table.insert(line.highlights, { col_start = col_start, col_end = pos, style = style })
    end

    line.text = line.text .. padded .. chars.vertical
    local border_start = pos
    pos = pos + #chars.vertical
    table.insert(line.highlights, { col_start = border_start, col_end = pos, style = "result_border" })
  end

  table.insert(self._lines, line)
  return self
end

---Add a result message line (e.g., "(X rows affected)")
---@param text string Message text
---@param style string? Style to use (default: "result_message")
---@return ContentBuilder self
function ContentBuilder:result_message(text, style)
  return self:styled(text, style or "result_message")
end

-- ============================================================================
-- Multi-line Cell Support
-- ============================================================================

---Wrap text to fit within a maximum width
---@param text string The text to wrap
---@param max_width number Maximum width per line
---@param mode string Wrap mode: "word" | "char" | "truncate"
---@param preserve_newlines boolean Whether to honor existing newlines
---@return string[] lines Array of wrapped lines
function ContentBuilder.wrap_text(text, max_width, mode, preserve_newlines)
  if not text or text == "" then
    return { "" }
  end

  -- Convert to string if needed
  text = tostring(text)

  -- Handle "truncate" mode - cut at first newline OR max_width, add "..."
  -- This mode always returns a single line
  if mode == "truncate" then
    -- Find first newline position
    local first_newline = text:find("[\r\n]")
    local truncated = text

    -- Cut at first newline if present
    if first_newline then
      truncated = text:sub(1, first_newline - 1)
    end

    -- Now apply max_width truncation
    if #truncated <= max_width then
      -- Fits, but indicate truncation if there was more content
      if first_newline or #text > #truncated then
        if #truncated + 3 <= max_width then
          return { truncated .. "..." }
        elseif #truncated > 3 then
          return { truncated:sub(1, max_width - 3) .. "..." }
        else
          return { truncated }
        end
      end
      return { truncated }
    else
      -- Truncate at max_width
      return { truncated:sub(1, max_width - 3) .. "..." }
    end
  end

  local lines = {}

  -- Split by newlines first if preserving them
  local segments
  if preserve_newlines then
    -- Normalize line endings and split
    local normalized = text:gsub("\r\n", "\n"):gsub("\r", "\n")
    segments = vim.split(normalized, "\n", { plain = true })
  else
    -- Collapse all newlines to spaces
    -- Use parentheses to capture only the string (gsub returns string, count)
    segments = { (text:gsub("\r\n", " "):gsub("\n", " "):gsub("\r", " ")) }
  end

  -- Wrap each segment
  for _, segment in ipairs(segments) do
    if #segment <= max_width then
      table.insert(lines, segment)
    elseif mode == "char" then
      -- Character-based wrapping
      local pos = 1
      while pos <= #segment do
        local chunk = segment:sub(pos, pos + max_width - 1)
        table.insert(lines, chunk)
        pos = pos + max_width
      end
    else
      -- Word-based wrapping (default)
      local current_line = ""
      local words = vim.split(segment, "%s+", { trimempty = false })

      for _, word in ipairs(words) do
        if word == "" then
          -- Preserve spacing
          if #current_line < max_width then
            current_line = current_line .. " "
          end
        elseif #current_line == 0 then
          -- First word on line
          if #word > max_width then
            -- Word itself is too long, break it
            local pos = 1
            while pos <= #word do
              local chunk = word:sub(pos, pos + max_width - 1)
              if pos + max_width - 1 < #word then
                table.insert(lines, chunk)
                pos = pos + max_width
              else
                current_line = chunk
                pos = #word + 1
              end
            end
          else
            current_line = word
          end
        elseif #current_line + 1 + #word <= max_width then
          -- Word fits on current line
          current_line = current_line .. " " .. word
        else
          -- Word doesn't fit, start new line
          table.insert(lines, current_line)
          if #word > max_width then
            -- Word is too long, break it
            local pos = 1
            while pos <= #word do
              local chunk = word:sub(pos, pos + max_width - 1)
              if pos + max_width - 1 < #word then
                table.insert(lines, chunk)
                pos = pos + max_width
              else
                current_line = chunk
                pos = #word + 1
              end
            end
          else
            current_line = word
          end
        end
      end

      -- Don't forget the last line
      if #current_line > 0 or #lines == 0 then
        table.insert(lines, current_line)
      end
    end
  end

  return #lines > 0 and lines or { "" }
end

---Add a row separator between data rows
---@param columns table[] Array of { width: number }
---@param border_style string "box" or "ascii"
---@return ContentBuilder self
function ContentBuilder:result_row_separator(columns, border_style)
  local chars = ContentBuilder.get_border_chars(border_style)
  local parts = { chars.t_left }

  for i, col in ipairs(columns) do
    table.insert(parts, string.rep(chars.horizontal, col.width + 2))
    if i < #columns then
      table.insert(parts, chars.cross)
    end
  end
  table.insert(parts, chars.t_right)

  local text = table.concat(parts, "")
  local line = {
    text = text,
    highlights = {{ col_start = 0, col_end = #text, style = "result_border" }},
  }
  table.insert(self._lines, line)
  return self
end

---Add a multi-line data row (all lines for cells that span multiple lines)
---@param cell_lines table[] Array of { lines: string[], width: number, datatype: string?, is_null: boolean? }
---@param color_mode string "datatype" | "uniform" | "none"
---@param border_style string "box" or "ascii"
---@param highlight_null boolean Whether to highlight NULL values
---@param row_number number? Row number to display (nil = no row number column)
---@param row_num_width number? Width of row number column
---@return ContentBuilder self
function ContentBuilder:result_multiline_data_row(cell_lines, color_mode, border_style, highlight_null, row_number, row_num_width)
  local chars = ContentBuilder.get_border_chars(border_style)

  -- Calculate the maximum number of lines across all cells
  local max_lines = 1
  for _, cell in ipairs(cell_lines) do
    if #cell.lines > max_lines then
      max_lines = #cell.lines
    end
  end

  -- Render each display line
  for line_idx = 1, max_lines do
    local line = { text = "", highlights = {} }
    local pos = 0

    -- Opening border
    line.text = chars.vertical
    pos = #chars.vertical
    table.insert(line.highlights, { col_start = 0, col_end = pos, style = "result_border" })

    -- Row number column (only show number on first line)
    if row_num_width then
      local row_num_str
      if line_idx == 1 and row_number then
        row_num_str = tostring(row_number)
      else
        row_num_str = ""
      end
      local padded = " " .. string.rep(" ", row_num_width - #row_num_str) .. row_num_str .. " "
      local col_start = pos
      pos = pos + #padded

      -- Style row number (muted)
      if line_idx == 1 and row_number then
        table.insert(line.highlights, { col_start = col_start, col_end = pos, style = "muted" })
      end

      line.text = line.text .. padded .. chars.vertical
      local border_start = pos
      pos = pos + #chars.vertical
      table.insert(line.highlights, { col_start = border_start, col_end = pos, style = "result_border" })
    end

    -- Each cell
    for _, cell in ipairs(cell_lines) do
      local cell_text = cell.lines[line_idx] or ""
      local padded = " " .. cell_text .. string.rep(" ", cell.width - #cell_text) .. " "
      local col_start = pos
      pos = pos + #padded

      -- Determine style (only apply to lines with content)
      local style = nil
      if color_mode ~= "none" and cell_text ~= "" then
        if highlight_null and cell.is_null then
          style = "result_null"
        elseif color_mode == "datatype" and cell.datatype then
          style = ContentBuilder.datatype_to_style(cell.datatype)
        elseif color_mode == "uniform" then
          style = "value"
        end
      end

      if style then
        table.insert(line.highlights, { col_start = col_start, col_end = pos, style = style })
      end

      line.text = line.text .. padded .. chars.vertical
      local border_start = pos
      pos = pos + #chars.vertical
      table.insert(line.highlights, { col_start = border_start, col_end = pos, style = "result_border" })
    end

    table.insert(self._lines, line)
  end

  return self
end

---Add a header row with optional row number column
---@param columns table[] Array of { name: string, width: number }
---@param border_style string "box" or "ascii"
---@param row_num_width number? Width of row number column (nil = no row number column)
---@return ContentBuilder self
function ContentBuilder:result_header_row_with_rownum(columns, border_style, row_num_width)
  local chars = ContentBuilder.get_border_chars(border_style)
  local line = { text = "", highlights = {} }
  local pos = 0

  -- Opening border
  line.text = chars.vertical
  pos = #chars.vertical
  table.insert(line.highlights, { col_start = 0, col_end = pos, style = "result_border" })

  -- Row number column header
  if row_num_width then
    local header = "#"
    local padded = " " .. string.rep(" ", row_num_width - #header) .. header .. " "
    local col_start = pos
    pos = pos + #padded
    table.insert(line.highlights, { col_start = col_start, col_end = pos, style = "result_header" })

    line.text = line.text .. padded .. chars.vertical
    local border_start = pos
    pos = pos + #chars.vertical
    table.insert(line.highlights, { col_start = border_start, col_end = pos, style = "result_border" })
  end

  -- Data columns
  for _, col in ipairs(columns) do
    local name = tostring(col.name or "")
    local padded = " " .. name .. string.rep(" ", col.width - #name) .. " "
    local col_start = pos
    pos = pos + #padded

    table.insert(line.highlights, { col_start = col_start, col_end = pos, style = "result_header" })

    line.text = line.text .. padded .. chars.vertical
    local border_start = pos
    pos = pos + #chars.vertical
    table.insert(line.highlights, { col_start = border_start, col_end = pos, style = "result_border" })
  end

  table.insert(self._lines, line)
  return self
end

---Add a top border with optional row number column
---@param columns table[] Array of { width: number }
---@param border_style string "box" or "ascii"
---@param row_num_width number? Width of row number column
---@return ContentBuilder self
function ContentBuilder:result_top_border_with_rownum(columns, border_style, row_num_width)
  local chars = ContentBuilder.get_border_chars(border_style)
  local parts = { chars.top_left }

  -- Row number column
  if row_num_width then
    table.insert(parts, string.rep(chars.horizontal, row_num_width + 2))
    table.insert(parts, chars.t_down)
  end

  -- Data columns
  for i, col in ipairs(columns) do
    table.insert(parts, string.rep(chars.horizontal, col.width + 2))
    if i < #columns then
      table.insert(parts, chars.t_down)
    end
  end
  table.insert(parts, chars.top_right)

  local text = table.concat(parts, "")
  local line = {
    text = text,
    highlights = {{ col_start = 0, col_end = #text, style = "result_border" }},
  }
  table.insert(self._lines, line)
  return self
end

---Add a separator (header/data) with optional row number column
---@param columns table[] Array of { width: number }
---@param border_style string "box" or "ascii"
---@param row_num_width number? Width of row number column
---@return ContentBuilder self
function ContentBuilder:result_separator_with_rownum(columns, border_style, row_num_width)
  local chars = ContentBuilder.get_border_chars(border_style)
  local parts = { chars.t_left }

  -- Row number column
  if row_num_width then
    table.insert(parts, string.rep(chars.horizontal, row_num_width + 2))
    table.insert(parts, chars.cross)
  end

  -- Data columns
  for i, col in ipairs(columns) do
    table.insert(parts, string.rep(chars.horizontal, col.width + 2))
    if i < #columns then
      table.insert(parts, chars.cross)
    end
  end
  table.insert(parts, chars.t_right)

  local text = table.concat(parts, "")
  local line = {
    text = text,
    highlights = {{ col_start = 0, col_end = #text, style = "result_border" }},
  }
  table.insert(self._lines, line)
  return self
end

---Add a bottom border with optional row number column
---@param columns table[] Array of { width: number }
---@param border_style string "box" or "ascii"
---@param row_num_width number? Width of row number column
---@return ContentBuilder self
function ContentBuilder:result_bottom_border_with_rownum(columns, border_style, row_num_width)
  local chars = ContentBuilder.get_border_chars(border_style)
  local parts = { chars.bottom_left }

  -- Row number column
  if row_num_width then
    table.insert(parts, string.rep(chars.horizontal, row_num_width + 2))
    table.insert(parts, chars.t_up)
  end

  -- Data columns
  for i, col in ipairs(columns) do
    table.insert(parts, string.rep(chars.horizontal, col.width + 2))
    if i < #columns then
      table.insert(parts, chars.t_up)
    end
  end
  table.insert(parts, chars.bottom_right)

  local text = table.concat(parts, "")
  local line = {
    text = text,
    highlights = {{ col_start = 0, col_end = #text, style = "result_border" }},
  }
  table.insert(self._lines, line)
  return self
end

---Build a row separator string with optional row number column (for caching)
---@param columns table[] Array of { width: number }
---@param border_style string "box" or "ascii"
---@param row_num_width number? Width of row number column
---@return string separator The separator string
function ContentBuilder.build_row_separator_with_rownum(columns, border_style, row_num_width)
  local chars = ContentBuilder.get_border_chars(border_style)
  local parts = { chars.t_left }

  -- Row number column
  if row_num_width then
    table.insert(parts, string.rep(chars.horizontal, row_num_width + 2))
    table.insert(parts, chars.cross)
  end

  -- Data columns
  for i, col in ipairs(columns) do
    table.insert(parts, string.rep(chars.horizontal, col.width + 2))
    if i < #columns then
      table.insert(parts, chars.cross)
    end
  end
  table.insert(parts, chars.t_right)

  return table.concat(parts, "")
end

---Add a pre-built row separator line (for performance when separator is cached)
---@param separator_text string The pre-built separator string
---@return ContentBuilder self
function ContentBuilder:add_cached_row_separator(separator_text)
  local line = {
    text = separator_text,
    highlights = {{ col_start = 0, col_end = #separator_text, style = "result_border" }},
  }
  table.insert(self._lines, line)
  return self
end

---Add a row separator with optional row number column
---@param columns table[] Array of { width: number }
---@param border_style string "box" or "ascii"
---@param row_num_width number? Width of row number column
---@return ContentBuilder self
function ContentBuilder:result_row_separator_with_rownum(columns, border_style, row_num_width)
  local text = ContentBuilder.build_row_separator_with_rownum(columns, border_style, row_num_width)
  return self:add_cached_row_separator(text)
end

return ContentBuilder
