---@module 'nvim-float.container.navigation'
---@brief Seamless vim-motion navigation between parent and container windows
---
---Enables spatial navigation via hjkl (and user-remapped keys) between a parent
---FloatWindow and its embedded containers (inputs, dropdowns, multi-dropdowns,
---content containers). Pads container rows in the parent buffer so horizontal
---movement can reach container positions.

local M = {}

-- ============================================================================
-- 1. Movement Key Detection
-- ============================================================================

---@class NavKeys
---@field down string[]
---@field up string[]
---@field left string[]
---@field right string[]

---Detect the user's actual movement keys by scanning global normal-mode keymaps.
---@return NavKeys
local function detect_movement_keys()
  local keys = {
    down  = { "j", "<Down>" },
    up    = { "k", "<Up>" },
    left  = { "h", "<Left>" },
    right = { "l", "<Right>" },
  }

  -- Map from rhs -> direction for detection
  local rhs_to_dir = { j = "down", k = "up", h = "left", l = "right" }

  local ok, maps = pcall(vim.api.nvim_get_keymap, "n")
  if not ok or not maps then return keys end

  for _, map in ipairs(maps) do
    local lhs = map.lhs or ""
    local rhs = map.rhs or ""

    -- If a key is mapped TO a movement key, add it as an alternative
    local dir = rhs_to_dir[rhs]
    if dir and #lhs > 0 and not rhs_to_dir[lhs] then
      table.insert(keys[dir], lhs)
    end

    -- If a standard movement key is remapped to something else, remove it
    if rhs_to_dir[lhs] and not rhs_to_dir[rhs] then
      local direction = rhs_to_dir[lhs]
      for i, k in ipairs(keys[direction]) do
        if k == lhs then
          table.remove(keys[direction], i)
          break
        end
      end
    end
  end

  return keys
end

-- ============================================================================
-- 2. Container Row Padding
-- ============================================================================

---Pad parent buffer rows that overlap container regions with spaces to window width.
---@param fw FloatWindow
---@param regions table[]
local function pad_container_rows(fw, regions)
  if not fw:is_valid() or #regions == 0 then return end

  vim.api.nvim_set_option_value("modifiable", true, { buf = fw.bufnr })

  for _, region in ipairs(regions) do
    for r = region.row, region.row + region.height - 1 do
      local lines = vim.api.nvim_buf_get_lines(fw.bufnr, r, r + 1, false)
      local line = lines[1] or ""
      if #line < fw._win_width then
        local padded = line .. string.rep(" ", fw._win_width - #line)
        vim.api.nvim_buf_set_lines(fw.bufnr, r, r + 1, false, { padded })
      end
    end
  end

  vim.api.nvim_set_option_value("modifiable", fw.config.modifiable or false, { buf = fw.bufnr })
end

-- ============================================================================
-- 3. Region Map
-- ============================================================================

---@class NavRegion
---@field row number 0-indexed row in parent
---@field col number 0-indexed col in parent
---@field width number
---@field height number
---@field name string
---@field source "container"|"input"|"dropdown"|"multi_dropdown"
---@field container EmbeddedContainer The underlying EmbeddedContainer
---@field field table? The EmbeddedInput/Dropdown/MultiDropdown wrapper (if input-type)

---Build a sorted list of all container regions within a FloatWindow.
---@param fw FloatWindow
---@return NavRegion[]
local function build_region_map(fw)
  local regions = {}

  -- From ContainerManager (full containers)
  if fw._container_manager then
    local names = fw._container_manager:get_names()
    for _, name in ipairs(names) do
      local c = fw._container_manager:get(name)
      if c and c:is_valid() then
        local g = c:get_region()
        table.insert(regions, {
          row = g.row,
          col = g.col,
          width = g.width,
          height = g.height,
          name = name,
          source = "container",
          container = c,
          field = nil,
        })
      end
    end
  end

  -- From EmbeddedInputManager (inputs, dropdowns, multi-dropdowns)
  if fw._embedded_input_manager then
    for _, entry in ipairs(fw._embedded_input_manager._field_order) do
      local field = fw._embedded_input_manager:get_field(entry.key)
      if field and field:is_valid() then
        local c = field:get_container()
        if c and c:is_valid() then
          local g = c:get_region()
          table.insert(regions, {
            row = g.row,
            col = g.col,
            width = g.width,
            height = g.height,
            name = entry.key,
            source = entry.type,
            container = c,
            field = field,
          })
        end
      end
    end
  end

  -- Sort by row, then col
  table.sort(regions, function(a, b)
    if a.row ~= b.row then return a.row < b.row end
    return a.col < b.col
  end)

  return regions
end

-- ============================================================================
-- 4. Position Query Helpers
-- ============================================================================

---Find a region that spans a given 0-indexed row.
---@param regions NavRegion[]
---@param row0 number 0-indexed row
---@return NavRegion?
local function find_region_on_row(regions, row0)
  for _, r in ipairs(regions) do
    if row0 >= r.row and row0 < r.row + r.height then
      return r
    end
  end
  return nil
end

---Find a region at an exact 0-indexed (row, col) position.
---@param regions NavRegion[]
---@param row0 number 0-indexed row
---@param col0 number 0-indexed col
---@return NavRegion?
local function find_region_at(regions, row0, col0)
  for _, r in ipairs(regions) do
    if row0 >= r.row and row0 < r.row + r.height
      and col0 >= r.col and col0 < r.col + r.width then
      return r
    end
  end
  return nil
end

---Find the nearest row not covered by any container.
---@param regions NavRegion[]
---@param row0 number 0-indexed row to start from
---@param total_lines number total buffer lines
---@return number row0 safe 0-indexed row
local function find_nearest_safe_row(regions, row0, total_lines)
  -- Check if current row is safe
  if not find_region_on_row(regions, row0) then
    return row0
  end

  -- Search outward
  for offset = 1, total_lines do
    local up = row0 - offset
    local down = row0 + offset
    if up >= 0 and not find_region_on_row(regions, up) then
      return up
    end
    if down < total_lines and not find_region_on_row(regions, down) then
      return down
    end
  end

  return 0
end

-- ============================================================================
-- 5. Focus Helpers
-- ============================================================================

---Focus a container region, updating the relevant manager's tracking state.
---@param fw FloatWindow
---@param region NavRegion
---@param cursor_row number? 1-indexed row within the container buffer
---@param cursor_col number? 0-indexed col within the container buffer
local function enter_container(fw, region, cursor_row, cursor_col)
  cursor_row = cursor_row or 1
  cursor_col = cursor_col or 0

  -- Update ContainerManager tracking
  if region.source == "container" and fw._container_manager then
    fw._container_manager._focused_name = region.name
  end

  -- Update EmbeddedInputManager tracking
  if region.source ~= "container" and fw._embedded_input_manager then
    fw._embedded_input_manager._focused_key = region.name
    -- Update _current_field_idx
    for i, entry in ipairs(fw._embedded_input_manager._field_order) do
      if entry.key == region.name then
        fw._embedded_input_manager._current_field_idx = i
        break
      end
    end
  end

  -- Position cursor inside the container before focusing
  if region.container:is_valid() then
    local line_count = vim.api.nvim_buf_line_count(region.container.bufnr)
    cursor_row = math.max(1, math.min(cursor_row, line_count))
    local line = vim.api.nvim_buf_get_lines(
      region.container.bufnr, cursor_row - 1, cursor_row, false
    )[1] or ""
    cursor_col = math.max(0, math.min(cursor_col, math.max(0, #line - 1)))
    vim.api.nvim_win_set_cursor(region.container.winid, { cursor_row, cursor_col })
  end

  -- Focus triggers on_focus callback (e.g. enter_edit for inputs)
  if region.field then
    region.field:focus()
  else
    region.container:focus()
  end
end

---Blur the currently focused container without specifying which one -
---checks both managers.
---@param fw FloatWindow
local function blur_current_container(fw)
  if fw._container_manager then
    local focused = fw._container_manager:get_focused()
    if focused then
      focused._focused = false
      if focused._config.on_blur then
        focused._config.on_blur()
      end
      fw._container_manager._focused_name = nil
    end
  end
  if fw._embedded_input_manager and fw._embedded_input_manager._focused_key then
    local field = fw._embedded_input_manager:get_field(fw._embedded_input_manager._focused_key)
    if field then
      -- For inputs, exit edit mode first
      if field.exit_edit then field:exit_edit() end
      -- Blur the container directly (skip blur() which calls set_current_win to parent)
      local c = field:get_container()
      if c then
        c._focused = false
        if c._config.on_blur then c._config.on_blur() end
      end
    end
    fw._embedded_input_manager._focused_key = nil
    fw._embedded_input_manager._current_field_idx = 0
  end
end

-- ============================================================================
-- 6. Parent Buffer Keymaps
-- ============================================================================

---Setup movement keymaps on the parent buffer.
---@param fw FloatWindow
---@param regions NavRegion[]
---@param nav_keys NavKeys
local function setup_parent_keymaps(fw, regions, nav_keys)
  if not fw:is_valid() then return end
  local bufnr = fw.bufnr
  local opts = { buffer = bufnr, noremap = true, silent = true }

  -- Vertical down
  for _, key in ipairs(nav_keys.down) do
    vim.keymap.set("n", key, function()
      if fw._navigating then return end
      if not fw:is_valid() then return end
      fw._navigating = true

      local cursor = vim.api.nvim_win_get_cursor(fw.winid)
      local row1 = cursor[1]     -- 1-indexed
      local col0 = cursor[2]     -- 0-indexed
      local target_row0 = row1   -- row1 + 1 in 1-indexed = row1 in 0-indexed

      local line_count = vim.api.nvim_buf_line_count(fw.bufnr)
      if target_row0 >= line_count then
        vim.schedule(function() fw._navigating = false end)
        return
      end

      local region = find_region_at(regions, target_row0, col0)
      if region then
        -- Enter at top of container
        local local_col = math.max(0, col0 - region.col)
        enter_container(fw, region, 1, local_col)
      else
        -- Check if target row is covered by a region at all (but col is outside)
        local row_region = find_region_on_row(regions, target_row0)
        if row_region then
          -- On a container row but col is on padding - just move there
          pcall(vim.api.nvim_win_set_cursor, fw.winid, { target_row0 + 1, col0 })
        else
          pcall(vim.api.nvim_win_set_cursor, fw.winid, { target_row0 + 1, col0 })
        end
      end

      vim.schedule(function() fw._navigating = false end)
    end, opts)
  end

  -- Vertical up
  for _, key in ipairs(nav_keys.up) do
    vim.keymap.set("n", key, function()
      if fw._navigating then return end
      if not fw:is_valid() then return end
      fw._navigating = true

      local cursor = vim.api.nvim_win_get_cursor(fw.winid)
      local row1 = cursor[1]
      local col0 = cursor[2]
      local target_row0 = row1 - 2  -- row1 - 1 in 1-indexed = row1 - 2 in 0-indexed

      if target_row0 < 0 then
        vim.schedule(function() fw._navigating = false end)
        return
      end

      local region = find_region_at(regions, target_row0, col0)
      if region then
        -- Enter at bottom of container
        local local_row = region.height  -- last row (1-indexed)
        local local_col = math.max(0, col0 - region.col)
        enter_container(fw, region, local_row, local_col)
      else
        pcall(vim.api.nvim_win_set_cursor, fw.winid, { target_row0 + 1, col0 })
      end

      vim.schedule(function() fw._navigating = false end)
    end, opts)
  end

  -- Horizontal right
  for _, key in ipairs(nav_keys.right) do
    vim.keymap.set("n", key, function()
      if fw._navigating then return end
      if not fw:is_valid() then return end
      fw._navigating = true

      local cursor = vim.api.nvim_win_get_cursor(fw.winid)
      local row1 = cursor[1]
      local col0 = cursor[2]
      local target_col0 = col0 + 1
      local row0 = row1 - 1

      local region = find_region_at(regions, row0, target_col0)
      if region then
        local local_row = row0 - region.row + 1  -- 1-indexed within container
        local local_col = target_col0 - region.col
        enter_container(fw, region, local_row, local_col)
      else
        -- Normal movement
        local line = vim.api.nvim_buf_get_lines(fw.bufnr, row0, row0 + 1, false)[1] or ""
        if target_col0 < #line then
          pcall(vim.api.nvim_win_set_cursor, fw.winid, { row1, target_col0 })
        end
      end

      vim.schedule(function() fw._navigating = false end)
    end, opts)
  end

  -- Horizontal left
  for _, key in ipairs(nav_keys.left) do
    vim.keymap.set("n", key, function()
      if fw._navigating then return end
      if not fw:is_valid() then return end
      fw._navigating = true

      local cursor = vim.api.nvim_win_get_cursor(fw.winid)
      local row1 = cursor[1]
      local col0 = cursor[2]
      local target_col0 = col0 - 1
      local row0 = row1 - 1

      if target_col0 < 0 then
        vim.schedule(function() fw._navigating = false end)
        return
      end

      local region = find_region_at(regions, row0, target_col0)
      if region then
        local local_row = row0 - region.row + 1
        local local_col = target_col0 - region.col
        enter_container(fw, region, local_row, local_col)
      else
        pcall(vim.api.nvim_win_set_cursor, fw.winid, { row1, target_col0 })
      end

      vim.schedule(function() fw._navigating = false end)
    end, opts)
  end
end

-- ============================================================================
-- 7. Container Buffer Keymaps (exit keymaps)
-- ============================================================================

---Setup movement keymaps on a container's buffer for exiting at edges.
---@param region NavRegion
---@param fw FloatWindow
---@param regions NavRegion[]
---@param nav_keys NavKeys
local function setup_container_exit_keymaps(region, fw, regions, nav_keys)
  local c = region.container
  if not c or not c:is_valid() then return end
  local bufnr = c.bufnr
  local opts = { buffer = bufnr, noremap = true, silent = true }

  ---Transfer to another container or exit to parent at a target position.
  ---@param target_row0 number 0-indexed row in parent
  ---@param target_col0 number 0-indexed col in parent
  local function exit_to(target_row0, target_col0)
    -- Check if target hits another container
    local target_region = find_region_at(regions, target_row0, target_col0)
    if target_region and target_region.name ~= region.name then
      -- Direct container-to-container transfer
      blur_current_container(fw)
      local local_row = target_row0 - target_region.row + 1
      local local_col = math.max(0, target_col0 - target_region.col)
      enter_container(fw, target_region, local_row, local_col)
      return
    end

    -- Exit to parent
    blur_current_container(fw)
    if fw:is_valid() then
      vim.api.nvim_set_current_win(fw.winid)
      local line_count = vim.api.nvim_buf_line_count(fw.bufnr)

      -- If target is still on a container region, snap to safety
      if find_region_at(regions, target_row0, target_col0) then
        target_row0 = find_nearest_safe_row(regions, target_row0, line_count)
      end

      local clamped_row = math.max(0, math.min(target_row0, line_count - 1))
      local line = vim.api.nvim_buf_get_lines(fw.bufnr, clamped_row, clamped_row + 1, false)[1] or ""
      local clamped_col = math.max(0, math.min(target_col0, math.max(0, #line - 1)))
      fw._navigating = true
      pcall(vim.api.nvim_win_set_cursor, fw.winid, { clamped_row + 1, clamped_col })
      vim.schedule(function() fw._navigating = false end)
    end
  end

  -- Down
  for _, key in ipairs(nav_keys.down) do
    vim.keymap.set("n", key, function()
      if not c:is_valid() then return end
      local cursor = vim.api.nvim_win_get_cursor(c.winid)
      local crow1 = cursor[1]
      local ccol0 = cursor[2]
      local line_count = vim.api.nvim_buf_line_count(c.bufnr)

      if crow1 >= line_count then
        -- At last row -> exit downward
        local parent_row0 = region.row + region.height  -- row just below container
        local parent_col0 = region.col + ccol0
        exit_to(parent_row0, parent_col0)
      else
        -- Normal movement within container
        pcall(vim.api.nvim_win_set_cursor, c.winid, { crow1 + 1, ccol0 })
      end
    end, opts)
  end

  -- Up
  for _, key in ipairs(nav_keys.up) do
    vim.keymap.set("n", key, function()
      if not c:is_valid() then return end
      local cursor = vim.api.nvim_win_get_cursor(c.winid)
      local crow1 = cursor[1]
      local ccol0 = cursor[2]

      if crow1 <= 1 then
        -- At first row -> exit upward
        local parent_row0 = region.row - 1  -- row just above container
        local parent_col0 = region.col + ccol0
        exit_to(parent_row0, parent_col0)
      else
        pcall(vim.api.nvim_win_set_cursor, c.winid, { crow1 - 1, ccol0 })
      end
    end, opts)
  end

  -- Right
  for _, key in ipairs(nav_keys.right) do
    vim.keymap.set("n", key, function()
      if not c:is_valid() then return end
      local cursor = vim.api.nvim_win_get_cursor(c.winid)
      local crow1 = cursor[1]
      local ccol0 = cursor[2]
      local line = vim.api.nvim_buf_get_lines(c.bufnr, crow1 - 1, crow1, false)[1] or ""
      local line_end = math.max(0, #line - 1)

      if ccol0 >= line_end then
        -- At end of line -> exit right
        local parent_row0 = region.row + (crow1 - 1)
        local parent_col0 = region.col + region.width
        exit_to(parent_row0, parent_col0)
      else
        pcall(vim.api.nvim_win_set_cursor, c.winid, { crow1, ccol0 + 1 })
      end
    end, opts)
  end

  -- Left
  for _, key in ipairs(nav_keys.left) do
    vim.keymap.set("n", key, function()
      if not c:is_valid() then return end
      local cursor = vim.api.nvim_win_get_cursor(c.winid)
      local crow1 = cursor[1]
      local ccol0 = cursor[2]

      if ccol0 <= 0 then
        -- At col 0 -> exit left
        local parent_row0 = region.row + (crow1 - 1)
        local parent_col0 = region.col - 1
        exit_to(parent_row0, parent_col0)
      else
        pcall(vim.api.nvim_win_set_cursor, c.winid, { crow1, ccol0 - 1 })
      end
    end, opts)
  end
end

-- ============================================================================
-- 8. CursorMoved Fallback on Parent Buffer
-- ============================================================================

---Setup a CursorMoved autocmd on the parent buffer as a safety net.
---@param fw FloatWindow
---@param regions NavRegion[]
local function setup_cursor_guard(fw, regions)
  if not fw:is_valid() or not fw._augroup then return end

  vim.api.nvim_create_autocmd("CursorMoved", {
    group = fw._augroup,
    buffer = fw.bufnr,
    callback = function()
      if fw._navigating then return end
      if not fw:is_valid() then return end

      local cursor = vim.api.nvim_win_get_cursor(fw.winid)
      local row0 = cursor[1] - 1
      local col0 = cursor[2]

      local region = find_region_at(regions, row0, col0)
      if region then
        fw._navigating = true
        enter_container(fw, region, row0 - region.row + 1, col0 - region.col)
        vim.schedule(function() fw._navigating = false end)
      end
    end,
  })
end

-- ============================================================================
-- 9. Main Entry Point
-- ============================================================================

---Setup spatial navigation for a FloatWindow and all its containers.
---@param fw FloatWindow
function M.setup(fw)
  if not fw:is_valid() then return end

  -- 1. Detect movement keys
  local nav_keys = detect_movement_keys()

  -- 2. Build region map
  local regions = build_region_map(fw)
  if #regions == 0 then return end

  -- Store on instance for external access
  fw._navigation_regions = regions

  -- 3. Pad container rows in parent buffer
  pad_container_rows(fw, regions)

  -- 4. Recursive padding for nested containers
  for _, region in ipairs(regions) do
    if region.source == "container" and region.container:is_valid() then
      local nested_c = region.container
      -- Check if the container has its own container/input managers
      if nested_c._container_manager or nested_c._embedded_input_manager then
        local nested_regions = build_region_map(nested_c)
        if #nested_regions > 0 then
          pad_container_rows(nested_c, nested_regions)
        end
      end
    end
  end

  -- 5. Setup parent buffer keymaps
  setup_parent_keymaps(fw, regions, nav_keys)

  -- 6. Setup exit keymaps on each container
  for _, region in ipairs(regions) do
    setup_container_exit_keymaps(region, fw, regions, nav_keys)
  end

  -- 7. Setup CursorMoved guard
  setup_cursor_guard(fw, regions)
end

return M
