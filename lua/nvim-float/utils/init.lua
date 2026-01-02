---@module 'nvim-float.utils'
---@brief Shared utility functions for nvim-float
---
---This module provides common buffer and highlight operations
---used throughout the nvim-float plugin.

local M = {}

-- Lazy-loaded submodules
local _buffer, _highlight

---Get buffer utilities
---@return table
function M.buffer()
  if not _buffer then
    _buffer = require("nvim-float.utils.buffer")
  end
  return _buffer
end

---Get highlight utilities
---@return table
function M.highlight()
  if not _highlight then
    _highlight = require("nvim-float.utils.highlight")
  end
  return _highlight
end

return M
