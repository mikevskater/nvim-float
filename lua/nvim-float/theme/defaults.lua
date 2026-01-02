---@module 'nvim-float.theme.defaults'
---@brief Default highlight group definitions for nvim-float

local M = {}

-- ============================================================================
-- Default Highlight Definitions
-- ============================================================================

---Default highlight group definitions (VS Code Dark+ inspired)
---Each entry is { fg, bg, attrs } or { link = "GroupName" }
---@type table<string, table>
M.highlights = {
  -- Float window
  NvimFloatNormal = { link = "NormalFloat" },
  NvimFloatBorder = { fg = "#569CD6" },
  NvimFloatTitle = { fg = "#C586C0", bold = true },
  NvimFloatSelected = { fg = "#FFFFFF", bg = "#04395E" },
  NvimFloatCursor = { link = "Cursor" },
  NvimFloatHint = { fg = "#858585" },

  -- Input fields
  NvimFloatInput = { bg = "#2D2D2D", fg = "#CCCCCC" },
  NvimFloatInputActive = { bg = "#3C3C3C", fg = "#FFFFFF", bold = true },
  NvimFloatInputPlaceholder = { bg = "#2D2D2D", fg = "#666666", italic = true },
  NvimFloatInputLabel = { fg = "#569CD6" },
  NvimFloatInputBorder = { fg = "#569CD6" },

  -- Dropdowns
  NvimFloatDropdown = { bg = "#2D2D2D", fg = "#CCCCCC" },
  NvimFloatDropdownSelected = { fg = "#FFFFFF", bg = "#04395E" },
  NvimFloatDropdownBorder = { fg = "#569CD6" },

  -- Scrollbar
  NvimFloatScrollbar = { bg = "NONE" },
  NvimFloatScrollbarThumb = { fg = "#569CD6" },
  NvimFloatScrollbarTrack = { fg = "#3C3C3C" },
  NvimFloatScrollbarArrow = { fg = "#858585" },

  -- Content styles - headers and structure
  NvimFloatHeader = { fg = "#9CDCFE", bold = true },
  NvimFloatSubheader = { fg = "#9CDCFE", bold = true },
  NvimFloatSection = { fg = "#C586C0", bold = true },

  -- Content styles - labels and values
  NvimFloatLabel = { fg = "#4EC9B0" },
  NvimFloatValue = { fg = "#9CDCFE" },
  NvimFloatKey = { fg = "#569CD6" },

  -- Content styles - emphasis
  NvimFloatEmphasis = { fg = "#4EC9B0" },
  NvimFloatStrong = { fg = "#569CD6", bold = true },
  NvimFloatHighlight = { link = "Search" },
  NvimFloatSearchMatch = { bg = "#613214" },

  -- Content styles - status
  NvimFloatSuccess = { fg = "#4EC9B0" },
  NvimFloatWarning = { fg = "#D7BA7D" },
  NvimFloatError = { fg = "#F48771" },

  -- Content styles - muted
  NvimFloatMuted = { fg = "#6A6A6A" },
  NvimFloatDim = { fg = "#4A4A4A" },
  NvimFloatComment = { fg = "#6A9955", italic = true },

  -- Code/syntax styles
  NvimFloatKeyword = { fg = "#569CD6", bold = true },
  NvimFloatString = { fg = "#CE9178" },
  NvimFloatNumber = { fg = "#B5CEA8" },
  NvimFloatOperator = { fg = "#D4D4D4" },
  NvimFloatFunction = { fg = "#DCDCAA" },
  NvimFloatType = { fg = "#4EC9B0" },
}

-- ============================================================================
-- Persistence
-- ============================================================================

---Get the filepath for persisted style overrides
---@return string filepath
function M.get_persistence_path()
  return vim.fn.stdpath("data") .. "/nvim_float_style.lua"
end

---Load persisted style overrides from disk
---@return table<string, table>?
function M.load_persisted()
  local filepath = M.get_persistence_path()
  if vim.fn.filereadable(filepath) ~= 1 then
    return nil
  end

  local ok, result = pcall(dofile, filepath)
  if not ok or type(result) ~= "table" then
    return nil
  end

  return result
end

-- ============================================================================
-- Highlight Group Helpers
-- ============================================================================

---Get the default highlight definition for a group
---@param name string Highlight group name
---@return table? definition The default definition or nil
function M.get(name)
  return M.highlights[name]
end

---Get all defined highlight group names
---@return string[]
function M.get_all_names()
  local groups = {}
  for name, _ in pairs(M.highlights) do
    table.insert(groups, name)
  end
  table.sort(groups)
  return groups
end

---Check if a highlight group is defined
---@param name string Highlight group name
---@return boolean
function M.exists(name)
  return M.highlights[name] ~= nil
end

return M
