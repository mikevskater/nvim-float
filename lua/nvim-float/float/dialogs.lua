---@class FloatDialogs
---Dialog helpers for floating windows
---Provides confirm, info, select dialogs and styled content support
---@module nvim-float.float.dialogs
local Dialogs = {}

---Create a simple confirmation dialog
---@param UiFloat table The UiFloat module (for create function and ZINDEX)
---@param message string|string[] Message to display
---@param on_confirm function Callback on confirmation
---@param on_cancel function? Callback on cancel (optional)
---@return FloatWindow
function Dialogs.confirm(UiFloat, message, on_confirm, on_cancel)
  local lines
  if type(message) == "table" then
    lines = message
  else
    -- Split string on newlines
    lines = vim.split(message, "\n", { plain = true })
  end
  table.insert(lines, "")
  table.insert(lines, "Press 'y' to confirm, 'n' to cancel")

  return UiFloat.create(lines, {
    title = "Confirm",
    border = "rounded",
    width = 50,
    zindex = UiFloat.ZINDEX and UiFloat.ZINDEX.MODAL or 150,
    keymaps = {
      y = function()
        if on_confirm then on_confirm() end
        vim.cmd('close')
      end,
      n = function()
        if on_cancel then on_cancel() end
        vim.cmd('close')
      end,
    }
  })
end

---Create a simple info dialog
---@param UiFloat table The UiFloat module
---@param message string|string[] Message to display
---@param title string? Optional title
---@return FloatWindow
function Dialogs.info(UiFloat, message, title)
  local lines
  if type(message) == "table" then
    lines = message
  else
    -- Split string on newlines
    lines = vim.split(message, "\n", { plain = true })
  end

  return UiFloat.create(lines, {
    title = title or "Info",
    border = "rounded",
    width = 50,
    zindex = UiFloat.ZINDEX and UiFloat.ZINDEX.MODAL or 150,
  })
end

---Create a selection menu
---@param UiFloat table The UiFloat module
---@param items string[] List of items
---@param on_select function Callback with selected index
---@param title string? Optional title
---@return FloatWindow
function Dialogs.select(UiFloat, items, on_select, title)
  local lines = {}
  for i, item in ipairs(items) do
    table.insert(lines, string.format("[%d] %s", i, item))
  end

  return UiFloat.create(lines, {
    title = title or "Select",
    border = "rounded",
    max_height = 20,
    cursorline = true,
    zindex = UiFloat.ZINDEX and UiFloat.ZINDEX.MODAL or 150,
    keymaps = {
      ['<CR>'] = function()
        local win = vim.api.nvim_get_current_win()
        local row = vim.api.nvim_win_get_cursor(win)[1]
        if row > 0 and row <= #items then
          vim.cmd('close')
          if on_select then
            on_select(row, items[row])
          end
        end
      end,
    }
  })
end

---Create a styled floating window using ContentBuilder
---@param UiFloat table The UiFloat module
---@param content_builder ContentBuilder ContentBuilder instance with styled content
---@param config FloatConfig? Configuration options
---@return FloatWindow instance
function Dialogs.create_styled(UiFloat, content_builder, config)
  config = config or {}

  -- Get plain lines for initial content
  local lines = content_builder:build_lines()

  -- Create the float window
  local instance = UiFloat.create(lines, config)

  -- Apply highlights from ContentBuilder
  if instance:is_valid() then
    local ns_id = vim.api.nvim_create_namespace("nvim_float_content")
    content_builder:apply_to_buffer(instance.bufnr, ns_id)
    instance._content_ns = ns_id
    instance._content_builder = content_builder
  end

  return instance
end

---Update a styled window with new ContentBuilder content
---@param float FloatWindow The FloatWindow instance to update
---@param content_builder ContentBuilder New styled content
function Dialogs.update_styled(float, content_builder)
  if not float:is_valid() then
    return
  end

  -- Update lines
  local lines = content_builder:build_lines()
  float:update_lines(lines)

  -- Reapply highlights
  local ns_id = float._content_ns or vim.api.nvim_create_namespace("nvim_float_content")
  content_builder:apply_to_buffer(float.bufnr, ns_id)
  float._content_ns = ns_id
  float._content_builder = content_builder
end

---Show controls popup
---@param UiFloat table The UiFloat module
---@param controls ControlsDefinition[] Controls to display
function Dialogs.show_controls_popup(UiFloat, controls)
  if not controls or #controls == 0 then
    vim.notify("No controls defined", vim.log.levels.INFO)
    return
  end

  -- Track the parent window to restore focus when popup closes
  local parent_winid = vim.api.nvim_get_current_win()

  local ContentBuilder = require('nvim-float.content')
  local cb = ContentBuilder.new()

  cb:header("Controls")
  cb:blank()

  -- Calculate max key width for alignment
  local max_key_width = 0
  for _, section in ipairs(controls) do
    for _, keydef in ipairs(section.keys or {}) do
      max_key_width = math.max(max_key_width, #keydef.key)
    end
  end

  -- Render each section
  for i, section in ipairs(controls) do
    if section.header then
      cb:section(section.header)
    end

    for _, keydef in ipairs(section.keys or {}) do
      -- Pad key to max width for alignment
      local padded_key = keydef.key .. string.rep(" ", max_key_width - #keydef.key)
      cb:line(string.format("  %s  %s", padded_key, keydef.desc))
    end

    -- Add blank line between sections (but not after last)
    if i < #controls then
      cb:blank()
    end
  end

  UiFloat.create({
    title = "Controls",
    content_builder = cb,
    min_width = 40,
    max_width = 60,
    border = "rounded",
    zindex = UiFloat.ZINDEX.MODAL,
    on_close = function()
      -- Restore focus to parent window if it still exists
      vim.schedule(function()
        if parent_winid and vim.api.nvim_win_is_valid(parent_winid) then
          vim.api.nvim_set_current_win(parent_winid)
        end
      end)
    end,
  })
end

---Get the ContentBuilder module for convenience
---@return ContentBuilder
function Dialogs.ContentBuilder()
  return require('nvim-float.content')
end

return Dialogs
