---@module 'nvim-float.icon_picker'
---@brief Searchable icon picker using multi-panel layout

local M = {}

local data = require("nvim-float.icon_picker.data")
local UiFloat = require("nvim-float.window")
local ContentBuilder = require("nvim-float.content")

---@type MultiPanelWindow?
local multi_panel = nil

---@type table?
local picker_data = nil

---@type userdata?
local timer = nil

---Namespace for search placeholder virtual text
local placeholder_ns = vim.api.nvim_create_namespace("nvim_float_icon_picker_placeholder")

---Update placeholder virtual text based on buffer content
---@param bufnr number
local function update_placeholder(bufnr)
  vim.api.nvim_buf_clear_namespace(bufnr, placeholder_ns, 0, -1)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local empty = #lines == 0 or (#lines == 1 and lines[1] == "")
  if empty then
    vim.api.nvim_buf_set_extmark(bufnr, placeholder_ns, 0, 0, {
      virt_text = { { "Type to search icons...", "Comment" } },
      virt_text_pos = "overlay",
    })
  end
end

-- ============================================================================
-- Helpers
-- ============================================================================

---Get the actual width of a panel
---@param state MultiPanelState
---@param panel_name string
---@return number
local function get_panel_width(state, panel_name)
  local panel = state.panels[panel_name]
  if not panel or not panel.float then return 50 end
  -- Try window API first (always accurate), fall back to stored width
  if panel.float.winid and vim.api.nvim_win_is_valid(panel.float.winid) then
    return vim.api.nvim_win_get_width(panel.float.winid)
  end
  return panel.float._win_width or 50
end

-- ============================================================================
-- Render Callbacks
-- ============================================================================

---Debounced filter and re-render of results from buffer content
local function on_search_changed()
  if not picker_data or not multi_panel then return end
  if picker_data._ignore_changes then return end

  -- Read query directly from the search buffer
  local search_float = multi_panel:get_panel_float("search")
  if not search_float or not search_float:is_valid() then return end
  local lines = vim.api.nvim_buf_get_lines(search_float.bufnr, 0, -1, false)
  local value = table.concat(lines, "")
  picker_data.query = value

  update_placeholder(search_float.bufnr)

  if timer then timer:stop(); timer:close() end
  timer = vim.loop.new_timer()
  timer:start(30, 0, vim.schedule_wrap(function()
    if timer then timer:close(); timer = nil end
    if not multi_panel then return end
    picker_data.filtered = data.filter(picker_data.all_icons, picker_data.query)
    multi_panel:render_panel("results", { force = true, cursor_row = 0 })

    -- Update footer count
    local total = #picker_data.all_icons
    local shown = #picker_data.filtered
    multi_panel:update_panel_footer("results",
      string.format("Icons (%d/%d)", shown, total), "center")
  end))
end

---Render the search panel (initial render only — buffer is directly editable after)
---@param state MultiPanelState
---@return string[], table[]
local function render_search(state)
  return { picker_data.query or "" }, {}
end

---Maximum number of icons to display in the grid at once
local MAX_DISPLAY = 300

---Render the results panel
---@param state MultiPanelState
---@return string[], table[]
local function render_results(state)
  local cb = ContentBuilder.new()
  local icons = picker_data.filtered
  local panel_width = get_panel_width(state, "results")
  local col_width = picker_data.col_width

  -- Don't show results until user has typed something
  if picker_data.query == "" then
    cb:blank()
    cb:muted("  Type in the search box above to find icons...")
    cb:blank()
    cb:muted(string.format("  %d icons available", #picker_data.all_icons))
    return cb:build_lines(), cb:build_raw_highlights() or {}
  end

  if #icons == 0 then
    cb:blank()
    cb:muted(string.format('  No icons match "%s"', picker_data.query))
    return cb:build_lines(), cb:build_raw_highlights() or {}
  end

  -- Cap displayed icons for performance
  local display_count = math.min(#icons, MAX_DISPLAY)

  -- Build cells: clear-icon first, then filtered icons (capped)
  local cells = {
    { text = "   (clear icon)", data = { glyph = "", name = "(clear)" } },
  }
  for i = 1, display_count do
    local entry = icons[i]
    cells[#cells + 1] = {
      text = string.format("%s  %s", entry.glyph, entry.name),
      data = entry,
    }
  end

  -- Calculate column count
  local cell_padding = 1
  local num_cols = math.max(1, math.floor(panel_width / (col_width + cell_padding)))
  picker_data.display_count = display_count

  cb:grid(cells, {
    column_width = col_width,
    columns = num_cols,
    cell_padding = cell_padding,
    track_elements = true,
    element_prefix = "icon",
  })

  -- Store CB for element tracking
  if multi_panel then
    multi_panel:set_panel_content_builder("results", cb)
  end

  return cb:build_lines(), cb:build_raw_highlights() or {}
end

-- ============================================================================
-- Selection
-- ============================================================================

---Select the icon under cursor using element tracking
local function select_icon()
  if not picker_data or not multi_panel then return end

  local element = multi_panel:get_element_at_cursor()
  if element and element.data then
    picker_data.on_select(element.data.glyph, element.data.name)
    M.close()
  end
end

---Cancel and close
local function cancel()
  if picker_data and picker_data.on_cancel then
    picker_data.on_cancel()
  end
  M.close()
end

-- ============================================================================
-- Public API
-- ============================================================================

---Open the icon picker
---@param opts { on_select: fun(glyph: string, name: string), on_cancel?: fun(), title?: string, nerd_fonts?: boolean, width_ratio?: number, height_ratio?: number, column_width?: number }
function M.open(opts)
  opts = opts or {}

  -- Close existing picker if open
  M.close()

  -- Load icon data
  local all_icons = data.load({ nerd_fonts = opts.nerd_fonts ~= false })

  -- Initialize picker state
  picker_data = {
    query = "",
    all_icons = all_icons,
    filtered = {},
    col_width = opts.column_width or 30,
    on_select = opts.on_select or function() end,
    on_cancel = opts.on_cancel,
  }

  local title = opts.title or "Pick Icon"

  -- Create multi-panel layout
  multi_panel = UiFloat.create_multi_panel({
    layout = {
      split = "vertical",
      children = {
        {
          name = "search",
          title = " " .. title .. " ",
          min_height = 1,
          ratio = 0,
          focusable = true,
          cursorline = false,
          on_render = render_search,
          on_create = function(buf, win)
            -- Disable completion/LSP in search buffer
            vim.api.nvim_buf_set_option(buf, 'omnifunc', '')
            vim.api.nvim_buf_set_option(buf, 'completefunc', '')
            vim.api.nvim_win_set_option(win, 'spell', false)
            -- Track changes via on_lines (attached early, fires after buffer becomes editable)
            vim.api.nvim_buf_attach(buf, false, {
              on_lines = function()
                vim.schedule(on_search_changed)
              end,
            })
            -- Insert-mode keymaps: Tab/Enter/Esc jump to results or cancel
            local function focus_results()
              vim.cmd("stopinsert")
              vim.schedule(function()
                if multi_panel then multi_panel:focus_panel("results") end
              end)
            end
            local iopts = { buffer = buf, noremap = true, silent = true }
            vim.keymap.set('i', '<Tab>', focus_results, iopts)
            vim.keymap.set('i', '<S-Tab>', focus_results, iopts)
            vim.keymap.set('i', '<CR>', focus_results, iopts)
            vim.keymap.set('i', '<Esc>', function()
              vim.cmd("stopinsert")
              vim.schedule(function() cancel() end)
            end, iopts)
          end,
        },
        {
          name = "results",
          ratio = 1.0,
          focusable = true,
          cursorline = true,
          on_render = render_results,
        },
      },
    },
    total_width_ratio = opts.width_ratio or 0.4,
    total_height_ratio = opts.height_ratio or 0.6,
    initial_focus = "search",
    augroup_name = "NvimFloatIconPicker",
    border = "rounded",
    on_close = function()
      multi_panel = nil
      picker_data = nil
    end,
  })

  if not multi_panel then
    vim.notify("Failed to create icon picker", vim.log.levels.ERROR)
    return
  end

  -- Render all panels (suppress on_lines during initial render)
  picker_data._ignore_changes = true
  multi_panel:render_all()

  -- Focus search and start in insert mode
  vim.schedule(function()
    if not multi_panel then return end
    local total = #picker_data.all_icons
    multi_panel:update_panel_footer("results",
      string.format("Icons (0/%d)", total), "center")

    -- Make search buffer editable (after render_all has set lines)
    local search_float = multi_panel:get_panel_float("search")
    if search_float and search_float:is_valid() then
      vim.api.nvim_buf_set_option(search_float.bufnr, 'modifiable', true)
      vim.api.nvim_buf_set_option(search_float.bufnr, 'readonly', false)
    end

    -- Show placeholder on empty search
    if search_float then
      update_placeholder(search_float.bufnr)
    end

    multi_panel:focus_panel("search")

    -- Disable nvim-cmp for search buffer (must be called while buffer is current)
    local ok, cmp = pcall(require, 'cmp')
    if ok then
      cmp.setup.buffer({ enabled = false })
    end

    picker_data._ignore_changes = false
    vim.cmd("startinsert")
  end)

  -- Keymaps for search panel (normal mode — insert mode uses native editing)
  multi_panel:set_panel_keymaps("search", {
    ["<Tab>"] = function() multi_panel:focus_panel("results") end,
    ["<S-Tab>"] = function() multi_panel:focus_panel("results") end,
    ["<CR>"] = function() multi_panel:focus_panel("results") end,
    ["<Esc>"] = cancel,
  })

  -- Keymaps for results panel (native j/k/h/l/gg/G/Ctrl-D/etc. all work)
  multi_panel:set_panel_keymaps("results", {
    ["<Tab>"] = function() multi_panel:focus_panel("search") end,
    ["<S-Tab>"] = function() multi_panel:focus_panel("search") end,
    ["<CR>"] = select_icon,
    ["<Esc>"] = cancel,
    ["q"] = cancel,
  })
end

---Close the icon picker
function M.close()
  if timer then
    timer:stop()
    timer:close()
    timer = nil
  end
  if multi_panel then
    multi_panel:close()
    multi_panel = nil
  end
  picker_data = nil
end

return M
