---@class UiFloatForm
---Form input floating window system
---Provides field-based input with navigation, editing, and validation
---Uses inline input fields instead of vim.ui.input prompts
local UiFloatForm = {}

local UiFloat = require('nvim-float.window')
local ContentBuilder = require('nvim-float.content')

---@class FormField
---@field name string Field name/identifier
---@field label string Display label
---@field type string Field type: "text", "checkbox", "readonly"
---@field value any Current value
---@field validator fun(value: any): boolean, string? Optional validation function
---@field options table? Options for select fields (future)

---@class FormConfig
---@field title string Form title
---@field fields FormField[] Array of form fields
---@field width number? Form width (default: 60)
---@field height number? Form height (auto-calculated if not provided)
---@field zindex number? Z-index for window stacking (default: BASE)
---@field on_submit fun(values: table) Called when form is submitted
---@field on_cancel fun()? Called when form is cancelled
---@field header string|string[]? Header text or lines

---@class FormState
---@field float FloatWindow The floating window
---@field fields FormField[] Form fields
---@field config FormConfig Configuration

-- Current form state (module-level for keymap access)
local current_state = nil

---Create a form floating UI
---@param config FormConfig Configuration
---@return FormState? state The state object (nil if creation failed)
function UiFloatForm.create(config)
  -- Validate config
  if not config.fields or #config.fields == 0 then
    vim.notify("nvim-float: Form must have at least one field", vim.log.levels.ERROR)
    return nil
  end

  if not config.on_submit then
    vim.notify("nvim-float: Form must have on_submit callback", vim.log.levels.ERROR)
    return nil
  end

  -- Close any existing form
  if current_state and current_state.float then
    pcall(function() current_state.float:close() end)
  end

  -- Create state
  local state = {
    fields = vim.deepcopy(config.fields),
    config = config,
  }

  -- Build content
  local cb = UiFloatForm._build_content(state)

  -- Calculate dimensions
  local width = config.width or 60
  local height = config.height or UiFloatForm._calculate_height(state)

  -- Build keymaps
  local keymaps = {
    ["s"] = function() UiFloatForm.submit() end,
    ["<C-s>"] = function() UiFloatForm.submit() end,
    ["q"] = function() UiFloatForm.cancel() end,
    ["<Esc>"] = function() UiFloatForm.cancel() end,
    ["<Space>"] = function() UiFloatForm.toggle_checkbox_at_cursor() end,
  }

  -- Create float with input support
  state.float = UiFloat.create(nil, {
    title = config.title or " Form ",
    title_pos = "center",
    border = "rounded",
    width = width,
    height = height,
    centered = true,
    default_keymaps = false,
    keymaps = keymaps,
    content_builder = cb,
    enable_inputs = true,
    zindex = config.zindex,
  })

  current_state = state
  return state
end

---Build ContentBuilder for form
---@param state FormState
---@return ContentBuilder
function UiFloatForm._build_content(state)
  local cb = ContentBuilder.new()

  -- Header
  if state.config.header then
    cb:blank()
    local headers = type(state.config.header) == "table" and state.config.header or { state.config.header }
    for _, line in ipairs(headers) do
      cb:styled("  " .. line, "muted")
    end
    cb:blank()
  end

  -- Fields
  for _, field in ipairs(state.fields) do
    if field.type == "text" then
      -- Text input field with dynamic width support
      cb:labeled_input(field.name, "  " .. field.label, {
        value = tostring(field.value or ""),
        placeholder = field.placeholder or "(empty)",
        width = field.width or 25,  -- Default width, expands for longer text
      })
    elseif field.type == "checkbox" then
      -- Checkbox (rendered as selectable line)
      local checkbox = field.value and "[x]" or "[ ]"
      cb:spans({
        { text = "  ", style = "text" },
        { text = checkbox .. " ", style = field.value and "success" or "muted" },
        { text = field.label, style = "label" },
      })
    elseif field.type == "readonly" then
      -- Read-only display
      cb:spans({
        { text = "  " .. field.label .. ": ", style = "label" },
        { text = tostring(field.value or ""), style = "value" },
      })
    end
  end

  cb:blank()

  -- Footer help
  cb:styled("  ───────────────────────────────────────────", "muted")
  cb:spans({
    { text = "  ", style = "text" },
    { text = "j/k", style = "key" },
    { text = " Navigate  ", style = "muted" },
    { text = "Enter", style = "key" },
    { text = " Edit  ", style = "muted" },
    { text = "Space", style = "key" },
    { text = " Toggle", style = "muted" },
  })
  cb:spans({
    { text = "  ", style = "text" },
    { text = "s", style = "key" },
    { text = " Submit    ", style = "muted" },
    { text = "q/Esc", style = "key" },
    { text = " Cancel", style = "muted" },
  })
  cb:blank()

  return cb
end

---Calculate form height based on fields
---@param state FormState
---@return number height
function UiFloatForm._calculate_height(state)
  local header_lines = 0
  if state.config.header then
    local headers = type(state.config.header) == "table" and state.config.header or { state.config.header }
    header_lines = #headers + 2  -- blank + headers + blank
  end

  local field_lines = #state.fields
  local footer_lines = 5  -- separator + 2 help lines + blank + border

  return header_lines + field_lines + footer_lines
end

---Toggle checkbox at current cursor position
function UiFloatForm.toggle_checkbox_at_cursor()
  if not current_state or not current_state.float then return end

  local cursor = current_state.float:get_cursor()
  local row = cursor  -- 1-indexed

  -- Find which field corresponds to this row
  local field_idx = UiFloatForm._get_field_at_row(row)
  if field_idx then
    local field = current_state.fields[field_idx]
    if field and field.type == "checkbox" then
      field.value = not field.value
      UiFloatForm._refresh()
    end
  end
end

---Get field index at a given row
---@param row number 1-indexed row
---@return number? field_idx
function UiFloatForm._get_field_at_row(row)
  if not current_state then return nil end

  -- Calculate starting row for fields
  local start_row = 1
  if current_state.config.header then
    local headers = type(current_state.config.header) == "table" and current_state.config.header or { current_state.config.header }
    start_row = 2 + #headers  -- blank + headers + blank
  end

  local field_row = row - start_row + 1
  if field_row >= 1 and field_row <= #current_state.fields then
    return field_row
  end
  return nil
end

---Refresh form display (preserving values)
function UiFloatForm._refresh()
  if not current_state or not current_state.float then return end

  -- Sync input values back to fields
  local input_values = current_state.float:get_all_input_values()
  for _, field in ipairs(current_state.fields) do
    if field.type == "text" and input_values[field.name] then
      field.value = input_values[field.name]
    end
  end

  -- Rebuild content
  local cb = UiFloatForm._build_content(current_state)
  current_state.float:update_styled(cb)

  -- Re-setup inputs
  if current_state.float._input_manager then
    local inputs = cb:get_inputs()
    local input_order = cb:get_input_order()
    current_state.float._input_manager:update_inputs(inputs, input_order)
    current_state.float._input_manager:init_highlights()
  end
end

---Submit the form
function UiFloatForm.submit()
  if not current_state then return end

  -- Collect values from inputs and fields
  local values = {}

  -- Get text input values
  if current_state.float then
    local input_values = current_state.float:get_all_input_values()
    for k, v in pairs(input_values) do
      values[k] = v
    end
  end

  -- Get checkbox/readonly values directly from fields
  for _, field in ipairs(current_state.fields) do
    if field.type == "checkbox" or field.type == "readonly" then
      values[field.name] = field.value
    end
  end

  -- Validate all fields
  for _, field in ipairs(current_state.fields) do
    if field.validator then
      local valid, err = field.validator(values[field.name])
      if not valid then
        vim.notify(string.format("nvim-float: %s - %s", field.label, err or "Invalid value"), vim.log.levels.WARN)
        return
      end
    end
  end

  -- Save callback before closing (close sets current_state to nil)
  local on_submit = current_state.config.on_submit

  -- Close form
  UiFloatForm.close()

  -- Call submit callback
  on_submit(values)
end

---Cancel the form
function UiFloatForm.cancel()
  if not current_state then return end

  local on_cancel = current_state.config.on_cancel

  -- Close form
  UiFloatForm.close()

  -- Call cancel callback if provided
  if on_cancel then
    on_cancel()
  end
end

---Close the form
function UiFloatForm.close()
  if current_state and current_state.float then
    pcall(function() current_state.float:close() end)
  end
  current_state = nil
end

---Render the form (compatibility - now just refreshes)
---@param state FormState
function UiFloatForm.render(state)
  -- No-op for compatibility, form renders on create
end

return UiFloatForm
