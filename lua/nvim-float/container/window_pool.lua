---@module 'nvim-float.container.window_pool'
---@brief WindowPool - Reusable buffer/window pairs for virtual container activation
---
---When a virtual container materializes, it needs a buffer and window. Rather than
---creating and destroying these on every activation/deactivation cycle, the pool
---keeps released buffers and creates fresh windows on acquire (since nvim_win_hide
---invalidates the window handle).

---@class WindowPoolEntry
---@field bufnr number Buffer handle
---@field winid number Window handle

---@class WindowPool
---@field _buffers number[] Available buffer handles for reuse
local WindowPool = {}
WindowPool.__index = WindowPool

---Create a new WindowPool
---@return WindowPool
function WindowPool.new()
  local self = setmetatable({}, WindowPool)
  self._buffers = {}
  return self
end

---Acquire a buffer/window pair configured for the given parent and position.
---Reuses a pooled buffer if available, otherwise creates a new one.
---@param parent_winid number Parent window ID for relative='win'
---@param config table Window config: { row, col, width, height, zindex, focusable? }
---@return WindowPoolEntry entry
function WindowPool:acquire(parent_winid, config)
  local bufnr

  -- Try to reuse a pooled buffer
  while #self._buffers > 0 do
    local candidate = table.remove(self._buffers)
    if vim.api.nvim_buf_is_valid(candidate) then
      bufnr = candidate
      -- Clear old content
      vim.api.nvim_set_option_value('modifiable', true, { buf = bufnr })
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "" })
      break
    end
  end

  -- Create new buffer if none available
  if not bufnr then
    bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_option_value('buftype', 'nofile', { buf = bufnr })
    vim.api.nvim_set_option_value('bufhidden', 'hide', { buf = bufnr })
    vim.api.nvim_set_option_value('swapfile', false, { buf = bufnr })
  end

  -- Always create a fresh window (hidden windows lose their handle)
  local winid = vim.api.nvim_open_win(bufnr, false, {
    relative = "win",
    win = parent_winid,
    row = config.row,
    col = config.col,
    width = math.max(1, config.width),
    height = math.max(1, config.height),
    zindex = config.zindex or 55,
    style = "minimal",
    focusable = config.focusable ~= false,
    border = "none",
  })

  return { bufnr = bufnr, winid = winid }
end

---Release a buffer/window pair back to the pool.
---The window is closed; the buffer is kept for reuse.
---@param entry WindowPoolEntry
function WindowPool:release(entry)
  if not entry then return end

  -- Clear buffer-local keymaps before returning to pool
  if entry.bufnr and vim.api.nvim_buf_is_valid(entry.bufnr) then
    for _, mode in ipairs({ 'n', 'i', 'v' }) do
      local ok, maps = pcall(vim.api.nvim_buf_get_keymap, entry.bufnr, mode)
      if ok then
        for _, map in ipairs(maps) do
          pcall(vim.keymap.del, mode, map.lhs, { buffer = entry.bufnr })
        end
      end
    end
  end

  -- Close the window (handle becomes invalid)
  if entry.winid and vim.api.nvim_win_is_valid(entry.winid) then
    pcall(vim.api.nvim_win_close, entry.winid, true)
  end

  -- Pool the buffer for reuse
  if entry.bufnr and vim.api.nvim_buf_is_valid(entry.bufnr) then
    table.insert(self._buffers, entry.bufnr)
  end
end

---Drain all pooled buffers, deleting everything.
function WindowPool:drain()
  for _, bufnr in ipairs(self._buffers) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end
  end
  self._buffers = {}
end

---Get the number of pooled buffers available
---@return number
function WindowPool:size()
  return #self._buffers
end

return WindowPool
