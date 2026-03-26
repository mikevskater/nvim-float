---@module 'nvim-float.content.diff'
---@brief Diff-based rendering engine for panel updates
---
---Compares previous render state with new state and applies only the delta
---to minimize Neovim buffer API calls. LuaJIT interns strings so
---old_line == new_line is O(1) pointer comparison.

local M = {}

---@class RenderCache
---@field lines string[] Previous text lines
---@field highlights table[] Previous highlight entries
---@field hl_by_line table<number, table[]> Highlights indexed by 0-based line number

---@class DiffResult
---@field text_changed boolean Whether any text lines changed
---@field changed_ranges {start: number, end_: number}[] Contiguous ranges of changed lines (0-indexed)
---@field hl_dirty_lines number[] Lines where highlights changed (0-indexed)
---@field line_count_changed boolean Whether line count differs

-- ============================================================================
-- Helpers
-- ============================================================================

---Build a lookup key for a line's highlights for fast comparison
---@param hls table[] Array of highlight entries for one line
---@return string key Comparison key
local function hl_line_key(hls)
  if not hls or #hls == 0 then return "" end
  local parts = {}
  for _, hl in ipairs(hls) do
    parts[#parts + 1] = string.format("%s:%d-%d",
      hl.hl_group or "", hl.col_start or 0, hl.col_end or 0)
  end
  table.sort(parts)
  return table.concat(parts, "|")
end

---Index highlights by 0-based line number
---@param highlights table[] Flat highlight array with .line field
---@return table<number, table[]>
local function index_highlights(highlights)
  local by_line = {}
  for _, hl in ipairs(highlights) do
    local line = hl.line
    if line then
      if not by_line[line] then
        by_line[line] = {}
      end
      by_line[line][#by_line[line] + 1] = hl
    end
  end
  return by_line
end

-- ============================================================================
-- Public API
-- ============================================================================

---Create a render cache from current state
---@param lines string[] Text lines
---@param highlights table[] Highlight entries
---@return RenderCache
function M.create_cache(lines, highlights)
  return {
    lines = lines,
    highlights = highlights,
    hl_by_line = index_highlights(highlights),
  }
end

---Compute diff between cached state and new state
---@param cache RenderCache Previous render state
---@param new_lines string[] New text lines
---@param new_highlights table[] New highlight entries
---@return DiffResult
function M.compute(cache, new_lines, new_highlights)
  local old_lines = cache.lines
  local old_hl_by_line = cache.hl_by_line
  local new_hl_by_line = index_highlights(new_highlights)

  local line_count_changed = #old_lines ~= #new_lines
  local text_changed = false
  local changed_ranges = {}
  local hl_dirty_lines = {}

  -- Linear scan for text changes, merge adjacent dirty lines into ranges
  -- Also track individual text-changed lines (0-indexed) since nvim_buf_set_lines
  -- destroys extmarks on replaced lines, requiring highlight reapplication
  local max_lines = math.max(#old_lines, #new_lines)
  local range_start = nil
  local text_changed_lines = {}

  for i = 1, max_lines do
    local old = old_lines[i]
    local new = new_lines[i]
    local different = (old ~= new) -- O(1) for interned strings

    if different then
      text_changed = true
      text_changed_lines[i - 1] = true -- 0-indexed
      if not range_start then
        range_start = i - 1 -- Convert to 0-indexed
      end
    else
      if range_start then
        changed_ranges[#changed_ranges + 1] = {
          start = range_start,
          end_ = i - 1, -- 0-indexed, exclusive
        }
        range_start = nil
      end
    end
  end

  -- Close final range
  if range_start then
    changed_ranges[#changed_ranges + 1] = {
      start = range_start,
      end_ = max_lines, -- 0-indexed, exclusive
    }
  end

  -- Per-line highlight comparison, also include lines where text changed
  -- (nvim_buf_set_lines destroys extmarks on replaced lines even if highlights are identical)
  local hl_dirty_set = {}
  local check_lines = math.max(#new_lines, #old_lines)
  for i = 0, check_lines - 1 do
    if text_changed_lines[i] then
      hl_dirty_set[i] = true
    else
      local old_key = hl_line_key(old_hl_by_line[i])
      local new_key = hl_line_key(new_hl_by_line[i])
      if old_key ~= new_key then
        hl_dirty_set[i] = true
      end
    end
  end

  -- Convert set to sorted array
  for line in pairs(hl_dirty_set) do
    hl_dirty_lines[#hl_dirty_lines + 1] = line
  end
  table.sort(hl_dirty_lines)

  return {
    text_changed = text_changed,
    changed_ranges = changed_ranges,
    hl_dirty_lines = hl_dirty_lines,
    line_count_changed = line_count_changed,
  }
end

---Apply a diff result to a buffer
---@param bufnr number Buffer number
---@param ns_id number Namespace ID for highlights
---@param diff DiffResult The computed diff
---@param new_lines string[] Full new lines array
---@param new_hl_by_line table<number, table[]> New highlights indexed by line
function M.apply_diff(bufnr, ns_id, diff, new_lines, new_hl_by_line)
  -- Apply text changes by range (bottom-to-top so insertions/deletions don't shift earlier ranges)
  if diff.text_changed then
    vim.api.nvim_set_option_value('modifiable', true, { buf = bufnr })
    for i = #diff.changed_ranges, 1, -1 do
      local range = diff.changed_ranges[i]
      local range_lines = {}
      for j = range.start + 1, math.min(range.end_, #new_lines) do
        range_lines[#range_lines + 1] = new_lines[j]
      end
      vim.api.nvim_buf_set_lines(bufnr, range.start, range.end_, false, range_lines)
    end
    vim.api.nvim_set_option_value('modifiable', false, { buf = bufnr })
  end

  -- Apply highlight changes per dirty line
  for _, line in ipairs(diff.hl_dirty_lines) do
    -- Only touch lines that exist in the new buffer
    if line < #new_lines then
      vim.api.nvim_buf_clear_namespace(bufnr, ns_id, line, line + 1)
      local hls = new_hl_by_line[line]
      if hls then
        for _, hl in ipairs(hls) do
          if hl.hl_group and hl.col_start and hl.col_end then
            vim.api.nvim_buf_add_highlight(
              bufnr, ns_id, hl.hl_group, line, hl.col_start, hl.col_end)
          end
        end
      end
    end
  end
end

---Convenience: index highlights by line (exposed for apply_diff callers)
---@param highlights table[] Flat highlight array
---@return table<number, table[]>
function M.index_highlights(highlights)
  return index_highlights(highlights)
end

return M
