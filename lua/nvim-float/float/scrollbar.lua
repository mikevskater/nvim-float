---@class Scrollbar
---Scrollbar support for FloatWindow
---Provides visual scroll indicators with themed styling
---@module nvim-float.float.scrollbar
local Scrollbar = {}

---Scrollbar characters
local CHARS = {
  UP_ARROW = "^",
  DOWN_ARROW = "v",
  THUMB = "#",
  TRACK = "|",
}

-- Highlight namespace for scrollbar
local NS_NAME = "nvim_float_scrollbar"

---Setup the scrollbar overlay window
---@param float FloatWindow The parent FloatWindow instance
function Scrollbar.setup(float)
  if not float:is_valid() then return end

  local total_lines = #float.lines
  local win_height = float._win_height

  -- Guard against nil win_height
  if not win_height or win_height <= 0 then
    return
  end

  -- Only show scrollbar if content exceeds window height
  if total_lines <= win_height then
    return
  end

  -- Don't create duplicate scrollbar
  if float._scrollbar_winid and vim.api.nvim_win_is_valid(float._scrollbar_winid) then
    -- Just update existing scrollbar
    return
  end

  -- Create scrollbar buffer (keep modifiable to avoid toggling during updates)
  float._scrollbar_bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value('buftype', 'nofile', { buf = float._scrollbar_bufnr })
  vim.api.nvim_set_option_value('bufhidden', 'wipe', { buf = float._scrollbar_bufnr })
  vim.api.nvim_set_option_value('swapfile', false, { buf = float._scrollbar_bufnr })
  vim.api.nvim_set_option_value('modifiable', true, { buf = float._scrollbar_bufnr })

  -- Calculate scrollbar position
  -- For editor-relative floats, the window row/col is where content starts
  -- Border is drawn around it visually but doesn't change the row/col values
  -- We want scrollbar at the rightmost column of the visible content area
  -- Add +1 to row to account for the top border
  local scrollbar_row = float._win_row + 1
  local scrollbar_col = float._win_col + float._win_width - 1  -- Last column of content area

  -- Create scrollbar window
  float._scrollbar_winid = vim.api.nvim_open_win(float._scrollbar_bufnr, false, {
    relative = "editor",
    width = 1,
    height = win_height,
    row = scrollbar_row,
    col = scrollbar_col,
    style = "minimal",
    focusable = false,
    zindex = (float.config.zindex or 50) + 1,  -- Above main window
  })

  -- Set scrollbar window options with themed highlight
  -- Links to NvimFloatScrollbar which derives from the theme's border/title colors
  vim.api.nvim_set_option_value('winblend', float.config.winblend or 0, { win = float._scrollbar_winid })
  vim.api.nvim_set_option_value('winhighlight', 'Normal:NvimFloatScrollbar,NormalFloat:NvimFloatScrollbar', { win = float._scrollbar_winid })

  -- Initial scrollbar render
  Scrollbar.update(float)

  -- Setup autocmd to track scrolling in main window
  float._scrollbar_autocmd = vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI", "WinScrolled" }, {
    buffer = float.bufnr,
    callback = function()
      if float:is_valid() then
        Scrollbar.update(float)
      end
    end,
  })
end

---Update the scrollbar display based on current scroll position
---@param float FloatWindow The parent FloatWindow instance
function Scrollbar.update(float)
  -- Guard against nil geometry (shouldn't happen but be safe)
  if not float._win_height or not float._win_width then
    return
  end

  local total_lines = #float.lines
  local win_height = float._win_height

  -- Don't show scrollbar if content fits
  if total_lines <= win_height then
    Scrollbar.close(float)
    return
  end

  -- Create scrollbar if it doesn't exist but should (content now exceeds window height)
  if not float._scrollbar_winid or not vim.api.nvim_win_is_valid(float._scrollbar_winid) then
    -- setup will call update at the end for rendering
    Scrollbar.setup(float)
    return
  end

  -- Get current scroll position
  local win_info = vim.fn.getwininfo(float.winid)[1]
  local top_line = win_info and win_info.topline or 1
  local bot_line = math.min(top_line + win_height - 1, total_lines)

  -- Skip update if scroll position hasn't changed (avoids unnecessary redraws)
  if float._scrollbar_last_top == top_line and float._scrollbar_last_total == total_lines then
    return
  end
  float._scrollbar_last_top = top_line
  float._scrollbar_last_total = total_lines

  -- Build scrollbar content
  local scrollbar_lines = {}
  local track_height = win_height

  -- Determine if we can scroll up/down
  local can_scroll_up = top_line > 1
  local can_scroll_down = bot_line < total_lines

  -- Calculate thumb position and size within the track area (excluding arrow rows)
  -- Arrows are at row 1 and row track_height, so thumb lives in rows 2 to track_height-1
  local thumb_track_height = track_height - 2  -- Exclude top and bottom arrow rows

  if thumb_track_height < 1 then
    -- Window too small for thumb track, just show arrows
    for i = 1, track_height do
      if i == 1 then
        table.insert(scrollbar_lines, CHARS.UP_ARROW)
      elseif i == track_height then
        table.insert(scrollbar_lines, CHARS.DOWN_ARROW)
      else
        table.insert(scrollbar_lines, CHARS.TRACK)
      end
    end
  else
    -- Calculate thumb size and position within the middle track
    local visible_ratio = win_height / total_lines
    local thumb_size = math.max(1, math.floor(thumb_track_height * visible_ratio))
    thumb_size = math.min(thumb_size, thumb_track_height)  -- Don't exceed track

    -- Calculate scroll position (0 to 1)
    local max_scroll = total_lines - win_height
    local scroll_ratio = max_scroll > 0 and (top_line - 1) / max_scroll or 0

    -- Calculate thumb start position within track (0-indexed within thumb_track)
    local thumb_start = math.floor(scroll_ratio * (thumb_track_height - thumb_size))
    thumb_start = math.max(0, math.min(thumb_start, thumb_track_height - thumb_size))

    for i = 1, track_height do
      local char
      if i == 1 then
        -- Top row - always show up arrow
        char = CHARS.UP_ARROW
      elseif i == track_height then
        -- Bottom row - always show down arrow
        char = CHARS.DOWN_ARROW
      else
        -- Middle rows (track area) - rows 2 to track_height-1
        -- Convert to 0-indexed position within thumb track
        local track_pos = i - 2  -- Row 2 becomes pos 0, row 3 becomes pos 1, etc.
        if track_pos >= thumb_start and track_pos < thumb_start + thumb_size then
          char = CHARS.THUMB
        else
          char = CHARS.TRACK
        end
      end
      table.insert(scrollbar_lines, char)
    end
  end

  -- Check if scrollbar content actually changed (avoid unnecessary updates)
  local new_content = table.concat(scrollbar_lines, "\n")
  if float._scrollbar_last_content == new_content then
    return
  end
  float._scrollbar_last_content = new_content

  -- Update scrollbar buffer (buffer is always modifiable - set in setup)
  vim.api.nvim_buf_set_lines(float._scrollbar_bufnr, 0, -1, false, scrollbar_lines)

  -- Apply themed highlights
  local ns_id = vim.api.nvim_create_namespace(NS_NAME)
  vim.api.nvim_buf_clear_namespace(float._scrollbar_bufnr, ns_id, 0, -1)

  for i, char in ipairs(scrollbar_lines) do
    local hl_group
    if char == CHARS.UP_ARROW or char == CHARS.DOWN_ARROW then
      hl_group = "NvimFloatScrollbarArrow"
    elseif char == CHARS.THUMB then
      hl_group = "NvimFloatScrollbarThumb"
    else
      hl_group = "NvimFloatScrollbarTrack"
    end
    vim.api.nvim_buf_add_highlight(float._scrollbar_bufnr, ns_id, hl_group, i - 1, 0, -1)
  end
end

---Close the scrollbar window
---@param float FloatWindow The parent FloatWindow instance
function Scrollbar.close(float)
  -- Remove autocmd
  if float._scrollbar_autocmd then
    pcall(vim.api.nvim_del_autocmd, float._scrollbar_autocmd)
    float._scrollbar_autocmd = nil
  end

  -- Close scrollbar window
  if float._scrollbar_winid and vim.api.nvim_win_is_valid(float._scrollbar_winid) then
    vim.api.nvim_win_close(float._scrollbar_winid, true)
  end
  float._scrollbar_winid = nil

  -- Delete scrollbar buffer
  if float._scrollbar_bufnr and vim.api.nvim_buf_is_valid(float._scrollbar_bufnr) then
    vim.api.nvim_buf_delete(float._scrollbar_bufnr, { force = true })
  end
  float._scrollbar_bufnr = nil

  -- Reset tracking state for next instance
  float._scrollbar_last_top = nil
  float._scrollbar_last_total = nil
  float._scrollbar_last_content = nil
end

---Reposition scrollbar after window geometry changes (e.g., on resize)
---@param float FloatWindow The parent FloatWindow instance
function Scrollbar.reposition(float)
  if not float._scrollbar_winid or not vim.api.nvim_win_is_valid(float._scrollbar_winid) then
    -- No scrollbar to reposition, try to set one up if needed
    if float.config.scrollbar then
      Scrollbar.setup(float)
    end
    return
  end

  -- Calculate new scrollbar position based on updated window geometry
  local scrollbar_row = float._win_row + 1
  local scrollbar_col = float._win_col + float._win_width - 1

  -- Update scrollbar window position and height
  vim.api.nvim_win_set_config(float._scrollbar_winid, {
    relative = "editor",
    width = 1,
    height = float._win_height,
    row = scrollbar_row,
    col = scrollbar_col,
  })

  -- Update scrollbar content for new dimensions
  Scrollbar.update(float)
end

return Scrollbar
