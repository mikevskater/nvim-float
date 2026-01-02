---@module 'nvim-float.float.multipanel.elements'
---@brief Element tracking support for MultiPanelWindow

local M = {}

-- ============================================================================
-- Element Tracking Support
-- ============================================================================

---Get element at cursor in the focused panel
---@param state MultiPanelState
---@return TrackedElement? element The element at cursor, or nil
function M.get_element_at_cursor(state)
  if state._closed then return nil end

  local panel = state.panels[state.focused_panel]
  if panel and panel.float then
    return panel.float:get_element_at_cursor()
  end
  return nil
end

---Get element by name from a specific panel
---@param state MultiPanelState
---@param panel_name string Panel name
---@param element_name string Element name
---@return TrackedElement? element
function M.get_element(state, panel_name, element_name)
  local panel = state.panels[panel_name]
  if panel and panel.float then
    return panel.float:get_element(element_name)
  end
  return nil
end

---Get all elements of a specific type from a panel
---@param state MultiPanelState
---@param panel_name string Panel name
---@param element_type string Element type to filter by
---@return TrackedElement[] elements
function M.get_elements_by_type(state, panel_name, element_type)
  local panel = state.panels[panel_name]
  if panel and panel.float then
    return panel.float:get_elements_by_type(element_type)
  end
  return {}
end

---Get all interactive elements from a panel
---@param state MultiPanelState
---@param panel_name string Panel name
---@return TrackedElement[] elements
function M.get_interactive_elements(state, panel_name)
  local panel = state.panels[panel_name]
  if panel and panel.float then
    return panel.float:get_interactive_elements()
  end
  return {}
end

---Interact with element at cursor in the focused panel
---@param state MultiPanelState
---@return boolean success Whether an element was interacted with
function M.interact_at_cursor(state)
  if state._closed then return false end

  local panel = state.panels[state.focused_panel]
  if not panel or not panel.float then return false end

  -- Get element at cursor
  local element = panel.float:get_element_at_cursor()
  if not element then return false end

  -- For input/dropdown/multi_dropdown elements, delegate to panel's InputManager
  if panel.input_manager then
    local element_type = element.type
    if element_type == "input" or element_type == "dropdown" or element_type == "multi_dropdown" then
      return panel.input_manager:activate_field(element.name)
    end
  end

  -- For other interactive elements, call their interact handler
  if element:is_interactive() then
    element:interact()
    return true
  end

  return false
end

---Focus next interactive element in the focused panel
---@param state MultiPanelState
---@return boolean success Whether focus moved to an element
function M.focus_next_element(state)
  if state._closed then return false end

  local panel = state.panels[state.focused_panel]
  if panel and panel.float then
    return panel.float:focus_next_element()
  end
  return false
end

---Focus previous interactive element in the focused panel
---@param state MultiPanelState
---@return boolean success Whether focus moved to an element
function M.focus_prev_element(state)
  if state._closed then return false end

  local panel = state.panels[state.focused_panel]
  if panel and panel.float then
    return panel.float:focus_prev_element()
  end
  return false
end

---Get the element registry from a panel's content builder
---@param state MultiPanelState
---@param panel_name string Panel name
---@return ElementRegistry?
function M.get_element_registry(state, panel_name)
  local panel = state.panels[panel_name]
  if panel and panel.float then
    return panel.float:get_element_registry()
  end
  return nil
end

---Check if a panel has any tracked elements
---@param state MultiPanelState
---@param panel_name string Panel name
---@return boolean
function M.has_elements(state, panel_name)
  local panel = state.panels[panel_name]
  if panel and panel.float then
    return panel.float:has_elements()
  end
  return false
end

---Associate a ContentBuilder with a panel for element tracking
---Call this after rendering with a ContentBuilder to enable element queries
---@param state MultiPanelState
---@param panel_name string Panel name
---@param content_builder ContentBuilder ContentBuilder instance
function M.set_panel_content_builder(state, panel_name, content_builder)
  local panel = state.panels[panel_name]
  if panel and panel.float then
    panel.float._content_builder = content_builder
  end
end

---Get the ContentBuilder associated with a panel
---@param state MultiPanelState
---@param panel_name string Panel name
---@return ContentBuilder?
function M.get_panel_content_builder(state, panel_name)
  local panel = state.panels[panel_name]
  if panel and panel.float then
    return panel.float:get_content_builder()
  end
  return nil
end

-- ============================================================================
-- Advanced Element Tracking (Hover, Focus/Blur Callbacks)
-- ============================================================================

---Enable element tracking for a specific panel
---@param state MultiPanelState
---@param panel_name string Panel name
---@param on_cursor_change fun(element: TrackedElement?)? Optional callback when cursor changes elements
function M.enable_element_tracking(state, panel_name, on_cursor_change)
  local panel = state.panels[panel_name]
  if panel and panel.float then
    panel.float:enable_element_tracking(on_cursor_change)
  end
end

---Disable element tracking for a specific panel
---@param state MultiPanelState
---@param panel_name string Panel name
function M.disable_element_tracking(state, panel_name)
  local panel = state.panels[panel_name]
  if panel and panel.float then
    panel.float:disable_element_tracking()
  end
end

---Enable element tracking for all panels
---@param state MultiPanelState
function M.enable_all_element_tracking(state)
  for name, _ in pairs(state.panels) do
    M.enable_element_tracking(state, name)
  end
end

---Disable element tracking for all panels
---@param state MultiPanelState
function M.disable_all_element_tracking(state)
  for name, _ in pairs(state.panels) do
    M.disable_element_tracking(state, name)
  end
end

---Focus a specific element by name in a panel
---@param state MultiPanelState
---@param panel_name string Panel name
---@param element_name string Element name
---@param focus_panel_func function Function to focus the panel
---@return boolean success
function M.focus_element(state, panel_name, element_name, focus_panel_func)
  local panel = state.panels[panel_name]
  if panel and panel.float then
    -- Focus the panel first
    focus_panel_func(state, panel_name)
    return panel.float:focus_element(element_name)
  end
  return false
end

---Check if cursor is on a specific element in the focused panel
---@param state MultiPanelState
---@param element_name string Element name
---@return boolean
function M.is_cursor_on(state, element_name)
  local panel = state.panels[state.focused_panel]
  if panel and panel.float then
    return panel.float:is_cursor_on(element_name)
  end
  return false
end

---Get the currently hovered element in a panel
---@param state MultiPanelState
---@param panel_name string Panel name
---@return TrackedElement?
function M.get_hovered_element(state, panel_name)
  local panel = state.panels[panel_name]
  if panel and panel.float then
    return panel.float:get_hovered_element()
  end
  return nil
end

return M
