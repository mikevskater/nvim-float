---@module 'nvim-float.content.results'
---@brief Result table formatting methods for ContentBuilder

local M = {}

-- ============================================================================
-- Constants
-- ============================================================================

---SQL datatype to style mappings
local DATATYPE_STYLES = {
  -- String types
  varchar = "result_string", nvarchar = "result_string",
  char = "result_string", nchar = "result_string",
  text = "result_string", ntext = "result_string",
  xml = "result_string",
  var_string = "result_string", string = "result_string",
  enum = "result_string", set = "result_string",
  geometry = "result_string",
  json = "result_string", jsonb = "result_string",

  -- Numeric types
  int = "result_number", bigint = "result_number",
  smallint = "result_number", tinyint = "result_number",
  decimal = "result_number", numeric = "result_number",
  float = "result_number", real = "result_number",
  money = "result_number", smallmoney = "result_number",
  integer = "result_number",
  ["double precision"] = "result_number",
  tiny = "result_number", short = "result_number",
  long = "result_number", longlong = "result_number",
  int24 = "result_number", double = "result_number",
  newdecimal = "result_number",

  -- Date/time types
  date = "result_date", time = "result_date",
  datetime = "result_date", datetime2 = "result_date",
  smalldatetime = "result_date", datetimeoffset = "result_date",
  timestamp = "result_date", timestamptz = "result_date",
  year = "result_date",

  -- Boolean
  bit = "result_bool", boolean = "result_bool",

  -- Binary
  binary = "result_binary", varbinary = "result_binary",
  image = "result_binary",
  blob = "result_binary", tiny_blob = "result_binary",
  medium_blob = "result_binary", long_blob = "result_binary",

  -- GUID/UUID
  uniqueidentifier = "result_guid", uuid = "result_guid",
}

---Border character sets
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

-- ============================================================================
-- Static Helpers
-- ============================================================================

---Map SQL datatype to style name
---@param datatype string SQL datatype
---@return string style Style name
function M.datatype_to_style(datatype)
  if not datatype then return "value" end
  local normalized = datatype:lower():match("^([a-z_]+)")
  return DATATYPE_STYLES[normalized] or "value"
end

---Get border characters for a style
---@param style string Border style: "box" or "ascii"
---@return table chars Border character set
function M.get_border_chars(style)
  return BORDER_CHARS[style] or BORDER_CHARS.box
end

---Calculate column positions for cell tracking
---@param columns table[] Array of { name, width }
---@param row_num_width number? Width of row number column
---@param border_style string "box" or "ascii"
---@return ResultColumnInfo[] column_positions, {start_col: number, end_col: number}? row_num_col
function M.calculate_column_positions(columns, row_num_width, border_style)
  local chars = M.get_border_chars(border_style)
  local positions = {}
  local current_col = #chars.vertical  -- Start after left border

  -- Row number column (if present)
  local row_num_col = nil
  if row_num_width then
    row_num_col = {
      start_col = current_col,
      end_col = current_col + row_num_width + 2,  -- +2 for padding (space before and after)
    }
    current_col = row_num_col.end_col + #chars.vertical  -- +border width
  end

  -- Data columns
  for i, col in ipairs(columns) do
    local start_col = current_col
    local end_col = current_col + col.width + 2  -- +2 for padding
    table.insert(positions, {
      index = i,
      name = col.name or "",
      start_col = start_col,
      end_col = end_col,
    })
    current_col = end_col + #chars.vertical  -- +border width
  end

  return positions, row_num_col
end

---Wrap text to fit within a maximum width
---@param text string The text to wrap
---@param max_width number Maximum width per line
---@param mode string Wrap mode: "word" | "char" | "truncate"
---@param preserve_newlines boolean Whether to honor existing newlines
---@return string[] lines Array of wrapped lines
function M.wrap_text(text, max_width, mode, preserve_newlines)
  if not text or text == "" then
    return { "" }
  end

  text = tostring(text)

  -- Handle "truncate" mode
  if mode == "truncate" then
    local first_newline = text:find("[\r\n]")
    local truncated = text

    if first_newline then
      truncated = text:sub(1, first_newline - 1)
    end

    if #truncated <= max_width then
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
      return { truncated:sub(1, max_width - 3) .. "..." }
    end
  end

  local lines = {}

  -- Split by newlines if preserving
  local segments
  if preserve_newlines then
    local normalized = text:gsub("\r\n", "\n"):gsub("\r", "\n")
    segments = vim.split(normalized, "\n", { plain = true })
  else
    segments = { (text:gsub("\r\n", " "):gsub("\n", " "):gsub("\r", " ")) }
  end

  -- Wrap each segment
  for _, segment in ipairs(segments) do
    if #segment <= max_width then
      table.insert(lines, segment)
    elseif mode == "char" then
      local pos = 1
      while pos <= #segment do
        local chunk = segment:sub(pos, pos + max_width - 1)
        table.insert(lines, chunk)
        pos = pos + max_width
      end
    else
      -- Word-based wrapping
      local current_line = ""
      local words = vim.split(segment, "%s+", { trimempty = false })

      for _, word in ipairs(words) do
        if word == "" then
          if #current_line < max_width then
            current_line = current_line .. " "
          end
        elseif #current_line == 0 then
          if #word > max_width then
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
          current_line = current_line .. " " .. word
        else
          table.insert(lines, current_line)
          if #word > max_width then
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

      if #current_line > 0 or #lines == 0 then
        table.insert(lines, current_line)
      end
    end
  end

  return #lines > 0 and lines or { "" }
end

-- ============================================================================
-- Basic Result Methods
-- ============================================================================

---Add a result table header row with borders
---@param cb ContentBuilder
---@param columns table[] Array of { name, width }
---@param border_style string "box" or "ascii"
---@return ContentBuilder self
function M.result_header_row(cb, columns, border_style)
  local chars = M.get_border_chars(border_style)
  local line = { text = "", highlights = {} }
  local pos = 0

  line.text = chars.vertical
  pos = #chars.vertical
  table.insert(line.highlights, { col_start = 0, col_end = pos, style = "result_border" })

  for _, col in ipairs(columns) do
    local padded = " " .. tostring(col.name) .. string.rep(" ", col.width - #tostring(col.name)) .. " "
    local col_start = pos
    pos = pos + #padded

    table.insert(line.highlights, { col_start = col_start, col_end = pos, style = "result_header" })

    line.text = line.text .. padded .. chars.vertical
    local border_start = pos
    pos = pos + #chars.vertical
    table.insert(line.highlights, { col_start = border_start, col_end = pos, style = "result_border" })
  end

  table.insert(cb._lines, line)
  return cb
end

---Add a result table top border row
---@param cb ContentBuilder
---@param columns table[] Array of { width }
---@param border_style string "box" or "ascii"
---@return ContentBuilder self
function M.result_top_border(cb, columns, border_style)
  local chars = M.get_border_chars(border_style)
  local parts = { chars.top_left }

  for i, col in ipairs(columns) do
    table.insert(parts, string.rep(chars.horizontal, col.width + 2))
    if i < #columns then
      table.insert(parts, chars.t_down)
    end
  end
  table.insert(parts, chars.top_right)

  local text = table.concat(parts, "")
  table.insert(cb._lines, {
    text = text,
    highlights = {{ col_start = 0, col_end = #text, style = "result_border" }},
  })
  return cb
end

---Add a result table separator row
---@param cb ContentBuilder
---@param columns table[] Array of { width }
---@param border_style string "box" or "ascii"
---@return ContentBuilder self
function M.result_separator(cb, columns, border_style)
  local chars = M.get_border_chars(border_style)
  local parts = { chars.t_left }

  for i, col in ipairs(columns) do
    table.insert(parts, string.rep(chars.horizontal, col.width + 2))
    if i < #columns then
      table.insert(parts, chars.cross)
    end
  end
  table.insert(parts, chars.t_right)

  local text = table.concat(parts, "")
  table.insert(cb._lines, {
    text = text,
    highlights = {{ col_start = 0, col_end = #text, style = "result_border" }},
  })
  return cb
end

---Add a result table bottom border row
---@param cb ContentBuilder
---@param columns table[] Array of { width }
---@param border_style string "box" or "ascii"
---@return ContentBuilder self
function M.result_bottom_border(cb, columns, border_style)
  local chars = M.get_border_chars(border_style)
  local parts = { chars.bottom_left }

  for i, col in ipairs(columns) do
    table.insert(parts, string.rep(chars.horizontal, col.width + 2))
    if i < #columns then
      table.insert(parts, chars.t_up)
    end
  end
  table.insert(parts, chars.bottom_right)

  local text = table.concat(parts, "")
  table.insert(cb._lines, {
    text = text,
    highlights = {{ col_start = 0, col_end = #text, style = "result_border" }},
  })
  return cb
end

---Add a result data row with datatype coloring
---@param cb ContentBuilder
---@param values table[] Array of { value, width, datatype?, is_null? }
---@param color_mode string "datatype" | "uniform" | "none"
---@param border_style string "box" or "ascii"
---@param highlight_null boolean Whether to highlight NULL values
---@return ContentBuilder self
function M.result_data_row(cb, values, color_mode, border_style, highlight_null)
  local chars = M.get_border_chars(border_style)
  local line = { text = "", highlights = {} }
  local pos = 0

  line.text = chars.vertical
  pos = #chars.vertical
  table.insert(line.highlights, { col_start = 0, col_end = pos, style = "result_border" })

  for _, val in ipairs(values) do
    local value_str = tostring(val.value or "")
    value_str = value_str:gsub("\n", " ")

    local padded = " " .. value_str .. string.rep(" ", val.width - #value_str) .. " "
    local col_start = pos
    pos = pos + #padded

    local style = nil
    if color_mode ~= "none" then
      if highlight_null and val.is_null then
        style = "result_null"
      elseif color_mode == "datatype" and val.datatype then
        style = M.datatype_to_style(val.datatype)
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

  table.insert(cb._lines, line)
  return cb
end

---Add a result message line
---@param cb ContentBuilder
---@param text string Message text
---@param style string? Style to use
---@return ContentBuilder self
function M.result_message(cb, text, style)
  local Lines = require("nvim-float.content.lines")
  return Lines.styled(cb, text, style or "result_message")
end

---Add a row separator between data rows
---@param cb ContentBuilder
---@param columns table[] Array of { width }
---@param border_style string "box" or "ascii"
---@return ContentBuilder self
function M.result_row_separator(cb, columns, border_style)
  return M.result_separator(cb, columns, border_style)
end

-- ============================================================================
-- Multi-line Cell Support
-- ============================================================================

---Add a multi-line data row
---@param cb ContentBuilder
---@param cell_lines table[] Array of { lines, width, datatype?, is_null? }
---@param color_mode string "datatype" | "uniform" | "none"
---@param border_style string "box" or "ascii"
---@param highlight_null boolean Whether to highlight NULL values
---@param row_number number? Row number to display (also used as row index for cell tracking)
---@param row_num_width number? Width of row number column
---@return ContentBuilder self
function M.result_multiline_data_row(cb, cell_lines, color_mode, border_style, highlight_null, row_number, row_num_width)
  local chars = M.get_border_chars(border_style)

  -- Track row start line (1-based)
  local row_start_line = #cb._lines + 1

  -- Calculate max lines across all cells
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

    line.text = chars.vertical
    pos = #chars.vertical
    table.insert(line.highlights, { col_start = 0, col_end = pos, style = "result_border" })

    -- Row number column
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

      local style = nil
      if color_mode ~= "none" and cell_text ~= "" then
        if highlight_null and cell.is_null then
          style = "result_null"
        elseif color_mode == "datatype" and cell.datatype then
          style = M.datatype_to_style(cell.datatype)
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

    table.insert(cb._lines, line)
  end

  -- Update cell map if tracking is active and row_number is provided
  if cb._result_cell_map and row_number then
    local row_end_line = #cb._lines
    table.insert(cb._result_cell_map.data_rows, {
      index = row_number,
      start_line = row_start_line,
      end_line = row_end_line,
    })
  end

  return cb
end

-- ============================================================================
-- Row Number Variants
-- ============================================================================

---Add a header row with row number column
---@param cb ContentBuilder
---@param columns table[] Array of { name, width }
---@param border_style string "box" or "ascii"
---@param row_num_width number? Width of row number column
---@return ContentBuilder self
function M.result_header_row_with_rownum(cb, columns, border_style, row_num_width)
  local chars = M.get_border_chars(border_style)
  local line = { text = "", highlights = {} }
  local pos = 0

  -- Track header line position (1-based)
  local header_line_num = #cb._lines + 1

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

  table.insert(cb._lines, line)

  -- Update cell map if tracking is active
  if cb._result_cell_map then
    local col_positions, row_num_col = M.calculate_column_positions(columns, row_num_width, border_style)
    cb._result_cell_map.columns = col_positions
    cb._result_cell_map.row_num_column = row_num_col
    cb._result_cell_map.header_lines = {
      start_line = header_line_num,
      end_line = header_line_num,
    }
  end

  return cb
end

---Add a top border with row number column
---@param cb ContentBuilder
---@param columns table[] Array of { width }
---@param border_style string "box" or "ascii"
---@param row_num_width number? Width of row number column
---@return ContentBuilder self
function M.result_top_border_with_rownum(cb, columns, border_style, row_num_width)
  local chars = M.get_border_chars(border_style)
  local parts = { chars.top_left }

  if row_num_width then
    table.insert(parts, string.rep(chars.horizontal, row_num_width + 2))
    table.insert(parts, chars.t_down)
  end

  for i, col in ipairs(columns) do
    table.insert(parts, string.rep(chars.horizontal, col.width + 2))
    if i < #columns then
      table.insert(parts, chars.t_down)
    end
  end
  table.insert(parts, chars.top_right)

  local text = table.concat(parts, "")
  table.insert(cb._lines, {
    text = text,
    highlights = {{ col_start = 0, col_end = #text, style = "result_border" }},
  })
  return cb
end

---Add a separator with row number column
---@param cb ContentBuilder
---@param columns table[] Array of { width }
---@param border_style string "box" or "ascii"
---@param row_num_width number? Width of row number column
---@return ContentBuilder self
function M.result_separator_with_rownum(cb, columns, border_style, row_num_width)
  local chars = M.get_border_chars(border_style)
  local parts = { chars.t_left }

  if row_num_width then
    table.insert(parts, string.rep(chars.horizontal, row_num_width + 2))
    table.insert(parts, chars.cross)
  end

  for i, col in ipairs(columns) do
    table.insert(parts, string.rep(chars.horizontal, col.width + 2))
    if i < #columns then
      table.insert(parts, chars.cross)
    end
  end
  table.insert(parts, chars.t_right)

  local text = table.concat(parts, "")
  table.insert(cb._lines, {
    text = text,
    highlights = {{ col_start = 0, col_end = #text, style = "result_border" }},
  })
  return cb
end

---Add a bottom border with row number column
---@param cb ContentBuilder
---@param columns table[] Array of { width }
---@param border_style string "box" or "ascii"
---@param row_num_width number? Width of row number column
---@return ContentBuilder self
function M.result_bottom_border_with_rownum(cb, columns, border_style, row_num_width)
  local chars = M.get_border_chars(border_style)
  local parts = { chars.bottom_left }

  if row_num_width then
    table.insert(parts, string.rep(chars.horizontal, row_num_width + 2))
    table.insert(parts, chars.t_up)
  end

  for i, col in ipairs(columns) do
    table.insert(parts, string.rep(chars.horizontal, col.width + 2))
    if i < #columns then
      table.insert(parts, chars.t_up)
    end
  end
  table.insert(parts, chars.bottom_right)

  local text = table.concat(parts, "")
  table.insert(cb._lines, {
    text = text,
    highlights = {{ col_start = 0, col_end = #text, style = "result_border" }},
  })
  return cb
end

---Build a row separator string with row number column (for caching)
---@param columns table[] Array of { width }
---@param border_style string "box" or "ascii"
---@param row_num_width number? Width of row number column
---@return string separator
function M.build_row_separator_with_rownum(columns, border_style, row_num_width)
  local chars = M.get_border_chars(border_style)
  local parts = { chars.t_left }

  if row_num_width then
    table.insert(parts, string.rep(chars.horizontal, row_num_width + 2))
    table.insert(parts, chars.cross)
  end

  for i, col in ipairs(columns) do
    table.insert(parts, string.rep(chars.horizontal, col.width + 2))
    if i < #columns then
      table.insert(parts, chars.cross)
    end
  end
  table.insert(parts, chars.t_right)

  return table.concat(parts, "")
end

---Add a pre-built row separator line
---@param cb ContentBuilder
---@param separator_text string The pre-built separator string
---@return ContentBuilder self
function M.add_cached_row_separator(cb, separator_text)
  table.insert(cb._lines, {
    text = separator_text,
    highlights = {{ col_start = 0, col_end = #separator_text, style = "result_border" }},
  })
  return cb
end

---Add a row separator with row number column
---@param cb ContentBuilder
---@param columns table[] Array of { width }
---@param border_style string "box" or "ascii"
---@param row_num_width number? Width of row number column
---@return ContentBuilder self
function M.result_row_separator_with_rownum(cb, columns, border_style, row_num_width)
  local text = M.build_row_separator_with_rownum(columns, border_style, row_num_width)
  return M.add_cached_row_separator(cb, text)
end

return M
