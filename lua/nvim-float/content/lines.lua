---@module 'nvim-float.content.lines'
---@brief Line building methods for ContentBuilder

local Elements = require("nvim-float.elements")
local Styles = require("nvim-float.theme.styles")

local M = {}

-- ============================================================================
-- Basic Line Methods
-- ============================================================================

---Add a plain text line (no special highlighting)
---@param cb ContentBuilder
---@param text string Line text
---@return ContentBuilder self For chaining
function M.line(cb, text)
  table.insert(cb._lines, {
    text = text or "",
    highlights = {},
  })
  return cb
end

---Alias for line() - add plain text
---@param cb ContentBuilder
---@param text string Text content
---@return ContentBuilder self For chaining
function M.text(cb, text)
  return M.line(cb, text)
end

---Add an empty line
---@param cb ContentBuilder
---@return ContentBuilder self For chaining
function M.blank(cb)
  return M.line(cb, "")
end

-- ============================================================================
-- Styled Line Methods
-- ============================================================================

---Add a styled line (entire line has one style)
---@param cb ContentBuilder
---@param text string Line text
---@param style string Style name from STYLE_MAPPINGS, or direct highlight group name
---@param opts? { track?: string|table } Optional tracking
---@return ContentBuilder self For chaining
function M.styled(cb, text, style, opts)
  local line = {
    text = text or "",
    highlights = {},
  }
  if style then
    local mapped_hl = Styles.get(style)
    if mapped_hl then
      -- Registered style - use style name (will be mapped in build_highlights)
      table.insert(line.highlights, {
        col_start = 0,
        col_end = #text,
        style = style,
      })
    else
      -- Not a registered style - assume it's a direct highlight group name
      table.insert(line.highlights, {
        col_start = 0,
        col_end = #text,
        hl_group = style,
      })
    end
  end
  table.insert(cb._lines, line)

  -- Handle element tracking
  if opts and opts.track then
    local track = opts.track
    local track_opts = type(track) == "string" and { name = track } or track

    local row = #cb._lines - 1  -- 0-indexed
    cb._registry:register({
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

  return cb
end

---Add a header line
---@param cb ContentBuilder
---@param text string Header text
---@return ContentBuilder self For chaining
function M.header(cb, text)
  return M.styled(cb, text, "header")
end

---Add a subheader line
---@param cb ContentBuilder
---@param text string Subheader text
---@return ContentBuilder self For chaining
function M.subheader(cb, text)
  return M.styled(cb, text, "subheader")
end

---Add a section header
---@param cb ContentBuilder
---@param text string Section text
---@return ContentBuilder self For chaining
function M.section(cb, text)
  return M.styled(cb, text, "section")
end

---Add muted text
---@param cb ContentBuilder
---@param text string Muted text
---@return ContentBuilder self For chaining
function M.muted(cb, text)
  return M.styled(cb, text, "muted")
end

---Add a bullet point
---@param cb ContentBuilder
---@param text string Bullet text
---@param style string? Optional style for the text
---@return ContentBuilder self For chaining
function M.bullet(cb, text, style)
  local prefix = "  - "
  if style then
    return M.spans(cb, {
      { text = prefix, style = "muted" },
      { text = text, style = style },
    })
  else
    return M.line(cb, prefix .. text)
  end
end

---Add a separator line
---@param cb ContentBuilder
---@param char string? Character to repeat (default: "-")
---@param width number? Width (default: 50)
---@return ContentBuilder self For chaining
function M.separator(cb, char, width)
  char = char or "-"
  width = width or 50
  return M.styled(cb, string.rep(char, width), "muted")
end

-- ============================================================================
-- Label/Value Methods
-- ============================================================================

---Add a label: value line
---@param cb ContentBuilder
---@param label string Label text
---@param value any Value (will be tostring'd)
---@param opts table? Options: { label_style, value_style, separator }
---@return ContentBuilder self For chaining
function M.label_value(cb, label, value, opts)
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
  if Styles.get(label_style) then
    table.insert(line.highlights, {
      col_start = 0,
      col_end = #label,
      style = label_style,
    })
  end

  -- Highlight value
  if Styles.get(value_style) then
    table.insert(line.highlights, {
      col_start = #label + #sep,
      col_end = #text,
      style = value_style,
    })
  end

  table.insert(cb._lines, line)
  return cb
end

---Add a key: value line
---@param cb ContentBuilder
---@param key string Key text
---@param value any Value
---@return ContentBuilder self For chaining
function M.key_value(cb, key, value)
  return M.label_value(cb, key, value, { label_style = "key", value_style = "value" })
end

-- ============================================================================
-- Spans (Mixed Styles)
-- ============================================================================

---Add a line with mixed styles using spans
---@param cb ContentBuilder
---@param spans table[] Array of { text, style?, hl_group?, track? }
---@return ContentBuilder self For chaining
function M.spans(cb, spans)
  local text_parts = {}
  local highlights = {}
  local tracked_elements = {}
  local pos = 0

  for _, span in ipairs(spans) do
    local span_text = span.text or ""
    table.insert(text_parts, span_text)

    -- Support both style (mapped) and hl_group (direct)
    if span.hl_group then
      table.insert(highlights, {
        col_start = pos,
        col_end = pos + #span_text,
        hl_group = span.hl_group,
      })
    elseif span.style then
      local mapped_hl = Styles.get(span.style)
      if mapped_hl then
        -- Registered style
        table.insert(highlights, {
          col_start = pos,
          col_end = pos + #span_text,
          style = span.style,
        })
      else
        -- Not registered - use as direct highlight group
        table.insert(highlights, {
          col_start = pos,
          col_end = pos + #span_text,
          hl_group = span.style,
        })
      end
    end

    -- Collect tracking info
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

  table.insert(cb._lines, {
    text = table.concat(text_parts, ""),
    highlights = highlights,
  })

  -- Register tracked elements
  local row = #cb._lines - 1
  for _, elem in ipairs(tracked_elements) do
    elem.row = row
    cb._registry:register(elem)
  end

  return cb
end

-- ============================================================================
-- Element Tracking Helpers
-- ============================================================================

---Add a tracked row element
---@param cb ContentBuilder
---@param name string Element name
---@param opts table Options
---@return ContentBuilder self For chaining
function M.tracked(cb, name, opts)
  opts = opts or {}
  local text = opts.text or ""
  local style = opts.style

  local line = {
    text = text,
    highlights = {},
  }

  if style and Styles.get(style) then
    table.insert(line.highlights, {
      col_start = 0,
      col_end = #text,
      style = style,
    })
  end

  table.insert(cb._lines, line)

  local row = #cb._lines - 1
  cb._registry:register({
    name = name,
    type = opts.type or Elements.ElementType.TEXT,
    row = row,
    col_start = 0,
    col_end = #text,
    row_based = opts.row_based ~= false,
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

  return cb
end

---Create a button span
---@param cb ContentBuilder
---@param text string Button text
---@param opts table Options
---@return table span Span table for use in spans()
function M.button(cb, text, opts)
  opts = opts or {}
  local Types = Elements.Types

  return {
    text = text,
    style = opts.style or Types.get_default_style("button"),
    track = {
      name = opts.name or ("button_" .. text:gsub("%W", "_")),
      type = Elements.ElementType.BUTTON,
      data = opts.data or { callback = opts.on_interact },
      on_interact = opts.on_interact,
      hover_style = opts.hover_style or Types.get_hover_style("button"),
    },
  }
end

---Create an action span
---@param cb ContentBuilder
---@param text string Action text
---@param opts table Options
---@return table span Span table for use in spans()
function M.action(cb, text, opts)
  opts = opts or {}
  local Types = Elements.Types

  return {
    text = text,
    style = opts.style or Types.get_default_style("action"),
    track = {
      name = opts.name or ("action_" .. text:gsub("%W", "_")),
      type = Elements.ElementType.ACTION,
      data = opts.data or { callback = opts.on_interact },
      on_interact = opts.on_interact,
      hover_style = opts.hover_style or Types.get_hover_style("action"),
    },
  }
end

---Create a toggle span
---@param cb ContentBuilder
---@param text string Toggle text
---@param opts table Options
---@return table span Span table for use in spans()
function M.toggle(cb, text, opts)
  opts = opts or {}
  local Types = Elements.Types

  return {
    text = text,
    style = opts.style or Types.get_default_style("toggle"),
    track = {
      name = opts.name or ("toggle_" .. text:gsub("%W", "_")),
      type = Elements.ElementType.TOGGLE,
      value = opts.value or false,
      data = opts.data,
      on_change = opts.on_change,
      hover_style = opts.hover_style or Types.get_hover_style("toggle"),
    },
  }
end

---Create a link span
---@param cb ContentBuilder
---@param text string Link text
---@param opts table Options
---@return table span Span table for use in spans()
function M.link(cb, text, opts)
  opts = opts or {}
  local Types = Elements.Types

  local data = opts.data or {}
  if opts.url then data.url = opts.url end
  if opts.on_interact then data.callback = opts.on_interact end

  return {
    text = text,
    style = opts.style or Types.get_default_style("link"),
    track = {
      name = opts.name or ("link_" .. text:gsub("%W", "_")),
      type = Elements.ElementType.LINK,
      data = data,
      on_interact = opts.on_interact,
      hover_style = opts.hover_style or Types.get_hover_style("link"),
    },
  }
end

-- ============================================================================
-- Utility Line Methods
-- ============================================================================

---Add a status line with icon
---@param cb ContentBuilder
---@param status_type "success"|"warning"|"error"|"muted" Status type
---@param text string Status text
---@return ContentBuilder self For chaining
function M.status(cb, status_type, text)
  local icons = {
    success = "ok",
    warning = "!",
    error = "x",
    muted = "-",
  }
  local icon = icons[status_type] or "-"
  return M.spans(cb, {
    { text = "[" .. icon .. "] ", style = status_type },
    { text = text, style = status_type },
  })
end

---Add a list item
---@param cb ContentBuilder
---@param text string Item text
---@param style string? Style for the text
---@param prefix string? Prefix (default: "  - ")
---@return ContentBuilder self For chaining
function M.list_item(cb, text, style, prefix)
  prefix = prefix or "  - "
  if style then
    return M.spans(cb, {
      { text = prefix, style = "muted" },
      { text = text, style = style },
    })
  else
    return M.line(cb, prefix .. text)
  end
end

---Add a table row with columns
---@param cb ContentBuilder
---@param columns table[] Array of { text, width?, style? }
---@return ContentBuilder self For chaining
function M.table_row(cb, columns)
  local spans = {}
  for i, col in ipairs(columns) do
    local text = col.text or ""
    local width = col.width

    if width then
      if #text < width then
        text = text .. string.rep(" ", width - #text)
      elseif #text > width then
        text = text:sub(1, width - 1) .. "..."
      end
    end

    if i > 1 then
      table.insert(spans, { text = " ", style = nil })
    end

    table.insert(spans, { text = text, style = col.style })
  end

  return M.spans(cb, spans)
end

---Add indented content
---@param cb ContentBuilder
---@param text string Text to indent
---@param level number? Indent level (default: 1)
---@param style string? Style for the text
---@return ContentBuilder self For chaining
function M.indent(cb, text, level, style)
  level = level or 1
  local prefix = string.rep("  ", level)
  if style then
    return M.spans(cb, {
      { text = prefix },
      { text = text, style = style },
    })
  else
    return M.line(cb, prefix .. text)
  end
end

return M
