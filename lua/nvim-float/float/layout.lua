---Layout calculation module for multi-panel floating windows
---Pure calculation functions with no UI dependencies
---@module nvim-float.float.layout
---@class FloatLayout
local FloatLayout = {}

-- ============================================================================
-- Type Definitions
-- ============================================================================

---@class LayoutNode
---A node in the layout tree - either a split or a panel
---@field split "horizontal"|"vertical"? Split direction (nil = leaf panel)
---@field ratio number? Size ratio relative to siblings (default: 1.0)
---@field min_height number? Minimum height in lines (for vertical splits)
---@field min_width number? Minimum width in columns (for horizontal splits)
---@field children LayoutNode[]? Child nodes for splits
---@field name string? Panel name (required for leaf nodes)
---@field title string? Panel title
---@field filetype string? Filetype for syntax highlighting
---@field focusable boolean? Can this panel be focused (default: true)
---@field cursorline boolean? Show cursor line when focused (default: true)
---@field on_render fun(state: MultiPanelState): string[], table[]? Render callback
---@field on_focus fun(state: MultiPanelState)? Called when panel gains focus
---@field on_blur fun(state: MultiPanelState)? Called when panel loses focus

---@class LayoutRect
---@field x number Left position
---@field y number Top position
---@field width number Width
---@field height number Height

---@class BorderPosition
---@field top boolean Has neighbor above
---@field bottom boolean Has neighbor below
---@field left boolean Has neighbor to the left
---@field right boolean Has neighbor to the right

---@class PanelLayout
---@field name string Panel name
---@field rect LayoutRect Panel rectangle
---@field border_pos BorderPosition Border position flags
---@field definition LayoutNode Panel definition

-- ============================================================================
-- Constants
-- ============================================================================

---Box drawing characters for panel borders
FloatLayout.BORDER_CHARS = {
  horizontal = "─",
  vertical = "│",
  top_left = "╭",
  top_right = "╮",
  bottom_left = "╰",
  bottom_right = "╯",
  t_down = "┬",  -- T pointing down (top edge with connection below)
  t_up = "┴",    -- T pointing up (bottom edge with connection above)
  t_right = "├", -- T pointing right (left edge with connection right)
  t_left = "┤",  -- T pointing left (right edge with connection left)
  cross = "┼",   -- 4-way intersection
}

-- ============================================================================
-- Border Calculation
-- ============================================================================

---Create border for a panel based on its position in the layout
---@param pos BorderPosition Position flags
---@return table border Border characters array
function FloatLayout.create_panel_border(pos)
  local c = FloatLayout.BORDER_CHARS

  -- Determine corner characters based on neighbors
  local top_left, top_right, bottom_left, bottom_right

  -- Top-left corner
  if pos.top and pos.left then
    top_left = c.cross
  elseif pos.top then
    top_left = c.t_right
  elseif pos.left then
    top_left = c.t_down
  else
    top_left = c.top_left
  end

  -- Top-right corner
  if pos.top and pos.right then
    top_right = c.cross
  elseif pos.top then
    top_right = c.t_left
  elseif pos.right then
    top_right = c.t_down
  else
    top_right = c.top_right
  end

  -- Bottom-left corner
  if pos.bottom and pos.left then
    bottom_left = c.cross
  elseif pos.bottom then
    bottom_left = c.t_right
  elseif pos.left then
    bottom_left = c.t_up
  else
    bottom_left = c.bottom_left
  end

  -- Bottom-right corner
  if pos.bottom and pos.right then
    bottom_right = c.cross
  elseif pos.bottom then
    bottom_right = c.t_left
  elseif pos.right then
    bottom_right = c.t_up
  else
    bottom_right = c.bottom_right
  end

  return {
    top_left, c.horizontal, top_right,
    c.vertical, bottom_right, c.horizontal,
    bottom_left, c.vertical,
  }
end

-- ============================================================================
-- Layout Calculation
-- ============================================================================

---Recursively calculate layout for a layout node
---@param node LayoutNode Layout node
---@param rect LayoutRect Available rectangle
---@param border_pos BorderPosition Inherited border position
---@param results PanelLayout[] Output array
---@param sibling_info table? Info about siblings {index, total, direction}
function FloatLayout.calculate_layout_recursive(node, rect, border_pos, results, sibling_info)
  if node.split then
    -- This is a split node - divide space among children
    local children = node.children or {}
    if #children == 0 then return end

    -- Calculate total ratio
    local total_ratio = 0
    for _, child in ipairs(children) do
      total_ratio = total_ratio + (child.ratio or 1.0)
    end

    if node.split == "horizontal" then
      -- Split horizontally (children side by side)
      local available_width = rect.width - (#children - 1)  -- Account for shared borders
      local current_x = rect.x

      for i, child in ipairs(children) do
        local child_ratio = (child.ratio or 1.0) / total_ratio
        local child_width = math.floor(available_width * child_ratio)

        -- Last child gets remaining width
        if i == #children then
          child_width = rect.x + rect.width - current_x
        end

        -- Calculate border position for child
        local child_border = {
          top = border_pos.top,
          bottom = border_pos.bottom,
          left = i > 1,           -- Has left neighbor if not first
          right = i < #children,  -- Has right neighbor if not last
        }

        local child_rect = {
          x = current_x,
          y = rect.y,
          width = child_width,
          height = rect.height,
        }

        FloatLayout.calculate_layout_recursive(child, child_rect, child_border, results, {
          index = i,
          total = #children,
          direction = "horizontal",
        })

        current_x = current_x + child_width + 1  -- +1 for shared border
      end
    else
      -- Split vertically (children stacked)
      local shared_borders = #children - 1
      local available_height = rect.height - shared_borders  -- Account for shared borders

      -- First pass: calculate minimum heights and remaining ratio-based space
      local total_min_height = 0
      local ratio_children = {}
      local fixed_children = {}

      for i, child in ipairs(children) do
        if child.min_height and child.min_height > 0 then
          -- This child has a minimum height requirement
          local min_h = child.min_height
          total_min_height = total_min_height + min_h
          table.insert(fixed_children, { index = i, child = child, min_height = min_h })
        else
          table.insert(ratio_children, { index = i, child = child })
        end
      end

      -- Calculate heights respecting minimums
      local remaining_height = available_height - total_min_height
      local child_heights = {}

      -- Calculate ratio total for non-fixed children
      local ratio_total = 0
      for _, rc in ipairs(ratio_children) do
        ratio_total = ratio_total + (rc.child.ratio or 1.0)
      end

      -- Assign heights to all children
      for i, child in ipairs(children) do
        local height
        if child.min_height and child.min_height > 0 then
          -- Use minimum height (or more if space allows based on ratio)
          local ratio_height = 0
          if ratio_total > 0 then
            local child_ratio = (child.ratio or 1.0) / total_ratio
            ratio_height = math.floor(available_height * child_ratio)
          end
          height = math.max(child.min_height, ratio_height)
        else
          -- Distribute remaining space by ratio
          if ratio_total > 0 and remaining_height > 0 then
            local child_ratio = (child.ratio or 1.0) / ratio_total
            height = math.floor(remaining_height * child_ratio)
          else
            height = math.floor(available_height / #children)
          end
        end
        child_heights[i] = math.max(1, height)  -- Ensure at least 1 line
      end

      -- Adjust last child to fill remaining space
      local total_assigned = 0
      for i = 1, #children - 1 do
        total_assigned = total_assigned + child_heights[i]
      end
      child_heights[#children] = math.max(1, available_height - total_assigned)

      -- Second pass: create child rectangles
      local current_y = rect.y
      for i, child in ipairs(children) do
        local child_height = child_heights[i]

        -- Calculate border position for child
        local child_border = {
          top = i > 1,            -- Has top neighbor if not first
          bottom = i < #children, -- Has bottom neighbor if not last
          left = border_pos.left,
          right = border_pos.right,
        }

        local child_rect = {
          x = rect.x,
          y = current_y,
          width = rect.width,
          height = child_height,
        }

        FloatLayout.calculate_layout_recursive(child, child_rect, child_border, results, {
          index = i,
          total = #children,
          direction = "vertical",
        })

        current_y = current_y + child_height + 1  -- +1 for shared border
      end
    end
  else
    -- This is a leaf panel
    table.insert(results, {
      name = node.name,
      rect = rect,
      border_pos = border_pos,
      definition = node,
    })
  end
end

---Calculate full layout from config
---@param config table Configuration with layout, total_width_ratio, total_height_ratio
---@return PanelLayout[] layouts Array of panel layouts
---@return number total_width Total width in columns
---@return number total_height Total height in rows
---@return number start_row Starting row position
---@return number start_col Starting column position
function FloatLayout.calculate_full_layout(config)
  local width_ratio = config.total_width_ratio or 0.85
  local height_ratio = config.total_height_ratio or 0.75
  local total_width = math.floor(vim.o.columns * width_ratio)
  local total_height = math.floor(vim.o.lines * height_ratio)
  local start_row = math.floor((vim.o.lines - total_height) / 2)
  local start_col = math.floor((vim.o.columns - total_width) / 2)

  local results = {}
  local root_rect = {
    x = start_col,
    y = start_row,
    width = total_width,
    height = total_height,
  }

  FloatLayout.calculate_layout_recursive(config.layout, root_rect, {
    top = false,
    bottom = false,
    left = false,
    right = false,
  }, results, nil)

  return results, total_width, total_height, start_row, start_col
end

-- ============================================================================
-- Panel Navigation
-- ============================================================================

---Collect panel names in order (for tab navigation)
---@param node LayoutNode Layout node
---@param result string[] Output array
function FloatLayout.collect_panel_names(node, result)
  if node.split then
    for _, child in ipairs(node.children or {}) do
      FloatLayout.collect_panel_names(child, result)
    end
  elseif node.name then
    table.insert(result, node.name)
  end
end

-- ============================================================================
-- Border Intersections
-- ============================================================================

---Find all border intersection points between panels
---@param layouts PanelLayout[] Panel layouts
---@return table[] intersections Array of {x, y, char} for each intersection
function FloatLayout.find_border_intersections(layouts)
  local c = FloatLayout.BORDER_CHARS
  local intersections = {}

  -- Collect all horizontal and vertical border positions
  -- For panels with borders, the border occupies:
  -- - Top border at row = rect.y (the window position includes the border)
  -- - Bottom border at row = rect.y + rect.height + 1
  -- - Left border at col = rect.x
  -- - Right border at col = rect.x + rect.width + 1
  local h_borders = {}  -- {y = {{start_x, end_x, panel}}}
  local v_borders = {}  -- {x = {{start_y, end_y, panel}}}

  for _, layout in ipairs(layouts) do
    local rect = layout.rect
    local top_y = rect.y
    local bottom_y = rect.y + rect.height + 1
    local left_x = rect.x
    local right_x = rect.x + rect.width + 1

    -- Store horizontal borders (top and bottom of each panel)
    h_borders[top_y] = h_borders[top_y] or {}
    table.insert(h_borders[top_y], {start_x = left_x, end_x = right_x, panel = layout.name})

    h_borders[bottom_y] = h_borders[bottom_y] or {}
    table.insert(h_borders[bottom_y], {start_x = left_x, end_x = right_x, panel = layout.name})

    -- Store vertical borders (left and right of each panel)
    v_borders[left_x] = v_borders[left_x] or {}
    table.insert(v_borders[left_x], {start_y = top_y, end_y = bottom_y, panel = layout.name})

    v_borders[right_x] = v_borders[right_x] or {}
    table.insert(v_borders[right_x], {start_y = top_y, end_y = bottom_y, panel = layout.name})
  end

  -- Track which intersections we've already added to avoid duplicates
  local added = {}

  -- Find all intersections: where borders meet (both internal and corners)
  for y, h_border_list in pairs(h_borders) do
    for x, v_border_list in pairs(v_borders) do
      -- Check what directions vertical borders extend from this point
      local v_extends_up = false
      local v_extends_down = false

      for _, v_border in ipairs(v_border_list) do
        -- Vertical border passes through or starts/ends at this Y
        if y >= v_border.start_y and y <= v_border.end_y then
          if v_border.start_y < y then
            v_extends_up = true
          end
          if v_border.end_y > y then
            v_extends_down = true
          end
        end
      end

      -- Check what directions horizontal borders extend from this point
      local h_extends_left = false
      local h_extends_right = false

      for _, h_border in ipairs(h_border_list) do
        if h_border.start_x <= x and h_border.end_x >= x then
          if h_border.start_x < x then
            h_extends_left = true
          end
          if h_border.end_x > x then
            h_extends_right = true
          end
        end
      end

      -- Determine the correct junction character based on all 4 directions
      -- Only create overlay if this is a junction (more than 2 directions, or a T-junction)
      local directions = (v_extends_up and 1 or 0) + (v_extends_down and 1 or 0) +
                         (h_extends_left and 1 or 0) + (h_extends_right and 1 or 0)

      -- We need an overlay if:
      -- 1. It's a cross (4 directions) or T-junction (3 directions)
      -- 2. It's a corner that needs a junction character (vertical in both directions + horizontal in one)
      if directions >= 3 then
        local key = string.format("%d,%d", x, y)
        if not added[key] then
          added[key] = true

          local char
          if v_extends_up and v_extends_down and h_extends_left and h_extends_right then
            char = c.cross  -- ┼
          elseif v_extends_up and v_extends_down and h_extends_left then
            char = c.t_left  -- ┤
          elseif v_extends_up and v_extends_down and h_extends_right then
            char = c.t_right  -- ├
          elseif h_extends_left and h_extends_right and v_extends_down then
            char = c.t_down  -- ┬
          elseif h_extends_left and h_extends_right and v_extends_up then
            char = c.t_up  -- ┴
          elseif v_extends_down and h_extends_right then
            -- Top-left corner style, but we only overlay if it should be a junction
            -- This case shouldn't happen with directions >= 3, but handle it
            char = c.top_left
          elseif v_extends_down and h_extends_left then
            char = c.top_right
          elseif v_extends_up and h_extends_right then
            char = c.bottom_left
          elseif v_extends_up and h_extends_left then
            char = c.bottom_right
          end

          if char then
            table.insert(intersections, {x = x, y = y, char = char})
          end
        end
      end
    end
  end

  return intersections
end

return FloatLayout
