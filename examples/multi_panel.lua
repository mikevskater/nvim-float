-- multi_panel.lua
-- Multi-panel layout examples for nvim-float
--
-- Run with: :luafile %

local nf = require("nvim-float")
local float = require("nvim-float.float")
local ContentBuilder = require("nvim-float.content_builder")

-- Ensure plugin is setup
nf.setup()

-- ============================================================================
-- Example 1: Simple Two-Panel Layout (Horizontal)
-- ============================================================================

local function example_two_panel_horizontal()
  local state = nf.create_multi_panel({
    layout = "horizontal",
    panels = {
      {
        id = "left",
        title = " Navigation ",
        width = 0.3, -- 30% of total width
        content = {
          "Files",
          "",
          "  src/",
          "    main.lua",
          "    utils.lua",
          "    config.lua",
          "",
          "  tests/",
          "    test_main.lua",
          "",
          "  docs/",
          "    README.md",
        },
      },
      {
        id = "right",
        title = " Preview ",
        width = 0.7, -- 70% of total width
        content = {
          "Select a file from the left panel to preview.",
          "",
          "Use Tab to switch between panels.",
          "Press 'q' or <Esc> to close.",
        },
      },
    },
    total_width = 100,
    total_height = 20,
  })

  if state then
    vim.notify("Multi-panel created with panels: " ..
      vim.inspect(vim.tbl_keys(state.panels)), vim.log.levels.INFO)
  end
end

-- ============================================================================
-- Example 2: Three-Panel Layout (Horizontal)
-- ============================================================================

local function example_three_panel()
  local state = nf.create_multi_panel({
    layout = "horizontal",
    panels = {
      {
        id = "sidebar",
        title = " Sidebar ",
        width = 0.2,
        content = {
          "Menu",
          "",
          "  [1] Dashboard",
          "  [2] Settings",
          "  [3] Help",
        },
      },
      {
        id = "main",
        title = " Main Content ",
        width = 0.5,
        content = {
          "Dashboard",
          "",
          "Welcome to the dashboard!",
          "",
          "Quick Stats:",
          "  - Active users: 42",
          "  - Pending tasks: 7",
          "  - Completed: 156",
        },
      },
      {
        id = "details",
        title = " Details ",
        width = 0.3,
        content = {
          "Additional Info",
          "",
          "Last updated: just now",
          "Status: Online",
          "Version: 1.0.0",
        },
      },
    },
    total_width = 120,
    total_height = 18,
  })
end

-- ============================================================================
-- Example 3: Vertical Layout
-- ============================================================================

local function example_vertical_layout()
  local state = nf.create_multi_panel({
    layout = "vertical",
    panels = {
      {
        id = "top",
        title = " Header ",
        height = 0.2,
        content = {
          "Application Header",
          "Version 1.0.0 | Status: Running",
        },
      },
      {
        id = "middle",
        title = " Content ",
        height = 0.6,
        content = {
          "Main Content Area",
          "",
          "This panel takes up most of the vertical space.",
          "You can put your primary content here.",
          "",
          "Line 1",
          "Line 2",
          "Line 3",
          "Line 4",
          "Line 5",
        },
      },
      {
        id = "bottom",
        title = " Footer ",
        height = 0.2,
        content = {
          "[q] Quit  [Tab] Switch panel  [?] Help",
        },
      },
    },
    total_width = 80,
    total_height = 25,
  })
end

-- ============================================================================
-- Example 4: Panel with Styled Content
-- ============================================================================

local function example_styled_panels()
  -- Create content builders for each panel
  local nav_builder = ContentBuilder.new()
  nav_builder:header("Servers")
  nav_builder:blank()
  nav_builder:bullet("Production", "success")
  nav_builder:bullet("Staging", "warning")
  nav_builder:bullet("Development", "muted")

  local detail_builder = ContentBuilder.new()
  detail_builder:header("Production Server")
  detail_builder:blank()
  detail_builder:key_value("  Status", "Online")
  detail_builder:key_value("  CPU", "23%")
  detail_builder:key_value("  Memory", "4.2 GB / 8 GB")
  detail_builder:key_value("  Uptime", "42 days")
  detail_builder:blank()
  detail_builder:subheader("Recent Events")
  detail_builder:muted("  10:42 - Health check passed")
  detail_builder:muted("  10:30 - Backup completed")
  detail_builder:muted("  09:15 - Deployment finished")

  local state = nf.create_multi_panel({
    layout = "horizontal",
    panels = {
      {
        id = "nav",
        title = " Navigation ",
        width = 0.35,
        content_builder = nav_builder,
      },
      {
        id = "detail",
        title = " Details ",
        width = 0.65,
        content_builder = detail_builder,
      },
    },
    total_width = 90,
    total_height = 18,
  })
end

-- ============================================================================
-- Example 5: Interactive Panel with Updates
-- ============================================================================

local function example_interactive_panels()
  local items = {
    { name = "Apple", price = 1.20, stock = 50 },
    { name = "Banana", price = 0.80, stock = 120 },
    { name = "Orange", price = 1.50, stock = 75 },
    { name = "Mango", price = 2.00, stock = 30 },
    { name = "Grape", price = 3.50, stock = 45 },
  }

  local selected_idx = 1

  local function build_list_content()
    local cb = ContentBuilder.new()
    cb:header("Products")
    cb:blank()
    for i, item in ipairs(items) do
      local prefix = i == selected_idx and " > " or "   "
      local style = i == selected_idx and "emphasis" or nil
      if style then
        cb:styled(prefix .. item.name, style)
      else
        cb:line(prefix .. item.name)
      end
    end
    cb:blank()
    cb:muted("[j/k] Navigate  [Enter] Select")
    return cb
  end

  local function build_detail_content()
    local item = items[selected_idx]
    local cb = ContentBuilder.new()
    cb:header(item.name)
    cb:blank()
    cb:key_value("  Price", string.format("$%.2f", item.price))
    cb:key_value("  Stock", tostring(item.stock))
    cb:blank()
    if item.stock < 40 then
      cb:warning("  Low stock warning!")
    else
      cb:success("  Stock level OK")
    end
    return cb
  end

  local state = nf.create_multi_panel({
    layout = "horizontal",
    panels = {
      {
        id = "list",
        title = " Products ",
        width = 0.4,
        content_builder = build_list_content(),
      },
      {
        id = "detail",
        title = " Details ",
        width = 0.6,
        content_builder = build_detail_content(),
      },
    },
    total_width = 70,
    total_height = 16,
  })

  if not state then
    return
  end

  -- Set up navigation keymaps on the list panel
  local list_win = state.panels.list
  if list_win and list_win.winid and vim.api.nvim_win_is_valid(list_win.winid) then
    vim.keymap.set("n", "j", function()
      selected_idx = math.min(selected_idx + 1, #items)
      list_win:update_styled(build_list_content())
      state.panels.detail:update_styled(build_detail_content())
    end, { buffer = list_win.bufnr })

    vim.keymap.set("n", "k", function()
      selected_idx = math.max(selected_idx - 1, 1)
      list_win:update_styled(build_list_content())
      state.panels.detail:update_styled(build_detail_content())
    end, { buffer = list_win.bufnr })
  end
end

-- ============================================================================
-- Example 6: Panel with Input Fields
-- ============================================================================

local function example_form_panel()
  local InputManager = nf.InputManager()

  -- Left panel: static info
  local info_builder = ContentBuilder.new()
  info_builder:header("Instructions")
  info_builder:blank()
  info_builder:text("Fill out the form on the right.")
  info_builder:blank()
  info_builder:bullet("All fields are required")
  info_builder:bullet("Tab to navigate")
  info_builder:bullet("Enter to submit")

  -- Right panel: form
  local form_builder = ContentBuilder.new()
  form_builder:header("Contact Form")
  form_builder:blank()
  form_builder:input("name", {
    label = "Name",
    width = 25,
    placeholder = "Your name",
  })
  form_builder:blank()
  form_builder:input("email", {
    label = "Email",
    width = 25,
    placeholder = "your@email.com",
  })
  form_builder:blank()
  form_builder:dropdown("subject", {
    label = "Subject",
    width = 25,
    options = {
      { value = "general", label = "General Inquiry" },
      { value = "support", label = "Technical Support" },
      { value = "billing", label = "Billing Question" },
      { value = "feedback", label = "Feedback" },
    },
  })
  form_builder:blank()
  form_builder:muted("[Tab] Next  [Enter] Submit")

  local state = nf.create_multi_panel({
    layout = "horizontal",
    panels = {
      {
        id = "info",
        title = " Info ",
        width = 0.35,
        content_builder = info_builder,
      },
      {
        id = "form",
        title = " Form ",
        width = 0.65,
        content_builder = form_builder,
        enable_inputs = true,
      },
    },
    total_width = 80,
    total_height = 15,
  })

  if state and state.panels.form then
    local form_win = state.panels.form
    local mgr = InputManager.get_for_buffer(form_win.bufnr)
    if mgr then
      mgr:focus_first_field()

      form_win:on_input_submit(function(key, value)
        local values = mgr:get_all_values()
        vim.notify("Form submitted: " .. vim.inspect(values), vim.log.levels.INFO)
      end)
    end
  end
end

-- ============================================================================
-- Run Examples
-- ============================================================================

-- Uncomment one of these to run:

-- example_two_panel_horizontal()
-- example_three_panel()
-- example_vertical_layout()
-- example_styled_panels()
-- example_interactive_panels()
-- example_form_panel()

-- Default: run the interactive panels example
example_interactive_panels()

print([[
nvim-float Multi-Panel Examples loaded!

Available functions:
  example_two_panel_horizontal()  - Simple two-panel layout
  example_three_panel()           - Three panels side by side
  example_vertical_layout()       - Vertical stacking
  example_styled_panels()         - Panels with ContentBuilder
  example_interactive_panels()    - Navigable list with detail view
  example_form_panel()            - Panel with input form

Use Tab to switch between panels!
]])
