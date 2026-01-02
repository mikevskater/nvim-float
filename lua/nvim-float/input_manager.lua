---@module 'nvim-float.input_manager'
---@brief Backward compatibility shim - delegates to nvim-float.input
---
---This file exists for backward compatibility.
---New code should require("nvim-float.input") directly.

return require("nvim-float.input")
