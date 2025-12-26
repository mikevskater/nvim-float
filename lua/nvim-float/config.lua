---@module nvim-float.config
---Configuration management for nvim-float

---@class NvimFloatConfig
---@field debug boolean Enable debug logging (default: false)
---@field theme NvimFloatThemeConfig? Theme configuration overrides
---@field defaults NvimFloatDefaults? Default values for float windows

---@class NvimFloatDefaults
---@field border "none"|"single"|"double"|"rounded"|"solid"|"shadow"|table? Default border style
---@field title_pos "left"|"center"|"right"? Default title position
---@field winblend number? Default window transparency (0-100)
---@field zindex number? Default z-index for windows

local M = {}

-- Default configuration
local defaults = {
  debug = false,
  theme = {},
  defaults = {
    border = "rounded",
    title_pos = "center",
    winblend = 0,
    zindex = 50,
  },
}

-- Current configuration (merged with user opts)
local config = vim.deepcopy(defaults)

---Setup configuration with user options
---@param opts NvimFloatConfig? User configuration
function M.setup(opts)
  opts = opts or {}

  -- Deep merge user options with defaults
  config = vim.tbl_deep_extend("force", defaults, opts)

  -- Enable/disable debug logging based on config
  if config.debug then
    local Debug = require("nvim-float.debug")
    Debug.enable()
  end
end

---Get the current configuration
---@return NvimFloatConfig
function M.get()
  return config
end

---Get a specific configuration value
---@param key string Dot-separated key path (e.g., "defaults.border")
---@return any
function M.get_value(key)
  local parts = vim.split(key, ".", { plain = true })
  local value = config
  for _, part in ipairs(parts) do
    if type(value) ~= "table" then
      return nil
    end
    value = value[part]
  end
  return value
end

---Get default float configuration
---@return NvimFloatDefaults
function M.get_defaults()
  return config.defaults
end

return M
