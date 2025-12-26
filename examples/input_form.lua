-- input_form.lua
-- Interactive form examples with input fields and dropdowns
--
-- Run with: :luafile %

local nf = require("nvim-float")
local float = require("nvim-float.float")
local ContentBuilder = require("nvim-float.content_builder")
local InputManager = nf.InputManager()

-- Ensure plugin is setup
nf.setup()

-- ============================================================================
-- Example 1: Simple Text Input Form
-- ============================================================================

local function example_text_inputs()
  local cb = ContentBuilder.new()

  cb:header("User Registration")
  cb:blank()

  cb:input("username", {
    label = "Username",
    width = 30,
    placeholder = "Enter username",
  })
  cb:blank()

  cb:input("email", {
    label = "Email",
    width = 30,
    placeholder = "user@example.com",
  })
  cb:blank()

  cb:input("password", {
    label = "Password",
    width = 30,
    placeholder = "Enter password",
  })
  cb:blank()
  cb:blank()

  cb:muted("[Tab] Next field  [Shift+Tab] Previous  [Enter] Submit")

  local win = float.create_styled(cb, {
    title = " Registration Form ",
    border = "rounded",
    enable_inputs = true,
    width = 50,
    zindex = nf.ZINDEX.MODAL,
  })

  -- Get the input manager
  local mgr = InputManager.get_for_buffer(win.bufnr)

  -- Set up submit handler
  win:on_input_submit(function(key, value)
    local values = mgr:get_all_values()
    vim.notify("Form submitted!\n" ..
      "Username: " .. (values.username or "") .. "\n" ..
      "Email: " .. (values.email or "") .. "\n" ..
      "Password: " .. (values.password or ""),
      vim.log.levels.INFO)
    win:close()
  end)

  -- Focus the first field
  mgr:focus_first_field()
end

-- ============================================================================
-- Example 2: Dropdown Selection
-- ============================================================================

local function example_dropdowns()
  local cb = ContentBuilder.new()

  cb:header("Project Settings")
  cb:blank()

  cb:dropdown("language", {
    label = "Language",
    width = 25,
    options = {
      { value = "lua", label = "Lua" },
      { value = "python", label = "Python" },
      { value = "javascript", label = "JavaScript" },
      { value = "typescript", label = "TypeScript" },
      { value = "rust", label = "Rust" },
      { value = "go", label = "Go" },
    },
    placeholder = "Select language",
  })
  cb:blank()

  cb:dropdown("framework", {
    label = "Framework",
    width = 25,
    options = {
      { value = "none", label = "None" },
      { value = "react", label = "React" },
      { value = "vue", label = "Vue" },
      { value = "angular", label = "Angular" },
      { value = "svelte", label = "Svelte" },
    },
    placeholder = "Select framework",
  })
  cb:blank()

  cb:dropdown("test_runner", {
    label = "Test Runner",
    width = 25,
    options = {
      { value = "jest", label = "Jest" },
      { value = "vitest", label = "Vitest" },
      { value = "mocha", label = "Mocha" },
      { value = "pytest", label = "Pytest" },
      { value = "busted", label = "Busted (Lua)" },
    },
    placeholder = "Select test runner",
  })
  cb:blank()
  cb:blank()

  cb:muted("[Tab] Navigate  [Enter/Space] Open dropdown  [Esc] Cancel")

  local win = float.create_styled(cb, {
    title = " Project Settings ",
    border = "rounded",
    enable_inputs = true,
    width = 50,
    zindex = nf.ZINDEX.MODAL,
  })

  local mgr = InputManager.get_for_buffer(win.bufnr)

  win:on_dropdown_change(function(key, value)
    vim.notify("Dropdown '" .. key .. "' changed to: " .. value, vim.log.levels.INFO)
  end)

  mgr:focus_first_field()
end

-- ============================================================================
-- Example 3: Multi-Select Dropdown
-- ============================================================================

local function example_multi_dropdown()
  local cb = ContentBuilder.new()

  cb:header("Select Features")
  cb:blank()

  cb:multi_dropdown("features", {
    label = "Features",
    width = 35,
    options = {
      { value = "auth", label = "Authentication" },
      { value = "api", label = "REST API" },
      { value = "graphql", label = "GraphQL" },
      { value = "websocket", label = "WebSocket" },
      { value = "db", label = "Database" },
      { value = "cache", label = "Caching" },
      { value = "queue", label = "Message Queue" },
      { value = "logging", label = "Logging" },
    },
    placeholder = "Select features",
    display_mode = "count", -- or "list"
    select_all_option = true,
  })
  cb:blank()
  cb:blank()

  cb:muted("[Tab] Navigate  [Enter/Space] Toggle  [Ctrl+A] Select all")

  local win = float.create_styled(cb, {
    title = " Multi-Select Example ",
    border = "rounded",
    enable_inputs = true,
    width = 55,
    zindex = nf.ZINDEX.MODAL,
  })

  local mgr = InputManager.get_for_buffer(win.bufnr)

  win:on_multi_dropdown_change(function(key, values)
    vim.notify("Selected features: " .. vim.inspect(values), vim.log.levels.INFO)
  end)

  mgr:focus_first_field()
end

-- ============================================================================
-- Example 4: Mixed Form (Inputs + Dropdowns)
-- ============================================================================

local function example_mixed_form()
  local cb = ContentBuilder.new()

  cb:header("New Connection")
  cb:blank()

  cb:input("name", {
    label = "Name",
    width = 30,
    placeholder = "Connection name",
  })
  cb:blank()

  cb:dropdown("type", {
    label = "Type",
    width = 30,
    options = {
      { value = "sqlserver", label = "SQL Server" },
      { value = "postgres", label = "PostgreSQL" },
      { value = "mysql", label = "MySQL" },
      { value = "sqlite", label = "SQLite" },
    },
  })
  cb:blank()

  cb:input("host", {
    label = "Host",
    width = 30,
    placeholder = "localhost",
    value = "localhost",
  })
  cb:blank()

  cb:input("port", {
    label = "Port",
    width = 10,
    placeholder = "1433",
    value = "1433",
    value_type = "integer",
    min_value = 1,
    max_value = 65535,
  })
  cb:blank()

  cb:input("database", {
    label = "Database",
    width = 30,
    placeholder = "master",
  })
  cb:blank()

  cb:multi_dropdown("options", {
    label = "Options",
    width = 30,
    options = {
      { value = "encrypt", label = "Encrypt Connection" },
      { value = "trust_cert", label = "Trust Server Certificate" },
      { value = "integrated", label = "Windows Auth" },
      { value = "readonly", label = "Read Only" },
    },
  })
  cb:blank()
  cb:blank()

  cb:muted("[Tab] Navigate  [Enter] Submit/Select  [Esc] Cancel")

  local win = float.create_styled(cb, {
    title = " New Connection ",
    border = "rounded",
    enable_inputs = true,
    width = 55,
    zindex = nf.ZINDEX.MODAL,
  })

  local mgr = InputManager.get_for_buffer(win.bufnr)

  -- Handle form submission
  win:on_input_submit(function(key, value)
    local values = mgr:get_all_values()
    local dropdown_values = {
      type = win:get_dropdown_value("type"),
    }
    local multi_values = {
      options = win:get_multi_dropdown_values("options"),
    }

    vim.notify("Connection saved!\n" ..
      "Name: " .. (values.name or "") .. "\n" ..
      "Type: " .. (dropdown_values.type or "") .. "\n" ..
      "Host: " .. (values.host or "") .. "\n" ..
      "Port: " .. (values.port or "") .. "\n" ..
      "Database: " .. (values.database or "") .. "\n" ..
      "Options: " .. vim.inspect(multi_values.options),
      vim.log.levels.INFO)
    win:close()
  end)

  mgr:focus_first_field()
end

-- ============================================================================
-- Example 5: Input with Validation
-- ============================================================================

local function example_validated_inputs()
  local cb = ContentBuilder.new()

  cb:header("Numeric Inputs with Validation")
  cb:blank()

  cb:input("age", {
    label = "Age",
    width = 10,
    placeholder = "0-120",
    value_type = "integer",
    min_value = 0,
    max_value = 120,
  })
  cb:blank()

  cb:input("price", {
    label = "Price",
    width = 15,
    placeholder = "0.00",
    value_type = "float",
    min_value = 0,
  })
  cb:blank()

  cb:input("quantity", {
    label = "Quantity",
    width = 10,
    placeholder = "1-100",
    value_type = "integer",
    min_value = 1,
    max_value = 100,
    value = "1",
  })
  cb:blank()
  cb:blank()

  cb:muted("Numeric fields validate on exit")
  cb:muted("[Tab] Navigate  [Enter] Submit")

  local win = float.create_styled(cb, {
    title = " Validated Inputs ",
    border = "rounded",
    enable_inputs = true,
    width = 45,
    zindex = nf.ZINDEX.MODAL,
  })

  local mgr = InputManager.get_for_buffer(win.bufnr)
  mgr:focus_first_field()
end

-- ============================================================================
-- Run Examples
-- ============================================================================

-- Uncomment one of these to run:

-- example_text_inputs()
-- example_dropdowns()
-- example_multi_dropdown()
-- example_mixed_form()
-- example_validated_inputs()

-- Default: run the mixed form example
example_mixed_form()

print([[
nvim-float Input Form Examples loaded!

Available functions:
  example_text_inputs()      - Simple text input form
  example_dropdowns()        - Dropdown selections
  example_multi_dropdown()   - Multi-select dropdown
  example_mixed_form()       - Mixed inputs and dropdowns
  example_validated_inputs() - Numeric validation

Try navigating with Tab/Shift+Tab!
]])
