---@module nvim-float.theme
---@brief Backward compatibility shim - delegates to theme/init.lua
---
---This file is kept for backward compatibility.
---New code should use: require("nvim-float.theme")
---which will load theme/init.lua

return require("nvim-float.theme.init")
