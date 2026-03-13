---@class IconEntry
---@field glyph string
---@field name string
---@field group string

local M = {}

---@type IconEntry[]?
local cached = nil

---@type boolean?
local cached_nerd_fonts = nil

---Load and merge icon datasets
---@param opts { nerd_fonts: boolean }
---@return IconEntry[]
function M.load(opts)
  local nerd = opts.nerd_fonts ~= false
  if cached and cached_nerd_fonts == nerd then
    return cached
  end

  local emoji = require('nvim-float.icon_picker.emoji')
  local all = {}

  for i = 1, #emoji do
    all[#all + 1] = emoji[i]
  end

  if nerd then
    local nerdfonts = require('nvim-float.icon_picker.nerdfonts')
    for i = 1, #nerdfonts do
      all[#all + 1] = nerdfonts[i]
    end
  end

  cached = all
  cached_nerd_fonts = nerd
  return all
end

---Filter icons by substring match on name
---@param icons IconEntry[]
---@param query string
---@return IconEntry[]
function M.filter(icons, query)
  if not query or query == "" then return icons end
  local q = query:lower()
  local results = {}
  for i = 1, #icons do
    if string.find(icons[i].name, q, 1, true) then
      results[#results + 1] = icons[i]
    end
  end
  return results
end

return M
