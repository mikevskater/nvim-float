---@module 'nvim-float.utils.highlight'
---@brief Highlight utility functions for nvim-float

local M = {}

-- Cache of created dynamic highlight groups
local _dynamic_highlights = {}

-- ============================================================================
-- Namespace Operations
-- ============================================================================

---Create or get a namespace
---@param name string Namespace name
---@return number ns_id Namespace ID
function M.create_namespace(name)
  return vim.api.nvim_create_namespace(name)
end

---Clear namespace highlights from buffer
---@param bufnr number Buffer number
---@param ns_id number Namespace ID
---@param start_line number? Start line (0-indexed, default 0)
---@param end_line number? End line (0-indexed, default -1 for all)
---@return boolean success
function M.clear_namespace(bufnr, ns_id, start_line, end_line)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return false
  end
  start_line = start_line or 0
  end_line = end_line or -1
  local ok = pcall(vim.api.nvim_buf_clear_namespace, bufnr, ns_id, start_line, end_line)
  return ok
end

-- ============================================================================
-- Highlight Application
-- ============================================================================

---Add highlight to buffer
---@param bufnr number Buffer number
---@param ns_id number Namespace ID
---@param hl_group string Highlight group name
---@param line number Line number (0-indexed)
---@param col_start number Start column (0-indexed)
---@param col_end number End column (0-indexed)
---@return boolean success
function M.add_highlight(bufnr, ns_id, hl_group, line, col_start, col_end)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return false
  end
  local ok = pcall(vim.api.nvim_buf_add_highlight, bufnr, ns_id, hl_group, line, col_start, col_end)
  return ok
end

---Add multiple highlights to buffer efficiently
---@param bufnr number Buffer number
---@param ns_id number Namespace ID
---@param highlights table[] Array of {line, col_start, col_end, hl_group} or {line=, col_start=, col_end=, hl_group=}
---@return number applied Number of highlights applied
function M.add_highlights(bufnr, ns_id, highlights)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return 0
  end

  local applied = 0
  for _, hl in ipairs(highlights) do
    -- Support both array format and named format
    local line = hl.line or hl[1]
    local col_start = hl.col_start or hl[2]
    local col_end = hl.col_end or hl[3]
    local hl_group = hl.hl_group or hl[4]

    if line and col_start and col_end and hl_group then
      if M.add_highlight(bufnr, ns_id, hl_group, line, col_start, col_end) then
        applied = applied + 1
      end
    end
  end

  return applied
end

-- ============================================================================
-- Extmark Operations
-- ============================================================================

---Set extmark with highlight
---@param bufnr number Buffer number
---@param ns_id number Namespace ID
---@param line number Line number (0-indexed)
---@param col number Column (0-indexed)
---@param opts table Extmark options (end_row, end_col, hl_group, priority, etc.)
---@return number? mark_id Extmark ID or nil on failure
function M.set_extmark(bufnr, ns_id, line, col, opts)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return nil
  end
  local ok, mark_id = pcall(vim.api.nvim_buf_set_extmark, bufnr, ns_id, line, col, opts)
  if ok then
    return mark_id
  end
  return nil
end

---Delete extmark
---@param bufnr number Buffer number
---@param ns_id number Namespace ID
---@param mark_id number Extmark ID
---@return boolean success
function M.del_extmark(bufnr, ns_id, mark_id)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return false
  end
  local ok = pcall(vim.api.nvim_buf_del_extmark, bufnr, ns_id, mark_id)
  return ok
end

---Get extmarks in range
---@param bufnr number Buffer number
---@param ns_id number Namespace ID
---@param start_line number Start line (0-indexed)
---@param end_line number End line (0-indexed, -1 for end of buffer)
---@return table[] extmarks Array of {id, row, col, opts}
function M.get_extmarks(bufnr, ns_id, start_line, end_line)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return {}
  end

  local start_pos = { start_line, 0 }
  local end_pos = end_line == -1 and -1 or { end_line, -1 }

  local ok, marks = pcall(vim.api.nvim_buf_get_extmarks, bufnr, ns_id, start_pos, end_pos, { details = true })
  if ok then
    return marks
  end
  return {}
end

-- ============================================================================
-- Dynamic Highlight Groups
-- ============================================================================

---Create or get a dynamic highlight group
---@param name string Base name for the highlight group
---@param opts table Highlight options (fg, bg, bold, italic, etc.)
---@return string hl_group The highlight group name
function M.create_dynamic(name, opts)
  -- Create unique key from opts
  local key = name
  for k, v in pairs(opts) do
    key = key .. "_" .. tostring(k) .. "_" .. tostring(v)
  end

  if not _dynamic_highlights[key] then
    local hl_name = "NvimFloatDyn_" .. name:gsub("[^%w]", "_") .. "_" .. #vim.tbl_keys(_dynamic_highlights)
    vim.api.nvim_set_hl(0, hl_name, opts)
    _dynamic_highlights[key] = hl_name
  end

  return _dynamic_highlights[key]
end

---Create highlight group for a specific color (foreground)
---@param hex string Hex color (e.g., "#FF5733")
---@param prefix string? Prefix for highlight group name (default "Color")
---@return string hl_group The highlight group name
function M.create_fg_color(hex, prefix)
  prefix = prefix or "Color"
  local safe_hex = hex:gsub("#", "")
  local hl_name = "NvimFloat" .. prefix .. "_" .. safe_hex

  if not _dynamic_highlights[hl_name] then
    vim.api.nvim_set_hl(0, hl_name, { fg = hex })
    _dynamic_highlights[hl_name] = true
  end

  return hl_name
end

---Create highlight group for a specific color (background)
---@param hex string Hex color (e.g., "#FF5733")
---@param prefix string? Prefix for highlight group name (default "Bg")
---@return string hl_group The highlight group name
function M.create_bg_color(hex, prefix)
  prefix = prefix or "Bg"
  local safe_hex = hex:gsub("#", "")
  local hl_name = "NvimFloat" .. prefix .. "_" .. safe_hex

  if not _dynamic_highlights[hl_name] then
    vim.api.nvim_set_hl(0, hl_name, { bg = hex })
    _dynamic_highlights[hl_name] = true
  end

  return hl_name
end

---Clear cached dynamic highlights
function M.clear_dynamic_cache()
  _dynamic_highlights = {}
end

-- ============================================================================
-- Highlight Group Helpers
-- ============================================================================

---Check if a highlight group exists
---@param name string Highlight group name
---@return boolean exists
function M.exists(name)
  local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = name })
  return ok and hl and next(hl) ~= nil
end

---Get highlight group definition
---@param name string Highlight group name
---@return table? definition Highlight definition or nil
function M.get_hl(name)
  local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = name })
  if ok and hl then
    return hl
  end
  return nil
end

---Set highlight group
---@param name string Highlight group name
---@param opts table Highlight options
---@return boolean success
function M.set_hl(name, opts)
  local ok = pcall(vim.api.nvim_set_hl, 0, name, opts)
  return ok
end

---Link highlight group to another
---@param name string Source highlight group
---@param target string Target highlight group to link to
---@return boolean success
function M.link(name, target)
  return M.set_hl(name, { link = target })
end

return M
