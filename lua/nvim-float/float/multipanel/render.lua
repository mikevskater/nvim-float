---@module 'nvim-float.float.multipanel.render'
---@brief Panel rendering methods for MultiPanelWindow

local Diff = require("nvim-float.content.diff")

local M = {}

-- ============================================================================
-- Panel Rendering Methods
-- ============================================================================

---Normalize a highlight entry to named format
---@param hl table Highlight in array or named format
---@return table normalized { line, col_start, col_end, hl_group }
local function normalize_hl(hl)
  return {
    line = hl.line or hl[1],
    col_start = hl.col_start or hl[2],
    col_end = hl.col_end or hl[3],
    hl_group = hl.hl_group or hl[4],
  }
end

---Render a specific panel
---@param state MultiPanelState
---@param panel_name string Panel to render
---@param opts? { cursor_row?: number, cursor_col?: number, force?: boolean } Optional cursor position and force flag
function M.render_panel(state, panel_name, opts)
  if state._closed then return end

  local panel = state.panels[panel_name]
  if not panel or not panel.float:is_valid() then return end

  local def = panel.definition
  if not def.on_render then return end

  -- Call render callback
  local lines, highlights = def.on_render(state)
  lines = lines or {}
  highlights = highlights or {}

  -- Normalize all highlights to named format
  local norm_highlights = {}
  for i, hl in ipairs(highlights) do
    norm_highlights[i] = normalize_hl(hl)
  end

  -- Helper to apply all highlights (full render path)
  local function apply_all_highlights()
    vim.api.nvim_buf_clear_namespace(panel.float.bufnr, panel.namespace, 0, -1)
    for _, hl in ipairs(norm_highlights) do
      if hl.line and hl.col_start and hl.col_end and hl.hl_group then
        vim.api.nvim_buf_add_highlight(
          panel.float.bufnr, panel.namespace,
          hl.hl_group, hl.line, hl.col_start, hl.col_end
        )
      end
    end
  end

  -- Diff-based rendering: skip buffer updates when nothing changed
  local force = opts and opts.force
  local did_diff = false

  if panel._render_cache and not force then
    local diff = Diff.compute(panel._render_cache, lines, norm_highlights)

    if not diff.text_changed and #diff.hl_dirty_lines == 0 then
      -- Nothing changed — zero API calls
      did_diff = true
    elseif not diff.line_count_changed then
      -- Same line count: apply surgical diff
      local new_hl_by_line = Diff.index_highlights(norm_highlights)
      Diff.apply_diff(panel.float.bufnr, panel.namespace, diff, lines, new_hl_by_line)
      panel.float.lines = lines
      if panel.float.config.scrollbar then
        require("nvim-float.float.scrollbar").update(panel.float)
      end
      did_diff = true
    end
    -- Line count changed: fall through to full render

    -- Update cache
    panel._render_cache = Diff.create_cache(lines, norm_highlights)
  end

  if not did_diff then
    -- Full render path
    panel.float:update_lines(lines)
    apply_all_highlights()
    panel._render_cache = Diff.create_cache(lines, norm_highlights)
  end

  -- Recreate embedded containers from stored ContentBuilder
  -- Skip container rebuild when diff found no text changes (pure cursor move)
  local cb = panel.float._content_builder
  local has_containers = cb and cb.get_containers and cb:get_containers()
  local has_old_vcm = panel.float._virtual_manager ~= nil
  local skip_container_rebuild = did_diff and not force

  if not skip_container_rebuild and (has_containers or has_old_vcm) then
    local fw = panel.float

    -- Save and restore focused window to avoid stealing focus during render
    local prev_win = vim.api.nvim_get_current_win()

    -- 1. Snapshot: capture VCM active state before teardown
    local scroll_snapshot = nil
    local was_active_name = nil
    local was_active_cursor = nil
    local was_active_mode = nil

    if fw._virtual_manager then
      scroll_snapshot = fw._virtual_manager:snapshot_scroll_state()

      if fw._virtual_manager._active_name then
        was_active_name = fw._virtual_manager._active_name
        was_active_mode = vim.fn.mode()
        local active_vc = fw._virtual_manager:get_active()
        if active_vc and active_vc._materialized then
          local active_container = active_vc:get_container()
          if active_container and active_container:is_valid() then
            was_active_cursor = vim.api.nvim_win_get_cursor(active_container.winid)
          end
        end
      end
    end

    -- 2. Teardown: close all managers cleanly
    require("nvim-float.container.scroll_sync").teardown(fw)

    if fw:is_valid() then
      pcall(vim.api.nvim_set_current_win, fw.winid)
    end

    if fw._virtual_manager then
      fw._virtual_manager:close_all()
      fw._virtual_manager = nil
    end
    if fw._container_manager then
      fw._container_manager:close_all()
    end
    if fw._embedded_input_manager then
      fw._embedded_input_manager:close_all()
    end
    fw._navigation_regions = nil

    -- 3. Recreate containers only if new CB has containers
    if has_containers then
      fw:_create_containers_from_builder(cb, true)

      -- 4. Restore scroll state
      if scroll_snapshot and fw._virtual_manager then
        fw._virtual_manager:restore_scroll_state(scroll_snapshot)
      end

      -- 5. Suppress virtual render for the container that will be re-activated
      if was_active_name and fw._virtual_manager then
        local pending_vc = fw._virtual_manager:get(was_active_name)
        if pending_vc then
          pending_vc._suppress_content = true
        end
      end

      -- 6. Render all virtual containers
      if fw._virtual_manager then
        fw._virtual_manager:render_all_virtual(true)
      end

      -- 7. Re-setup scroll sync
      require("nvim-float.container.scroll_sync").setup(fw)

      -- 8. Re-activate previously active container and restore cursor + mode
      if was_active_name and fw._virtual_manager then
        local vc = fw._virtual_manager:get(was_active_name)
        if vc then
          vc._suppress_content = false
          fw._virtual_manager:activate(was_active_name)

          if was_active_cursor then
            local active = fw._virtual_manager:get_active()
            local active_container = active and active:get_container()
            if active_container and active_container:is_valid() then
              local max_lines = vim.api.nvim_buf_line_count(active_container.bufnr)
              local row = math.min(was_active_cursor[1], max_lines)
              pcall(vim.api.nvim_win_set_cursor, active_container.winid,
                { row, was_active_cursor[2] })
            end
          end

          if was_active_mode == 'i' or was_active_mode == 'R' then
            local active = fw._virtual_manager:get_active()
            if active and active.type == "embedded_input" then
              local real_field = active:get_real_field()
              if real_field then
                real_field:enter_edit()
              end
            end
          end
        end
      end

      -- 9. Safety: clear _suppress_content on ALL containers
      if fw._virtual_manager then
        for _, vc in pairs(fw._virtual_manager._virtuals) do
          if vc._suppress_content then
            vc._suppress_content = false
            if not vc._materialized then
              vc:render_virtual()
            end
          end
        end
      end
    end

    -- Restore focus to previously focused window
    if prev_win and vim.api.nvim_win_is_valid(prev_win) then
      pcall(vim.api.nvim_set_current_win, prev_win)
    end
  end

  -- Set cursor position if specified
  if opts and opts.cursor_row then
    panel.float:set_cursor(opts.cursor_row, opts.cursor_col or 0)
  end
end

---Render all panels
---@param state MultiPanelState
function M.render_all(state)
  for name, _ in pairs(state.panels) do
    M.render_panel(state, name)
  end
end

---Update panel title
---@param state MultiPanelState
---@param panel_name string Panel name
---@param title string New title
function M.update_panel_title(state, panel_name, title)
  if state._closed then return end

  local panel = state.panels[panel_name]
  if not panel or not panel.float:is_valid() then
    return
  end

  vim.api.nvim_win_set_config(panel.float.winid, {
    title = string.format(" %s ", title),
    title_pos = "center",
  })
end

---Update panel footer
---@param state MultiPanelState
---@param panel_name string Panel name
---@param footer string New footer text
---@param footer_pos? "left"|"center"|"right" Footer position (default: "center")
function M.update_panel_footer(state, panel_name, footer, footer_pos)
  if state._closed then return end

  local panel = state.panels[panel_name]
  if not panel or not panel.float:is_valid() then
    return
  end

  vim.api.nvim_win_set_config(panel.float.winid, {
    footer = string.format(" %s ", footer),
    footer_pos = footer_pos or "center",
  })
end

return M
