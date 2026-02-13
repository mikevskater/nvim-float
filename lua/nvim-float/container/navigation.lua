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

---Pad parent buffer rows that overlap container regions so horizontal movement can reach them.
---Only pads to the start column of the rightmost container on each row, not full window width.
---@param fw FloatWindow
---@param regions table[]
local function pad_container_rows(fw, regions)
  if not fw:is_valid() or #regions == 0 then return end

  -- Build a map: row0 -> max start col needed (rightmost container's LEFT edge)
  local row_pad_targets = {}
  for _, region in ipairs(regions) do
    for r = region.row, region.row + region.visual_height - 1 do
      row_pad_targets[r] = math.max(row_pad_targets[r] or 0, region.col)
    end
  end

  vim.api.nvim_set_option_value("modifiable", true, { buf = fw.bufnr })

  for r, target in pairs(row_pad_targets) do
    local lines = vim.api.nvim_buf_get_lines(fw.bufnr, r, r + 1, false)
    local line = lines[1] or ""
    if #line < target then
      vim.api.nvim_buf_set_lines(fw.bufnr, r, r + 1, false, { line .. string.rep(" ", target - #line) })
    end
  end

  vim.api.nvim_set_option_value("modifiable", fw.config.modifiable or false, { buf = fw.bufnr })
end

-- ============================================================================
-- 3. Region Map
-- ============================================================================

---Compute border thickness offsets for a window border config.
---Returns the number of rows/cols each border edge occupies.
---@param border any Border config (string, table, or nil)
---@return number top
---@return number bottom
---@return number left
---@return number right
function M.compute_border_offsets(border)
  if not border or border == "none" or border == "" then
    return 0, 0, 0, 0
  end
  if type(border) == "string" then
    if border == "shadow" then return 0, 1, 0, 1 end
    return 1, 1, 1, 1  -- rounded, single, double, solid
  end
  if type(border) == "table" then
    local function has_char(e)
      if not e then return false end
      if type(e) == "string" then return e ~= "" end
      if type(e) == "table" then return e[1] and e[1] ~= "" end
      return false
    end
    return
      has_char(border[2]) and 1 or 0,   -- top
      has_char(border[6]) and 1 or 0,   -- bottom
      has_char(border[8]) and 1 or 0,   -- left
      has_char(border[4]) and 1 or 0    -- right
  end
  return 0, 0, 0, 0
end

---@class NavRegion
---@field row number 0-indexed row in parent (border top-left for bordered containers)
---@field col number 0-indexed col in parent (border top-left for bordered containers)
---@field width number Content width
---@field height number Content height
---@field border_top number Border thickness at top
---@field border_bottom number Border thickness at bottom
---@field border_left number Border thickness at left
---@field border_right number Border thickness at right
---@field visual_width number Total width including borders
---@field visual_height number Total height including borders
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
        local bt, bb, bl, br = M.compute_border_offsets(c._config.border)
        local row = c._buffer_row or c._row
        local col = c._buffer_col or c._col
        local w = c._original_width or c._width
        local h = c._original_height or c._height
        table.insert(regions, {
          row = row,
          col = col,
          width = w,
          height = h,
          border_top = bt,
          border_bottom = bb,
          border_left = bl,
          border_right = br,
          visual_width = w + bl + br,
          visual_height = h + bt + bb,
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
          local row = c._buffer_row or c._row
          local col = c._buffer_col or c._col
          local w = c._original_width or c._width
          local h = c._original_height or c._height
          table.insert(regions, {
            row = row,
            col = col,
            width = w,
            height = h,
            border_top = 0,
            border_bottom = 0,
            border_left = 0,
            border_right = 0,
            visual_width = w,
            visual_height = h,
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
    if row0 >= r.row and row0 < r.row + r.visual_height then
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
    if row0 >= r.row and row0 < r.row + r.visual_height
      and col0 >= r.col and col0 < r.col + r.visual_width then
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

---Check whether a target position in the parent is valid for exiting to.
---@param fw FloatWindow
---@param regions NavRegion[]
---@param parent_row0 number 0-indexed target row in parent
---@param parent_col0 number 0-indexed target col in parent
---@return boolean
local function can_exit_to(fw, regions, parent_row0, parent_col0)
  if not fw:is_valid() then return false end
  -- Out of buffer bounds?
  local line_count = vim.api.nvim_buf_line_count(fw.bufnr)
  if parent_row0 < 0 or parent_row0 >= line_count then return false end
  if parent_col0 < 0 then return false end
  -- Another container at target? Always valid (container-to-container transfer)
  local target_r = find_region_at(regions, parent_row0, parent_col0)
  if target_r and not target_r.container:is_hidden() then return true end
  -- Check parent line has content at target col
  local line = vim.api.nvim_buf_get_lines(fw.bufnr, parent_row0, parent_row0 + 1, false)[1] or ""
  return parent_col0 < #line
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
    local winid = region.container.winid
    local line_count = vim.api.nvim_buf_line_count(region.container.bufnr)

    -- Map visual offset to buffer line within visible range
    local visible_top = vim.fn.line('w0', winid)
    if visible_top > 1 then
      cursor_row = visible_top + (cursor_row - 1)
    end

    cursor_row = math.max(1, math.min(cursor_row, line_count))
    local line = vim.api.nvim_buf_get_lines(
      region.container.bufnr, cursor_row - 1, cursor_row, false
    )[1] or ""
    cursor_col = math.max(0, math.min(cursor_col, math.max(0, #line - 1)))
    vim.api.nvim_win_set_cursor(winid, { cursor_row, cursor_col })
  end

  -- Focus the window
  if region.source == "input" then
    -- Direct window focus — skip on_focus callback to avoid auto-insert
    vim.api.nvim_set_current_win(region.container.winid)
    region.container._focused = true
  elseif region.field then
    region.field:focus()  -- dropdowns/multi-dropdowns: normal focus is fine
  else
    region.container:focus()  -- content containers
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
      if region and not region.container:is_hidden() then
        -- Enter at top of container content (offset by border)
        local content_row = target_row0 - region.row - region.border_top + 1
        local content_col = math.max(0, col0 - region.col - region.border_left)
        enter_container(fw, region, content_row, content_col)
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
      if region and not region.container:is_hidden() then
        -- Enter at appropriate content row (offset by border)
        local content_row = target_row0 - region.row - region.border_top + 1
        local content_col = math.max(0, col0 - region.col - region.border_left)
        enter_container(fw, region, content_row, content_col)
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
      if region and not region.container:is_hidden() then
        local content_row = row0 - region.row - region.border_top + 1
        local content_col = math.max(0, target_col0 - region.col - region.border_left)
        enter_container(fw, region, content_row, content_col)
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
      if region and not region.container:is_hidden() then
        local content_row = row0 - region.row - region.border_top + 1
        local content_col = math.max(0, target_col0 - region.col - region.border_left)
        enter_container(fw, region, content_row, content_col)
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
    if target_region and target_region.name ~= region.name and not target_region.container:is_hidden() then
      -- Direct container-to-container transfer
      blur_current_container(fw)
      local local_row = target_row0 - target_region.row - target_region.border_top + 1
      local local_col = math.max(0, target_col0 - target_region.col - target_region.border_left)
      enter_container(fw, target_region, local_row, local_col)
      return
    end

    -- Exit to parent
    blur_current_container(fw)
    if fw:is_valid() then
      vim.api.nvim_set_current_win(fw.winid)
      local line_count = vim.api.nvim_buf_line_count(fw.bufnr)

      -- If target is still on a visible container region, snap to safety
      local snap_r = find_region_at(regions, target_row0, target_col0)
      if snap_r and not snap_r.container:is_hidden() then
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
        local parent_row0 = region.row + region.visual_height  -- row just below bottom border
        local parent_col0 = region.col + region.border_left + ccol0
        local buf_lines = vim.api.nvim_buf_line_count(fw.bufnr)
        if parent_row0 >= 0 and parent_row0 < buf_lines then
          exit_to(parent_row0, parent_col0)
        end
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
        local parent_row0 = region.row - 1  -- row just above top border
        local parent_col0 = region.col + region.border_left + ccol0
        local buf_lines = vim.api.nvim_buf_line_count(fw.bufnr)
        if parent_row0 >= 0 and parent_row0 < buf_lines then
          exit_to(parent_row0, parent_col0)
        end
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
        local visible_top = vim.fn.line('w0', c.winid)
        local visual_row = crow1 - visible_top  -- 0-indexed visual offset
        local parent_row0 = region.row + region.border_top + visual_row
        local parent_col0 = region.col + region.visual_width  -- just past right border
        if can_exit_to(fw, regions, parent_row0, parent_col0) then
          exit_to(parent_row0, parent_col0)
        end
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
        local visible_top = vim.fn.line('w0', c.winid)
        local visual_row = crow1 - visible_top  -- 0-indexed visual offset
        local parent_row0 = region.row + region.border_top + visual_row
        local parent_col0 = region.col - 1  -- just before left border
        local buf_lines = vim.api.nvim_buf_line_count(fw.bufnr)
        if parent_col0 >= 0 and parent_row0 >= 0 and parent_row0 < buf_lines then
          exit_to(parent_row0, parent_col0)
        end
      else
        pcall(vim.api.nvim_win_set_cursor, c.winid, { crow1, ccol0 - 1 })
      end
    end, opts)
  end

  -- Close parent UI from container (q/Esc)
  if fw.config.default_keymaps then
    vim.keymap.set("n", "q", function()
      blur_current_container(fw)
      fw:close()
    end, opts)
    vim.keymap.set("n", "<Esc>", function()
      blur_current_container(fw)
      fw:close()
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
      if region and not region.container:is_hidden() then
        fw._navigating = true
        local content_row = row0 - region.row - region.border_top + 1
        local content_col = math.max(0, col0 - region.col - region.border_left)
        enter_container(fw, region, content_row, content_col)
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
