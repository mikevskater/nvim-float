---@module 'nvim-float.container.virtual_manager'
---@brief VirtualContainerManager - Orchestrates all virtual containers
---
---Manages the lifecycle of virtual containers: creation, activation/deactivation,
---CursorMoved-based activation (for input types), explicit activation (for
---generic containers), Tab navigation, and unified value API.
---At most 1 container is materialized (has a real window) at any time.

local VirtualContainer = require("nvim-float.container.virtual")
local WindowPool = require("nvim-float.container.window_pool")

---@class VirtualContainerManager
---@field _parent_float FloatWindow
---@field _virtuals table<string, VirtualContainer>
---@field _field_order {type: string, key: string}[]
---@field _active_name string|nil Currently materialized container name
---@field _cursor_autocmd_id number|nil CursorMoved autocmd ID
---@field _pool WindowPool Reusable buffer pool
---@field _nav_augroup number|nil Augroup for navigation autocmds
---@field _activating boolean Guard against reentrant activation
local VirtualContainerManager = {}
VirtualContainerManager.__index = VirtualContainerManager

-- ============================================================================
-- Constructor
-- ============================================================================

---Create a new VirtualContainerManager
---@param parent_float FloatWindow
---@return VirtualContainerManager
function VirtualContainerManager.new(parent_float)
  local self = setmetatable({}, VirtualContainerManager)
  self._parent_float = parent_float
  self._virtuals = {}
  self._field_order = {}
  self._active_name = nil
  self._cursor_autocmd_id = nil
  self._pool = WindowPool.new()
  self._nav_augroup = nil
  self._activating = false
  self._pending_cursor = false
  self._pending_render = false
  return self
end

-- ============================================================================
-- Add Definitions
-- ============================================================================

---Add a virtual container from a ContentBuilder definition
---@param name string Field key
---@param def table Container definition from ContentBuilder
function VirtualContainerManager:add_from_definition(name, def)
  local vc = VirtualContainer.new(name, def, self._parent_float)
  self._virtuals[name] = vc
  table.insert(self._field_order, { type = def.type, key = name })
end

-- ============================================================================
-- Activation / Deactivation
-- ============================================================================

---Activate a virtual container (materialize it as a real window).
---Deactivates the currently active container first if different.
---@param name string Container name to activate
function VirtualContainerManager:activate(name)
  if self._activating then return end

  local vc = self._virtuals[name]
  if not vc then return end

  -- Skip if already active
  if name == self._active_name then return end

  -- Guard: skip if a dropdown list is currently open
  if self._active_name then
    local active_vc = self._virtuals[self._active_name]
    if active_vc and active_vc:is_list_open() then
      return
    end
  end

  self._activating = true

  -- Deactivate current
  if self._active_name then
    self:_deactivate_internal()
  end

  self._active_name = name

  -- Materialize the new container
  vc:materialize(function()
    -- On Esc: deactivate and return to parent
    self:deactivate()
  end)

  -- Focus the real field
  if vc:get_real_field() then
    local container = vc:get_container()
    if container and container:is_valid() then
      if vc.type == "embedded_input" then
        -- Focus the window directly (don't trigger auto-insert)
        vim.api.nvim_set_current_win(container.winid)
        container._focused = true
      elseif vc.type == "container" then
        -- Focus the EmbeddedContainer directly
        container:focus()
      else
        vc:get_real_field():focus()
      end
    end
  end

  -- Setup exit keymaps on the real container for navigation
  if vc.type == "container" then
    self:_setup_container_exit_keymaps(vc)
  else
    self:_setup_active_exit_keymaps(vc)
  end

  self._activating = false
end

---Deactivate the currently active container (dematerialize it).
function VirtualContainerManager:deactivate()
  if self._activating then return end

  self._activating = true
  self:_deactivate_internal()

  -- Return focus to parent
  local fw = self._parent_float
  if fw and fw:is_valid() then
    pcall(vim.api.nvim_set_current_win, fw.winid)
  end

  self._activating = false
end

---Internal deactivation (no focus change, no guard)
function VirtualContainerManager:_deactivate_internal()
  if not self._active_name then return end

  local vc = self._virtuals[self._active_name]
  if vc then
    -- For inputs, exit edit mode before dematerializing
    if vc.type == "embedded_input" and vc:get_real_field() then
      pcall(function() vc:get_real_field():exit_edit() end)
    end
    vc:dematerialize()
  end

  self._active_name = nil
end

-- ============================================================================
-- Navigation
-- ============================================================================

---Focus the next field in order (Tab)
function VirtualContainerManager:focus_next()
  if #self._field_order == 0 then return end

  local current_idx = 0
  if self._active_name then
    for i, entry in ipairs(self._field_order) do
      if entry.key == self._active_name then
        current_idx = i
        break
      end
    end
  end

  local next_idx = (current_idx % #self._field_order) + 1
  local next_entry = self._field_order[next_idx]
  if next_entry then
    self:activate(next_entry.key)
  end
end

---Focus the previous field in order (Shift+Tab)
function VirtualContainerManager:focus_prev()
  if #self._field_order == 0 then return end

  local current_idx = 0
  if self._active_name then
    for i, entry in ipairs(self._field_order) do
      if entry.key == self._active_name then
        current_idx = i
        break
      end
    end
  end

  local prev_idx = ((current_idx - 2) % #self._field_order) + 1
  local prev_entry = self._field_order[prev_idx]
  if prev_entry then
    self:activate(prev_entry.key)
  end
end

-- ============================================================================
-- CursorMoved Tracking
-- ============================================================================

---Setup CursorMoved autocmd on parent buffer to detect cursor entering container regions.
function VirtualContainerManager:setup_cursor_tracking()
  local fw = self._parent_float
  if not fw or not fw:is_valid() then return end

  self._nav_augroup = vim.api.nvim_create_augroup(
    "nvim_float_virtual_nav_" .. fw.bufnr, { clear = true })

  -- CursorMoved handler: activate when cursor lands on an input-type container's region
  vim.api.nvim_create_autocmd("CursorMoved", {
    group = self._nav_augroup,
    buffer = fw.bufnr,
    callback = function()
      if self._pending_cursor then return end
      self._pending_cursor = true
      vim.schedule(function()
        self._pending_cursor = false
        if self._activating then return end
        if not fw:is_valid() then return end

        local cursor = vim.api.nvim_win_get_cursor(fw.winid)
        local row0 = cursor[1] - 1
        local col0 = cursor[2]

        -- Convert byte col to display col for region matching
        local line = vim.api.nvim_buf_get_lines(fw.bufnr, row0, row0 + 1, false)[1] or ""
        local dcol = vim.fn.strdisplaywidth(line:sub(1, col0))

        local target = self:_find_virtual_at(row0, dcol)
        if target and target.name ~= self._active_name then
          self:activate(target.name)
        elseif not target and self._active_name then
          -- Only auto-deactivate input-type fields, not generic containers
          local active_vc = self._virtuals[self._active_name]
          if active_vc and active_vc.type ~= "container" then
            self:deactivate()
          end
        end
      end)
    end,
  })

  -- Tab / Shift-Tab for field navigation on parent buffer
  local opts = { buffer = fw.bufnr, noremap = true, silent = true }
  vim.keymap.set('n', '<Tab>', function()
    self:focus_next()
  end, vim.tbl_extend('force', opts, { desc = "Next virtual field" }))

  vim.keymap.set('n', '<S-Tab>', function()
    self:focus_prev()
  end, vim.tbl_extend('force', opts, { desc = "Previous virtual field" }))
end

---Find which input-type virtual container (if any) covers the given position.
---Skips generic containers (type=="container") since they require explicit activation.
---@param row0 number 0-indexed row
---@param dcol number 0-indexed display column
---@return VirtualContainer|nil
function VirtualContainerManager:_find_virtual_at(row0, dcol)
  for _, vc in pairs(self._virtuals) do
    -- Skip generic containers: they use explicit activation, not CursorMoved
    if vc.type ~= "container" then
      if row0 == vc._row and dcol >= vc._col and dcol < vc._col + vc._width then
        return vc
      end
    end
  end
  return nil
end

---Find which generic container (type=="container") covers the given position.
---Multi-line hit test: checks if cursor is within the container's row/col bounds.
---@param row0 number 0-indexed row
---@param dcol number 0-indexed display column
---@return VirtualContainer|nil
function VirtualContainerManager:find_container_at(row0, dcol)
  for _, vc in pairs(self._virtuals) do
    if vc.type == "container" then
      if row0 >= vc._row and row0 < vc._row + vc._height
        and dcol >= vc._col and dcol < vc._col + vc._width then
        return vc
      end
    end
  end
  return nil
end

-- ============================================================================
-- Exit Keymaps on Active Container (input/dropdown types)
-- ============================================================================

---Setup exit keymaps (hjkl, Esc) on a materialized input-type container.
---For single-line fields, j/k always exit the field.
---@param vc VirtualContainer
function VirtualContainerManager:_setup_active_exit_keymaps(vc)
  local container = vc:get_container()
  if not container or not container:is_valid() then return end

  local bufnr = container.bufnr
  local opts = { buffer = bufnr, noremap = true, silent = true }
  local fw = self._parent_float

  -- Tab / Shift-Tab for cycling between fields
  vim.keymap.set('n', '<Tab>', function()
    self:focus_next()
  end, vim.tbl_extend('force', opts, { desc = "Next virtual field" }))

  vim.keymap.set('n', '<S-Tab>', function()
    self:focus_prev()
  end, vim.tbl_extend('force', opts, { desc = "Previous virtual field" }))

  -- Close parent UI from active container
  if fw.config.default_keymaps then
    vim.keymap.set('n', 'q', function()
      self:deactivate()
      fw:close()
    end, opts)
  end

  -- Up/Down keymaps: deactivate and return cursor to parent at appropriate position
  vim.keymap.set('n', 'k', function()
    if not container:is_valid() then return end
    -- Exit upward: go to row above container
    local target_row0 = vc._row - 1
    self:deactivate()
    if fw:is_valid() and target_row0 >= 0 then
      local line_count = vim.api.nvim_buf_line_count(fw.bufnr)
      target_row0 = math.min(target_row0, line_count - 1)
      pcall(vim.api.nvim_win_set_cursor, fw.winid, { target_row0 + 1, vc._col })
    end
  end, opts)

  vim.keymap.set('n', 'j', function()
    if not container:is_valid() then return end
    -- Exit downward: go to row below container
    local target_row0 = vc._row + 1
    self:deactivate()
    if fw:is_valid() then
      local line_count = vim.api.nvim_buf_line_count(fw.bufnr)
      target_row0 = math.min(target_row0, line_count - 1)
      pcall(vim.api.nvim_win_set_cursor, fw.winid, { target_row0 + 1, vc._col })
    end
  end, opts)

  vim.keymap.set('n', '<Up>', function()
    if not container:is_valid() then return end
    local target_row0 = vc._row - 1
    self:deactivate()
    if fw:is_valid() and target_row0 >= 0 then
      local line_count = vim.api.nvim_buf_line_count(fw.bufnr)
      target_row0 = math.min(target_row0, line_count - 1)
      pcall(vim.api.nvim_win_set_cursor, fw.winid, { target_row0 + 1, vc._col })
    end
  end, opts)

  vim.keymap.set('n', '<Down>', function()
    if not container:is_valid() then return end
    local target_row0 = vc._row + 1
    self:deactivate()
    if fw:is_valid() then
      local line_count = vim.api.nvim_buf_line_count(fw.bufnr)
      target_row0 = math.min(target_row0, line_count - 1)
      pcall(vim.api.nvim_win_set_cursor, fw.winid, { target_row0 + 1, vc._col })
    end
  end, opts)
end

-- ============================================================================
-- Exit Keymaps on Active Container (generic container type)
-- ============================================================================

---Setup exit keymaps on a materialized generic container.
---j/k navigate internally; only exit at first/last line boundary.
---@param vc VirtualContainer
function VirtualContainerManager:_setup_container_exit_keymaps(vc)
  local container = vc:get_container()
  if not container or not container:is_valid() then return end

  local bufnr = container.bufnr
  local opts = { buffer = bufnr, noremap = true, silent = true }
  local fw = self._parent_float

  -- Tab / Shift-Tab for cycling between fields
  vim.keymap.set('n', '<Tab>', function()
    self:focus_next()
  end, vim.tbl_extend('force', opts, { desc = "Next virtual field" }))

  vim.keymap.set('n', '<S-Tab>', function()
    self:focus_prev()
  end, vim.tbl_extend('force', opts, { desc = "Previous virtual field" }))

  -- Close parent UI
  if fw.config.default_keymaps then
    vim.keymap.set('n', 'q', function()
      self:deactivate()
      fw:close()
    end, opts)
  end

  -- j: move down within container, exit at bottom boundary
  vim.keymap.set('n', 'j', function()
    if not container:is_valid() then return end
    local cursor = vim.api.nvim_win_get_cursor(container.winid)
    local total_lines = vim.api.nvim_buf_line_count(container.bufnr)
    if cursor[1] >= total_lines then
      -- At last line: exit downward past the container
      local target_row0 = vc._row + vc._height
      self:deactivate()
      if fw:is_valid() then
        local line_count = vim.api.nvim_buf_line_count(fw.bufnr)
        target_row0 = math.min(target_row0, line_count - 1)
        pcall(vim.api.nvim_win_set_cursor, fw.winid, { target_row0 + 1, vc._col })
      end
    else
      -- Normal j within container
      vim.cmd("normal! j")
    end
  end, opts)

  -- k: move up within container, exit at top boundary
  vim.keymap.set('n', 'k', function()
    if not container:is_valid() then return end
    local cursor = vim.api.nvim_win_get_cursor(container.winid)
    if cursor[1] <= 1 then
      -- At first line: exit upward above the container
      local target_row0 = vc._row - 1
      self:deactivate()
      if fw:is_valid() and target_row0 >= 0 then
        local line_count = vim.api.nvim_buf_line_count(fw.bufnr)
        target_row0 = math.min(target_row0, line_count - 1)
        pcall(vim.api.nvim_win_set_cursor, fw.winid, { target_row0 + 1, vc._col })
      end
    else
      -- Normal k within container
      vim.cmd("normal! k")
    end
  end, opts)

  -- Arrow keys: same boundary behavior
  vim.keymap.set('n', '<Down>', function()
    if not container:is_valid() then return end
    local cursor = vim.api.nvim_win_get_cursor(container.winid)
    local total_lines = vim.api.nvim_buf_line_count(container.bufnr)
    if cursor[1] >= total_lines then
      local target_row0 = vc._row + vc._height
      self:deactivate()
      if fw:is_valid() then
        local line_count = vim.api.nvim_buf_line_count(fw.bufnr)
        target_row0 = math.min(target_row0, line_count - 1)
        pcall(vim.api.nvim_win_set_cursor, fw.winid, { target_row0 + 1, vc._col })
      end
    else
      vim.cmd("normal! j")
    end
  end, opts)

  vim.keymap.set('n', '<Up>', function()
    if not container:is_valid() then return end
    local cursor = vim.api.nvim_win_get_cursor(container.winid)
    if cursor[1] <= 1 then
      local target_row0 = vc._row - 1
      self:deactivate()
      if fw:is_valid() and target_row0 >= 0 then
        local line_count = vim.api.nvim_buf_line_count(fw.bufnr)
        target_row0 = math.min(target_row0, line_count - 1)
        pcall(vim.api.nvim_win_set_cursor, fw.winid, { target_row0 + 1, vc._col })
      end
    else
      vim.cmd("normal! k")
    end
  end, opts)
end

-- ============================================================================
-- Value API
-- ============================================================================

---Get a value by key
---@param key string
---@return string|string[]|nil
function VirtualContainerManager:get_value(key)
  local vc = self._virtuals[key]
  if vc then
    return vc:get_value()
  end
  return nil
end

---Set a value by key
---@param key string
---@param value string|string[]
function VirtualContainerManager:set_value(key, value)
  local vc = self._virtuals[key]
  if vc then
    vc:set_value(value)
  end
end

---Get all values as a map
---@return table<string, string|string[]>
function VirtualContainerManager:get_all_values()
  local values = {}
  for key, vc in pairs(self._virtuals) do
    values[key] = vc:get_value()
  end
  return values
end

-- ============================================================================
-- Rendering
-- ============================================================================

---Render virtual containers as text in the parent buffer.
---@param force? boolean If true, render all regardless of dirty state (for initial render)
function VirtualContainerManager:render_all_virtual(force)
  for _, vc in pairs(self._virtuals) do
    if not vc._materialized and (force or vc:is_dirty()) then
      vc:render_virtual()
    end
  end
end

---Scheduled variant that only re-renders dirty containers.
---Coalesces rapid-fire calls so only the final state is rendered.
function VirtualContainerManager:render_all_virtual_async()
  if self._pending_render then return end
  self._pending_render = true
  vim.schedule(function()
    self._pending_render = false
    local fw = self._parent_float
    if not fw or not vim.api.nvim_buf_is_valid(fw.bufnr) then return end
    self:render_all_virtual()
  end)
end

-- ============================================================================
-- Query
-- ============================================================================

---Get the currently active virtual container
---@return VirtualContainer|nil
function VirtualContainerManager:get_active()
  if self._active_name then
    return self._virtuals[self._active_name]
  end
  return nil
end

---Get a virtual container by name
---@param name string
---@return VirtualContainer|nil
function VirtualContainerManager:get(name)
  return self._virtuals[name]
end

---Get the field order
---@return {type: string, key: string}[]
function VirtualContainerManager:get_field_order()
  return self._field_order
end

---Get all virtual container names
---@return string[]
function VirtualContainerManager:get_names()
  local names = {}
  for _, entry in ipairs(self._field_order) do
    table.insert(names, entry.key)
  end
  return names
end

---Get the number of virtual containers
---@return number
function VirtualContainerManager:count()
  return #self._field_order
end

-- ============================================================================
-- Cleanup
-- ============================================================================

---Close all virtual containers and clean up resources
function VirtualContainerManager:close_all()
  -- Deactivate first (closes real window)
  if self._active_name then
    self:_deactivate_internal()
  end

  -- Close all virtual containers
  for _, vc in pairs(self._virtuals) do
    vc:close()
  end

  -- Clean up autocmds
  if self._nav_augroup then
    pcall(vim.api.nvim_del_augroup_by_id, self._nav_augroup)
    self._nav_augroup = nil
  end

  -- Drain pool
  self._pool:drain()

  self._virtuals = {}
  self._field_order = {}
  self._active_name = nil
end

return VirtualContainerManager
