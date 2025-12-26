-- basic_float.lua
-- Basic floating window examples for nvim-float
--
-- Run with: :luafile %

local nf = require("nvim-float")

-- Ensure plugin is setup
nf.setup()

-- ============================================================================
-- Example 1: Simple floating window with text
-- ============================================================================

local function example_simple()
  nf.create({
    "This is a simple floating window.",
    "",
    "You can display any text content here.",
    "",
    "Press 'q' or <Esc> to close.",
  }, {
    title = " Simple Example ",
    border = "rounded",
    width = 45,
  })
end

-- ============================================================================
-- Example 2: Styled content with ContentBuilder
-- ============================================================================

local function example_styled()
  local float = require("nvim-float.float")
  local builder = nf.content_builder()

  builder:header("Welcome to nvim-float")
  builder:blank()
  builder:text("This window demonstrates styled content using ContentBuilder.")
  builder:blank()
  builder:subheader("Features")
  builder:bullet("Headers and subheaders")
  builder:bullet("Styled text with semantic highlighting")
  builder:bullet("Key-value pairs")
  builder:bullet("Status messages")
  builder:blank()
  builder:subheader("Status Examples")
  builder:success("  Success: Operation completed!")
  builder:warning("  Warning: Check your configuration")
  builder:styled("  Error: Something went wrong", "error")
  builder:blank()
  builder:subheader("Key-Value Examples")
  builder:key_value("  Name", "nvim-float")
  builder:key_value("  Version", "0.1.0")
  builder:key_value("  Author", "Community")
  builder:blank()
  builder:muted("Press 'q' or <Esc> to close")

  float.create_styled(builder, {
    title = " Styled Content ",
    border = "rounded",
    width = 55,
    zindex = nf.ZINDEX.MODAL,
  })
end

-- ============================================================================
-- Example 3: Custom keymaps
-- ============================================================================

local function example_keymaps()
  local win = nf.create({
    "This window has custom keymaps!",
    "",
    "Press 'a' to show a message",
    "Press 'b' to close the window",
    "Press 'c' to scroll down",
    "",
    "Line 1",
    "Line 2",
    "Line 3",
    "Line 4",
    "Line 5",
    "Line 6",
    "Line 7",
    "Line 8",
    "Line 9",
    "Line 10",
  }, {
    title = " Custom Keymaps ",
    border = "double",
    width = 40,
    height = 10,
    keymaps = {
      ["a"] = function()
        vim.notify("You pressed 'a'!", vim.log.levels.INFO)
      end,
      ["b"] = function()
        -- Close the window
        vim.api.nvim_win_close(0, true)
      end,
      ["c"] = function()
        -- Scroll down
        vim.cmd("normal! 3j")
      end,
    },
  })
end

-- ============================================================================
-- Example 4: Dialogs
-- ============================================================================

local function example_dialogs()
  -- First show an info dialog
  nf.info({
    "This demonstrates the dialog system.",
    "",
    "Next, you'll see a confirmation dialog.",
    "",
    "Press <Enter> or 'q' to continue...",
  }, "Dialog Demo")

  -- After closing, we'd show confirm dialog
  -- (In real code, you'd chain these with callbacks)
end

local function example_confirm()
  nf.confirm("Do you want to proceed with this action?", function()
    vim.notify("You confirmed!", vim.log.levels.INFO)
  end, function()
    vim.notify("You cancelled.", vim.log.levels.WARN)
  end)
end

local function example_select()
  nf.select({
    "Option A - First choice",
    "Option B - Second choice",
    "Option C - Third choice",
    "Option D - Fourth choice",
  }, function(index, item)
    vim.notify("Selected: " .. item .. " (index " .. index .. ")", vim.log.levels.INFO)
  end, "Choose an Option")
end

-- ============================================================================
-- Example 5: Positioned window
-- ============================================================================

local function example_positioned()
  nf.create({
    "This window is positioned in the top-left corner.",
    "",
    "You can use row/col to place windows anywhere.",
  }, {
    title = " Positioned ",
    border = "rounded",
    width = 50,
    centered = false,
    row = 2,
    col = 2,
  })
end

-- ============================================================================
-- Example 6: Transparent window
-- ============================================================================

local function example_transparent()
  nf.create({
    "This window has transparency (winblend).",
    "",
    "You can see content behind it.",
    "",
    "Transparency: 30%",
  }, {
    title = " Transparent ",
    border = "rounded",
    width = 45,
    winblend = 30,
  })
end

-- ============================================================================
-- Run Examples
-- ============================================================================

-- Uncomment one of these to run when sourcing this file:

-- example_simple()
-- example_styled()
-- example_keymaps()
-- example_dialogs()
-- example_confirm()
-- example_select()
-- example_positioned()
-- example_transparent()

-- Or run the demo:
nf.demo()

-- Print available examples
print([[
nvim-float Basic Examples loaded!

Available functions:
  example_simple()      - Simple text window
  example_styled()      - Styled content with ContentBuilder
  example_keymaps()     - Custom keymaps
  example_dialogs()     - Info dialog
  example_confirm()     - Confirmation dialog
  example_select()      - Selection dialog
  example_positioned()  - Positioned window
  example_transparent() - Transparent window

Or run :NvimFloat for the built-in demo.
]])
