---@module 'nvim-float.float.multipanel.focus'
---@brief Panel focus management for MultiPanelWindow

local M = {}

-- ============================================================================
-- Panel Focus Methods
-- ============================================================================

---Focus a specific panel
---@param state MultiPanelState
---@param panel_name string Panel to focus
function M.focus_panel(state, panel_name)
  if state._closed then return end

  local panel = state.panels[panel_name]
  if not panel or panel.definition.focusable == false then
    return
  end

  -- Call blur on current panel
  local current_panel = state.panels[state.focused_panel]
  if current_panel and current_panel.definition.name ~= panel_name then
    -- Disable cursorline on previous panel
    if current_panel.float:is_valid() then
      vim.api.nvim_set_option_value('cursorline', false, { win = current_panel.float.winid })
    end
    if current_panel.definition.on_blur then
      current_panel.definition.on_blur(state)
    end
  end

  -- Update focused panel
  state.focused_panel = panel_name

  -- Focus the window and enable cursorline
  if panel.float:is_valid() then
    vim.api.nvim_set_current_win(panel.float.winid)
    if panel.definition.cursorline ~= false then
      vim.api.nvim_set_option_value('cursorline', true, { win = panel.float.winid })
    end
  end

  -- Call focus callback
  if panel.definition.on_focus then
    panel.definition.on_focus(state)
  end
end

---Focus next panel in order
---@param state MultiPanelState
function M.focus_next_panel(state)
  if state._closed then return end

  local current_idx = 1
  for i, name in ipairs(state.panel_order) do
    if name == state.focused_panel then
      current_idx = i
      break
    end
  end

  -- Find next focusable panel
  for offset = 1, #state.panel_order do
    local next_idx = ((current_idx - 1 + offset) % #state.panel_order) + 1
    local next_name = state.panel_order[next_idx]
    local next_panel = state.panels[next_name]
    if next_panel and next_panel.definition.focusable ~= false then
      M.focus_panel(state, next_name)
      return
    end
  end
end

---Focus previous panel in order
---@param state MultiPanelState
function M.focus_prev_panel(state)
  if state._closed then return end

  local current_idx = 1
  for i, name in ipairs(state.panel_order) do
    if name == state.focused_panel then
      current_idx = i
      break
    end
  end

  -- Find previous focusable panel
  for offset = 1, #state.panel_order do
    local prev_idx = ((current_idx - 1 - offset) % #state.panel_order) + 1
    local prev_name = state.panel_order[prev_idx]
    local prev_panel = state.panels[prev_name]
    if prev_panel and prev_panel.definition.focusable ~= false then
      M.focus_panel(state, prev_name)
      return
    end
  end
end

return M
