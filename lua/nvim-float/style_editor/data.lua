---@module nvim-float.style_editor.data
---Highlight group definitions for the style editor

local M = {}

---@class HighlightDefinition
---@field key string The highlight group name
---@field name string Display name for the UI
---@field category string Category name
---@field has_bg boolean? Whether this group typically uses bg color
---@field has_fg boolean? Whether this group typically uses fg color (default true)
---@field note string? Optional note/warning about this highlight

---All highlight groups organized by category
---@type HighlightDefinition[]
M.HIGHLIGHT_DEFINITIONS = {
  -- Window
  { key = "NvimFloatNormal", name = "Window Base", category = "Window", has_bg = true, note = "Base for all unstyled text" },
  { key = "NvimFloatBorder", name = "Border", category = "Window" },
  { key = "NvimFloatTitle", name = "Title", category = "Window" },
  { key = "NvimFloatSelected", name = "Selected", category = "Window", has_bg = true },
  { key = "NvimFloatCursor", name = "Cursor", category = "Window", has_bg = true },
  { key = "NvimFloatHint", name = "Hint", category = "Window" },

  -- Input
  { key = "NvimFloatInput", name = "Input", category = "Input", has_bg = true },
  { key = "NvimFloatInputActive", name = "Input Active", category = "Input", has_bg = true },
  { key = "NvimFloatInputPlaceholder", name = "Placeholder", category = "Input" },
  { key = "NvimFloatInputLabel", name = "Label", category = "Input" },
  { key = "NvimFloatInputBorder", name = "Border", category = "Input" },

  -- Dropdown
  { key = "NvimFloatDropdown", name = "Dropdown", category = "Dropdown", has_bg = true },
  { key = "NvimFloatDropdownSelected", name = "Selected", category = "Dropdown", has_bg = true },
  { key = "NvimFloatDropdownBorder", name = "Border", category = "Dropdown" },

  -- Scrollbar
  { key = "NvimFloatScrollbar", name = "Background", category = "Scrollbar", has_bg = true, has_fg = false },
  { key = "NvimFloatScrollbarThumb", name = "Thumb", category = "Scrollbar" },
  { key = "NvimFloatScrollbarTrack", name = "Track", category = "Scrollbar" },
  { key = "NvimFloatScrollbarArrow", name = "Arrow", category = "Scrollbar" },

  -- Headers
  { key = "NvimFloatHeader", name = "Header", category = "Headers" },
  { key = "NvimFloatSubheader", name = "Subheader", category = "Headers" },
  { key = "NvimFloatSection", name = "Section", category = "Headers" },

  -- Labels
  { key = "NvimFloatLabel", name = "Label", category = "Labels" },
  { key = "NvimFloatValue", name = "Value", category = "Labels" },
  { key = "NvimFloatKey", name = "Key", category = "Labels" },

  -- Emphasis
  { key = "NvimFloatEmphasis", name = "Emphasis", category = "Emphasis" },
  { key = "NvimFloatStrong", name = "Strong", category = "Emphasis" },
  { key = "NvimFloatHighlight", name = "Highlight", category = "Emphasis", has_bg = true },
  { key = "NvimFloatSearchMatch", name = "Search Match", category = "Emphasis", has_bg = true },

  -- Status
  { key = "NvimFloatSuccess", name = "Success", category = "Status" },
  { key = "NvimFloatWarning", name = "Warning", category = "Status" },
  { key = "NvimFloatError", name = "Error", category = "Status" },

  -- Muted
  { key = "NvimFloatMuted", name = "Muted", category = "Muted" },
  { key = "NvimFloatDim", name = "Dim", category = "Muted" },
  { key = "NvimFloatComment", name = "Comment", category = "Muted" },

  -- Code
  { key = "NvimFloatKeyword", name = "Keyword", category = "Code" },
  { key = "NvimFloatString", name = "String", category = "Code" },
  { key = "NvimFloatNumber", name = "Number", category = "Code" },
  { key = "NvimFloatOperator", name = "Operator", category = "Code" },
  { key = "NvimFloatFunction", name = "Function", category = "Code" },
  { key = "NvimFloatType", name = "Type", category = "Code" },
}

---Get ordered list of unique categories
---@return string[]
function M.get_categories()
  local seen = {}
  local categories = {}
  for _, def in ipairs(M.HIGHLIGHT_DEFINITIONS) do
    if not seen[def.category] then
      seen[def.category] = true
      table.insert(categories, def.category)
    end
  end
  return categories
end

---Get highlight definitions by category
---@param category string Category name
---@return HighlightDefinition[]
function M.get_by_category(category)
  local result = {}
  for _, def in ipairs(M.HIGHLIGHT_DEFINITIONS) do
    if def.category == category then
      table.insert(result, def)
    end
  end
  return result
end

---Find definition by key
---@param key string Highlight group name
---@return HighlightDefinition?
function M.get_by_key(key)
  for _, def in ipairs(M.HIGHLIGHT_DEFINITIONS) do
    if def.key == key then
      return def
    end
  end
  return nil
end

---Get index of definition by key
---@param key string Highlight group name
---@return number? index 1-indexed
function M.get_index_by_key(key)
  for i, def in ipairs(M.HIGHLIGHT_DEFINITIONS) do
    if def.key == key then
      return i
    end
  end
  return nil
end

return M
