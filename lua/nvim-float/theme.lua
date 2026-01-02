---@module nvim-float.theme
---Theme and highlight group definitions for nvim-float
---
---This module defines all the highlight groups used by nvim-float.
---Users can override these by defining their own highlights after setup().

local M = {}

---@class NvimFloatThemeConfig
---@field link_to_existing boolean? Link to existing Neovim highlight groups (default: true)
---@field override table<string, table>? Custom highlight overrides

---Default highlight group definitions (VS Code Dark+ inspired, matching SSNS)
---Each entry is { fg, bg, attrs } or { link = "GroupName" }
local default_highlights = {
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

---Custom highlight groups registered by plugins
---@type table<string, table>
local custom_highlights = {}

---Persisted style overrides from style editor
---@type table<string, table>?
local persisted_overrides = nil

---Load persisted style overrides from disk
---@return table<string, table>?
local function load_persisted_overrides()
  local filepath = vim.fn.stdpath("data") .. "/nvim_float_style.lua"
  if vim.fn.filereadable(filepath) ~= 1 then
    return nil
  end

  local ok, result = pcall(dofile, filepath)
  if not ok or type(result) ~= "table" then
    return nil
  end

  return result
end

---Register additional highlight groups
---Allows plugins to add their own highlight groups
---@param highlights table<string, table> Map of highlight group name -> definition
function M.register_highlights(highlights)
  for name, def in pairs(highlights) do
    custom_highlights[name] = def
  end
  -- Apply immediately if already setup
  for name, def in pairs(highlights) do
    vim.api.nvim_set_hl(0, name, def)
  end
end

---Setup highlight groups
---@param opts NvimFloatThemeConfig? Theme configuration
function M.setup(opts)
  opts = opts or {}

  -- Load persisted overrides from style editor (if any)
  persisted_overrides = load_persisted_overrides()

  -- Apply default highlights
  -- Priority: persisted > user config > default
  for name, def in pairs(default_highlights) do
    local persisted_def = persisted_overrides and persisted_overrides[name]
    local user_def = opts.override and opts.override[name]

    if persisted_def then
      vim.api.nvim_set_hl(0, name, persisted_def)
    elseif user_def then
      vim.api.nvim_set_hl(0, name, user_def)
    else
      vim.api.nvim_set_hl(0, name, def)
    end
  end

  -- Apply custom highlights registered by plugins
  for name, def in pairs(custom_highlights) do
    local persisted_def = persisted_overrides and persisted_overrides[name]
    local user_def = opts.override and opts.override[name]

    if persisted_def then
      vim.api.nvim_set_hl(0, name, persisted_def)
    elseif user_def then
      vim.api.nvim_set_hl(0, name, user_def)
    else
      vim.api.nvim_set_hl(0, name, def)
    end
  end
end

---Get the highlight group name for a semantic style
---This maps user-friendly style names to actual highlight groups
---Note: ContentBuilder.register_styles() is the preferred way to add custom styles
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

---Get the default highlight definition for a group
---@param name string Highlight group name
---@return table? definition The default definition or nil
function M.get_default_highlight(name)
  return default_highlights[name]
end

return M
