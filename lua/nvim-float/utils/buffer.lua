---@module 'nvim-float.utils.buffer'
---@brief Buffer utility functions for nvim-float

local M = {}

-- ============================================================================
-- Buffer Validity Checks
-- ============================================================================

---Check if a buffer is valid
---@param bufnr number? Buffer number
---@return boolean
function M.is_valid(bufnr)
  return bufnr ~= nil and vim.api.nvim_buf_is_valid(bufnr)
end

---Check if a window is valid
---@param winid number? Window ID
---@return boolean
function M.is_win_valid(winid)
  return winid ~= nil and vim.api.nvim_win_is_valid(winid)
end

---Check if both buffer and window are valid
---@param bufnr number? Buffer number
---@param winid number? Window ID
---@return boolean
function M.is_float_valid(bufnr, winid)
  return M.is_valid(bufnr) and M.is_win_valid(winid)
end

-- ============================================================================
-- Buffer Content Operations
-- ============================================================================

---Set buffer modifiable state safely
---@param bufnr number Buffer number
---@param modifiable boolean Whether buffer should be modifiable
---@return boolean success Whether the operation succeeded
function M.set_modifiable(bufnr, modifiable)
  if not M.is_valid(bufnr) then
    return false
  end
  local ok = pcall(vim.api.nvim_buf_set_option, bufnr, 'modifiable', modifiable)
  return ok
end

---Set buffer lines safely
---@param bufnr number Buffer number
---@param lines string[] Lines to set
---@param start_line number? Start line (0-indexed, default 0)
---@param end_line number? End line (0-indexed, default -1 for all)
---@return boolean success Whether the operation succeeded
function M.set_lines(bufnr, lines, start_line, end_line)
  if not M.is_valid(bufnr) then
    return false
  end
  start_line = start_line or 0
  end_line = end_line or -1
  local ok = pcall(vim.api.nvim_buf_set_lines, bufnr, start_line, end_line, false, lines)
  return ok
end

---Get buffer lines safely
---@param bufnr number Buffer number
---@param start_line number? Start line (0-indexed, default 0)
---@param end_line number? End line (0-indexed, default -1 for all)
---@return string[] lines Buffer lines (empty array on failure)
function M.get_lines(bufnr, start_line, end_line)
  if not M.is_valid(bufnr) then
    return {}
  end
  start_line = start_line or 0
  end_line = end_line or -1
  local ok, lines = pcall(vim.api.nvim_buf_get_lines, bufnr, start_line, end_line, false)
  if ok then
    return lines
  end
  return {}
end

---Get line count of buffer
---@param bufnr number Buffer number
---@return number count Line count (0 on failure)
function M.line_count(bufnr)
  if not M.is_valid(bufnr) then
    return 0
  end
  local ok, count = pcall(vim.api.nvim_buf_line_count, bufnr)
  if ok then
    return count
  end
  return 0
end

---Set buffer content with automatic modifiable handling
---@param bufnr number Buffer number
---@param lines string[] Lines to set
---@param restore_modifiable boolean? Whether to restore modifiable state (default true)
---@return boolean success Whether the operation succeeded
function M.set_content(bufnr, lines, restore_modifiable)
  if not M.is_valid(bufnr) then
    return false
  end

  restore_modifiable = restore_modifiable ~= false

  -- Get current modifiable state
  local was_modifiable = vim.api.nvim_buf_get_option(bufnr, 'modifiable')

  -- Make modifiable if needed
  if not was_modifiable then
    M.set_modifiable(bufnr, true)
  end

  -- Set content
  local ok = M.set_lines(bufnr, lines)

  -- Restore modifiable state if requested
  if restore_modifiable and not was_modifiable then
    M.set_modifiable(bufnr, false)
  end

  return ok
end

-- ============================================================================
-- Buffer Option Helpers
-- ============================================================================

---Set buffer option safely
---@param bufnr number Buffer number
---@param name string Option name
---@param value any Option value
---@return boolean success
function M.set_option(bufnr, name, value)
  if not M.is_valid(bufnr) then
    return false
  end
  local ok = pcall(vim.api.nvim_buf_set_option, bufnr, name, value)
  return ok
end

---Get buffer option safely
---@param bufnr number Buffer number
---@param name string Option name
---@return any? value Option value or nil on failure
function M.get_option(bufnr, name)
  if not M.is_valid(bufnr) then
    return nil
  end
  local ok, value = pcall(vim.api.nvim_buf_get_option, bufnr, name)
  if ok then
    return value
  end
  return nil
end

---Set window option safely
---@param winid number Window ID
---@param name string Option name
---@param value any Option value
---@return boolean success
function M.set_win_option(winid, name, value)
  if not M.is_win_valid(winid) then
    return false
  end
  local ok = pcall(vim.api.nvim_set_option_value, name, value, { win = winid })
  return ok
end

---Get window option safely
---@param winid number Window ID
---@param name string Option name
---@return any? value Option value or nil on failure
function M.get_win_option(winid, name)
  if not M.is_win_valid(winid) then
    return nil
  end
  local ok, value = pcall(vim.api.nvim_get_option_value, name, { win = winid })
  if ok then
    return value
  end
  return nil
end

-- ============================================================================
-- Cursor Operations
-- ============================================================================

---Get cursor position safely
---@param winid number Window ID
---@return number row, number col (1-indexed row, 0-indexed col)
function M.get_cursor(winid)
  if not M.is_win_valid(winid) then
    return 1, 0
  end
  local ok, cursor = pcall(vim.api.nvim_win_get_cursor, winid)
  if ok then
    return cursor[1], cursor[2]
  end
  return 1, 0
end

---Set cursor position safely
---@param winid number Window ID
---@param row number Row (1-indexed)
---@param col number Column (0-indexed)
---@return boolean success
function M.set_cursor(winid, row, col)
  if not M.is_win_valid(winid) then
    return false
  end
  local ok = pcall(vim.api.nvim_win_set_cursor, winid, { row, col })
  return ok
end

---Set cursor with clamping to valid buffer range
---@param winid number Window ID
---@param bufnr number Buffer number
---@param row number Desired row (1-indexed)
---@param col number Desired column (0-indexed)
---@return boolean success
function M.set_cursor_clamped(winid, bufnr, row, col)
  if not M.is_float_valid(bufnr, winid) then
    return false
  end

  local line_count = M.line_count(bufnr)
  local clamped_row = math.max(1, math.min(row, line_count))

  return M.set_cursor(winid, clamped_row, col)
end

return M
