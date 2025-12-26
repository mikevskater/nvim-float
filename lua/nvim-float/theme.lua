---@module nvim-float.theme
---Theme and highlight group definitions for nvim-float
---
---This module defines all the highlight groups used by nvim-float.
---Users can override these by defining their own highlights after setup().

local M = {}

---@class NvimFloatThemeConfig
---@field link_to_existing boolean? Link to existing Neovim highlight groups (default: true)
---@field override table<string, table>? Custom highlight overrides

---Default highlight group definitions
---Each entry is { fg, bg, attrs } or { link = "GroupName" }
local default_highlights = {
  -- Float window
  NvimFloatNormal = { link = "NormalFloat" },
  NvimFloatBorder = { link = "FloatBorder" },
  NvimFloatTitle = { link = "FloatTitle" },
  NvimFloatSelected = { link = "PmenuSel" },
  NvimFloatCursor = { link = "Cursor" },
  NvimFloatHint = { link = "Comment" },

  -- Input fields
  NvimFloatInput = { bg = "#2D2D2D", fg = "#CCCCCC" },
  NvimFloatInputActive = { bg = "#3C3C3C", fg = "#FFFFFF", bold = true },
  NvimFloatInputPlaceholder = { bg = "#2D2D2D", fg = "#666666", italic = true },
  NvimFloatInputLabel = { link = "Label" },
  NvimFloatInputBorder = { link = "FloatBorder" },

  -- Dropdowns
  NvimFloatDropdown = { link = "NvimFloatInput" },
  NvimFloatDropdownSelected = { link = "PmenuSel" },
  NvimFloatDropdownBorder = { link = "FloatBorder" },

  -- Scrollbar
  NvimFloatScrollbar = { bg = "NONE" },
  NvimFloatScrollbarThumb = { link = "NvimFloatTitle" },
  NvimFloatScrollbarTrack = { link = "NvimFloatBorder" },
  NvimFloatScrollbarArrow = { link = "NvimFloatHint" },

  -- Content styles - headers and structure
  NvimFloatHeader = { fg = "#DCDCAA", bold = true },
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
  NvimFloatError = { fg = "#F44747" },

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

  -- Result tables
  NvimFloatTableHeader = { fg = "#9CDCFE", bold = true },
  NvimFloatTableBorder = { fg = "#4A4A4A" },
  NvimFloatTableRow = { link = "Normal" },
  NvimFloatTableRowAlt = { bg = "#252525" },
  NvimFloatTableNull = { fg = "#6A6A6A", italic = true },
  NvimFloatTableMessage = { fg = "#6A9955", italic = true },
  NvimFloatTableString = { link = "NvimFloatString" },
  NvimFloatTableNumber = { link = "NvimFloatNumber" },
  NvimFloatTableDate = { fg = "#D7BA7D" },
  NvimFloatTableBool = { fg = "#569CD6" },
  NvimFloatTableBinary = { fg = "#808080" },
  NvimFloatTableGuid = { fg = "#CE9178" },
}

---Setup highlight groups
---@param opts NvimFloatThemeConfig? Theme configuration
function M.setup(opts)
  opts = opts or {}

  -- Apply default highlights
  for name, def in pairs(default_highlights) do
    -- Check for user override
    local user_def = opts.override and opts.override[name]
    if user_def then
      vim.api.nvim_set_hl(0, name, user_def)
    else
      vim.api.nvim_set_hl(0, name, def)
    end
  end
end

---Get the highlight group name for a semantic style
---This maps user-friendly style names to actual highlight groups
---@param style string Semantic style name
---@return string? hl_group Highlight group name or nil
function M.get_hl_group(style)
  local mappings = {
    -- Headers and titles
    header = "NvimFloatHeader",
    title = "NvimFloatHeader",
    subheader = "NvimFloatSubheader",
    section = "NvimFloatSection",

    -- Labels and values
    label = "NvimFloatLabel",
    value = "NvimFloatValue",
    key = "NvimFloatKey",

    -- Emphasis styles
    emphasis = "NvimFloatEmphasis",
    strong = "NvimFloatStrong",
    highlight = "NvimFloatHighlight",
    search_match = "NvimFloatSearchMatch",

    -- Status styles
    success = "NvimFloatSuccess",
    warning = "NvimFloatWarning",
    error = "NvimFloatError",

    -- Muted/subtle styles
    muted = "NvimFloatMuted",
    dim = "NvimFloatDim",
    comment = "NvimFloatComment",

    -- Code/syntax styles
    keyword = "NvimFloatKeyword",
    string = "NvimFloatString",
    number = "NvimFloatNumber",
    operator = "NvimFloatOperator",
    func = "NvimFloatFunction",
    type = "NvimFloatType",

    -- Input field styles
    input = "NvimFloatInput",
    input_active = "NvimFloatInputActive",
    input_placeholder = "NvimFloatInputPlaceholder",

    -- Dropdown field styles
    dropdown = "NvimFloatDropdown",
    dropdown_active = "NvimFloatInputActive",
    dropdown_arrow = "NvimFloatHint",

    -- Result table styles
    result_header = "NvimFloatTableHeader",
    result_border = "NvimFloatTableBorder",
    result_null = "NvimFloatTableNull",
    result_message = "NvimFloatTableMessage",
    result_string = "NvimFloatTableString",
    result_number = "NvimFloatTableNumber",
    result_date = "NvimFloatTableDate",
    result_bool = "NvimFloatTableBool",
    result_binary = "NvimFloatTableBinary",
    result_guid = "NvimFloatTableGuid",

    -- Special
    normal = nil,
    none = nil,
  }

  return mappings[style]
end

---Get all defined highlight group names
---@return string[]
function M.get_all_groups()
  local groups = {}
  for name, _ in pairs(default_highlights) do
    table.insert(groups, name)
  end
  table.sort(groups)
  return groups
end

return M
