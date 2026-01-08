---@class UiFloatInteractive
---Reusable interactive floating picker system
---Provides state management, navigation, and common keymaps for interactive list pickers
local UiFloatInteractive = {}

local UiFloat = require('nvim-float.window')

-- Namespace for highlights
local HIGHLIGHT_NS = vim.api.nvim_create_namespace("nvim_float_interactive")

---@class FloatInteractiveConfig
---@field title string Window title
---@field footer string? Footer text (default: "<CR> Select | <Esc> Cancel | j/k Navigate")
---@field width number? Window width (default: 60)
---@field height number? Window height (default: 20)
---@field header_lines number? Number of header lines before selectable items (default: 0)
---@field item_count number? Number of selectable items (if not provided, calculated from lines - header - 1)
---@field on_render fun(state: FloatInteractiveState): string[], table[]? Function to render current content (returns lines, optional highlights)
---@field on_select fun(state: FloatInteractiveState) Function called when item is selected
---@field on_navigate fun(state: FloatInteractiveState, direction: string)? Called after navigation (optional)
---@field on_close fun(state: FloatInteractiveState)? Called when picker closes (optional)
---@field custom_keymaps table<string, fun(state: FloatInteractiveState)>? Additional keymaps
---@field initial_data any? Initial state data (accessible as state.data)

---@class FloatInteractiveState
---@field bufnr number Buffer number
---@field winid number Window ID
---@field float FloatWindow The nvim-float window instance
---@field selected_idx number Currently selected item index (1-based, within selectable items)
---@field data any Custom data provided by caller
---@field config FloatInteractiveConfig Configuration
---@field total_items number Total number of selectable items
---@field header_lines number Number of header lines before selectable items

---Create a new interactive floating picker
---@param config FloatInteractiveConfig Configuration
---@return FloatInteractiveState? state The state object (nil if creation failed)
function UiFloatInteractive.create(config)
  -- Validate config
  if not config.on_render or not config.on_select then
    vim.notify("nvim-float: on_render and on_select are required", vim.log.levels.ERROR)
    return nil
  end

  -- Create state first (needed for keymaps)
  local state = {
    bufnr = nil,
    winid = nil,
    float = nil,
    selected_idx = 1,
    data = config.initial_data,
    config = config,
    total_items = 0,
    header_lines = config.header_lines or 0,
  }

  -- Build keymaps (reference state via closure)
  local keymaps = {
    -- Navigation
    ["j"] = function() UiFloatInteractive.navigate(state, 'down') end,
    ["k"] = function() UiFloatInteractive.navigate(state, 'up') end,
    ["<Down>"] = function() UiFloatInteractive.navigate(state, 'down') end,
    ["<Up>"] = function() UiFloatInteractive.navigate(state, 'up') end,
    -- Selection
    ["<CR>"] = function() config.on_select(state) end,
    -- Close
    ["<Esc>"] = function() UiFloatInteractive.close(state) end,
    ["q"] = function() UiFloatInteractive.close(state) end,
  }

  -- Add custom keymaps
  if config.custom_keymaps then
    for key, handler in pairs(config.custom_keymaps) do
      keymaps[key] = function() handler(state) end
    end
  end

  -- Create float using nvim-float
  local float = UiFloat.create(nil, {
    width = config.width or 60,
    height = config.height or 20,
    title = config.title,
    title_pos = "center",
    footer = config.footer or "<CR> Select | <Esc> Cancel | j/k Navigate",
    footer_pos = "center",
    border = 'rounded',
    centered = true,
    enter = true,
    zindex = 50,
    cursorline = true,
    default_keymaps = false,
    keymaps = keymaps,
  })

  if not float or not float:is_valid() then
    vim.notify("nvim-float: Failed to create floating window", vim.log.levels.ERROR)
    return nil
  end

  -- Update state with float references
  state.float = float
  state.bufnr = float.bufnr
  state.winid = float.winid

  -- Set filetype
  vim.api.nvim_buf_set_option(state.bufnr, 'filetype', 'nvim-float-picker')

  -- Set winhighlight for themed UI
  vim.api.nvim_set_option_value('winhighlight',
    'Normal:Normal,FloatBorder:NvimFloatBorder,FloatTitle:NvimFloatTitle,CursorLine:NvimFloatSelected',
    { win = state.winid })

  -- Initial render
  UiFloatInteractive.render(state)

  return state
end

---Render the picker content
---@param state FloatInteractiveState
function UiFloatInteractive.render(state)
  if not state or not state.float or not state.float:is_valid() then
    return
  end

  -- Get lines and optional highlights from render callback
  local lines, highlights = state.config.on_render(state)
  highlights = highlights or {}

  -- Use item_count from config if provided, otherwise calculate from lines
  if state.config.item_count then
    state.total_items = state.config.item_count
  else
    -- Calculate total selectable items (total lines minus header lines minus footer lines)
    local selectable_items = #lines - state.header_lines - 1
    if selectable_items < 0 then selectable_items = 0 end
    state.total_items = selectable_items
  end

  -- Clamp selected_idx
  if state.selected_idx < 1 then
    state.selected_idx = 1
  elseif state.total_items > 0 and state.selected_idx > state.total_items then
    state.selected_idx = state.total_items
  end

  -- Write to buffer
  state.float:update_lines(lines)

  -- Apply highlights if provided
  if #highlights > 0 then
    vim.api.nvim_buf_clear_namespace(state.bufnr, HIGHLIGHT_NS, 0, -1)
    for _, hl in ipairs(highlights) do
      -- Support both array format {line, col_start, col_end, hl_group}
      -- and named format {line=, col_start=, col_end=, hl_group=} from ContentBuilder
      local line_idx = hl.line or hl[1]
      local col_start = hl.col_start or hl[2]
      local col_end = hl.col_end or hl[3]
      local hl_group = hl.hl_group or hl[4]

      -- Ensure col_end is valid (not nil/0) to prevent highlighting to end of line
      if not col_end or col_end <= 0 then
        -- Fallback to line length if available
        local line_text = lines[line_idx + 1]
        if line_text then
          col_end = #line_text
        end
      end

      if line_idx and col_start and col_end and col_end > col_start and hl_group then
        vim.api.nvim_buf_add_highlight(
          state.bufnr, HIGHLIGHT_NS,
          hl_group, line_idx, col_start, col_end
        )
      end
    end
  end

  -- Position cursor on the correct line (header_lines + selected_idx)
  if state.total_items > 0 then
    local cursor_line = state.header_lines + state.selected_idx
    state.float:set_cursor(cursor_line, 0)
  end
end

---Navigate up/down in the list
---@param state FloatInteractiveState
---@param direction string "up" or "down"
function UiFloatInteractive.navigate(state, direction)
  if not state or state.total_items == 0 then
    return
  end

  if direction == "up" then
    state.selected_idx = state.selected_idx - 1
    if state.selected_idx < 1 then
      state.selected_idx = state.total_items  -- Wrap to bottom
    end
  elseif direction == "down" then
    state.selected_idx = state.selected_idx + 1
    if state.selected_idx > state.total_items then
      state.selected_idx = 1  -- Wrap to top
    end
  end

  -- DON'T re-render on navigation - just move cursor
  -- Uses cursorline for selection highlighting, no need to rebuild buffer
  if state.float and state.float:is_valid() then
    local cursor_line = state.header_lines + state.selected_idx
    state.float:set_cursor(cursor_line, 0)
  end

  -- Call navigation callback if provided
  if state.config.on_navigate then
    state.config.on_navigate(state, direction)
  end
end

---Close the picker
---@param state FloatInteractiveState
function UiFloatInteractive.close(state)
  if not state then return end

  -- Call close callback if provided
  if state.config.on_close then
    state.config.on_close(state)
  end

  -- Close float (handles buffer cleanup)
  if state.float then
    state.float:close()
  end
end

---Update window title dynamically
---@param state FloatInteractiveState
---@param title string New title
function UiFloatInteractive.update_title(state, title)
  if state and state.float and state.float:is_valid() then
    state.float:update_title(title)
  end
end

---Update window footer dynamically
---@param state FloatInteractiveState
---@param footer string New footer
function UiFloatInteractive.update_footer(state, footer)
  if state and state.float and state.float:is_valid() then
    state.float:update_footer(footer)
  end
end

---Helper: Add selection indicator to line
---@param line string Line content
---@param is_selected boolean Whether this line is selected
---@return string line Line with indicator
function UiFloatInteractive.add_indicator(line, is_selected)
  if is_selected then
    return "▶ " .. line
  else
    return "  " .. line
  end
end

return UiFloatInteractive
