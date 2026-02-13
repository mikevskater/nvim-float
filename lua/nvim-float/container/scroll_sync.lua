---@module 'nvim-float.container.scroll_sync'
---@brief Synchronize embedded container positions with parent scroll state
---
---When the parent FloatWindow scrolls, child windows (relative='win') stay at
---fixed viewport offsets while content moves underneath. This module listens
---for WinScrolled on the parent and repositions/clips/hides containers so they
---track their associated buffer rows.

local M = {}

-- ============================================================================
-- Helpers
-- ============================================================================

---Sync a single EmbeddedContainer against the parent's scroll state.
---@param c EmbeddedContainer
---@param scroll_row number Parent topline (0-indexed: topline - 1)
---@param scroll_col number Parent leftcol
---@param parent_h number Parent window height
---@param parent_w number Parent window width
---@return boolean was_focused True if this container was focused before being hidden
local function sync_one(c, scroll_row, scroll_col, parent_h, parent_w)
  if not c:is_valid() then return false end

  local buf_row = c._buffer_row
  local buf_col = c._buffer_col
  local orig_h = c._original_height
  local orig_w = c._original_width
  local bt = c._border_top
  local bb = c._border_bottom
  local bl = c._border_left
  local br = c._border_right

  -- Viewport-relative position
  local vp_row = buf_row - scroll_row
  local vp_col = buf_col - scroll_col

  -- Total visual footprint including borders
  local visual_h = orig_h + bt + bb
  local visual_w = orig_w + bl + br
  local has_border = (bt + bb + bl + br) > 0

  local was_hidden = c._hidden
  local was_focused = c._focused

  -- Fully outside viewport → hide
  if vp_row >= parent_h or (vp_row + visual_h) <= 0
    or vp_col >= parent_w or (vp_col + visual_w) <= 0 then
    c:hide()
    return was_focused and not was_hidden
  end

  -- Clipping amounts
  local clip_top = math.max(0, -vp_row)
  local clip_left = math.max(0, -vp_col)
  local clip_bottom = math.max(0, (vp_row + visual_h) - parent_h)
  local clip_right = math.max(0, (vp_col + visual_w) - parent_w)

  -- Bordered containers: hide if any top/left clipping (can't slice through border)
  if has_border and (clip_top > 0 or clip_left > 0) then
    c:hide()
    return was_focused and not was_hidden
  end

  -- New content dimensions after clipping
  local new_h = orig_h - clip_top - clip_bottom
  local new_w = orig_w - clip_left - clip_right

  if new_h < 1 or new_w < 1 then
    c:hide()
    return was_focused and not was_hidden
  end

  -- Final viewport position
  local final_row = math.max(0, vp_row)
  local final_col = math.max(0, vp_col)

  -- Apply position and size
  c:update_region(final_row, final_col, new_w, new_h)

  -- Show if was hidden
  if was_hidden then
    c:show()
  end

  -- Adjust internal scroll for top-clipped borderless containers
  if clip_top > 0 and not has_border and orig_h > 1 then
    if c._last_clip_top ~= clip_top then
      c._last_clip_top = clip_top
      -- Set the container's topline so clipped rows scroll out of view
      pcall(vim.api.nvim_win_call, c.winid, function()
        vim.cmd("normal! " .. (clip_top + 1) .. "zt")
      end)
    end
  elseif c._last_clip_top > 0 then
    -- Restore: no longer clipped at top
    c._last_clip_top = 0
    pcall(vim.api.nvim_win_call, c.winid, function()
      vim.cmd("normal! 1zt")
    end)
  end

  return false
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
