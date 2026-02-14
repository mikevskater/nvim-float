---@module 'nvim-float.container.scroll_sync'
---@brief Synchronize embedded container positions with parent scroll state
---
---When the parent FloatWindow scrolls, child windows (relative='win') stay at
---fixed viewport offsets while content moves underneath. This module listens
---for WinScrolled on the parent and repositions/clips/hides containers so they
---track their associated buffer rows.

local M = {}

-- ============================================================================
-- Border Helpers
-- ============================================================================

-- Named border presets → 8-element character tables
-- Index: 1=top-left, 2=top, 3=top-right, 4=right, 5=bottom-right, 6=bottom, 7=bottom-left, 8=left
local BORDER_CHARS = {
  single  = { "┌", "─", "┐", "│", "┘", "─", "└", "│" },
  double  = { "╔", "═", "╗", "║", "╝", "═", "╚", "║" },
  rounded = { "╭", "─", "╮", "│", "╯", "─", "╰", "│" },
  solid   = { "█", "█", "█", "█", "█", "█", "█", "█" },
}

---Convert a border spec (string or table) to a normalized 8-element table.
---Returns nil for "none"/nil/unknown borders that can't be dynamically clipped.
---@param border string|table|nil
---@return table|nil
local function border_to_table(border)
  if not border or border == "none" or border == "" then
    return nil
  end
  if type(border) == "table" then
    local n = #border
    if n == 0 then return nil end
    local result = {}
    for i = 1, 8 do
      local elem = border[((i - 1) % n) + 1]
      if type(elem) == "table" then
        result[i] = { elem[1], elem[2] }
      else
        result[i] = elem
      end
    end
    return result
  end
  local chars = BORDER_CHARS[border]
  if chars then
    local result = {}
    for i = 1, 8 do result[i] = chars[i] end
    return result
  end
  return nil
end

M.border_to_table = border_to_table

-- ============================================================================
-- Sync Logic
-- ============================================================================

---Sync a single bordered container using 5 independent windows.
---@param c EmbeddedContainer
---@param scroll_row number Parent topline (0-indexed)
---@param scroll_col number Parent leftcol
---@param parent_h number Parent window height
---@param parent_w number Parent window width
---@return boolean was_focused True if this container was focused before being hidden
local function sync_bordered(c, scroll_row, scroll_col, parent_h, parent_w)
  local buf_row = c._buffer_row
  local buf_col = c._buffer_col
  local orig_h = c._original_height
  local orig_w = c._original_width
  local bt = c._border_top
  local bb = c._border_bottom
  local bl = c._border_left
  local br = c._border_right
  local visual_h = orig_h + bt + bb
  local visual_w = orig_w + bl + br

  local was_hidden = c._hidden
  local was_focused = c._focused

  -- Lazy-init border windows on first sync
  if not c._border_windows_initialized then
    c:_setup_border_windows()
  end

  -- Fully outside viewport → hide everything
  local vp_row = buf_row - scroll_row
  local vp_col = buf_col - scroll_col
  if vp_row >= parent_h or (vp_row + visual_h) <= 0
    or vp_col >= parent_w or (vp_col + visual_w) <= 0 then
    c:hide()
    return was_focused and not was_hidden
  end

  -- Viewport positions for each component
  local vp_top_row = vp_row                         -- top border
  local vp_content_row = vp_row + bt                -- content + left/right borders
  local vp_bottom_row = vp_row + bt + orig_h        -- bottom border
  local vp_left_col = vp_col                        -- left border
  local vp_content_col = vp_col + bl                -- content
  local vp_right_col = vp_col + bl + orig_w         -- right border

  local any_visible = false

  -- ── TOP BORDER (1 row) ─────────────────────────────────────────────
  if bt > 0 and vp_top_row >= 0 and vp_top_row < parent_h then
    local h_clip_left = math.max(0, -vp_left_col)
    local h_clip_right = math.max(0, (vp_left_col + visual_w) - parent_w)
    local include_lc = (h_clip_left == 0)
    local include_rc = (h_clip_right == 0)
    local visible_col = math.max(0, vp_left_col + h_clip_left)
    local visible_w_chars = visual_w - h_clip_left - h_clip_right
    if visible_w_chars >= 1 then
      -- Compute inner fill width: subtract corner chars that are included
      local fill_w = visible_w_chars
      if include_lc then fill_w = fill_w - bl end
      if include_rc then fill_w = fill_w - br end
      if fill_w < 0 then fill_w = 0 end
      c:reposition_border_top(vp_top_row, visible_col, fill_w, include_lc, include_rc)
      c:show_border_top()
      any_visible = true
    else
      c:hide_border_top()
    end
  else
    c:hide_border_top()
  end

  -- ── BOTTOM BORDER (1 row) ──────────────────────────────────────────
  if bb > 0 and vp_bottom_row >= 0 and vp_bottom_row < parent_h then
    local h_clip_left = math.max(0, -vp_left_col)
    local h_clip_right = math.max(0, (vp_left_col + visual_w) - parent_w)
    local include_lc = (h_clip_left == 0)
    local include_rc = (h_clip_right == 0)
    local visible_col = math.max(0, vp_left_col + h_clip_left)
    local visible_w_chars = visual_w - h_clip_left - h_clip_right
    if visible_w_chars >= 1 then
      local fill_w = visible_w_chars
      if include_lc then fill_w = fill_w - bl end
      if include_rc then fill_w = fill_w - br end
      if fill_w < 0 then fill_w = 0 end
      c:reposition_border_bottom(vp_bottom_row, visible_col, fill_w, include_lc, include_rc)
      c:show_border_bottom()
      any_visible = true
    else
      c:hide_border_bottom()
    end
  else
    c:hide_border_bottom()
  end

  -- ── LEFT BORDER (orig_h rows × 1 col) ─────────────────────────────
  if bl > 0 and vp_left_col >= 0 and vp_left_col < parent_w then
    local v_clip_top = math.max(0, -vp_content_row)
    local v_clip_bottom = math.max(0, (vp_content_row + orig_h) - parent_h)
    local visible_h = orig_h - v_clip_top - v_clip_bottom
    local visible_row = math.max(0, vp_content_row + v_clip_top)
    if visible_h >= 1 then
      c:reposition_border_left(visible_row, vp_left_col, visible_h)
      c:show_border_left()
      any_visible = true
    else
      c:hide_border_left()
    end
  else
    c:hide_border_left()
  end

  -- ── RIGHT BORDER (orig_h rows × 1 col) ────────────────────────────
  if br > 0 and vp_right_col >= 0 and vp_right_col < parent_w then
    local v_clip_top = math.max(0, -vp_content_row)
    local v_clip_bottom = math.max(0, (vp_content_row + orig_h) - parent_h)
    local visible_h = orig_h - v_clip_top - v_clip_bottom
    local visible_row = math.max(0, vp_content_row + v_clip_top)
    if visible_h >= 1 then
      c:reposition_border_right(visible_row, vp_right_col, visible_h)
      c:show_border_right()
      any_visible = true
    else
      c:hide_border_right()
    end
  else
    c:hide_border_right()
  end

  -- ── CONTENT (orig_h × orig_w, borderless) ─────────────────────────
  local content_clip_top = math.max(0, -vp_content_row)
  local content_clip_bottom = math.max(0, (vp_content_row + orig_h) - parent_h)
  local content_clip_left = math.max(0, -vp_content_col)
  local content_clip_right = math.max(0, (vp_content_col + orig_w) - parent_w)
  local new_h = orig_h - content_clip_top - content_clip_bottom
  local new_w = orig_w - content_clip_left - content_clip_right

  if new_h >= 1 and new_w >= 1 then
    local final_row = math.max(0, vp_content_row + content_clip_top)
    local final_col = math.max(0, vp_content_col + content_clip_left)

    -- Save scroll state BEFORE update_region (which may reset it)
    local saved_topline = vim.fn.line('w0', c.winid)
    local saved_leftcol = 0
    pcall(function()
      saved_leftcol = vim.api.nvim_win_call(c.winid, function()
        return vim.fn.winsaveview().leftcol or 0
      end)
    end)

    c:update_region(final_row, final_col, new_w, new_h)
    if c._content_hidden then c:show_content() end
    any_visible = true

    -- Restore vertical scroll, adjusted for clip change
    local v_delta = content_clip_top - (c._last_clip_top or 0)
    local target_topline = math.max(1, saved_topline + v_delta)
    -- Clamp so content fills the window (no gap at bottom)
    local total_lines = vim.api.nvim_buf_line_count(c.bufnr)
    if total_lines > new_h then
      target_topline = math.min(target_topline, total_lines - new_h + 1)
    end
    c._last_clip_top = content_clip_top
    c._last_clip_bottom = content_clip_bottom
    pcall(vim.api.nvim_win_call, c.winid, function()
      vim.cmd("normal! " .. target_topline .. "zt")
    end)

    -- Restore horizontal scroll, adjusted for clip change
    local h_delta = content_clip_left - (c._last_clip_left or 0)
    local target_leftcol = math.max(0, saved_leftcol + h_delta)
    c._last_clip_left = content_clip_left
    c._last_clip_right = content_clip_right
    pcall(vim.api.nvim_win_call, c.winid, function()
      vim.fn.winrestview({ leftcol = target_leftcol })
    end)
  else
    c:hide_content()
  end

  -- Update overall hidden state
  c._hidden = not any_visible
  if was_hidden and any_visible then
    -- Went from fully hidden to partially visible - no need for full show()
    -- Individual components already shown above
  end

  return was_focused and not was_hidden and c._hidden
end

---Sync a single borderless container against the parent's scroll state.
---@param c EmbeddedContainer
---@param scroll_row number Parent topline (0-indexed)
---@param scroll_col number Parent leftcol
---@param parent_h number Parent window height
---@param parent_w number Parent window width
---@return boolean was_focused True if this container was focused before being hidden
local function sync_borderless(c, scroll_row, scroll_col, parent_h, parent_w)
  local buf_row = c._buffer_row
  local buf_col = c._buffer_col
  local orig_h = c._original_height
  local orig_w = c._original_width

  local vp_row = buf_row - scroll_row
  local vp_col = buf_col - scroll_col

  local was_hidden = c._hidden
  local was_focused = c._focused

  -- Fully outside viewport
  if vp_row >= parent_h or (vp_row + orig_h) <= 0
    or vp_col >= parent_w or (vp_col + orig_w) <= 0 then
    c:hide()
    return was_focused and not was_hidden
  end

  local clip_top = math.max(0, -vp_row)
  local clip_bottom = math.max(0, (vp_row + orig_h) - parent_h)
  local clip_left = math.max(0, -vp_col)
  local clip_right = math.max(0, (vp_col + orig_w) - parent_w)

  local new_h = orig_h - clip_top - clip_bottom
  local new_w = orig_w - clip_left - clip_right

  if new_h < 1 or new_w < 1 then
    c:hide()
    return was_focused and not was_hidden
  end

  local final_row = math.max(0, vp_row)
  local final_col = math.max(0, vp_col)

  -- Save scroll state BEFORE update_region (which may reset it)
  local saved_topline = vim.fn.line('w0', c.winid)
  local saved_leftcol = 0
  pcall(function()
    saved_leftcol = vim.api.nvim_win_call(c.winid, function()
      return vim.fn.winsaveview().leftcol or 0
    end)
  end)

  c:update_region(final_row, final_col, new_w, new_h)

  if was_hidden then c:show() end

  -- Restore vertical scroll, adjusted for clip change
  local v_delta = clip_top - (c._last_clip_top or 0)
  local target_topline = math.max(1, saved_topline + v_delta)
  -- Clamp so content fills the window (no gap at bottom)
  local total_lines = vim.api.nvim_buf_line_count(c.bufnr)
  if total_lines > new_h then
    target_topline = math.min(target_topline, total_lines - new_h + 1)
  end
  c._last_clip_top = clip_top
  c._last_clip_bottom = clip_bottom
  pcall(vim.api.nvim_win_call, c.winid, function()
    vim.cmd("normal! " .. target_topline .. "zt")
  end)

  -- Restore horizontal scroll, adjusted for clip change
  local h_delta = clip_left - (c._last_clip_left or 0)
  local target_leftcol = math.max(0, saved_leftcol + h_delta)
  c._last_clip_left = clip_left
  c._last_clip_right = clip_right
  pcall(vim.api.nvim_win_call, c.winid, function()
    vim.fn.winrestview({ leftcol = target_leftcol })
  end)

  return false
end

---Sync a single EmbeddedContainer against the parent's scroll state.
---Dispatches to bordered or borderless sync logic.
---@param c EmbeddedContainer
---@param scroll_row number Parent topline (0-indexed: topline - 1)
---@param scroll_col number Parent leftcol
---@param parent_h number Parent window height
---@param parent_w number Parent window width
---@return boolean was_focused True if this container was focused before being hidden
local function sync_one(c, scroll_row, scroll_col, parent_h, parent_w)
  if not c:is_valid() then return false end

  local has_border = (c._border_top + c._border_bottom + c._border_left + c._border_right) > 0
  if has_border then
    return sync_bordered(c, scroll_row, scroll_col, parent_h, parent_w)
  else
    return sync_borderless(c, scroll_row, scroll_col, parent_h, parent_w)
  end
end

-- ============================================================================
-- Core Sync
-- ============================================================================

---Run a full sync pass over all containers in a FloatWindow.
---@param fw FloatWindow
function M.sync(fw)
  if not fw:is_valid() then return end
  if fw._scroll_syncing then return end
  fw._scroll_syncing = true

  -- Get parent scroll state
  local topline = vim.fn.line("w0", fw.winid)
  local scroll_row = topline - 1  -- 0-indexed
  local scroll_col = vim.fn.winsaveview and 0 or 0
  pcall(function()
    local view = vim.api.nvim_win_call(fw.winid, function()
      return vim.fn.winsaveview()
    end)
    scroll_col = view.leftcol or 0
  end)

  -- Check cache: skip if nothing changed
  local cache = fw._scroll_sync_cache
  if cache and cache.topline == scroll_row and cache.leftcol == scroll_col then
    fw._scroll_syncing = false
    return
  end
  if cache then
    cache.topline = scroll_row
    cache.leftcol = scroll_col
  end

  local parent_h = fw._win_height
  local parent_w = fw._win_width
  local any_focus_lost = false

  -- Sync generic containers (ContainerManager)
  if fw._container_manager then
    local names = fw._container_manager:get_names()
    for _, name in ipairs(names) do
      local c = fw._container_manager:get(name)
      if c then
        local lost = sync_one(c, scroll_row, scroll_col, parent_h, parent_w)
        if lost then any_focus_lost = true end
      end
    end
  end

  -- Sync embedded input-type containers (EmbeddedInputManager)
  if fw._embedded_input_manager then
    fw._embedded_input_manager:for_each_field(function(_key, field, _type)
      local c = field:get_container()
      if c then
        -- Check if this field was focused
        local field_focused = (fw._embedded_input_manager._focused_key == _key)
        local lost = sync_one(c, scroll_row, scroll_col, parent_h, parent_w)
        if lost or (field_focused and c:is_hidden()) then
          any_focus_lost = true
          -- Exit edit mode for inputs before losing focus
          if field.exit_edit then
            pcall(field.exit_edit, field)
          end
        end
      end
    end)
  end

  -- If a focused container was hidden, return focus to parent
  if any_focus_lost and fw:is_valid() then
    -- Clear focus tracking
    if fw._container_manager then
      fw._container_manager._focused_name = nil
    end
    if fw._embedded_input_manager then
      fw._embedded_input_manager._focused_key = nil
      fw._embedded_input_manager._current_field_idx = 0
    end
    pcall(vim.api.nvim_set_current_win, fw.winid)
  end

  fw._scroll_syncing = false
end

-- ============================================================================
-- Setup / Teardown
-- ============================================================================

---Attach scroll-sync to a FloatWindow. Creates a WinScrolled autocmd.
---@param fw FloatWindow
function M.setup(fw)
  if not fw:is_valid() then return end
  if fw._scroll_sync_augroup then return end

  fw._scroll_sync_augroup = vim.api.nvim_create_augroup(
    "nvim_float_scroll_sync_" .. fw.bufnr, { clear = true })
  fw._scroll_sync_cache = { topline = nil, leftcol = nil }
  fw._scroll_syncing = false

  vim.api.nvim_create_autocmd("WinScrolled", {
    group = fw._scroll_sync_augroup,
    buffer = fw.bufnr,
    callback = function()
      if fw:is_valid() and not fw._scroll_syncing then
        M.sync(fw)
      end
    end,
  })

  -- Initial sync (parent may already be scrolled)
  M.sync(fw)
end

---Detach scroll-sync from a FloatWindow.
---@param fw FloatWindow
function M.teardown(fw)
  if fw._scroll_sync_augroup then
    pcall(vim.api.nvim_del_augroup_by_id, fw._scroll_sync_augroup)
    fw._scroll_sync_augroup = nil
  end
  fw._scroll_sync_cache = nil
  fw._scroll_syncing = nil
end

return M
