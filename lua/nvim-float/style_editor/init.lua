---@module nvim-float.style_editor
---Interactive style editor for nvim-float highlight groups

local M = {}

local Data = require("nvim-float.style_editor.data")
local Render = require("nvim-float.style_editor.render")
local Preview = require("nvim-float.style_editor.preview")
local Persistence = require("nvim-float.style_editor.persistence")
local UiFloat = require("nvim-float.float")

---@class StyleEditorState
---@field selected_color_idx number Currently selected color index (1-indexed)
---@field original_highlights table<string, table> Backup of original highlight definitions
---@field modified_highlights table<string, table> Modified highlights (for saving)
---@field is_dirty boolean Whether any changes have been made

---@type MultiPanelWindow?
local multi_panel = nil

---@type StyleEditorState?
local state = nil

-- ============================================================================
-- Internal Helpers
-- ============================================================================

---Create initial state
---@return StyleEditorState
local function create_state()
  local st = {
    selected_color_idx = 1,
    original_highlights = {},
    modified_highlights = {},
    is_dirty = false,
  }

  -- Backup all current highlights
  for _, def in ipairs(Data.HIGHLIGHT_DEFINITIONS) do
    st.original_highlights[def.key] = vim.api.nvim_get_hl(0, { name = def.key })
  end

  -- Load any existing persisted overrides
  local persisted = Persistence.load()
  if persisted then
    st.modified_highlights = vim.deepcopy(persisted)
  end

  return st
end

---Refresh the UI after color change (scheduled to avoid blocking)
local function refresh_ui()
  if not multi_panel then return end

  vim.schedule(function()
    if not multi_panel or not state then return end

    multi_panel:render_panel("colors")
    multi_panel:render_panel("preview")

    -- Re-apply swatch highlights after render
    local colors_buf = multi_panel:get_panel_buffer("colors")
    if colors_buf then
      Render.apply_swatch_highlights(colors_buf, state)
    end
  end)
end

-- ============================================================================
-- Navigation
-- ============================================================================

---Navigate colors list
---@param direction number 1 for down, -1 for up
local function navigate_colors(direction)
  if not state or not multi_panel then return end

  state.selected_color_idx = state.selected_color_idx + direction

  local total = #Data.HIGHLIGHT_DEFINITIONS
  if state.selected_color_idx < 1 then
    state.selected_color_idx = total
  elseif state.selected_color_idx > total then
    state.selected_color_idx = 1
  end

  -- Just move cursor - no need to re-render the panel
  local cursor_line = Render.get_color_cursor_line(state.selected_color_idx)
  multi_panel:set_cursor("colors", cursor_line, 0)
end

---Sync cursor to current selection (called when focusing colors panel)
local function sync_cursor_to_selection()
  if not state or not multi_panel then return end
  local cursor_line = Render.get_color_cursor_line(state.selected_color_idx)
  multi_panel:set_cursor("colors", cursor_line, 0)
end

-- ============================================================================
-- Color Editing
-- ============================================================================

---Edit the currently selected color using the color picker
local function edit_color()
  if not state or not multi_panel then return end

  local def = Data.HIGHLIGHT_DEFINITIONS[state.selected_color_idx]
  if not def then return end

  -- Try to load colorpicker
  local ok, colorpicker = pcall(require, "nvim-colorpicker")
  if not ok then
    vim.notify("nvim-colorpicker is required for color editing", vim.log.levels.ERROR)
    return
  end

  -- Get current highlight values
  local current_hl = vim.api.nvim_get_hl(0, { name = def.key })
  local original_value = vim.deepcopy(current_hl)

  -- Working copies
  local working_colors = {
    fg = current_hl.fg and string.format("#%06X", current_hl.fg) or "#808080",
    bg = current_hl.bg and string.format("#%06X", current_hl.bg) or nil,
    bold = current_hl.bold or false,
    italic = current_hl.italic or false,
  }

  -- Track original for comparison
  local original_colors = {
    fg = working_colors.fg,
    bg = working_colors.bg or "#808080",
  }

  -- Determine initial target
  local initial_target = "fg"
  if def.has_bg and not current_hl.fg and current_hl.bg then
    initial_target = "bg"
  elseif def.has_fg == false and def.has_bg then
    initial_target = "bg"
  end

  -- Prepare target options
  local target_options = { "fg" }
  if def.has_bg or current_hl.bg then
    target_options = { "fg", "bg" }
  end
  if def.has_fg == false then
    target_options = { "bg" }
    initial_target = "bg"
  end

  -- Helper to apply working colors
  local function apply_working_colors()
    if not state then return end

    local hl_def = {}
    if working_colors.fg and working_colors.fg ~= "#808080" then
      hl_def.fg = working_colors.fg
    end
    if working_colors.bg then
      hl_def.bg = working_colors.bg
    end
    if working_colors.bold then hl_def.bold = true end
    if working_colors.italic then hl_def.italic = true end

    vim.api.nvim_set_hl(0, def.key, hl_def)
    state.is_dirty = true
    state.modified_highlights[def.key] = hl_def

    refresh_ui()
  end

  -- Build custom controls
  local custom_controls = {}

  -- Target selector (fg/bg)
  if #target_options > 1 then
    table.insert(custom_controls, {
      id = "target",
      type = "select",
      label = "Target",
      options = target_options,
      default = initial_target,
      key = "B",
      on_change = function(new_target, old_target)
        -- Save current picker color to the old target
        local current_color = colorpicker.get_color()
        if current_color then
          working_colors[old_target] = current_color
        end
        -- Load the new target's color into the picker
        local new_color = working_colors[new_target] or "#808080"
        local new_original = original_colors[new_target]
        colorpicker.set_color(new_color, new_original)
        apply_working_colors()
      end,
    })
  end

  -- Bold toggle
  table.insert(custom_controls, {
    id = "bold",
    type = "toggle",
    label = "Bold",
    default = working_colors.bold,
    key = "b",
    on_change = function(new_val)
      working_colors.bold = new_val
      apply_working_colors()
    end,
  })

  -- Italic toggle
  table.insert(custom_controls, {
    id = "italic",
    type = "toggle",
    label = "Italic",
    default = working_colors.italic,
    key = "i",
    on_change = function(new_val)
      working_colors.italic = new_val
      apply_working_colors()
    end,
  })

  -- Open color picker
  colorpicker.pick({
    color = working_colors[initial_target] or "#808080",
    title = def.name .. " (" .. def.key .. ")",
    custom_controls = custom_controls,

    -- Live preview as user navigates
    on_change = function(result)
      if not state then return end

      local target = result.custom and result.custom.target or initial_target
      working_colors[target] = result.color

      if result.custom then
        working_colors.bold = result.custom.bold
        working_colors.italic = result.custom.italic
      end

      apply_working_colors()
    end,

    -- User confirmed selection
    on_select = function(result)
      if not state then return end

      local target = result.custom and result.custom.target or initial_target
      working_colors[target] = result.color

      if result.custom then
        working_colors.bold = result.custom.bold
        working_colors.italic = result.custom.italic
      end

      apply_working_colors()

      if multi_panel then
        multi_panel:update_panel_title("colors", " Highlight Groups * ")
      end
    end,

    -- User cancelled - restore original
    on_cancel = function()
      if not state then return end

      vim.api.nvim_set_hl(0, def.key, original_value)
      state.modified_highlights[def.key] = nil
      state.is_dirty = vim.tbl_count(state.modified_highlights) > 0

      refresh_ui()
    end,
  })
end

---Reset current highlight to default
local function reset_to_default()
  if not state or not multi_panel then return end

  local def = Data.HIGHLIGHT_DEFINITIONS[state.selected_color_idx]
  if not def then return end

  -- Get default from theme module
  local Theme = require("nvim-float.theme")
  local default_hl = Theme.get_default_highlight(def.key)

  if default_hl then
    vim.api.nvim_set_hl(0, def.key, default_hl)
    state.modified_highlights[def.key] = nil
    state.is_dirty = vim.tbl_count(state.modified_highlights) > 0

    refresh_ui()
    vim.notify("Reset " .. def.key .. " to default", vim.log.levels.INFO)
  end
end

-- ============================================================================
-- Save/Cancel
-- ============================================================================

---Save changes to disk
local function save_changes()
  if not state then return end

  if vim.tbl_count(state.modified_highlights) == 0 then
    vim.notify("No overrides to save", vim.log.levels.INFO)
    return
  end

  local success = Persistence.save(state.modified_highlights)
  if success then
    state.is_dirty = false
    vim.notify(
      string.format("Saved %d style override(s) - will load automatically on startup", vim.tbl_count(state.modified_highlights)),
      vim.log.levels.INFO
    )

    if multi_panel then
      multi_panel:update_panel_title("colors", " Highlight Groups ")
    end
  end
end

---Reset all highlights to defaults and clear persisted overrides
local function reset_all()
  if not state or not multi_panel then return end

  -- Confirm with user
  local nf = require("nvim-float")
  nf.confirm("Reset all highlights to defaults?\nThis will clear all saved customizations.", function()
    -- Apply all defaults
    local Theme = require("nvim-float.theme")
    for _, def in ipairs(Data.HIGHLIGHT_DEFINITIONS) do
      local default_hl = Theme.get_default_highlight(def.key)
      if default_hl then
        vim.api.nvim_set_hl(0, def.key, default_hl)
      end
    end

    -- Clear persisted overrides
    Persistence.clear()

    -- Reset state
    state.modified_highlights = {}
    state.is_dirty = false

    refresh_ui()
    if multi_panel then
      multi_panel:update_panel_title("colors", " Highlight Groups ")
    end

    vim.notify("All highlights reset to defaults", vim.log.levels.INFO)
  end)
end

---Cancel and restore original highlights
local function cancel()
  if not state then return end

  -- Restore all original highlights
  for key, hl_def in pairs(state.original_highlights) do
    vim.api.nvim_set_hl(0, key, hl_def)
  end

  M.close()
end

-- ============================================================================
-- Public API
-- ============================================================================

---Close the style editor
function M.close()
  if multi_panel then
    Render.clear_swatch_highlights()
    multi_panel:close()
    multi_panel = nil
  end
  state = nil
end

---Show the style editor UI
function M.show()
  -- Close existing editor if open
  if multi_panel then
    M.close()
  end

  -- Create state
  state = create_state()

  -- Create two-panel layout
  multi_panel = UiFloat.create_multi_panel({
    layout = {
      split = "horizontal",
      children = {
        {
          name = "colors",
          title = " Highlight Groups ",
          ratio = 0.45,
          filetype = "nvim-float-style-editor",
          cursorline = true,
          on_render = function()
            return Render.render_colors(state)
          end,
          on_create = function(bufnr, winid)
            -- Create bg-only CursorLine so swatches show through
            local selected_hl = vim.api.nvim_get_hl(0, { name = "NvimFloatSelected" })
            vim.api.nvim_set_hl(0, "NvimFloatSelectedBgOnly", {
              bg = selected_hl.bg or "#3a3a3a",
            })
            vim.api.nvim_set_option_value(
              "winhighlight",
              "Normal:NvimFloatNormal,FloatBorder:NvimFloatBorder,FloatTitle:NvimFloatTitle,CursorLine:NvimFloatSelectedBgOnly",
              { win = winid }
            )
            -- Apply swatch highlights
            vim.schedule(function()
              Render.apply_swatch_highlights(bufnr, state)
            end)
          end,
          on_focus = function()
            if multi_panel then
              local dirty_marker = state and state.is_dirty and " *" or ""
              multi_panel:update_panel_title("colors", " Highlight Groups" .. dirty_marker .. " * ")
              multi_panel:update_panel_title("preview", " Preview ")
              -- Sync cursor to selection when focusing
              sync_cursor_to_selection()
            end
          end,
        },
        {
          name = "preview",
          title = " Preview ",
          ratio = 0.55,
          filetype = "nvim-float-style-editor",
          cursorline = false,
          on_render = function()
            return Preview.build()
          end,
          on_focus = function()
            if multi_panel then
              multi_panel:update_panel_title("preview", " Preview * ")
              multi_panel:update_panel_title("colors", state and state.is_dirty and " Highlight Groups * " or " Highlight Groups ")
            end
          end,
        },
      },
    },
    total_width_ratio = 0.85,
    total_height_ratio = 0.80,
    initial_focus = "colors",
    augroup_name = "NvimFloatStyleEditor",
    border = "rounded",
    controls = {
      {
        header = "Navigation",
        keys = {
          { key = "j/k", desc = "Navigate up/down" },
          { key = "Tab", desc = "Switch panels" },
        },
      },
      {
        header = "Editing",
        keys = {
          { key = "Enter", desc = "Open color picker" },
          { key = "r", desc = "Reset current to default" },
          { key = "R", desc = "Reset ALL to defaults" },
        },
      },
      {
        header = "Actions",
        keys = {
          { key = "s", desc = "Save to disk" },
          { key = "q/Esc", desc = "Cancel" },
        },
      },
    },
  })

  if not multi_panel then
    vim.notify("Failed to create style editor", vim.log.levels.ERROR)
    return
  end

  -- Initial render of all panels
  multi_panel:render_all()

  -- Apply swatch highlights after initial render
  vim.schedule(function()
    if multi_panel then
      local colors_buf = multi_panel:get_panel_buffer("colors")
      if colors_buf then
        Render.apply_swatch_highlights(colors_buf, state)
      end
    end
  end)

  -- Set up keymaps for colors panel
  multi_panel:set_panel_keymaps("colors", {
    ["j"] = function() navigate_colors(1) end,
    ["k"] = function() navigate_colors(-1) end,
    ["<Down>"] = function() navigate_colors(1) end,
    ["<Up>"] = function() navigate_colors(-1) end,
    ["<CR>"] = edit_color,
    ["r"] = reset_to_default,
    ["R"] = reset_all,
    ["s"] = save_changes,
    ["q"] = cancel,
    ["<Esc>"] = cancel,
    ["<Tab>"] = function() multi_panel:focus_next_panel() end,
    ["<S-Tab>"] = function() multi_panel:focus_prev_panel() end,
  })

  -- Set up keymaps for preview panel
  multi_panel:set_panel_keymaps("preview", {
    ["<Tab>"] = function() multi_panel:focus_next_panel() end,
    ["<S-Tab>"] = function() multi_panel:focus_prev_panel() end,
    ["q"] = cancel,
    ["<Esc>"] = cancel,
  })

  -- Position cursor on first color
  local cursor_line = Render.get_color_cursor_line(1)
  multi_panel:set_cursor("colors", cursor_line, 0)
end

return M
