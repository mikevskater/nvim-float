---@module 'nvim-float.theme.styles'
---@brief Style name to highlight group mappings for nvim-float

local M = {}

-- ============================================================================
-- Core Style Mappings
-- ============================================================================

---Maps semantic style names to highlight groups
---This is the core mapping used by ContentBuilder and other modules
---@type table<string, string?>
M.mappings = {
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
  dimmed = "NvimFloatDim",  -- Alias
  comment = "NvimFloatComment",

  -- Code/syntax styles
  keyword = "NvimFloatKeyword",
  code_keyword = "NvimFloatKeyword",
  string = "NvimFloatString",
  code_string = "NvimFloatString",
  number = "NvimFloatNumber",
  code_number = "NvimFloatNumber",
  operator = "NvimFloatOperator",
  func = "NvimFloatFunction",
  code_function = "NvimFloatFunction",
  type = "NvimFloatType",
  code = "NvimFloatValue",  -- Generic code style
  code_comment = "NvimFloatComment",

  -- Input field styles
  input = "NvimFloatInput",
  input_active = "NvimFloatInputActive",
  input_placeholder = "NvimFloatInputPlaceholder",

  -- Dropdown field styles
  dropdown = "NvimFloatDropdown",
  dropdown_active = "NvimFloatInputActive",
  dropdown_selected = "NvimFloatDropdownSelected",
  dropdown_arrow = "NvimFloatHint",

  -- Window elements
  normal = nil,
  none = nil,
  border = "NvimFloatBorder",
  selected = "NvimFloatSelected",
  hint = "NvimFloatHint",
}

---Custom style mappings registered by plugins
---@type table<string, string>
local custom_mappings = {}

-- ============================================================================
-- Public API
-- ============================================================================

---Get the highlight group for a semantic style name
---@param style string Semantic style name
---@return string? hl_group Highlight group name or nil
function M.get(style)
  -- Check custom mappings first (allows overrides)
  if custom_mappings[style] then
    return custom_mappings[style]
  end
  return M.mappings[style]
end

---Register additional style mappings
---Allows plugins to add their own style name → highlight group mappings
---@param mappings table<string, string> Map of style name → highlight group
function M.register(mappings)
  for style, hl_group in pairs(mappings) do
    custom_mappings[style] = hl_group
  end
end

---Clear custom style mappings
function M.clear_custom()
  custom_mappings = {}
end

---Get all registered style names
---@return string[]
function M.get_all_names()
  local names = {}
  local seen = {}

  -- Add core mappings
  for name, _ in pairs(M.mappings) do
    if not seen[name] then
      table.insert(names, name)
      seen[name] = true
    end
  end

  -- Add custom mappings
  for name, _ in pairs(custom_mappings) do
    if not seen[name] then
      table.insert(names, name)
      seen[name] = true
    end
  end

  table.sort(names)
  return names
end

---Check if a style name is defined
---@param style string Style name
---@return boolean
function M.exists(style)
  return M.mappings[style] ~= nil or custom_mappings[style] ~= nil
end

---Get all mappings (core + custom merged)
---@return table<string, string?>
function M.get_all()
  local result = vim.tbl_extend("force", {}, M.mappings)
  for style, hl_group in pairs(custom_mappings) do
    result[style] = hl_group
  end
  return result
end

return M
