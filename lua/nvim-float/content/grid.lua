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

  -- Walk character by character using vim.fn.strcharpart
  local nchars = vim.fn.strchars(text)
  local accum = 0
  local keep = 0
  for i = 0, nchars - 1 do
    local ch = vim.fn.strcharpart(text, i, 1)
    local ch_w = vim.fn.strdisplaywidth(ch)
    if accum + ch_w > target_width - 1 then
      break
    end
    accum = accum + ch_w
    keep = i + 1
  end
  local truncated = vim.fn.strcharpart(text, 0, keep) .. "…"
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
  local track = opts.track_elements
  local elem_prefix = opts.element_prefix or "grid"

  -- Chunk cells into rows and build lines
  local row_idx = 0
  local flat_idx = 0
  for i = 1, #cells, num_cols do
    row_idx = row_idx + 1
    local parts = {}
    local line_highlights = {}
    local tracked_cells = track and {} or nil

    for c = 0, num_cols - 1 do
      local cell = cells[i + c]
      if not cell then break end

      flat_idx = flat_idx + 1

      -- Pad cell text to column_width
      local padded = pad_cell(cell.text, col_width)

      -- Add padding between cells (not before first)
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

      -- Collect cell info for element registration
      if track and cell.data then
        tracked_cells[#tracked_cells + 1] = {
          name = elem_prefix .. "_" .. flat_idx,
          byte_offset = byte_offset,
          padded_len = #padded,
          data = cell.data,
        }
      end
    end

    local line_text = table.concat(parts)
    table.insert(cb._lines, {
      text = line_text,
      highlights = line_highlights,
    })

    -- Register tracked elements now that we know the line's row index
    if tracked_cells then
      local row_0 = #cb._lines - 1 -- 0-indexed row of line just added
      for _, tc in ipairs(tracked_cells) do
        cb._registry:register({
          name = tc.name,
          type = "grid_cell",
          row = row_0,
          col_start = tc.byte_offset,
          col_end = tc.byte_offset + tc.padded_len,
          row_based = false,
          data = tc.data,
        })
      end
    end
  end

  return cb
end

return M
