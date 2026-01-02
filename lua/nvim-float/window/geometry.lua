---@module 'nvim-float.window.geometry'
---@brief Dimension and position calculations for FloatWindow

local M = {}

-- ============================================================================
-- Dimension Calculation
-- ============================================================================

---Calculate window dimensions based on content and config
---@param fw FloatWindow The FloatWindow instance
---@return number width, number height
function M.calculate_dimensions(fw)
  local width = fw.config.width
  local height = fw.config.height

  -- If both width and height are explicitly set, use them directly
  if width and height then
    return width, height
  end

  -- Auto-calculate width if not specified
  if not width then
    width = fw.config.min_width or 60

    -- Calculate content width
    local max_line_width = 0
    for _, line in ipairs(fw.lines) do
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
    height = #fw.lines
  end

  -- Apply constraints
  if fw.config.min_width then
    width = math.max(width, fw.config.min_width)
  end
  if fw.config.max_width then
    width = math.min(width, fw.config.max_width)
  end
  if fw.config.min_height then
    height = math.max(height, fw.config.min_height)
  end
  if fw.config.max_height then
    local screen_max = vim.o.lines - 6
    local effective_max = math.min(fw.config.max_height, screen_max)
    height = math.min(height, effective_max)
  end

  -- Account for title/footer if present
  if fw.config.title then
    local title_width = vim.fn.strdisplaywidth(fw.config.title) + 2
    width = math.max(width, title_width)
  end
  if fw.config.footer then
    local footer_width = vim.fn.strdisplaywidth(fw.config.footer) + 2
    width = math.max(width, footer_width)
  end

  return width, height
end

-- ============================================================================
-- Position Calculation
-- ============================================================================

---Calculate window position
---@param fw FloatWindow The FloatWindow instance
---@param width number Window width
---@param height number Window height
---@return number row, number col
function M.calculate_position(fw, width, height)
  local row, col

  -- If row and col are explicitly set with centered=false, use them directly
  if not fw.config.centered and fw.config.row and fw.config.col then
    return fw.config.row, fw.config.col
  end

  if fw.config.centered then
    -- Center on screen
    row = math.floor((vim.o.lines - height) / 2)
    col = math.floor((vim.o.columns - width) / 2)
  elseif fw.config.relative == "cursor" then
    -- Position relative to cursor
    row = fw.config.row or 1
    col = fw.config.col or 0
  else
    -- Use specified position
    row = fw.config.row or 0
    col = fw.config.col or 0
  end

  -- Ensure window stays on screen
  row = math.max(0, math.min(row, vim.o.lines - height - 4))
  col = math.max(0, math.min(col, vim.o.columns - width - 2))

  return row, col
end

-- ============================================================================
-- Layout Recalculation
-- ============================================================================

---Recalculate layout after terminal resize
---@param fw FloatWindow The FloatWindow instance
function M.recalculate_layout(fw)
  if not fw:is_valid() then return end

  -- Update max constraints based on current terminal size
  local screen_max_width = vim.o.columns - 4
  local screen_max_height = vim.o.lines - 6

  fw.config.max_width = screen_max_width
  fw.config.max_height = screen_max_height

  local width, height

  if fw._user_specified_width then
    width = math.min(fw.config.width, screen_max_width)
  else
    width = fw.config.min_width or 60
    local max_line_width = 0
    for _, line in ipairs(fw.lines) do
      local line_width = vim.fn.strdisplaywidth(line)
      if line_width > max_line_width then
        max_line_width = line_width
      end
    end
    if max_line_width > width then
      width = max_line_width
    end
    if fw.config.min_width then
      width = math.max(width, fw.config.min_width)
    end
    width = math.min(width, screen_max_width)
  end

  if fw._user_specified_height then
    height = math.min(fw.config.height, screen_max_height)
  else
    height = math.min(#fw.lines, screen_max_height)
    if fw.config.min_height then
      height = math.max(height, fw.config.min_height)
    end
  end

  -- Recalculate position
  local row, col = M.calculate_position(fw, width, height)

  -- Store updated geometry
  fw._win_row = row
  fw._win_col = col
  fw._win_width = width
  fw._win_height = height

  -- Update window config
  vim.api.nvim_win_set_config(fw.winid, {
    relative = fw.config.relative,
    width = width,
    height = height,
    row = row,
    col = col,
  })

  -- Reposition scrollbar if enabled
  if fw.config.scrollbar then
    local Scrollbar = require("nvim-float.float.scrollbar")
    Scrollbar.reposition(fw)
  end
end

return M
