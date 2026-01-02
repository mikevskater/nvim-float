---@module nvim-float.style_editor.preview
---Preview content showing all highlight groups in action

local M = {}

---Build preview content using ContentBuilder
---@return string[] lines
---@return table[] highlights
function M.build()
  local ContentBuilder = require("nvim-float.content_builder")
  local cb = ContentBuilder.new()

  -- Window Elements Section
  cb:blank()
  cb:styled("  === Window Elements ===", "header")
  cb:blank()
  cb:spans({
    { text = "    Normal: ", style = "label" },
    { text = " Background ", hl_group = "NvimFloatNormal" },
    { text = "  Cursor: ", style = "label" },
    { text = " Block ", hl_group = "NvimFloatCursor" },
  })
  cb:spans({
    { text = "    Border: ", style = "label" },
    { text = "─────────", hl_group = "NvimFloatBorder" },
    { text = "  Title: ", style = "label" },
    { text = " Title ", hl_group = "NvimFloatTitle" },
  })
  cb:spans({
    { text = "    Selected: ", style = "label" },
    { text = " Selected Item ", hl_group = "NvimFloatSelected" },
  })
  cb:spans({
    { text = "    Hint: ", style = "label" },
    { text = "Press ? for help", hl_group = "NvimFloatHint" },
  })

  -- Input Elements Section
  cb:blank()
  cb:styled("  === Input Elements ===", "header")
  cb:blank()
  cb:spans({
    { text = "    Input: ", style = "label" },
    { text = " user@example.com ", hl_group = "NvimFloatInput" },
  })
  cb:spans({
    { text = "    Active: ", style = "label" },
    { text = " typing here... ", hl_group = "NvimFloatInputActive" },
  })
  cb:spans({
    { text = "    Placeholder: ", style = "label" },
    { text = "Enter value...", hl_group = "NvimFloatInputPlaceholder" },
  })
  cb:spans({
    { text = "    Label: ", style = "label" },
    { text = "Field Label", hl_group = "NvimFloatInputLabel" },
    { text = "  Border: ", style = "label" },
    { text = "───", hl_group = "NvimFloatInputBorder" },
  })

  -- Dropdown Elements Section
  cb:blank()
  cb:styled("  === Dropdown Elements ===", "header")
  cb:blank()
  cb:spans({
    { text = "    Dropdown: ", style = "label" },
    { text = " Option One ", hl_group = "NvimFloatDropdown" },
  })
  cb:spans({
    { text = "    Selected: ", style = "label" },
    { text = " Active Option ", hl_group = "NvimFloatDropdownSelected" },
  })
  cb:spans({
    { text = "    Border: ", style = "label" },
    { text = "───────────", hl_group = "NvimFloatDropdownBorder" },
  })

  -- Scrollbar Section
  cb:blank()
  cb:styled("  === Scrollbar ===", "header")
  cb:blank()
  cb:spans({
    { text = "    " },
    { text = "▲", hl_group = "NvimFloatScrollbarArrow" },
    { text = " Arrow  " },
    { text = "█", hl_group = "NvimFloatScrollbarThumb" },
    { text = " Thumb  " },
    { text = "░", hl_group = "NvimFloatScrollbarTrack" },
    { text = " Track  " },
    { text = " ", hl_group = "NvimFloatScrollbar" },
    { text = " BG" },
  })

  -- Content Styles Section
  cb:blank()
  cb:styled("  === Content Styles ===", "header")

  -- Headers subsection
  cb:blank()
  cb:styled("    --- Headers ---", "subheader")
  cb:spans({
    { text = "      " },
    { text = "Header", hl_group = "NvimFloatHeader" },
    { text = "  " },
    { text = "Subheader", hl_group = "NvimFloatSubheader" },
    { text = "  " },
    { text = "Section", hl_group = "NvimFloatSection" },
  })

  -- Labels subsection
  cb:blank()
  cb:styled("    --- Labels & Values ---", "subheader")
  cb:spans({
    { text = "      " },
    { text = "Label", hl_group = "NvimFloatLabel" },
    { text = ": " },
    { text = "Value", hl_group = "NvimFloatValue" },
    { text = "   " },
    { text = "Key", hl_group = "NvimFloatKey" },
    { text = ": data" },
  })

  -- Emphasis subsection
  cb:blank()
  cb:styled("    --- Emphasis ---", "subheader")
  cb:spans({
    { text = "      " },
    { text = "Emphasis", hl_group = "NvimFloatEmphasis" },
    { text = "  " },
    { text = "Strong", hl_group = "NvimFloatStrong" },
  })
  cb:spans({
    { text = "      " },
    { text = " Highlight ", hl_group = "NvimFloatHighlight" },
    { text = "  " },
    { text = " SearchMatch ", hl_group = "NvimFloatSearchMatch" },
  })

  -- Status subsection
  cb:blank()
  cb:styled("    --- Status ---", "subheader")
  cb:spans({
    { text = "      " },
    { text = "[ok] Success", hl_group = "NvimFloatSuccess" },
    { text = "  " },
    { text = "[!] Warning", hl_group = "NvimFloatWarning" },
    { text = "  " },
    { text = "[x] Error", hl_group = "NvimFloatError" },
  })

  -- Muted subsection
  cb:blank()
  cb:styled("    --- Muted ---", "subheader")
  cb:spans({
    { text = "      " },
    { text = "Muted", hl_group = "NvimFloatMuted" },
    { text = "  " },
    { text = "Dim", hl_group = "NvimFloatDim" },
    { text = "  " },
    { text = "-- Comment", hl_group = "NvimFloatComment" },
  })

  -- Code subsection
  cb:blank()
  cb:styled("    --- Code ---", "subheader")
  cb:spans({
    { text = "      " },
    { text = "local", hl_group = "NvimFloatKeyword" },
    { text = " " },
    { text = "foo", hl_group = "NvimFloatFunction" },
    { text = " = " },
    { text = '"bar"', hl_group = "NvimFloatString" },
  })
  cb:spans({
    { text = "      " },
    { text = "MyType", hl_group = "NvimFloatType" },
    { text = " = " },
    { text = "42", hl_group = "NvimFloatNumber" },
    { text = " " },
    { text = "+", hl_group = "NvimFloatOperator" },
    { text = " " },
    { text = "10", hl_group = "NvimFloatNumber" },
  })

  cb:blank()

  return cb:build_lines(), cb:build_highlights()
end

return M
