---@module nvim-float.style_editor.render
---Rendering functions for the style editor colors panel

local M = {}

local Data = require("nvim-float.style_editor.data")
local ContentBuilder = require("nvim-float.content_builder")

---Namespace for swatch extmarks
local swatch_ns = vim.api.nvim_create_namespace("nvim_float_style_editor_swatch")

---Swatch character (bullet)
local SWATCH_CHAR = "●"
local SWATCH_BYTES = 3 -- UTF-8 bytes for ●

---Format a color value for display
---@param hl table Highlight definition from nvim_get_hl
---@return string
local function format_color_value(hl)
  local parts = {}

  if hl.fg then
    local fg = type(hl.fg) == "number" and string.format("#%06X", hl.fg) or tostring(hl.fg)
    table.insert(parts, fg)
  end

  if hl.bg then
    local bg = type(hl.bg) == "number" and string.format("#%06X", hl.bg) or tostring(hl.bg)
    if #parts > 0 then
      table.insert(parts, "/ " .. bg)
    else
      table.insert(parts, bg)
    end
  end

  if hl.bold then table.insert(parts, "B") end
  if hl.italic then table.insert(parts, "I") end

  if #parts == 0 then
    if hl.link then
      return "→ " .. hl.link
    end
    return "default"
  end

  return table.concat(parts, " ")
end

---Render the colors panel content
---@param state StyleEditorState
---@return string[] lines
---@return table[] highlights
function M.render_colors(state)
  local cb = ContentBuilder.new()
  local current_category = nil

  cb:blank()

  for i, def in ipairs(Data.HIGHLIGHT_DEFINITIONS) do
    -- Category header
    if def.category ~= current_category then
      if current_category ~= nil then
        cb:blank()
      end
      cb:styled("  ─── " .. def.category .. " ───", "section")
      cb:blank()
      current_category = def.category
    end

    -- Get current highlight values
    local hl = vim.api.nvim_get_hl(0, { name = def.key })
    local color_str = format_color_value(hl)
    local is_selected = (i == state.selected_color_idx)

    -- Build the line with selection indicator
    local prefix = is_selected and " ▸ " or "   "
    local name_padded = string.format("%-20s", def.name)

    if is_selected then
      cb:spans({
        { text = prefix, style = "emphasis" },
        { text = name_padded, style = "strong" },
        { text = SWATCH_CHAR }, -- Will be overwritten by extmark
        { text = " " .. color_str, style = "value" },
      })
    else
      cb:spans({
        { text = prefix, style = "muted" },
        { text = name_padded, style = "label" },
        { text = SWATCH_CHAR }, -- Will be overwritten by extmark
        { text = " " .. color_str, style = "muted" },
      })
    end
  end

  cb:blank()

  return cb:build_lines(), cb:build_highlights()
end

---Calculate the cursor line for a given color index
---@param color_idx number 1-indexed color index
---@return number line 0-indexed line number
function M.get_color_cursor_line(color_idx)
  local line = 1 -- Start after initial blank line
  local current_category = nil

  for i, def in ipairs(Data.HIGHLIGHT_DEFINITIONS) do
    -- Account for category headers
    if def.category ~= current_category then
      if current_category ~= nil then
        line = line + 1 -- Blank line before category
      end
      line = line + 1 -- Category header
      line = line + 1 -- Blank line after header
      current_category = def.category
    end

    if i == color_idx then
      return line
    end

    line = line + 1
  end

  return 1
end

---Apply swatch highlight extmarks to the buffer
---@param bufnr number Buffer number
---@param state StyleEditorState
function M.apply_swatch_highlights(bufnr, state)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  -- Clear existing swatch highlights
  vim.api.nvim_buf_clear_namespace(bufnr, swatch_ns, 0, -1)

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local current_category = nil
  local line_idx = 1 -- Start after initial blank line (0-indexed)

  for i, def in ipairs(Data.HIGHLIGHT_DEFINITIONS) do
    -- Account for category headers
    if def.category ~= current_category then
      if current_category ~= nil then
        line_idx = line_idx + 1 -- Blank line before category
      end
      line_idx = line_idx + 1 -- Category header
      line_idx = line_idx + 1 -- Blank line after header
      current_category = def.category
    end

    -- Get current highlight colors
    local hl = vim.api.nvim_get_hl(0, { name = def.key })

    -- Create dynamic highlight group for this swatch
    local hl_name = "StyleEditorSwatch" .. i
    local hl_def = {}

    if hl.fg then
      hl_def.fg = hl.fg
    elseif hl.bg then
      -- If only bg, show that as fg for the swatch
      hl_def.fg = hl.bg
    elseif hl.link then
      -- Resolve linked highlight
      local linked = vim.api.nvim_get_hl(0, { name = hl.link, link = false })
      if linked.fg then
        hl_def.fg = linked.fg
      elseif linked.bg then
        hl_def.fg = linked.bg
      end
    end

    -- Only apply if we have a color to show
    if hl_def.fg or hl_def.bg then
      vim.api.nvim_set_hl(0, hl_name, hl_def)

      -- Find swatch position in line
      local line_text = lines[line_idx + 1] -- 1-indexed
      if line_text then
        local swatch_start = line_text:find(SWATCH_CHAR, 1, true)
        if swatch_start then
          local col_start = swatch_start - 1 -- 0-indexed
          pcall(vim.api.nvim_buf_set_extmark, bufnr, swatch_ns, line_idx, col_start, {
            end_col = col_start + SWATCH_BYTES,
            hl_group = hl_name,
          })
        end
      end
    end

    line_idx = line_idx + 1
  end
end

---Clear all swatch highlights
---@param bufnr number? Buffer number (optional, clears highlight groups regardless)
function M.clear_swatch_highlights(bufnr)
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_buf_clear_namespace(bufnr, swatch_ns, 0, -1)
  end

  -- Clear the dynamic highlight groups
  for i = 1, #Data.HIGHLIGHT_DEFINITIONS do
    pcall(vim.api.nvim_set_hl, 0, "StyleEditorSwatch" .. i, {})
  end
end

return M
