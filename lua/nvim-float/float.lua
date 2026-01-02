---@module 'nvim-float.float'
---@brief Backward compatibility shim - delegates to nvim-float.window
---
---This file exists for backward compatibility.
---New code should require("nvim-float.window") directly.

return require("nvim-float.window")
