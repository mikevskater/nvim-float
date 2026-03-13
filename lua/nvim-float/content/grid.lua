---@module 'nvim-float.content.grid'
---@brief Grid rendering for ContentBuilder

local M = {}

-- ============================================================================
-- Helpers
-- ============================================================================

---Truncate text to fit within target display width, adding ellipsis if needed
---@param text string
---@param target_width number
---@return string truncated
local function truncate_to_width(text, target_width)
  if target_width <= 0 then return "" end
  local dw = vim.fn.strdisplaywidth(text)
  if dw <= target_width then return text end

  -- Walk character by character, accumulating display width
  local result = {}
  local accum = 0
  for _, code in utf8.codes(text) do
    local ch = utf8.char(code)
    local ch_w = vim.fn.strdisplaywidth(ch)
    if accum + ch_w > target_width - 1 then
      break
    end
    result[#result + 1] = ch
    accum = accum + ch_w
  end
  local truncated = table.concat(result) .. "…"
  -- Pad if ellipsis doesn't fill exactly
  local final_w = vim.fn.strdisplaywidth(truncated)
  if final_w < target_width then
    truncated = truncated .. string.rep(" ", target_width - final_w)
  end
  return truncated
end

---Pad or truncate text to exactly target display width
---@param text string
---@param target_width number
---@return string padded
local function pad_cell(text, target_width)
  local dw = vim.fn.strdisplaywidth(text)
  if dw > target_width then
    return truncate_to_width(text, target_width)
  end
  if dw < target_width then
    return text .. string.rep(" ", target_width - dw)
  end
  return text
end

---Calculate column count from options
---@param opts GridOpts
---@return number
local function calc_columns(opts)
  if opts.columns then return opts.columns end
  local available = opts.available_width or 80
  local cell_total = opts.column_width + (opts.cell_padding or 1)
  return math.max(1, math.floor(available / cell_total))
end

---Calculate byte offset for column position in a line string
---Uses the fact that cells are padded to fixed display widths
---@param line_text string The full line text
---@param col_idx number 1-indexed column position
---@param col_width number Display width per cell
---@param cell_padding number Padding between cells
---@return number byte_start, number byte_end
local function calc_cell_byte_range(line_text, col_idx, col_width, cell_padding)
  -- Walk through the line text to find byte positions
  -- Each cell occupies col_width display columns + cell_padding spaces
  local cell_total = col_width + cell_padding
  local target_display_start = (col_idx - 1) * cell_total

  local byte_pos = 1
  local display_pos = 0

  -- Walk to start position
  while display_pos < target_display_start and byte_pos <= #line_text do
    local code = utf8.codepoint(line_text, byte_pos)
    local ch = utf8.char(code)
    local ch_w = vim.fn.strdisplaywidth(ch)
    display_pos = display_pos + ch_w
    byte_pos = byte_pos + #ch
  end

  local byte_start = byte_pos - 1 -- 0-indexed

  -- Walk col_width display columns for the cell content
  local cell_display = 0
  while cell_display < col_width and byte_pos <= #line_text do
    local code = utf8.codepoint(line_text, byte_pos)
    local ch = utf8.char(code)
    local ch_w = vim.fn.strdisplaywidth(ch)
    cell_display = cell_display + ch_w
    byte_pos = byte_pos + #ch
  end

  local byte_end = byte_pos - 1 -- 0-indexed, exclusive-ish (last byte of cell content)

  return byte_start, byte_end
end

-- ============================================================================
-- Grid Method
-- ============================================================================

---Render a multi-column grid of cells
---@param cb ContentBuilder
---@param cells GridCell[] Flat array of cells
---@param opts GridOpts Grid options
---@return ContentBuilder cb For chaining
function M.grid(cb, cells, opts)
  if not cells or #cells == 0 then return cb end

  local col_width = opts.column_width
  local cell_padding = opts.cell_padding or 1
  local num_cols = calc_columns(opts)
  local sel = opts.selected
  local sel_hl = opts.selection_hl or "NvimFloatGridSelected"
  local base_line = #cb._lines -- 0-indexed start line for the grid

  -- Chunk cells into rows and build lines
  local row_idx = 0
  for i = 1, #cells, num_cols do
    row_idx = row_idx + 1
    local parts = {}
    local line_highlights = {}

    for c = 0, num_cols - 1 do
      local cell = cells[i + c]
      if not cell then break end

      -- Pad cell text to column_width
      local padded = pad_cell(cell.text, col_width)

      -- Add padding between cells (except after last)
      if c > 0 then
        parts[#parts + 1] = string.rep(" ", cell_padding)
      end

      -- Track byte offset for highlights
      local part_text = table.concat(parts)
      local byte_offset = #part_text

      parts[#parts + 1] = padded

      -- Cell highlight
      if cell.hl_group then
        line_highlights[#line_highlights + 1] = {
          col_start = byte_offset,
          col_end = byte_offset + #padded,
          hl_group = cell.hl_group,
        }
      end

      -- Selection highlight
      if sel and sel.row == row_idx and sel.col == (c + 1) then
        line_highlights[#line_highlights + 1] = {
          col_start = byte_offset,
          col_end = byte_offset + #padded,
          hl_group = sel_hl,
        }
      end
    end

    local line_text = table.concat(parts)
    table.insert(cb._lines, {
      text = line_text,
      highlights = line_highlights,
    })
  end

  return cb
end

return M
