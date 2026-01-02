---@module 'nvim-float.float.multipanel.junction'
---@brief Junction overlay management for MultiPanelWindow

local M = {}

-- Lazy load FloatLayout
local _FloatLayout = nil
local function get_FloatLayout()
  if not _FloatLayout then
    _FloatLayout = require('nvim-float.float.layout')
  end
  return _FloatLayout
end

-- ============================================================================
-- Junction Overlay Methods
-- ============================================================================

---Create junction overlay windows for proper border intersections
---@param state MultiPanelState
---@param layouts PanelLayout[] Panel layouts
---@param UiFloat table UiFloat module reference
function M.create_junction_overlays(state, layouts, UiFloat)
  local FloatLayout = get_FloatLayout()

  -- Find all intersection points
  local intersections = FloatLayout.find_border_intersections(layouts)

  -- Create a small overlay window at each intersection
  for _, intersection in ipairs(intersections) do
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_option(buf, 'buftype', 'nofile')
    vim.api.nvim_buf_set_option(buf, 'bufhidden', 'wipe')
    vim.api.nvim_buf_set_option(buf, 'modifiable', true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {intersection.char})
    vim.api.nvim_buf_set_option(buf, 'modifiable', false)

    local win = vim.api.nvim_open_win(buf, false, {
      relative = "editor",
      width = 1,
      height = 1,
      row = intersection.y,
      col = intersection.x,
      style = "minimal",
      border = "none",
      focusable = false,
      zindex = UiFloat.ZINDEX.OVERLAY,  -- High z-index to be on top of panel borders
    })

    -- Style with border color
    vim.api.nvim_set_option_value('winhighlight', 'Normal:NvimFloatBorder', { win = win })

    table.insert(state._junction_overlays, {bufnr = buf, winid = win, x = intersection.x, y = intersection.y, char = intersection.char})
  end
end

---Close all junction overlay windows
---@param state MultiPanelState
function M.close_junction_overlays(state)
  for _, overlay in ipairs(state._junction_overlays or {}) do
    if overlay.winid and vim.api.nvim_win_is_valid(overlay.winid) then
      pcall(vim.api.nvim_win_close, overlay.winid, true)
    end
    if overlay.bufnr and vim.api.nvim_buf_is_valid(overlay.bufnr) then
      pcall(vim.api.nvim_buf_delete, overlay.bufnr, { force = true })
    end
  end
  state._junction_overlays = {}
end

---Update junction overlays after layout recalculation
---@param state MultiPanelState
---@param layouts PanelLayout[] New panel layouts
---@param UiFloat table UiFloat module reference
function M.update_junction_overlays(state, layouts, UiFloat)
  local FloatLayout = get_FloatLayout()

  -- Find new intersection points
  local intersections = FloatLayout.find_border_intersections(layouts)

  -- Remove excess overlays
  while #state._junction_overlays > #intersections do
    local overlay = table.remove(state._junction_overlays)
    if overlay.winid and vim.api.nvim_win_is_valid(overlay.winid) then
      pcall(vim.api.nvim_win_close, overlay.winid, true)
    end
    if overlay.bufnr and vim.api.nvim_buf_is_valid(overlay.bufnr) then
      pcall(vim.api.nvim_buf_delete, overlay.bufnr, { force = true })
    end
  end

  -- Update existing overlays and create new ones if needed
  for i, intersection in ipairs(intersections) do
    if state._junction_overlays[i] then
      -- Update existing overlay
      local overlay = state._junction_overlays[i]
      if overlay.winid and vim.api.nvim_win_is_valid(overlay.winid) then
        vim.api.nvim_win_set_config(overlay.winid, {
          relative = "editor",
          row = intersection.y,
          col = intersection.x,
        })
        -- Update character if changed
        if overlay.char ~= intersection.char and overlay.bufnr and vim.api.nvim_buf_is_valid(overlay.bufnr) then
          vim.api.nvim_buf_set_option(overlay.bufnr, 'modifiable', true)
          vim.api.nvim_buf_set_lines(overlay.bufnr, 0, -1, false, {intersection.char})
          vim.api.nvim_buf_set_option(overlay.bufnr, 'modifiable', false)
          overlay.char = intersection.char
        end
        overlay.x = intersection.x
        overlay.y = intersection.y
      end
    else
      -- Create new overlay
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_option(buf, 'buftype', 'nofile')
      vim.api.nvim_buf_set_option(buf, 'bufhidden', 'wipe')
      vim.api.nvim_buf_set_option(buf, 'modifiable', true)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, {intersection.char})
      vim.api.nvim_buf_set_option(buf, 'modifiable', false)

      local win = vim.api.nvim_open_win(buf, false, {
        relative = "editor",
        width = 1,
        height = 1,
        row = intersection.y,
        col = intersection.x,
        style = "minimal",
        border = "none",
        focusable = false,
        zindex = UiFloat.ZINDEX.OVERLAY,
      })

      vim.api.nvim_set_option_value('winhighlight', 'Normal:NvimFloatBorder', { win = win })

      table.insert(state._junction_overlays, {bufnr = buf, winid = win, x = intersection.x, y = intersection.y, char = intersection.char})
    end
  end
end

return M
