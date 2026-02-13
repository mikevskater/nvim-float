---@module 'nvim-float.float.multipanel.render'
---@brief Panel rendering methods for MultiPanelWindow

local M = {}

-- ============================================================================
-- Panel Rendering Methods
-- ============================================================================

---Render a specific panel
---@param state MultiPanelState
---@param panel_name string Panel to render
---@param opts? { cursor_row?: number, cursor_col?: number } Optional cursor position to set after rendering completes
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

  -- Helper to apply all highlights
  local function apply_all_highlights()
    vim.api.nvim_buf_clear_namespace(panel.float.bufnr, panel.namespace, 0, -1)
    for _, hl in ipairs(highlights) do
      -- Support both array format {line, col_start, col_end, hl_group}
      -- and named format {line=, col_start=, col_end=, hl_group=} from ContentBuilder
      local line = hl.line or hl[1]
      local col_start = hl.col_start or hl[2]
      local col_end = hl.col_end or hl[3]
      local hl_group = hl.hl_group or hl[4]

      if line and col_start and col_end and hl_group then
        vim.api.nvim_buf_add_highlight(
          panel.float.bufnr, panel.namespace,
          hl_group, line, col_start, col_end
        )
      end
    end
  end

  -- Always use synchronous single-pass rendering (simpler and more reliable)
  panel.float:update_lines(lines)
  apply_all_highlights()

  -- Recreate embedded containers from stored ContentBuilder
  local cb = panel.float._content_builder
  if cb and cb.get_containers and cb:get_containers() then
    if panel.float._container_manager then
      panel.float._container_manager:close_all()
    end
    if panel.float._embedded_input_manager then
      panel.float._embedded_input_manager:close_all()
    end
    panel.float._navigation_regions = nil
    panel.float:_create_containers_from_builder(cb)
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
