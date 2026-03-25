---@module 'nvim-float.content.highlights'
---@brief Highlight building and buffer rendering for ContentBuilder

local Styles = require("nvim-float.theme.styles")
local Diff = require("nvim-float.content.diff")

local M = {}

-- Per-buffer render caches for diff-based rendering
---@type table<number, RenderCache>
local _render_caches = {}

-- Shared chunked state (referenced from ContentBuilder)
local _chunked_state = {}

---Remove cache entries for buffers that no longer exist
local function prune_invalid_caches()
  for bufnr in pairs(_render_caches) do
    if not vim.api.nvim_buf_is_valid(bufnr) then
      _render_caches[bufnr] = nil
    end
  end
end

-- ============================================================================
-- Build Methods
-- ============================================================================

---Build and return the plain text lines (for buffer content)
---@param cb ContentBuilder
---@return string[] lines Array of text lines
function M.build_lines(cb)
  local lines = {}
  for _, line in ipairs(cb._lines) do
    table.insert(lines, line.text)
  end
  return lines
end

---Build and return highlight data (mapped styles only)
---@param cb ContentBuilder
---@return table[] highlights Array of { line, col_start, col_end, hl_group }
function M.build_highlights(cb)
  local highlights = {}
  for line_idx, line in ipairs(cb._lines) do
    for _, hl in ipairs(line.highlights) do
      -- Use direct hl_group if set, otherwise map from style
      local hl_group = hl.hl_group or Styles.get(hl.style)
      if hl_group then
        table.insert(highlights, {
          line = line_idx - 1,  -- 0-indexed
          col_start = hl.col_start,
          col_end = hl.col_end,
          hl_group = hl_group,
        })
      end
    end
  end
  return highlights
end

---Build and return highlight data (alias for build_highlights)
---@param cb ContentBuilder
---@return table[] highlights
function M.build_raw_highlights(cb)
  return M.build_highlights(cb)
end

-- ============================================================================
-- Buffer Application Methods
-- ============================================================================

---Apply highlights to a buffer
---@param cb ContentBuilder
---@param bufnr number Buffer number
---@param ns_id number? Namespace ID (creates one if nil)
---@return number ns_id The namespace ID used
function M.apply_to_buffer(cb, bufnr, ns_id)
  ns_id = ns_id or vim.api.nvim_create_namespace("nvim_float_content_builder")

  -- Clear existing highlights in namespace
  vim.api.nvim_buf_clear_namespace(bufnr, ns_id, 0, -1)

  -- Build lines for fallback col_end calculation
  local lines = M.build_lines(cb)

  -- Apply new highlights
  local highlights = M.build_highlights(cb)
  for _, hl in ipairs(highlights) do
    local col_end = hl.col_end

    -- Ensure col_end is valid (not nil/0) to prevent highlighting to end of line
    if not col_end or col_end <= 0 then
      -- Fallback to line length
      local line_text = lines[hl.line + 1]
      if line_text then
        col_end = #line_text
      end
    end

    -- Only apply if we have valid bounds
    if col_end and col_end > hl.col_start then
      pcall(vim.api.nvim_buf_add_highlight, bufnr, ns_id, hl.hl_group, hl.line, hl.col_start, col_end)
    end
  end

  return ns_id
end

---Clear the render cache for a buffer (forces full render on next call)
---@param bufnr number Buffer number
function M.clear_render_cache(bufnr)
  _render_caches[bufnr] = nil
end

---Diff-based render with raw lines and highlights
---@param bufnr number Buffer number
---@param ns_id number? Namespace ID
---@param lines string[] Text lines to render
---@param highlights table[] Highlight entries { line, col_start, col_end, hl_group }
---@return string[] lines The lines that were set
---@return number ns_id The namespace ID used
---@return DiffResult? diff_result Nil on first render, DiffResult on subsequent
function M.render_diff(bufnr, ns_id, lines, highlights)
  ns_id = ns_id or vim.api.nvim_create_namespace("nvim_float_content_builder")
  prune_invalid_caches()

  local cache = _render_caches[bufnr]
  local diff_result = nil

  if cache then
    local diff = Diff.compute(cache, lines, highlights)
    diff_result = diff

    if not diff.text_changed and #diff.hl_dirty_lines == 0 then
      -- Nothing changed — zero API calls
      _render_caches[bufnr] = Diff.create_cache(lines, highlights)
      return lines, ns_id, diff_result
    end

    -- Apply surgical diff (handles line-count changes via reverse iteration)
    local new_hl_by_line = Diff.index_highlights(highlights)
    Diff.apply_diff(bufnr, ns_id, diff, lines, new_hl_by_line)
  else
    -- No cache: full render
    vim.api.nvim_set_option_value('modifiable', true, { buf = bufnr })
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    vim.api.nvim_set_option_value('modifiable', false, { buf = bufnr })

    -- Full highlight application
    vim.api.nvim_buf_clear_namespace(bufnr, ns_id, 0, -1)
    for _, hl in ipairs(highlights) do
      local col_end = hl.col_end
      if not col_end or col_end <= 0 then
        local line_text = lines[hl.line + 1]
        if line_text then col_end = #line_text end
      end
      if col_end and col_end > hl.col_start then
        pcall(vim.api.nvim_buf_add_highlight, bufnr, ns_id, hl.hl_group, hl.line, hl.col_start, col_end)
      end
    end
  end

  _render_caches[bufnr] = Diff.create_cache(lines, highlights)
  return lines, ns_id, diff_result
end

---Build everything and apply to a buffer in one call (diff-aware)
---@param cb ContentBuilder
---@param bufnr number Buffer number
---@param ns_id number? Namespace ID
---@return string[] lines The lines that were set
---@return number ns_id The namespace ID used
---@return DiffResult? diff_result Nil on first render, DiffResult on subsequent
function M.render_to_buffer(cb, bufnr, ns_id)
  local lines = M.build_lines(cb)
  local highlights = M.build_highlights(cb)
  return M.render_diff(bufnr, ns_id, lines, highlights)
end

-- ============================================================================
-- Chunked Rendering
-- ============================================================================

---Build everything and apply to a buffer in chunks to avoid blocking UI
---@param cb ContentBuilder
---@param bufnr number Buffer number
---@param ns_id number? Namespace ID
---@param opts table? Options: { chunk_size?, on_progress?, on_complete? }
function M.render_to_buffer_chunked(cb, bufnr, ns_id, opts)
  local lines = M.build_lines(cb)
  local highlights = M.build_highlights(cb)

  opts = opts or {}
  local chunk_size = opts.chunk_size or 100
  local on_progress = opts.on_progress
  local on_complete = opts.on_complete
  local total_lines = #lines

  ns_id = ns_id or vim.api.nvim_create_namespace("nvim_float_content_builder")

  -- Cancel any existing chunked render for this buffer
  M.cancel_chunked_render(bufnr)

  -- For small line counts, use sync render
  if total_lines <= chunk_size then
    M.render_to_buffer(cb, bufnr, ns_id)
    if on_progress then on_progress(total_lines, total_lines) end
    if on_complete then on_complete(lines, ns_id) end
    return
  end

  -- Initialize chunked state for this buffer
  _chunked_state[bufnr] = {
    timer = nil,
    cancelled = false,
  }

  local state = _chunked_state[bufnr]
  local current_idx = 1
  local is_first_chunk = true

  -- Make buffer modifiable for the duration of chunked write
  vim.api.nvim_set_option_value('modifiable', true, { buf = bufnr })

  -- Clear existing highlights
  vim.api.nvim_buf_clear_namespace(bufnr, ns_id, 0, -1)

  local function write_next_chunk()
    -- Check if cancelled or buffer no longer valid
    if state.cancelled or not vim.api.nvim_buf_is_valid(bufnr) then
      _chunked_state[bufnr] = nil
      return
    end

    local end_idx = math.min(current_idx + chunk_size - 1, total_lines)

    -- Extract chunk of lines
    local chunk = {}
    for i = current_idx, end_idx do
      table.insert(chunk, lines[i])
    end

    -- Write chunk to buffer
    if is_first_chunk then
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, chunk)
      is_first_chunk = false
    else
      local append_start = current_idx - 1
      vim.api.nvim_buf_set_lines(bufnr, append_start, append_start, false, chunk)
    end

    -- Apply highlights for lines in this chunk
    for _, hl in ipairs(highlights) do
      local line_0idx = hl.line
      local line_1idx = line_0idx + 1
      if line_1idx >= current_idx and line_1idx <= end_idx then
        local col_end = hl.col_end

        -- Ensure col_end is valid (not nil/0) to prevent highlighting to end of line
        if not col_end or col_end <= 0 then
          local line_text = lines[line_1idx]
          if line_text then
            col_end = #line_text
          end
        end

        if col_end and col_end > hl.col_start then
          pcall(vim.api.nvim_buf_add_highlight, bufnr, ns_id, hl.hl_group, line_0idx, hl.col_start, col_end)
        end
      end
    end

    -- Report progress
    if on_progress then
      on_progress(end_idx, total_lines)
    end

    current_idx = end_idx + 1

    if current_idx <= total_lines then
      -- Schedule next chunk
      state.timer = vim.fn.timer_start(0, function()
        state.timer = nil
        vim.schedule(write_next_chunk)
      end)
    else
      -- All chunks written - finalize
      vim.api.nvim_set_option_value('modifiable', false, { buf = bufnr })
      _chunked_state[bufnr] = nil

      if on_complete then
        on_complete(lines, ns_id)
      end
    end
  end

  -- Start writing first chunk
  write_next_chunk()
end

---Cancel any in-progress chunked render for a buffer
---@param bufnr number Buffer number
function M.cancel_chunked_render(bufnr)
  local state = _chunked_state[bufnr]
  if state then
    state.cancelled = true
    if state.timer then
      vim.fn.timer_stop(state.timer)
      state.timer = nil
    end
    if vim.api.nvim_buf_is_valid(bufnr) then
      pcall(vim.api.nvim_set_option_value, 'modifiable', false, { buf = bufnr })
    end
    _chunked_state[bufnr] = nil
  end
end

---Check if a chunked render is currently in progress
---@param bufnr number Buffer number
---@return boolean
function M.is_chunked_render_active(bufnr)
  local state = _chunked_state[bufnr]
  return state ~= nil and not state.cancelled
end

return M
