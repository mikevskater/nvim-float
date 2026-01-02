---@class InputManager
---Manages input fields within floating windows
---Handles input mode, Tab navigation, and value extraction
local InputManager = {}
InputManager.__index = InputManager

local Debug = require('nvim-float.debug')

-- Module-level cooldown to prevent dropdown re-opening across ALL InputManager instances
-- This is needed because clicking away from a dropdown may land on a different panel's InputManager
local _global_dropdown_close_cooldown = false

-- Flag to track if a dropdown is currently being opened (prevents premature close from WinLeave/BufLeave)
local _dropdown_opening = false

-- Timestamp of when last dropdown was opened (to prevent immediate close from focus events)
local _dropdown_open_time = 0

-- Flag to track if ANY dropdown is currently open (prevents mouse clicks from opening another dropdown while one is open)
local _any_dropdown_open = false

---@class InputManagerConfig
---@field bufnr number Buffer number to manage
---@field winid number Window ID
---@field inputs table<string, InputField> Map of input key -> field info
---@field input_order string[] Ordered list of input keys
---@field dropdowns table<string, DropdownField>? Map of dropdown key -> field info
---@field dropdown_order string[]? Ordered list of dropdown keys
---@field multi_dropdowns table<string, MultiDropdownField>? Map of multi-dropdown key -> field info
---@field multi_dropdown_order string[]? Ordered list of multi-dropdown keys
---@field on_value_change fun(key: string, value: string)? Called when input value changes
---@field on_input_enter fun(key: string)? Called when entering input mode
---@field on_input_exit fun(key: string)? Called when exiting input mode
---@field on_dropdown_change fun(key: string, value: string)? Called when dropdown value changes
---@field on_multi_dropdown_change fun(key: string, values: string[])? Called when multi-dropdown values change

---@class InputField (from content_builder)
---@field key string Unique identifier for the input
---@field line number 1-indexed line number
---@field col_start number 0-indexed start column of input value area
---@field col_end number 0-indexed end column of input value area (dynamic, updates based on content)
---@field width number Current effective width of input field
---@field default_width number Default/minimum display width (pads with spaces, expands if text longer)
---@field min_width number? Minimum display width override
---@field value string Current value
---@field default string Default/initial value
---@field placeholder string Placeholder text when empty
---@field is_showing_placeholder boolean Whether currently displaying placeholder text
---@field prefix_len number? Length of label prefix (for line reconstruction)
---Validation settings (can be modified after creation)
---@field value_type "text"|"integer"|"float"|nil Input value type for validation
---@field min_value number? Minimum numeric value (clamped on commit)
---@field max_value number? Maximum numeric value (clamped on commit)
---@field input_pattern string? Lua pattern for allowed characters (e.g., "[%d]" for digits only)
---@field allow_negative boolean? Whether to allow negative numbers (default: true for numeric types)

---@class InputManagerState
---@field in_input_mode boolean Whether currently in input mode
---@field active_input string? Key of currently active input
---@field values table<string, string> Current input values
---@field original_keymaps table Stored original keymaps

-- Debounce delay for TextChangedI rendering (ms)
local TEXT_CHANGED_DEBOUNCE_MS = 30

---Create a new InputManager
---@param config InputManagerConfig
---@return InputManager
function InputManager.new(config)
  local self = setmetatable({}, InputManager)

  self.bufnr = config.bufnr
  self.winid = config.winid
  self.inputs = config.inputs or {}
  self.input_order = config.input_order or {}
  self.dropdowns = config.dropdowns or {}
  self.dropdown_order = config.dropdown_order or {}
  self.multi_dropdowns = config.multi_dropdowns or {}
  self.multi_dropdown_order = config.multi_dropdown_order or {}
  self.on_value_change = config.on_value_change
  self.on_input_enter = config.on_input_enter
  self.on_input_exit = config.on_input_exit
  self.on_dropdown_change = config.on_dropdown_change
  self.on_multi_dropdown_change = config.on_multi_dropdown_change

  -- Build combined field order (inputs, dropdowns, multi-dropdowns interleaved by line number)
  self._all_fields = {}  -- Array of { type = "input"|"dropdown"|"multi_dropdown", key = string, line = number }
  self._field_order = {}  -- Ordered keys for navigation

  -- State
  self.in_input_mode = false
  self.active_input = nil
  self.current_field_idx = 1  -- Track current field index for Tab navigation
  self.values = {}
  self.dropdown_values = {}
  self.multi_dropdown_values = {}
  self._namespace = vim.api.nvim_create_namespace("nvim_float_input_manager")
  self._autocmd_group = nil
  self._text_changed_timer = nil  -- Debounce timer for TextChangedI rendering

  -- Dropdown state (single-select)
  self._dropdown_open = false
  self._dropdown_key = nil
  self._dropdown_float = nil  -- FloatWindow instance
  self._dropdown_ns = nil     -- Highlight namespace for dropdown content
  self._dropdown_selected_idx = 1
  self._dropdown_original_value = nil
  self._dropdown_filtered_options = nil
  self._dropdown_filter_text = ""
  self._dropdown_autocmd_group = nil

  -- Multi-dropdown state
  self._multi_dropdown_open = false
  self._multi_dropdown_key = nil
  self._multi_dropdown_float = nil
  self._multi_dropdown_ns = nil
  self._multi_dropdown_cursor_idx = 1
  self._multi_dropdown_original_values = nil
  self._multi_dropdown_pending_values = nil  -- Values being modified before confirm
  self._multi_dropdown_autocmd_group = nil

  -- Initialize values from input definitions and track placeholder state
  for key, input in pairs(self.inputs) do
    self.values[key] = input.value or ""
    -- Track if this input is showing placeholder
    input.is_showing_placeholder = (self.values[key] == "" and (input.placeholder or "") ~= "")
  end

  -- Initialize dropdown values
  for key, dropdown in pairs(self.dropdowns) do
    self.dropdown_values[key] = dropdown.value or ""
  end

  -- Initialize multi-dropdown values
  for key, multi_dropdown in pairs(self.multi_dropdowns) do
    self.multi_dropdown_values[key] = vim.deepcopy(multi_dropdown.values or {})
  end

  -- Build combined field order sorted by line number
  self:_build_field_order()

  return self
end

---Build combined field order sorted by line number
function InputManager:_build_field_order()
  self._all_fields = {}

  -- Add inputs
  for _, key in ipairs(self.input_order) do
    local input = self.inputs[key]
    if input then
      table.insert(self._all_fields, {
        type = "input",
        key = key,
        line = input.line,
      })
    end
  end

  -- Add dropdowns
  for _, key in ipairs(self.dropdown_order) do
    local dropdown = self.dropdowns[key]
    if dropdown then
      table.insert(self._all_fields, {
        type = "dropdown",
        key = key,
        line = dropdown.line,
      })
    end
  end

  -- Add multi-dropdowns
  for _, key in ipairs(self.multi_dropdown_order) do
    local multi_dropdown = self.multi_dropdowns[key]
    if multi_dropdown then
      table.insert(self._all_fields, {
        type = "multi_dropdown",
        key = key,
        line = multi_dropdown.line,
      })
    end
  end

  -- Sort by line number
  table.sort(self._all_fields, function(a, b)
    return a.line < b.line
  end)

  -- Build ordered key list
  self._field_order = {}
  for _, field in ipairs(self._all_fields) do
    table.insert(self._field_order, field.key)
  end
end

---Get field info by key (input, dropdown, or multi-dropdown)
---@param key string Field key
---@return table? field_info { type = "input"|"dropdown"|"multi_dropdown", field = InputField|DropdownField|MultiDropdownField }
function InputManager:_get_field(key)
  if self.inputs[key] then
    return { type = "input", field = self.inputs[key] }
  elseif self.dropdowns[key] then
    return { type = "dropdown", field = self.dropdowns[key] }
  elseif self.multi_dropdowns[key] then
    return { type = "multi_dropdown", field = self.multi_dropdowns[key] }
  end
  return nil
end

---Setup input mode handling for the buffer
function InputManager:setup()
  -- Create autocmd group for this manager
  self._autocmd_group = vim.api.nvim_create_augroup(
    "NvimFloatInputManager_" .. self.bufnr,
    { clear = true }
  )

  -- Setup cursor movement detection to enter input mode
  vim.api.nvim_create_autocmd("CursorMoved", {
    group = self._autocmd_group,
    buffer = self.bufnr,
    callback = function()
      if not self.in_input_mode then
        self:_check_cursor_on_input()
      end
    end,
  })

  -- Handle InsertLeave to exit input mode properly
  vim.api.nvim_create_autocmd("InsertLeave", {
    group = self._autocmd_group,
    buffer = self.bufnr,
    callback = function()
      if self.in_input_mode then
        self:_exit_input_mode()
      end
    end,
  })

  -- Handle text changes in insert mode - sync value and adjust width in real-time
  -- Uses debounce to prevent excessive re-rendering on rapid typing
  vim.api.nvim_create_autocmd("TextChangedI", {
    group = self._autocmd_group,
    buffer = self.bufnr,
    callback = function()
      if self.in_input_mode and self.active_input then
        -- Always sync value immediately (lightweight operation)
        self:_sync_input_value()

        -- Debounce the re-render (heavier operation involving buffer updates)
        if self._text_changed_timer then
          vim.fn.timer_stop(self._text_changed_timer)
        end
        local active_key = self.active_input
        self._text_changed_timer = vim.fn.timer_start(TEXT_CHANGED_DEBOUNCE_MS, function()
          self._text_changed_timer = nil
          vim.schedule(function()
            -- Verify still in input mode for the same input
            if self.in_input_mode and self.active_input == active_key then
              self:_render_input_realtime(active_key)
            end
          end)
        end)
      end
    end,
  })

  -- Filter characters during input based on validation settings
  vim.api.nvim_create_autocmd("InsertCharPre", {
    group = self._autocmd_group,
    buffer = self.bufnr,
    callback = function()
      if self.in_input_mode and self.active_input then
        local char = vim.v.char
        if not self:is_char_allowed(char) then
          -- Block the character by setting v:char to empty
          vim.v.char = ""
        end
      end
    end,
  })

  -- Setup Tab/Shift-Tab for input navigation
  self:_setup_input_keymaps()
end

---Check if cursor is on an input field and update highlighting
function InputManager:_check_cursor_on_input()
  local cursor = vim.api.nvim_win_get_cursor(self.winid)
  local row = cursor[1]  -- 1-indexed
  local col = cursor[2]  -- 0-indexed

  -- Find input at cursor position
  for i, key in ipairs(self.input_order) do
    local input = self.inputs[key]
    if input and input.line == row and col >= input.col_start and col < input.col_end then
      -- Cursor is on this input - update index and highlight
      self.current_input_idx = i
      self:_highlight_current_input(key)
      return
    end
  end

  -- Not on any input - keep current input highlighted
  if #self.input_order > 0 then
    local current_key = self.input_order[self.current_input_idx]
    self:_highlight_current_input(current_key)
  end
end

---Enter input mode for a specific input field
---@param key string Input key to activate
function InputManager:enter_input_mode(key)
  local input = self.inputs[key]
  if not input then return end

  self.in_input_mode = true
  self.active_input = key

  -- Update current_input_idx to match activated input
  for i, k in ipairs(self.input_order) do
    if k == key then
      self.current_input_idx = i
      break
    end
  end

  -- Make buffer modifiable
  vim.api.nvim_buf_set_option(self.bufnr, 'modifiable', true)

  -- Disable autocompletion in input buffer
  vim.b[self.bufnr].cmp_enabled = false      -- nvim-cmp
  vim.b[self.bufnr].blink_cmp_enable = false -- blink.cmp
  vim.b[self.bufnr].completion = false       -- generic

  -- If showing placeholder, clear it to blank spaces for editing
  local value = self.values[key] or ""
  if input.is_showing_placeholder then
    -- Clear the placeholder - replace with spaces
    self:_clear_input_to_spaces(key)
    value = ""
    self.values[key] = ""
    input.is_showing_placeholder = false
  end

  -- Position cursor at end of current value (or start if empty)
  local cursor_col = input.col_start + #value
  cursor_col = math.min(cursor_col, input.col_end - 1)

  vim.api.nvim_win_set_cursor(self.winid, {input.line, cursor_col})

  -- Highlight active input
  self:_highlight_current_input(key)

  -- Enter insert mode
  vim.cmd("startinsert")

  -- Callback
  if self.on_input_enter then
    self.on_input_enter(key)
  end
end

---Exit input mode
function InputManager:_exit_input_mode()
  if not self.in_input_mode then return end

  local exited_key = self.active_input

  -- Sync final value
  self:_sync_input_value()

  self.in_input_mode = false
  self.active_input = nil

  -- Always re-render to normalize width (removes extra spaces, restores placeholder if empty)
  if exited_key then
    local input = self.inputs[exited_key]
    local value = self.values[exited_key] or ""
    if input then
      -- Track placeholder state
      if value == "" and (input.placeholder or "") ~= "" then
        input.is_showing_placeholder = true
      else
        input.is_showing_placeholder = false
      end
      -- Re-render to normalize display width
      self:_render_input(exited_key)
    end
  end

  -- Make buffer non-modifiable again
  vim.api.nvim_buf_set_option(self.bufnr, 'modifiable', false)

  -- Keep the current input highlighted (not all cleared)
  if exited_key then
    self:_highlight_current_input(exited_key)
  end

  -- Callback
  if self.on_input_exit and exited_key then
    self.on_input_exit(exited_key)
  end
end

---Clear an input field to blank spaces (for placeholder clearing)
---Resets to default_width when clearing
---@param key string Input key
function InputManager:_clear_input_to_spaces(key)
  local input = self.inputs[key]
  if not input then return end

  local default_width = input.default_width or input.width or 20
  local min_width = input.min_width or default_width
  local effective_width = math.max(default_width, min_width)

  -- Replace with spaces at default width
  local blank_text = string.rep(" ", effective_width)

  -- Get current line
  local lines = vim.api.nvim_buf_get_lines(self.bufnr, input.line - 1, input.line, false)
  if #lines == 0 then return end

  local line = lines[1]

  -- Find the actual closing bracket position
  local bracket_pos = line:find("%]", input.col_start + 1)
  if not bracket_pos then return end

  -- Reconstruct line with blank content at default width
  local before = line:sub(1, input.col_start)  -- Up to and including "["
  local after = line:sub(bracket_pos + 1)  -- Everything after "]"

  -- Build new line and update col_end
  local new_line = before .. blank_text .. "]" .. after
  input.col_end = input.col_start + effective_width
  input.width = effective_width

  -- Update buffer (already modifiable when entering input mode)
  vim.api.nvim_buf_set_lines(self.bufnr, input.line - 1, input.line, false, {new_line})
end

---Sync the current input's value from the buffer
function InputManager:_sync_input_value()
  if not self.active_input then return end

  local input = self.inputs[self.active_input]
  if not input then return end

  -- Read the line from buffer
  local lines = vim.api.nvim_buf_get_lines(self.bufnr, input.line - 1, input.line, false)
  if #lines == 0 then return end

  local line_text = lines[1]

  -- Find the closing bracket to determine actual input end
  -- Start searching from col_start
  local bracket_pos = line_text:find("%]", input.col_start + 1)
  local actual_col_end = bracket_pos and (bracket_pos - 1) or input.col_end

  -- Extract value from input area (between col_start and closing bracket)
  local raw_value = line_text:sub(input.col_start + 1, actual_col_end)

  -- Trim trailing spaces (but preserve leading spaces if user wants them)
  local value = raw_value:gsub("%s+$", "")

  -- Update stored value and col_end
  local old_value = self.values[self.active_input]
  self.values[self.active_input] = value

  -- Update col_end based on new content
  local default_width = input.default_width or input.width or 20
  local min_width = input.min_width or default_width
  local effective_width = math.max(default_width, min_width, #value)
  input.col_end = input.col_start + effective_width
  input.width = effective_width

  -- Callback if changed
  if self.on_value_change and value ~= old_value then
    self.on_value_change(self.active_input, value)
  end
end

---Navigate to next field (input or dropdown)
function InputManager:next_input()
  if #self._field_order == 0 then return end

  -- Find next field index
  local next_idx = (self.current_field_idx % #self._field_order) + 1
  local next_key = self._field_order[next_idx]

  -- Update tracked index
  self.current_field_idx = next_idx

  -- Exit current input mode if active
  if self.in_input_mode then
    -- Stop insert mode, then move to next
    vim.cmd("stopinsert")
    vim.schedule(function()
      self:_focus_field(next_key)
    end)
  else
    self:_focus_field(next_key)
  end
end

---Navigate to previous field (input or dropdown)
function InputManager:prev_input()
  if #self._field_order == 0 then return end

  -- Find previous field index
  local prev_idx = ((self.current_field_idx - 2) % #self._field_order) + 1
  local prev_key = self._field_order[prev_idx]

  -- Update tracked index
  self.current_field_idx = prev_idx

  -- Exit current input mode if active
  if self.in_input_mode then
    vim.cmd("stopinsert")
    vim.schedule(function()
      self:_focus_field(prev_key)
    end)
  else
    self:_focus_field(prev_key)
  end
end

---Focus a field (input or dropdown) without activating it
---@param key string Field key
function InputManager:_focus_field(key)
  local field_info = self:_get_field(key)
  if not field_info then return end

  local field = field_info.field
  vim.api.nvim_win_set_cursor(self.winid, {field.line, field.col_start})
  self:_highlight_current_field(key)
end

---Focus a specific field by key (public API)
---@param key string Field key to focus
function InputManager:focus_field(key)
  -- Find the field index
  for i, k in ipairs(self._field_order) do
    if k == key then
      self.current_field_idx = i
      break
    end
  end
  self:_focus_field(key)
end

---Focus the first field in the panel
function InputManager:focus_first_field()
  if #self._field_order > 0 then
    self.current_field_idx = 1
    self:_focus_field(self._field_order[1])
  end
end

---Activate a field (enter input mode or open dropdown)
---@param key string Field key
function InputManager:_activate_field(key)
  local field_info = self:_get_field(key)
  if not field_info then return end

  if field_info.type == "input" then
    self:enter_input_mode(key)
  elseif field_info.type == "dropdown" then
    self:_open_dropdown(key)
  elseif field_info.type == "multi_dropdown" then
    self:_open_multi_dropdown(key)
  end
end

---Public API: Activate a field by key (for element tracking integration)
---@param key string Field key (input, dropdown, or multi-dropdown)
---@return boolean success Whether the field was activated
function InputManager:activate_field(key)
  local field_info = self:_get_field(key)
  if not field_info then return false end
  self:_activate_field(key)
  return true
end

---Setup keymaps for input navigation
function InputManager:_setup_input_keymaps()
  local opts = { buffer = self.bufnr, noremap = true, silent = true }

  -- Helper function to activate field at cursor position
  local function activate_field_at_cursor(source)
    local cursor = vim.api.nvim_win_get_cursor(self.winid)
    local row = cursor[1]
    local col = cursor[2]

    Debug.log(string.format("[DROPDOWN DEBUG] activate_field_at_cursor called from: %s, row=%d, col=%d", source or "unknown", row, col))

    -- First check if cursor is directly on an input
    for key, input in pairs(self.inputs) do
      if input.line == row and col >= input.col_start and col < input.col_end then
        Debug.log(string.format("[DROPDOWN DEBUG] Activating INPUT: %s", key))
        self:enter_input_mode(key)
        return true
      end
    end

    -- Check if cursor is directly on a dropdown
    for key, dropdown in pairs(self.dropdowns) do
      if dropdown.line == row and col >= dropdown.col_start and col < dropdown.col_end then
        Debug.log(string.format("[DROPDOWN DEBUG] Activating DROPDOWN: %s (line=%d, col_start=%d, col_end=%d)", key, dropdown.line, dropdown.col_start, dropdown.col_end))
        self:_open_dropdown(key)
        return true
      end
    end

    -- Check if cursor is directly on a multi-dropdown
    for key, multi_dropdown in pairs(self.multi_dropdowns) do
      if multi_dropdown.line == row and col >= multi_dropdown.col_start and col < multi_dropdown.col_end then
        Debug.log(string.format("[DROPDOWN DEBUG] Activating MULTI-DROPDOWN: %s (line=%d, col_start=%d, col_end=%d)", key, multi_dropdown.line, multi_dropdown.col_start, multi_dropdown.col_end))
        self:_open_multi_dropdown(key)
        return true
      end
    end

    Debug.log("[DROPDOWN DEBUG] No field found at cursor position")
    return false
  end

  -- Normal mode: Enter activates field under cursor (or at current index)
  vim.keymap.set('n', '<CR>', function()
    Debug.log("[DROPDOWN DEBUG] <CR> keymap triggered")
    if not activate_field_at_cursor("<CR> keymap") then
      -- Otherwise, activate the current tracked field
      if #self._field_order > 0 then
        local current_key = self._field_order[self.current_field_idx]
        if current_key then
          Debug.log(string.format("[DROPDOWN DEBUG] <CR> fallback to _activate_field: %s", current_key))
          self:_activate_field(current_key)
        end
      end
    end
  end, opts)

  -- Mouse click: activate field under mouse cursor
  vim.keymap.set('n', '<LeftRelease>', function()
    Debug.log(string.format("[DROPDOWN DEBUG] <LeftRelease> keymap triggered, cooldown=%s, any_open=%s, self_dropdown=%s, self_multi=%s",
      tostring(_global_dropdown_close_cooldown), tostring(_any_dropdown_open),
      tostring(self._dropdown_open), tostring(self._multi_dropdown_open)))

    -- If a dropdown is currently open on THIS InputManager, just close it and don't open anything new
    -- The click is on the parent buffer, not the dropdown, so user wants to close the dropdown
    if self._dropdown_open then
      Debug.log("[DROPDOWN DEBUG] <LeftRelease> closing open dropdown (click outside dropdown)")
      self:_close_dropdown(true)
      return
    end
    if self._multi_dropdown_open then
      Debug.log("[DROPDOWN DEBUG] <LeftRelease> closing open multi-dropdown (click outside dropdown)")
      self:_close_multi_dropdown(true)
      return
    end

    -- If a dropdown is open on ANY InputManager (different panel), don't open a new one
    -- The WinLeave/BufLeave on the dropdown will handle closing it
    if _any_dropdown_open then
      Debug.log("[DROPDOWN DEBUG] <LeftRelease> BLOCKED: dropdown open on another panel")
      return
    end

    -- Mouse click already moves cursor, so just activate field at cursor
    vim.schedule(function()
      -- Skip if dropdown just closed (prevents immediate re-open)
      -- Use global cooldown because click may land on a different InputManager instance
      if _global_dropdown_close_cooldown then
        Debug.log("[DROPDOWN DEBUG] <LeftRelease> BLOCKED by global cooldown")
        return
      end
      activate_field_at_cursor("<LeftRelease> keymap (scheduled)")
    end)
  end, opts)

  -- Normal mode: j/Down moves to next input
  vim.keymap.set('n', 'j', function()
    self:next_input()
  end, opts)

  vim.keymap.set('n', '<Down>', function()
    self:next_input()
  end, opts)

  -- Normal mode: k/Up moves to previous input
  vim.keymap.set('n', 'k', function()
    self:prev_input()
  end, opts)

  vim.keymap.set('n', '<Up>', function()
    self:prev_input()
  end, opts)

  -- Normal mode Tab/Shift-Tab: also move between inputs (alternative)
  vim.keymap.set('n', '<Tab>', function()
    self:next_input()
  end, opts)

  vim.keymap.set('n', '<S-Tab>', function()
    self:prev_input()
  end, opts)

  -- Insert mode Enter: confirm/exit input (instead of newline)
  vim.keymap.set('i', '<CR>', function()
    vim.cmd("stopinsert")
    -- Call on_submit callback if set (after a short delay to let stopinsert complete)
    vim.schedule(function()
      if self.on_submit then
        self.on_submit()
      end
    end)
  end, opts)

  -- Insert mode Tab/Shift-Tab: move to next/prev input
  vim.keymap.set('i', '<Tab>', function()
    self:next_input()
  end, opts)

  vim.keymap.set('i', '<S-Tab>', function()
    self:prev_input()
  end, opts)

  -- Insert mode Escape: exit input mode
  vim.keymap.set('i', '<Esc>', function()
    vim.cmd("stopinsert")
  end, opts)

  -- Prevent cursor from leaving input bounds in insert mode
  vim.keymap.set('i', '<Left>', function()
    local cursor = vim.api.nvim_win_get_cursor(self.winid)
    local input = self.inputs[self.active_input]
    if input and cursor[2] > input.col_start then
      vim.api.nvim_win_set_cursor(self.winid, {cursor[1], cursor[2] - 1})
    end
  end, opts)

  vim.keymap.set('i', '<Right>', function()
    local cursor = vim.api.nvim_win_get_cursor(self.winid)
    local input = self.inputs[self.active_input]
    if input then
      local value = self.values[self.active_input] or ""
      local max_col = input.col_start + #value
      -- Allow cursor to move up to end of actual value (not padded spaces)
      if cursor[2] < max_col then
        vim.api.nvim_win_set_cursor(self.winid, {cursor[1], cursor[2] + 1})
      end
    end
  end, opts)

  -- Prevent Home/End from going outside input
  vim.keymap.set('i', '<Home>', function()
    local input = self.inputs[self.active_input]
    if input then
      vim.api.nvim_win_set_cursor(self.winid, {input.line, input.col_start})
    end
  end, opts)

  vim.keymap.set('i', '<End>', function()
    local input = self.inputs[self.active_input]
    if input then
      local value = self.values[self.active_input] or ""
      vim.api.nvim_win_set_cursor(self.winid, {input.line, input.col_start + #value})
    end
  end, opts)

  -- Handle backspace at start of input
  vim.keymap.set('i', '<BS>', function()
    local cursor = vim.api.nvim_win_get_cursor(self.winid)
    local input = self.inputs[self.active_input]
    if input and cursor[2] > input.col_start then
      -- Normal backspace
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<BS>', true, false, true), 'n', false)
    end
    -- Don't do anything if at start of input
  end, opts)
end

---Highlight an input field
---@param key string Input key
---@param active boolean Whether input is active/focused
function InputManager:_highlight_input(key, active)
  local input = self.inputs[key]
  if not input then return end

  -- Check if buffer is still valid
  if not self.bufnr or not vim.api.nvim_buf_is_valid(self.bufnr) then
    return
  end

  -- Clear existing highlights first
  vim.api.nvim_buf_clear_namespace(self.bufnr, self._namespace, input.line - 1, input.line)

  -- Determine highlight group based on state
  local hl_group
  if active then
    hl_group = "NvimFloatInputActive"
  elseif input.is_showing_placeholder then
    hl_group = "NvimFloatInputPlaceholder"
  else
    hl_group = "NvimFloatInput"
  end

  vim.api.nvim_buf_add_highlight(
    self.bufnr, self._namespace, hl_group,
    input.line - 1, input.col_start, input.col_end
  )
end

---Highlight the current input (for Tab navigation in normal mode)
---@param current_key string Key of currently focused input
function InputManager:_highlight_current_input(current_key)
  -- Check if buffer is still valid
  if not self.bufnr or not vim.api.nvim_buf_is_valid(self.bufnr) then
    return
  end

  -- Clear all and reapply with current highlighted
  vim.api.nvim_buf_clear_namespace(self.bufnr, self._namespace, 0, -1)

  for key, _ in pairs(self.inputs) do
    self:_highlight_input(key, key == current_key)
  end
end

---Clear all input highlights
function InputManager:_clear_input_highlights()
  -- Check if buffer is still valid
  if not self.bufnr or not vim.api.nvim_buf_is_valid(self.bufnr) then
    return
  end

  vim.api.nvim_buf_clear_namespace(self.bufnr, self._namespace, 0, -1)

  -- Reapply inactive highlights to all inputs
  for key, _ in pairs(self.inputs) do
    self:_highlight_input(key, false)
  end
end

---Initialize highlights for all fields (inputs and dropdowns)
function InputManager:init_highlights()
  -- Highlight first field as current, others as inactive
  if #self._field_order > 0 then
    local first_key = self._field_order[1]
    self:_highlight_current_field(first_key)
  end
end

---Get the current value of an input
---@param key string Input key
---@return string? value
function InputManager:get_value(key)
  return self.values[key]
end

---Get all input values
---@return table<string, string> values Map of key -> value
function InputManager:get_all_values()
  return vim.deepcopy(self.values)
end

---Set the value of an input
---@param key string Input key
---@param value string New value
function InputManager:set_value(key, value)
  local input = self.inputs[key]
  if not input then return end

  self.values[key] = value or ""

  -- Update buffer content if buffer is valid
  if vim.api.nvim_buf_is_valid(self.bufnr) then
    self:_render_input(key)
  end
end

---Render an input field's value to the buffer (with dynamic width support)
---@param key string Input key
function InputManager:_render_input(key)
  local input = self.inputs[key]
  if not input then return end

  local value = self.values[key] or ""
  local placeholder = input.placeholder or ""
  local default_width = input.default_width or input.width or 20
  local min_width = input.min_width or default_width

  -- Determine display text and track placeholder state
  local display_text = value
  if value == "" and placeholder ~= "" then
    display_text = placeholder
    input.is_showing_placeholder = true
  else
    input.is_showing_placeholder = false
  end

  -- Calculate effective width: at least default_width, but expands for longer text
  local effective_width = math.max(default_width, min_width, #display_text)

  -- Pad to effective width (no truncation - expands if needed)
  if #display_text < effective_width then
    display_text = display_text .. string.rep(" ", effective_width - #display_text)
  end

  -- Get current line
  local lines = vim.api.nvim_buf_get_lines(self.bufnr, input.line - 1, input.line, false)
  if #lines == 0 then return end

  local line = lines[1]

  -- Find the actual closing bracket position in the current line
  local bracket_pos = line:find("%]", input.col_start + 1)
  if not bracket_pos then
    -- No bracket found, something is wrong - just return
    return
  end

  -- Update input's col_end and width for dynamic sizing
  input.col_end = input.col_start + effective_width
  input.width = effective_width

  -- Reconstruct the line with new input content
  local before = line:sub(1, input.col_start)  -- Everything up to and including "["
  local after = line:sub(bracket_pos + 1)  -- Everything after the "]"

  -- Build new line: before + display_text + "]" + after
  local new_line = before .. display_text .. "]" .. after

  -- Update buffer
  local was_modifiable = vim.api.nvim_buf_get_option(self.bufnr, 'modifiable')
  vim.api.nvim_buf_set_option(self.bufnr, 'modifiable', true)
  vim.api.nvim_buf_set_lines(self.bufnr, input.line - 1, input.line, false, {new_line})
  vim.api.nvim_buf_set_option(self.bufnr, 'modifiable', was_modifiable)

  -- Re-apply highlight for this input after width change
  local current_key = self.input_order[self.current_input_idx]
  self:_highlight_input(key, key == current_key)
end

---Render an input field in real-time while typing (preserves cursor position)
---@param key string Input key
function InputManager:_render_input_realtime(key)
  local input = self.inputs[key]
  if not input then return end

  local value = self.values[key] or ""
  local default_width = input.default_width or input.width or 20
  local min_width = input.min_width or default_width

  -- Calculate effective width: at least default_width, but expands for longer text
  local effective_width = math.max(default_width, min_width, #value)

  -- Pad value with spaces to effective width
  local display_text = value
  if #display_text < effective_width then
    display_text = display_text .. string.rep(" ", effective_width - #display_text)
  end

  -- Save cursor position (relative to input start)
  local cursor = vim.api.nvim_win_get_cursor(self.winid)
  local cursor_offset = cursor[2] - input.col_start

  -- Get current line
  local lines = vim.api.nvim_buf_get_lines(self.bufnr, input.line - 1, input.line, false)
  if #lines == 0 then return end

  local line = lines[1]

  -- Find the actual closing bracket position in the current line
  local bracket_pos = line:find("%]", input.col_start + 1)
  if not bracket_pos then
    -- No bracket found, something is wrong - just return
    return
  end

  -- Update input's col_end and width for dynamic sizing
  input.col_end = input.col_start + effective_width
  input.width = effective_width

  -- Reconstruct the line with new input content
  local before = line:sub(1, input.col_start)  -- Everything up to and including "["
  local after = line:sub(bracket_pos + 1)  -- Everything after the "]"

  -- Build new line: before + display_text + "]" + after
  local new_line = before .. display_text .. "]" .. after

  -- Update buffer (already modifiable in insert mode)
  vim.api.nvim_buf_set_lines(self.bufnr, input.line - 1, input.line, false, {new_line})

  -- Restore cursor position
  local new_cursor_col = input.col_start + cursor_offset
  -- Clamp cursor to valid range (don't go past end of actual value)
  new_cursor_col = math.min(new_cursor_col, input.col_start + #value)
  new_cursor_col = math.max(new_cursor_col, input.col_start)
  vim.api.nvim_win_set_cursor(self.winid, {cursor[1], new_cursor_col})

  -- Re-apply highlight
  self:_highlight_input(key, true)
end

---Update input definitions (e.g., after re-render)
---@param inputs table<string, InputField> New input definitions
---@param input_order string[] New input order
---@param dropdowns table<string, DropdownField>? New dropdown definitions
---@param dropdown_order string[]? New dropdown order
---@param multi_dropdowns table<string, MultiDropdownField>? New multi-dropdown definitions
---@param multi_dropdown_order string[]? New multi-dropdown order
function InputManager:update_inputs(inputs, input_order, dropdowns, dropdown_order, multi_dropdowns, multi_dropdown_order)
  self.inputs = inputs or {}
  self.input_order = input_order or {}
  self.dropdowns = dropdowns or self.dropdowns or {}
  self.dropdown_order = dropdown_order or self.dropdown_order or {}
  self.multi_dropdowns = multi_dropdowns or self.multi_dropdowns or {}
  self.multi_dropdown_order = multi_dropdown_order or self.multi_dropdown_order or {}

  -- Preserve existing values, add new ones, and track placeholder state
  for key, input in pairs(self.inputs) do
    if not self.values[key] then
      self.values[key] = input.value or ""
    end
    -- Update placeholder state based on current value
    local value = self.values[key] or ""
    input.is_showing_placeholder = (value == "" and (input.placeholder or "") ~= "")
  end

  -- Preserve dropdown values
  for key, dropdown in pairs(self.dropdowns) do
    if not self.dropdown_values[key] then
      self.dropdown_values[key] = dropdown.value or ""
    end
  end

  -- Preserve multi-dropdown values
  for key, multi_dropdown in pairs(self.multi_dropdowns) do
    if not self.multi_dropdown_values[key] then
      self.multi_dropdown_values[key] = vim.deepcopy(multi_dropdown.values or {})
    end
  end

  -- Rebuild field order
  self:_build_field_order()
end

---Update validation settings for a specific input
---@param key string Input key
---@param settings table Validation settings: { value_type?, min_value?, max_value?, input_pattern?, allow_negative? }
function InputManager:update_input_settings(key, settings)
  local input = self.inputs[key]
  if not input then return end

  if settings.value_type ~= nil then
    input.value_type = settings.value_type
  end
  if settings.min_value ~= nil then
    input.min_value = settings.min_value
  end
  if settings.max_value ~= nil then
    input.max_value = settings.max_value
  end
  if settings.input_pattern ~= nil then
    input.input_pattern = settings.input_pattern
  end
  if settings.allow_negative ~= nil then
    input.allow_negative = settings.allow_negative
  end
end

---Update validation settings for multiple inputs at once
---@param settings_map table<string, table> Map of input key -> settings
function InputManager:update_all_input_settings(settings_map)
  for key, settings in pairs(settings_map) do
    self:update_input_settings(key, settings)
  end
end

---Validate and clamp a value according to input settings
---@param key string Input key
---@param value string Raw input value
---@return string validated_value The validated/clamped value
function InputManager:validate_input_value(key, value)
  local input = self.inputs[key]
  if not input then return value end

  -- If no validation settings, return as-is
  if not input.value_type or input.value_type == "text" then
    return value
  end

  -- Extract numeric value
  local num = nil
  if input.value_type == "integer" then
    -- Extract integer (strip non-digit chars except leading minus)
    local sign = ""
    if input.allow_negative ~= false and value:match("^%-") then
      sign = "-"
    end
    local digits = value:gsub("[^%d]", "")
    if digits ~= "" then
      num = tonumber(sign .. digits)
    end
  elseif input.value_type == "float" then
    -- Extract float (allow one decimal point)
    local sign = ""
    if input.allow_negative ~= false and value:match("^%-") then
      sign = "-"
    end
    -- Extract digits and first decimal point
    local cleaned = value:gsub("[^%d%.]", "")
    -- Only keep first decimal point
    local first_dot = cleaned:find("%.")
    if first_dot then
      local before = cleaned:sub(1, first_dot)
      local after = cleaned:sub(first_dot + 1):gsub("%.", "")
      cleaned = before .. after
    end
    if cleaned ~= "" and cleaned ~= "." then
      num = tonumber(sign .. cleaned)
    end
  end

  -- If we couldn't parse a number, return empty or original
  if num == nil then
    return ""
  end

  -- Clamp to min/max
  if input.min_value ~= nil and num < input.min_value then
    num = input.min_value
  end
  if input.max_value ~= nil and num > input.max_value then
    num = input.max_value
  end

  -- Format output
  if input.value_type == "integer" then
    return tostring(math.floor(num + 0.5))
  else
    -- For floats, preserve reasonable precision
    if num == math.floor(num) then
      return tostring(math.floor(num))
    else
      return string.format("%.2f", num):gsub("%.?0+$", "")
    end
  end
end

---Check if a character is allowed for the current input
---@param char string Single character to check
---@return boolean allowed Whether the character is allowed
function InputManager:is_char_allowed(char)
  if not self.active_input then return true end

  local input = self.inputs[self.active_input]
  if not input then return true end

  -- Check custom pattern first
  if input.input_pattern then
    return char:match(input.input_pattern) ~= nil
  end

  -- Check based on value_type
  if input.value_type == "integer" then
    -- Allow digits and minus (for negative)
    if char:match("[%d]") then return true end
    if input.allow_negative ~= false and char == "-" then
      -- Only allow minus at start
      local current = self.values[self.active_input] or ""
      return current == "" or current == input.placeholder
    end
    return false
  elseif input.value_type == "float" then
    -- Allow digits, decimal point, and minus
    if char:match("[%d]") then return true end
    if char == "." then
      -- Only allow one decimal point
      local current = self.values[self.active_input] or ""
      return not current:find("%.")
    end
    if input.allow_negative ~= false and char == "-" then
      local current = self.values[self.active_input] or ""
      return current == "" or current == input.placeholder
    end
    return false
  end

  -- Default: allow all
  return true
end

---Get validated value for an input (call this on commit)
---@param key string Input key
---@return string value Validated value
function InputManager:get_validated_value(key)
  local raw = self.values[key] or ""
  return self:validate_input_value(key, raw)
end

---Highlight a field (input, dropdown, or multi-dropdown)
---@param current_key string Key of currently focused field
function InputManager:_highlight_current_field(current_key)
  -- Check if buffer is still valid (may have been replaced by callback)
  if not self.bufnr or not vim.api.nvim_buf_is_valid(self.bufnr) then
    return
  end

  -- Clear all and reapply with current highlighted
  vim.api.nvim_buf_clear_namespace(self.bufnr, self._namespace, 0, -1)

  -- Highlight inputs
  for key, _ in pairs(self.inputs) do
    self:_highlight_input(key, key == current_key)
  end

  -- Highlight dropdowns
  for key, _ in pairs(self.dropdowns) do
    self:_highlight_dropdown(key, key == current_key)
  end

  -- Highlight multi-dropdowns
  for key, _ in pairs(self.multi_dropdowns) do
    self:_highlight_multi_dropdown(key, key == current_key)
  end
end

---Highlight a dropdown/multi-dropdown field (shared base)
---@param dropdown_type "dropdown"|"multi_dropdown"
---@param key string Field key
---@param active boolean Whether field is active/focused
function InputManager:_highlight_dropdown_base(dropdown_type, key, active)
  local field = dropdown_type == "dropdown" and self.dropdowns[key] or self.multi_dropdowns[key]
  if not field then return end

  -- Check if buffer is still valid
  if not self.bufnr or not vim.api.nvim_buf_is_valid(self.bufnr) then
    return
  end

  -- Determine highlight group based on state
  local hl_group
  if active then
    hl_group = "NvimFloatInputActive"
  elseif field.is_placeholder then
    hl_group = "NvimFloatInputPlaceholder"
  else
    hl_group = "NvimFloatInput"
  end

  -- Highlight the dropdown value area (excluding arrow)
  local arrow_len = 4  -- Both " ▼" and " ▾" are 4 bytes
  vim.api.nvim_buf_add_highlight(
    self.bufnr, self._namespace, hl_group,
    field.line - 1, field.col_start, field.col_end - arrow_len
  )

  -- Arrow always gets hint color
  vim.api.nvim_buf_add_highlight(
    self.bufnr, self._namespace, "NvimFloatHint",
    field.line - 1, field.col_end - arrow_len, field.col_end
  )
end

---Highlight a dropdown field
---@param key string Dropdown key
---@param active boolean Whether dropdown is active/focused
function InputManager:_highlight_dropdown(key, active)
  self:_highlight_dropdown_base("dropdown", key, active)
end

---Highlight a multi-dropdown field
---@param key string Multi-dropdown key
---@param active boolean Whether multi-dropdown is active/focused
function InputManager:_highlight_multi_dropdown(key, active)
  self:_highlight_dropdown_base("multi_dropdown", key, active)
end

---Open dropdown window for a dropdown field
---@param key string Dropdown key
function InputManager:_open_dropdown(key)
  Debug.log(string.format("[DROPDOWN DEBUG] _open_dropdown CALLED for key=%s, global_cooldown=%s, opening=%s", key, tostring(_global_dropdown_close_cooldown), tostring(_dropdown_opening)))

  -- Prevent opening while another dropdown is still being opened
  if _dropdown_opening then
    Debug.log("[DROPDOWN DEBUG] _open_dropdown BLOCKED: another dropdown is being opened")
    return
  end

  local dropdown = self.dropdowns[key]
  if not dropdown then
    Debug.log(string.format("[DROPDOWN DEBUG] _open_dropdown: dropdown '%s' not found!", key))
    return
  end

  -- Set opening flag and timestamp to prevent premature close
  _dropdown_opening = true
  _dropdown_open_time = vim.loop.now()
  _any_dropdown_open = true

  Debug.log(string.format("[DROPDOWN DEBUG] _open_dropdown: key=%s, options=%d, current_value=%s, open_time=%d", key, #(dropdown.options or {}), tostring(self.dropdown_values[key]), _dropdown_open_time))

  -- Store original value for cancel
  self._dropdown_original_value = self.dropdown_values[key]
  self._dropdown_key = key
  self._dropdown_open = true
  self._dropdown_filter_text = ""
  self._dropdown_filtered_options = vim.deepcopy(dropdown.options)

  -- Find index of currently selected value
  self._dropdown_selected_idx = 1
  for i, opt in ipairs(dropdown.options) do
    if opt.value == self._dropdown_original_value then
      self._dropdown_selected_idx = i
      break
    end
  end

  Debug.log(string.format("DEBUG _open_dropdown: selected_idx=%d, callback=%s", self._dropdown_selected_idx, self.on_dropdown_change and "yes" or "NO"))

  -- Calculate dropdown window position (below the dropdown field)
  local win_info = vim.fn.getwininfo(self.winid)[1]
  if not win_info then return end

  -- Get screen position of parent window
  local parent_row = win_info.winrow
  local parent_col = win_info.wincol

  -- Dropdown position: directly below the field, aligned with the "[" bracket
  -- col_start points to after "[", so we subtract 1 to align with the bracket
  local dropdown_row = parent_row + dropdown.line
  local dropdown_col = parent_col + dropdown.col_start - 1

  -- Dropdown dimensions - match the dropdown field width (including brackets)
  -- text_width is the content width, add 2 for brackets
  local width = (dropdown.text_width or dropdown.width) + 2
  local height = math.min(#dropdown.options, dropdown.max_height or 6)

  -- Build initial content using ContentBuilder
  local cb = self:_build_dropdown_content()
  local lines = cb:build_lines()

  -- Get UiFloat for creating the dropdown
  local UiFloat = require('nvim-float.float')

  -- Create dropdown using UiFloat for proper theming and scrollbar
  self._dropdown_float = UiFloat.create(lines, {
    -- Explicit positioning (no centering)
    centered = false,
    relative = "editor",
    row = dropdown_row,
    col = dropdown_col,
    width = width,
    height = height,
    -- Styling
    border = "rounded",
    zindex = UiFloat.ZINDEX.DROPDOWN,
    -- Window options
    cursorline = true,
    focusable = true,
    enter = true,
    wrap = false,  -- Allow horizontal scrolling for long labels
    -- Disable default keymaps (we set our own)
    default_keymaps = false,
    -- Scrollbar for long lists
    scrollbar = true,
  })

  if not self._dropdown_float or not self._dropdown_float:is_valid() then
    self._dropdown_open = false
    self._dropdown_key = nil
    _dropdown_opening = false  -- Reset opening flag on failure
    return
  end

  -- Apply highlights from ContentBuilder
  self._dropdown_ns = vim.api.nvim_create_namespace("nvim_float_dropdown_content")
  cb:apply_to_buffer(self._dropdown_float.bufnr, self._dropdown_ns)

  -- Setup dropdown keymaps
  self:_setup_dropdown_keymaps()

  -- Setup autocmds for focus-lost detection
  self:_setup_dropdown_autocmds()

  -- Position cursor on selected item (schedule to ensure window is fully ready)
  local selected_idx = self._dropdown_selected_idx
  local dropdown_float = self._dropdown_float
  vim.schedule(function()
    if dropdown_float and dropdown_float:is_valid() and selected_idx <= height then
      dropdown_float:set_cursor(selected_idx, 0)
      -- Force redraw to ensure cursorline is visible
      vim.cmd('redraw')
    end
  end)

  -- Clear opening flag after a short delay to allow dropdown to settle
  vim.defer_fn(function()
    _dropdown_opening = false
    Debug.log("[DROPDOWN DEBUG] Dropdown opening flag CLEARED (50ms elapsed)")
  end, 50)
end

---Build dropdown content using ContentBuilder
---@return ContentBuilder cb
function InputManager:_build_dropdown_content()
  local ContentBuilder = require('nvim-float.content_builder')
  local cb = ContentBuilder.new()

  local key = self._dropdown_key
  local dropdown = self.dropdowns[key]
  if not dropdown then return cb end

  local filtered = self._dropdown_filtered_options or dropdown.options

  -- Calculate max label width for proper padding
  local max_label_len = 0
  for _, opt in ipairs(filtered) do
    max_label_len = math.max(max_label_len, #opt.label)
  end

  for _, opt in ipairs(filtered) do
    local is_original = (opt.value == self._dropdown_original_value)
    -- Pad label for alignment
    local padded_label = opt.label .. string.rep(" ", max_label_len - #opt.label)

    if is_original then
      -- Original value gets special styling with indicator
      cb:spans({
        { text = " ", style = "normal" },
        { text = padded_label, style = "emphasis" },
        { text = " *", style = "success" },
      })
    else
      -- Regular option
      cb:spans({
        { text = " ", style = "normal" },
        { text = padded_label, style = "value" },
      })
    end
  end

  if #filtered == 0 then
    cb:styled(" (no matches)", "muted")
  end

  return cb
end

---Close dropdown window
---@param cancel boolean Whether to cancel (restore original value)
function InputManager:_close_dropdown(cancel)
  Debug.log(string.format("[DROPDOWN DEBUG] _close_dropdown called, cancel=%s, open=%s", tostring(cancel), tostring(self._dropdown_open)))
  if not self._dropdown_open then return end

  -- Clear opening flag in case close is called during opening phase
  _dropdown_opening = false
  _any_dropdown_open = false

  local key = self._dropdown_key

  -- Cancel = restore original value
  if cancel and key and self._dropdown_original_value ~= nil then
    self.dropdown_values[key] = self._dropdown_original_value
    self:_update_dropdown_display(key)
  end

  -- Clean up autocmds
  if self._dropdown_autocmd_group then
    pcall(vim.api.nvim_del_augroup_by_id, self._dropdown_autocmd_group)
    self._dropdown_autocmd_group = nil
  end

  -- Close dropdown FloatWindow (handles window and buffer cleanup)
  if self._dropdown_float then
    pcall(function() self._dropdown_float:close() end)
  end

  -- Reset state
  self._dropdown_open = false
  self._dropdown_key = nil
  self._dropdown_float = nil
  self._dropdown_ns = nil
  self._dropdown_selected_idx = 1
  self._dropdown_original_value = nil
  self._dropdown_filtered_options = nil
  self._dropdown_filter_text = ""

  -- Set global cooldown to prevent immediate re-open from mouse click on ANY panel
  _global_dropdown_close_cooldown = true
  Debug.log("[DROPDOWN DEBUG] Global cooldown SET to true")
  vim.defer_fn(function()
    _global_dropdown_close_cooldown = false
    Debug.log("[DROPDOWN DEBUG] Global cooldown RESET to false (200ms elapsed)")
  end, 200)

  -- Return focus to parent window
  if vim.api.nvim_win_is_valid(self.winid) then
    vim.api.nvim_set_current_win(self.winid)
  end

  -- Re-highlight current field
  if key then
    self:_highlight_current_field(key)
  end
end

---Select current dropdown option
function InputManager:_select_dropdown()
  if not self._dropdown_open or not self._dropdown_key then return end

  local key = self._dropdown_key
  local dropdown = self.dropdowns[key]
  if not dropdown then return end

  -- Get selected option
  local filtered = self._dropdown_filtered_options or dropdown.options
  local selected_opt = filtered[self._dropdown_selected_idx]

  Debug.log(string.format("DEBUG _select_dropdown: key=%s, idx=%d, opt=%s", key, self._dropdown_selected_idx, selected_opt and selected_opt.value or "nil"))

  if selected_opt then
    -- Compare against ORIGINAL value (from when dropdown opened), not current value
    -- (current value may have been updated by live preview on cursor movement)
    local original_value = self._dropdown_original_value
    self.dropdown_values[key] = selected_opt.value

    Debug.log(string.format("DEBUG _select_dropdown: original=%s, new=%s, callback=%s", tostring(original_value), selected_opt.value, self.on_dropdown_change and "yes" or "NO"))

    -- Callback if value changed from original
    if self.on_dropdown_change and selected_opt.value ~= original_value then
      Debug.log("DEBUG _select_dropdown: Calling on_dropdown_change callback")
      self.on_dropdown_change(key, selected_opt.value)
    elseif not self.on_dropdown_change then
      Debug.log("DEBUG _select_dropdown: No callback set!")
    elseif selected_opt.value == original_value then
      Debug.log("DEBUG _select_dropdown: Value unchanged from original, skipping callback")
    end
  end

  self:_close_dropdown(false)
end

---Render dropdown options
function InputManager:_render_dropdown()
  if not self._dropdown_float or not self._dropdown_float:is_valid() then return end

  -- Build content with ContentBuilder
  local cb = self:_build_dropdown_content()
  local lines = cb:build_lines()

  -- Update lines
  self._dropdown_float:update_lines(lines)

  -- Reapply highlights
  if self._dropdown_ns then
    cb:apply_to_buffer(self._dropdown_float.bufnr, self._dropdown_ns)
  end
end

---Navigate dropdown selection
---@param direction number 1 for down, -1 for up
function InputManager:_navigate_dropdown(direction)
  if not self._dropdown_open then return end

  local filtered = self._dropdown_filtered_options or {}
  if #filtered == 0 then return end

  -- Update selection index
  self._dropdown_selected_idx = self._dropdown_selected_idx + direction

  -- Wrap around
  if self._dropdown_selected_idx < 1 then
    self._dropdown_selected_idx = #filtered
  elseif self._dropdown_selected_idx > #filtered then
    self._dropdown_selected_idx = 1
  end

  -- Move cursor in dropdown window
  if self._dropdown_float and self._dropdown_float:is_valid() then
    self._dropdown_float:set_cursor(self._dropdown_selected_idx, 0)
  end

  -- Live preview: update parent display
  local selected_opt = filtered[self._dropdown_selected_idx]
  if selected_opt and self._dropdown_key then
    self.dropdown_values[self._dropdown_key] = selected_opt.value
    self:_update_dropdown_display(self._dropdown_key)
  end
end

---Filter dropdown options based on typed text
---@param char string Character to add to filter
function InputManager:_filter_dropdown(char)
  if not self._dropdown_open or not self._dropdown_key then return end

  local dropdown = self.dropdowns[self._dropdown_key]
  if not dropdown then return end

  -- Add character to filter
  self._dropdown_filter_text = self._dropdown_filter_text .. char
  local filter_lower = self._dropdown_filter_text:lower()

  -- Filter options
  self._dropdown_filtered_options = {}
  for _, opt in ipairs(dropdown.options) do
    if opt.label:lower():find(filter_lower, 1, true) then
      table.insert(self._dropdown_filtered_options, opt)
    end
  end

  -- Reset selection to first match
  self._dropdown_selected_idx = 1

  -- Re-render
  self:_render_dropdown()

  -- Update window height
  local height = math.min(#self._dropdown_filtered_options, dropdown.max_height or 6)
  height = math.max(height, 1)  -- At least 1 line

  if self._dropdown_float and self._dropdown_float:is_valid() then
    vim.api.nvim_win_set_config(self._dropdown_float.winid, {
      height = height,
    })

    -- Position cursor
    if #self._dropdown_filtered_options > 0 then
      self._dropdown_float:set_cursor(1, 0)

      -- Live preview first match
      local first_opt = self._dropdown_filtered_options[1]
      if first_opt then
        self.dropdown_values[self._dropdown_key] = first_opt.value
        self:_update_dropdown_display(self._dropdown_key)
      end
    end
  end
end

---Clear dropdown filter
function InputManager:_clear_dropdown_filter()
  if not self._dropdown_open or not self._dropdown_key then return end

  local dropdown = self.dropdowns[self._dropdown_key]
  if not dropdown then return end

  self._dropdown_filter_text = ""
  self._dropdown_filtered_options = vim.deepcopy(dropdown.options)
  self._dropdown_selected_idx = 1

  -- Re-render
  self:_render_dropdown()

  -- Update window height
  local height = math.min(#dropdown.options, dropdown.max_height or 6)
  if self._dropdown_float and self._dropdown_float:is_valid() then
    vim.api.nvim_win_set_config(self._dropdown_float.winid, {
      height = height,
    })
    self._dropdown_float:set_cursor(1, 0)
  end
end

---Pad or truncate display text to target width with optional ellipsis
---@param text string Display text
---@param target_width number Target display width
---@return string padded_text
function InputManager:_pad_or_truncate_text(text, target_width)
  local display_len = vim.fn.strdisplaywidth(text)
  if display_len < target_width then
    return text .. string.rep(" ", target_width - display_len)
  elseif display_len > target_width then
    -- Truncate with ellipsis - use vim.fn.strcharpart for proper UTF-8 handling
    local truncated = ""
    local current_width = 0
    local char_idx = 0
    while current_width < target_width - 1 do
      local char = vim.fn.strcharpart(text, char_idx, 1)
      if char == "" then break end
      local char_width = vim.fn.strdisplaywidth(char)
      if current_width + char_width > target_width - 1 then
        break
      end
      truncated = truncated .. char
      current_width = current_width + char_width
      char_idx = char_idx + 1
    end
    -- Pad to exact width and add ellipsis
    local pad_needed = target_width - 1 - vim.fn.strdisplaywidth(truncated)
    if pad_needed > 0 then
      truncated = truncated .. string.rep(" ", pad_needed)
    end
    return truncated .. "…"
  end
  return text
end

---Update dropdown/multi-dropdown display in parent buffer (shared base)
---@param dropdown_type "dropdown"|"multi_dropdown"
---@param key string Field key
---@param display_text string Text to display
---@param is_placeholder boolean Whether showing placeholder
---@param arrow string Arrow character (e.g., " ▼" or " ▾")
function InputManager:_update_dropdown_display_base(dropdown_type, key, display_text, is_placeholder, arrow)
  local field = dropdown_type == "dropdown" and self.dropdowns[key] or self.multi_dropdowns[key]
  if not field then return end

  -- Check if buffer is still valid (may have been replaced by callback)
  if not self.bufnr or not vim.api.nvim_buf_is_valid(self.bufnr) then
    return
  end

  local text_width = field.text_width or 18
  local padded_text = self:_pad_or_truncate_text(display_text, text_width)

  -- Get current line
  local lines = vim.api.nvim_buf_get_lines(self.bufnr, field.line - 1, field.line, false)
  if #lines == 0 then return end

  local line = lines[1]

  -- Find brackets
  local bracket_pos = line:find("%]", field.col_start + 1)
  if not bracket_pos then return end

  -- Reconstruct line
  local before = line:sub(1, field.col_start)
  local after = line:sub(bracket_pos + 1)
  local new_line = before .. padded_text .. arrow .. "]" .. after

  -- Update buffer
  local was_modifiable = vim.api.nvim_buf_get_option(self.bufnr, 'modifiable')
  vim.api.nvim_buf_set_option(self.bufnr, 'modifiable', true)
  vim.api.nvim_buf_set_lines(self.bufnr, field.line - 1, field.line, false, {new_line})
  vim.api.nvim_buf_set_option(self.bufnr, 'modifiable', was_modifiable)

  -- Update placeholder state
  field.is_placeholder = is_placeholder

  -- Update col_end based on new line content (find the closing bracket)
  local new_bracket_pos = new_line:find("%]", field.col_start + 1)
  if new_bracket_pos then
    field.col_end = new_bracket_pos
  end

  -- Re-apply highlights (they get lost when buffer line is replaced)
  local hl_group = is_placeholder and "NvimFloatInputPlaceholder" or "NvimFloatInput"

  -- Clear existing highlights for this line
  vim.api.nvim_buf_clear_namespace(self.bufnr, self._namespace, field.line - 1, field.line)

  -- Highlight the dropdown value area (excluding arrow)
  local arrow_len = 4  -- Both " ▼" and " ▾" are 4 bytes
  vim.api.nvim_buf_add_highlight(
    self.bufnr, self._namespace, hl_group,
    field.line - 1, field.col_start, field.col_end - arrow_len
  )

  -- Arrow always gets hint color
  vim.api.nvim_buf_add_highlight(
    self.bufnr, self._namespace, "NvimFloatHint",
    field.line - 1, field.col_end - arrow_len, field.col_end
  )
end

---Update dropdown display in parent buffer
---@param key string Dropdown key
function InputManager:_update_dropdown_display(key)
  local dropdown = self.dropdowns[key]
  if not dropdown then return end

  local value = self.dropdown_values[key]

  -- Find label for value
  local display_text = dropdown.placeholder or "(select)"
  local is_placeholder = true
  for _, opt in ipairs(dropdown.options) do
    if opt.value == value then
      display_text = opt.label
      is_placeholder = false
      break
    end
  end

  self:_update_dropdown_display_base("dropdown", key, display_text, is_placeholder, " ▼")
end

---Setup keymaps for dropdown window
function InputManager:_setup_dropdown_keymaps()
  if not self._dropdown_float or not self._dropdown_float:is_valid() then return end

  local bufnr = self._dropdown_float.bufnr
  local opts = { buffer = bufnr, noremap = true, silent = true, nowait = true }

  -- Navigation
  vim.keymap.set('n', 'j', function() self:_navigate_dropdown(1) end, opts)
  vim.keymap.set('n', 'k', function() self:_navigate_dropdown(-1) end, opts)
  vim.keymap.set('n', '<Down>', function() self:_navigate_dropdown(1) end, opts)
  vim.keymap.set('n', '<Up>', function() self:_navigate_dropdown(-1) end, opts)

  -- Select
  vim.keymap.set('n', '<CR>', function() self:_select_dropdown() end, opts)

  -- Mouse click: select option under cursor
  vim.keymap.set('n', '<LeftRelease>', function()
    vim.schedule(function()
      -- Get cursor position (1-indexed row)
      local cursor = vim.api.nvim_win_get_cursor(0)
      local row = cursor[1]
      -- Get filtered options (may differ from full options if user typed to filter)
      local dropdown = self.dropdowns[self._dropdown_key]
      local filtered = self._dropdown_filtered_options or (dropdown and dropdown.options or {})
      -- Update selection index and select
      if row >= 1 and row <= #filtered then
        self._dropdown_selected_idx = row
        self:_select_dropdown()
      end
    end)
  end, opts)

  -- Cancel
  vim.keymap.set('n', '<Esc>', function() self:_close_dropdown(true) end, opts)
  vim.keymap.set('n', 'q', function() self:_close_dropdown(true) end, opts)

  -- Note: h/l/w/b etc are NOT mapped so users can scroll horizontally to see long labels

  -- Clear filter
  vim.keymap.set('n', '<BS>', function() self:_clear_dropdown_filter() end, opts)

  -- Type-to-filter: handle printable characters
  -- Skip navigation keys so they work normally for horizontal scrolling
  local skip_chars = {
    j = true, k = true,           -- Vertical navigation
    h = true, l = true,           -- Horizontal navigation
    w = true, b = true, e = true, -- Word navigation
    ['0'] = true, ['$'] = true, ['^'] = true, -- Line navigation
    q = true,                     -- Cancel
  }
  for char_code = 32, 126 do  -- Printable ASCII
    local char = string.char(char_code)
    if not skip_chars[char] then
      vim.keymap.set('n', char, function()
        self:_filter_dropdown(char)
      end, opts)
    end
  end
end

---Setup autocmds for dropdown/multi-dropdown focus-lost detection (shared base)
---@param dropdown_type "dropdown"|"multi_dropdown"
function InputManager:_setup_dropdown_autocmds_base(dropdown_type)
  local float = dropdown_type == "dropdown" and self._dropdown_float or self._multi_dropdown_float
  if not float or not float:is_valid() then return end

  local bufnr = float.bufnr
  local group_name = dropdown_type == "dropdown" and "NvimFloatDropdown_" or "NvimFloatMultiDropdown_"
  local autocmd_group = vim.api.nvim_create_augroup(group_name .. bufnr, { clear = true })

  -- Store autocmd group reference
  if dropdown_type == "dropdown" then
    self._dropdown_autocmd_group = autocmd_group
  else
    self._multi_dropdown_autocmd_group = autocmd_group
  end

  -- Minimum time (ms) after opening before WinLeave/BufLeave can close the dropdown
  local SETTLE_TIME_MS = 150
  local close_method = dropdown_type == "dropdown" and self._close_dropdown or self._close_multi_dropdown
  local debug_prefix = dropdown_type == "dropdown" and "Dropdown" or "Multi-dropdown"

  -- Close on WinLeave (focus lost)
  vim.api.nvim_create_autocmd("WinLeave", {
    group = autocmd_group,
    buffer = bufnr,
    callback = function()
      local elapsed = vim.loop.now() - _dropdown_open_time
      Debug.log(string.format("[DROPDOWN DEBUG] %s WinLeave autocmd fired, elapsed=%dms", debug_prefix, elapsed))

      if elapsed < SETTLE_TIME_MS then
        Debug.log(string.format("[DROPDOWN DEBUG] %s WinLeave IGNORED: within settle period (%dms < %dms)", debug_prefix, elapsed, SETTLE_TIME_MS))
        return
      end

      vim.schedule(function()
        local current_win = vim.api.nvim_get_current_win()
        if current_win ~= self.winid then
          Debug.log(string.format("[DROPDOWN DEBUG] %s WinLeave: closing with cancel=true", debug_prefix))
          close_method(self, true)
        end
      end)
    end,
  })

  -- Close on BufLeave
  vim.api.nvim_create_autocmd("BufLeave", {
    group = autocmd_group,
    buffer = bufnr,
    callback = function()
      local elapsed = vim.loop.now() - _dropdown_open_time
      Debug.log(string.format("[DROPDOWN DEBUG] %s BufLeave autocmd fired, elapsed=%dms", debug_prefix, elapsed))

      if elapsed < SETTLE_TIME_MS then
        Debug.log(string.format("[DROPDOWN DEBUG] %s BufLeave IGNORED: within settle period (%dms < %dms)", debug_prefix, elapsed, SETTLE_TIME_MS))
        return
      end

      vim.schedule(function()
        Debug.log(string.format("[DROPDOWN DEBUG] %s BufLeave: closing with cancel=true", debug_prefix))
        close_method(self, true)
      end)
    end,
  })
end

---Setup autocmds for dropdown focus-lost detection
function InputManager:_setup_dropdown_autocmds()
  self:_setup_dropdown_autocmds_base("dropdown")
end

---Get dropdown value
---@param key string Dropdown key
---@return string? value
function InputManager:get_dropdown_value(key)
  return self.dropdown_values[key]
end

---Set dropdown value
---@param key string Dropdown key
---@param value string New value
function InputManager:set_dropdown_value(key, value)
  local dropdown = self.dropdowns[key]
  if not dropdown then return end

  self.dropdown_values[key] = value
  self:_update_dropdown_display(key)
end

-- ============================================================================
-- Multi-Dropdown Methods
-- ============================================================================

---Open multi-dropdown window
---@param key string Multi-dropdown key
function InputManager:_open_multi_dropdown(key)
  Debug.log(string.format("[DROPDOWN DEBUG] _open_multi_dropdown CALLED for key=%s, global_cooldown=%s, opening=%s", key, tostring(_global_dropdown_close_cooldown), tostring(_dropdown_opening)))

  -- Prevent opening while another dropdown is still being opened
  if _dropdown_opening then
    Debug.log("[DROPDOWN DEBUG] _open_multi_dropdown BLOCKED: another dropdown is being opened")
    return
  end

  local multi_dropdown = self.multi_dropdowns[key]
  if not multi_dropdown then
    Debug.log(string.format("[DROPDOWN DEBUG] _open_multi_dropdown: multi_dropdown '%s' not found!", key))
    return
  end

  -- Set opening flag and timestamp to prevent premature close
  _dropdown_opening = true
  _dropdown_open_time = vim.loop.now()
  _any_dropdown_open = true
  Debug.log(string.format("[DROPDOWN DEBUG] _open_multi_dropdown: open_time set to %d", _dropdown_open_time))

  -- Store original values for cancel
  self._multi_dropdown_original_values = vim.deepcopy(self.multi_dropdown_values[key] or {})
  self._multi_dropdown_pending_values = vim.deepcopy(self._multi_dropdown_original_values)
  self._multi_dropdown_key = key
  self._multi_dropdown_open = true
  self._multi_dropdown_cursor_idx = 1

  -- Calculate window position
  local win_info = vim.fn.getwininfo(self.winid)[1]
  if not win_info then return end

  local parent_row = win_info.winrow
  local parent_col = win_info.wincol

  local dropdown_row = parent_row + multi_dropdown.line
  local dropdown_col = parent_col + multi_dropdown.col_start - 1

  -- Calculate dimensions
  local width = (multi_dropdown.text_width or multi_dropdown.width) + 4  -- Extra space for checkbox
  local option_count = #multi_dropdown.options
  if multi_dropdown.select_all_option then
    option_count = option_count + 2  -- "Select All" + separator
  end
  local height = math.min(option_count, multi_dropdown.max_height or 8)

  -- Build content
  local cb = self:_build_multi_dropdown_content()
  local lines = cb:build_lines()

  -- Create float
  local UiFloat = require('nvim-float.float')
  self._multi_dropdown_float = UiFloat.create(lines, {
    centered = false,
    relative = "editor",
    row = dropdown_row,
    col = dropdown_col,
    width = width,
    height = height,
    border = "rounded",
    zindex = UiFloat.ZINDEX.DROPDOWN,
    cursorline = true,
    focusable = true,
    enter = true,
    wrap = false,
    default_keymaps = false,
    scrollbar = true,
  })

  if not self._multi_dropdown_float or not self._multi_dropdown_float:is_valid() then
    self._multi_dropdown_open = false
    self._multi_dropdown_key = nil
    _dropdown_opening = false  -- Reset opening flag on failure
    return
  end

  -- Apply highlights
  self._multi_dropdown_ns = vim.api.nvim_create_namespace("nvim_float_multi_dropdown_content")
  cb:apply_to_buffer(self._multi_dropdown_float.bufnr, self._multi_dropdown_ns)

  -- Position cursor
  self._multi_dropdown_float:set_cursor(1, 0)

  -- Setup keymaps and autocmds
  self:_setup_multi_dropdown_keymaps()
  self:_setup_multi_dropdown_autocmds()

  -- Clear opening flag after a short delay to allow dropdown to settle
  vim.defer_fn(function()
    _dropdown_opening = false
    Debug.log("[DROPDOWN DEBUG] Multi-dropdown opening flag CLEARED (50ms elapsed)")
  end, 50)
end

---Build multi-dropdown content using ContentBuilder
---@return ContentBuilder cb
function InputManager:_build_multi_dropdown_content()
  local ContentBuilder = require('nvim-float.content_builder')
  local cb = ContentBuilder.new()

  local key = self._multi_dropdown_key
  local multi_dropdown = self.multi_dropdowns[key]
  if not multi_dropdown then return cb end

  local pending = self._multi_dropdown_pending_values or {}
  local options = multi_dropdown.options

  -- Helper to check if value is selected
  local function is_selected(value)
    for _, v in ipairs(pending) do
      if v == value then return true end
    end
    return false
  end

  -- Calculate max label width
  local max_label_len = 0
  for _, opt in ipairs(options) do
    max_label_len = math.max(max_label_len, #opt.label)
  end
  if multi_dropdown.select_all_option then
    max_label_len = math.max(max_label_len, 10)  -- "Select All"
  end

  -- Add "Select All" option if enabled
  if multi_dropdown.select_all_option then
    local all_selected = (#pending == #options)
    local checkbox = all_selected and "[x]" or "[ ]"
    local label = "Select All"
    local padded = label .. string.rep(" ", max_label_len - #label)

    cb:spans({
      { text = " " .. checkbox .. " ", style = all_selected and "success" or "muted" },
      { text = padded, style = "emphasis" },
    })

    -- Separator
    cb:styled(" " .. string.rep("─", max_label_len + 4), "muted")
  end

  -- Add options
  for _, opt in ipairs(options) do
    local selected = is_selected(opt.value)
    local checkbox = selected and "[x]" or "[ ]"
    local padded = opt.label .. string.rep(" ", max_label_len - #opt.label)

    cb:spans({
      { text = " " .. checkbox .. " ", style = selected and "success" or "muted" },
      { text = padded, style = selected and "value" or "normal" },
    })
  end

  return cb
end

---Render multi-dropdown content
function InputManager:_render_multi_dropdown()
  if not self._multi_dropdown_float or not self._multi_dropdown_float:is_valid() then return end

  local cb = self:_build_multi_dropdown_content()
  local lines = cb:build_lines()

  self._multi_dropdown_float:update_lines(lines)

  if self._multi_dropdown_ns then
    cb:apply_to_buffer(self._multi_dropdown_float.bufnr, self._multi_dropdown_ns)
  end
end

---Close multi-dropdown window
---@param cancel boolean Whether to cancel (restore original values)
function InputManager:_close_multi_dropdown(cancel)
  Debug.log(string.format("[DROPDOWN DEBUG] _close_multi_dropdown called, cancel=%s, open=%s", tostring(cancel), tostring(self._multi_dropdown_open)))
  if not self._multi_dropdown_open then return end

  -- Clear opening flag in case close is called during opening phase
  _dropdown_opening = false
  _any_dropdown_open = false

  local key = self._multi_dropdown_key

  -- Cancel = restore original values
  if cancel and key and self._multi_dropdown_original_values then
    self.multi_dropdown_values[key] = vim.deepcopy(self._multi_dropdown_original_values)
  end

  -- Clean up autocmds
  if self._multi_dropdown_autocmd_group then
    pcall(vim.api.nvim_del_augroup_by_id, self._multi_dropdown_autocmd_group)
    self._multi_dropdown_autocmd_group = nil
  end

  -- Close float
  if self._multi_dropdown_float then
    pcall(function() self._multi_dropdown_float:close() end)
  end

  -- Reset state
  self._multi_dropdown_open = false
  self._multi_dropdown_key = nil
  self._multi_dropdown_float = nil
  self._multi_dropdown_ns = nil
  self._multi_dropdown_cursor_idx = 1
  self._multi_dropdown_original_values = nil
  self._multi_dropdown_pending_values = nil

  -- Set global cooldown to prevent immediate re-open from mouse click on ANY panel
  _global_dropdown_close_cooldown = true
  Debug.log("[DROPDOWN DEBUG] Multi-dropdown global cooldown SET to true")
  vim.defer_fn(function()
    _global_dropdown_close_cooldown = false
    Debug.log("[DROPDOWN DEBUG] Multi-dropdown global cooldown RESET to false (200ms elapsed)")
  end, 200)

  -- Return focus to parent
  if vim.api.nvim_win_is_valid(self.winid) then
    vim.api.nvim_set_current_win(self.winid)
  end

  -- Re-highlight current field
  if key then
    self:_highlight_current_field(key)
  end
end

---Confirm multi-dropdown selection
function InputManager:_confirm_multi_dropdown()
  if not self._multi_dropdown_open or not self._multi_dropdown_key then return end

  local key = self._multi_dropdown_key
  local old_values = vim.deepcopy(self.multi_dropdown_values[key] or {})

  -- Apply pending values
  self.multi_dropdown_values[key] = vim.deepcopy(self._multi_dropdown_pending_values or {})

  -- Update parent display
  self:_update_multi_dropdown_display(key)

  -- Callback if changed
  if self.on_multi_dropdown_change then
    local new_values = self.multi_dropdown_values[key]
    -- Check if values changed
    local changed = (#old_values ~= #new_values)
    if not changed then
      for i, v in ipairs(old_values) do
        if new_values[i] ~= v then
          changed = true
          break
        end
      end
    end
    if changed then
      self.on_multi_dropdown_change(key, new_values)
    end
  end

  self:_close_multi_dropdown(false)
end

---Toggle option at current cursor position
function InputManager:_toggle_multi_dropdown_option()
  if not self._multi_dropdown_open or not self._multi_dropdown_key then return end

  local multi_dropdown = self.multi_dropdowns[self._multi_dropdown_key]
  if not multi_dropdown then return end

  local cursor_idx = self._multi_dropdown_cursor_idx
  local has_select_all = multi_dropdown.select_all_option

  -- Determine which option is being toggled
  if has_select_all then
    if cursor_idx == 1 then
      -- Toggle "Select All"
      self:_toggle_select_all_multi_dropdown()
      return
    elseif cursor_idx == 2 then
      -- Separator line, do nothing
      return
    else
      -- Adjust for header rows
      cursor_idx = cursor_idx - 2
    end
  end

  -- Get the option
  local opt = multi_dropdown.options[cursor_idx]
  if not opt then return end

  -- Toggle selection
  local pending = self._multi_dropdown_pending_values or {}
  local found_idx = nil
  for i, v in ipairs(pending) do
    if v == opt.value then
      found_idx = i
      break
    end
  end

  if found_idx then
    table.remove(pending, found_idx)
  else
    table.insert(pending, opt.value)
  end

  self._multi_dropdown_pending_values = pending

  -- Re-render
  self:_render_multi_dropdown()
end

---Toggle select all
function InputManager:_toggle_select_all_multi_dropdown()
  if not self._multi_dropdown_open or not self._multi_dropdown_key then return end

  local multi_dropdown = self.multi_dropdowns[self._multi_dropdown_key]
  if not multi_dropdown then return end

  local pending = self._multi_dropdown_pending_values or {}
  local all_selected = (#pending == #multi_dropdown.options)

  if all_selected then
    -- Deselect all
    self._multi_dropdown_pending_values = {}
  else
    -- Select all
    self._multi_dropdown_pending_values = {}
    for _, opt in ipairs(multi_dropdown.options) do
      table.insert(self._multi_dropdown_pending_values, opt.value)
    end
  end

  -- Re-render
  self:_render_multi_dropdown()
end

---Navigate multi-dropdown
---@param direction number 1 for down, -1 for up
function InputManager:_navigate_multi_dropdown(direction)
  if not self._multi_dropdown_open then return end

  local multi_dropdown = self.multi_dropdowns[self._multi_dropdown_key]
  if not multi_dropdown then return end

  -- Calculate total lines
  local total_lines = #multi_dropdown.options
  if multi_dropdown.select_all_option then
    total_lines = total_lines + 2  -- Select All + separator
  end

  -- Update cursor
  self._multi_dropdown_cursor_idx = self._multi_dropdown_cursor_idx + direction

  -- Skip separator line
  if multi_dropdown.select_all_option and self._multi_dropdown_cursor_idx == 2 then
    self._multi_dropdown_cursor_idx = self._multi_dropdown_cursor_idx + direction
  end

  -- Wrap around
  if self._multi_dropdown_cursor_idx < 1 then
    self._multi_dropdown_cursor_idx = total_lines
  elseif self._multi_dropdown_cursor_idx > total_lines then
    self._multi_dropdown_cursor_idx = 1
  end

  -- Move cursor in window
  if self._multi_dropdown_float and self._multi_dropdown_float:is_valid() then
    self._multi_dropdown_float:set_cursor(self._multi_dropdown_cursor_idx, 0)
  end
end

---Update multi-dropdown display in parent buffer
---@param key string Multi-dropdown key
function InputManager:_update_multi_dropdown_display(key)
  local multi_dropdown = self.multi_dropdowns[key]
  if not multi_dropdown then return end

  local values = self.multi_dropdown_values[key] or {}

  -- Build display text
  local display_text
  local is_placeholder = (#values == 0)

  if #values == 0 then
    display_text = multi_dropdown.placeholder or "(none selected)"
  elseif multi_dropdown.display_mode == "list" then
    local labels = {}
    for _, v in ipairs(values) do
      for _, opt in ipairs(multi_dropdown.options) do
        if opt.value == v then
          table.insert(labels, opt.label)
          break
        end
      end
    end
    display_text = table.concat(labels, ", ")
  else  -- "count" mode
    if #values == #multi_dropdown.options then
      display_text = "All (" .. #values .. ")"
    else
      display_text = #values .. " selected"
    end
  end

  self:_update_dropdown_display_base("multi_dropdown", key, display_text, is_placeholder, " ▾")
end

---Setup keymaps for multi-dropdown
function InputManager:_setup_multi_dropdown_keymaps()
  if not self._multi_dropdown_float or not self._multi_dropdown_float:is_valid() then return end

  local bufnr = self._multi_dropdown_float.bufnr
  local opts = { buffer = bufnr, noremap = true, silent = true, nowait = true }

  -- Navigation
  vim.keymap.set('n', 'j', function() self:_navigate_multi_dropdown(1) end, opts)
  vim.keymap.set('n', 'k', function() self:_navigate_multi_dropdown(-1) end, opts)
  vim.keymap.set('n', '<Down>', function() self:_navigate_multi_dropdown(1) end, opts)
  vim.keymap.set('n', '<Up>', function() self:_navigate_multi_dropdown(-1) end, opts)

  -- Toggle selection
  vim.keymap.set('n', '<Space>', function() self:_toggle_multi_dropdown_option() end, opts)
  vim.keymap.set('n', 'x', function() self:_toggle_multi_dropdown_option() end, opts)

  -- Mouse click: toggle option under cursor and auto-apply
  vim.keymap.set('n', '<LeftRelease>', function()
    vim.schedule(function()
      -- Get cursor position (1-indexed row)
      local cursor = vim.api.nvim_win_get_cursor(0)
      local row = cursor[1]
      -- Calculate max row (accounting for "Select All" + separator rows if present)
      local multi_dropdown = self.multi_dropdowns[self._multi_dropdown_key]
      if not multi_dropdown then return end

      local has_select_all = multi_dropdown.select_all_option
      -- When select_all_option is true: row 1 = Select All, row 2 = separator, rows 3+ = options
      local header_rows = has_select_all and 2 or 0
      local max_row = #multi_dropdown.options + header_rows

      if row >= 1 and row <= max_row then
        -- Update cursor index (used by _toggle_multi_dropdown_option)
        self._multi_dropdown_cursor_idx = row
        self:_toggle_multi_dropdown_option()

        -- Auto-apply: immediately save pending values so clicking away keeps changes
        local key = self._multi_dropdown_key
        if key then
          local old_values = vim.deepcopy(self.multi_dropdown_values[key] or {})
          self.multi_dropdown_values[key] = vim.deepcopy(self._multi_dropdown_pending_values or {})

          -- Also update original values so WinLeave close doesn't revert
          self._multi_dropdown_original_values = vim.deepcopy(self._multi_dropdown_pending_values or {})

          -- Update parent display
          self:_update_multi_dropdown_display(key)

          -- Callback if changed
          if self.on_multi_dropdown_change then
            local new_values = self.multi_dropdown_values[key]
            local changed = (#old_values ~= #new_values)
            if not changed then
              for i, v in ipairs(old_values) do
                if new_values[i] ~= v then
                  changed = true
                  break
                end
              end
            end
            if changed then
              self.on_multi_dropdown_change(key, new_values)
            end
          end
        end
      end
    end)
  end, opts)

  -- Select all
  vim.keymap.set('n', 'a', function() self:_toggle_select_all_multi_dropdown() end, opts)

  -- Confirm
  vim.keymap.set('n', '<CR>', function() self:_confirm_multi_dropdown() end, opts)

  -- Cancel
  vim.keymap.set('n', '<Esc>', function() self:_close_multi_dropdown(true) end, opts)
  vim.keymap.set('n', 'q', function() self:_close_multi_dropdown(true) end, opts)
end

---Setup autocmds for multi-dropdown
function InputManager:_setup_multi_dropdown_autocmds()
  self:_setup_dropdown_autocmds_base("multi_dropdown")
end

---Get multi-dropdown values
---@param key string Multi-dropdown key
---@return string[]? values
function InputManager:get_multi_dropdown_values(key)
  return self.multi_dropdown_values[key]
end

---Set multi-dropdown values
---@param key string Multi-dropdown key
---@param values string[] New values
function InputManager:set_multi_dropdown_values(key, values)
  local multi_dropdown = self.multi_dropdowns[key]
  if not multi_dropdown then return end

  self.multi_dropdown_values[key] = vim.deepcopy(values)
  self:_update_multi_dropdown_display(key)
end

---Cleanup the input manager
function InputManager:destroy()
  -- Close any open dropdown first
  if self._dropdown_open then
    self:_close_dropdown(true)
  end

  -- Close any open multi-dropdown
  if self._multi_dropdown_open then
    self:_close_multi_dropdown(true)
  end

  -- Cancel any pending text change timer
  if self._text_changed_timer then
    vim.fn.timer_stop(self._text_changed_timer)
    self._text_changed_timer = nil
  end

  if self._autocmd_group then
    pcall(vim.api.nvim_del_augroup_by_id, self._autocmd_group)
  end

  if vim.api.nvim_buf_is_valid(self.bufnr) then
    vim.api.nvim_buf_clear_namespace(self.bufnr, self._namespace, 0, -1)
  end
end

return InputManager
