---@module 'nvim-float.container.manager'
---@brief ContainerManager - Manages lifecycle and focus of all containers within a parent FloatWindow

local EmbeddedContainer = require("nvim-float.container")

---@class ContainerManager
---Manages all embedded containers within a parent FloatWindow
local ContainerManager = {}
ContainerManager.__index = ContainerManager

-- ============================================================================
-- Constructor
-- ============================================================================

---Create a new ContainerManager for a parent FloatWindow
---@param parent_float FloatWindow The parent FloatWindow instance
---@return ContainerManager
function ContainerManager.new(parent_float)
  local self = setmetatable({}, ContainerManager)
  self._parent_float = parent_float
  self._containers = {}      -- Map of name -> EmbeddedContainer
  self._container_order = {} -- Ordered list of container names (insertion order)
  self._focused_name = nil   -- Name of currently focused container
  return self
end

-- ============================================================================
-- Container Lifecycle
-- ============================================================================

---Add a new embedded container
---@param config EmbeddedContainerConfig Container configuration
---@return EmbeddedContainer container The created container
function ContainerManager:add(config)
  -- Set parent references if not provided
  config.parent_winid = config.parent_winid or self._parent_float.winid
  config.parent_float = config.parent_float or self._parent_float

  local container = EmbeddedContainer.new(config)
  self._containers[config.name] = container
  table.insert(self._container_order, config.name)

  return container
end

---Remove a container by name
---@param name string Container name
function ContainerManager:remove(name)
  local container = self._containers[name]
  if not container then return end

  -- Unfocus if this was focused
  if self._focused_name == name then
    self._focused_name = nil
  end

  container:close()
  self._containers[name] = nil

  -- Remove from order
  for i, n in ipairs(self._container_order) do
    if n == name then
      table.remove(self._container_order, i)
      break
    end
  end
end

---Get a container by name
---@param name string Container name
---@return EmbeddedContainer? container
function ContainerManager:get(name)
  return self._containers[name]
end

---Check if a container exists
---@param name string Container name
---@return boolean
function ContainerManager:has(name)
  return self._containers[name] ~= nil
end

---Get all container names in order
---@return string[]
function ContainerManager:get_names()
  return vim.deepcopy(self._container_order)
end

---Get count of containers
---@return number
function ContainerManager:count()
  return #self._container_order
end

-- ============================================================================
-- Focus Management
-- ============================================================================

---Focus the next container in order
---@return string? name Name of the newly focused container
function ContainerManager:focus_next()
  if #self._container_order == 0 then return nil end

  local current_idx = 0
  if self._focused_name then
    for i, name in ipairs(self._container_order) do
      if name == self._focused_name then
        current_idx = i
        break
      end
    end
  end

  local next_idx = (current_idx % #self._container_order) + 1
  local next_name = self._container_order[next_idx]
  local container = self._containers[next_name]

  if container and container:is_valid() then
    -- Blur current
    if self._focused_name and self._containers[self._focused_name] then
      self._containers[self._focused_name]._focused = false
      if self._containers[self._focused_name]._config.on_blur then
        self._containers[self._focused_name]._config.on_blur()
      end
    end
    self._focused_name = next_name
    container:focus()
    return next_name
  end

  return nil
end

---Focus the previous container in order
---@return string? name Name of the newly focused container
function ContainerManager:focus_prev()
  if #self._container_order == 0 then return nil end

  local current_idx = 1
  if self._focused_name then
    for i, name in ipairs(self._container_order) do
      if name == self._focused_name then
        current_idx = i
        break
      end
    end
  end

  local prev_idx = ((current_idx - 2) % #self._container_order) + 1
  local prev_name = self._container_order[prev_idx]
  local container = self._containers[prev_name]

  if container and container:is_valid() then
    -- Blur current
    if self._focused_name and self._containers[self._focused_name] then
      self._containers[self._focused_name]._focused = false
      if self._containers[self._focused_name]._config.on_blur then
        self._containers[self._focused_name]._config.on_blur()
      end
    end
    self._focused_name = prev_name
    container:focus()
    return prev_name
  end

  return nil
end

---Focus a specific container by name
---@param name string Container name
---@return boolean success
function ContainerManager:focus(name)
  local container = self._containers[name]
  if not container or not container:is_valid() then return false end

  -- Blur current
  if self._focused_name and self._focused_name ~= name then
    local current = self._containers[self._focused_name]
    if current then
      current._focused = false
      if current._config.on_blur then
        current._config.on_blur()
      end
    end
  end

  self._focused_name = name
  container:focus()
  return true
end

---Blur the currently focused container (return focus to parent)
function ContainerManager:blur_focused()
  if not self._focused_name then return end

  local container = self._containers[self._focused_name]
  if container then
    container:blur()
  end
  self._focused_name = nil
end

---Get the currently focused container
---@return EmbeddedContainer? container
function ContainerManager:get_focused()
  if not self._focused_name then return nil end
  return self._containers[self._focused_name]
end

---Get the name of the currently focused container
---@return string? name
function ContainerManager:get_focused_name()
  return self._focused_name
end

-- ============================================================================
-- Reposition
-- ============================================================================

---Reposition all containers (e.g., after parent resize)
function ContainerManager:reposition_all()
  for _, name in ipairs(self._container_order) do
    local container = self._containers[name]
    if container and container:is_valid() then
      -- The container's row/col relative to parent are stored in its config
      -- They should still be valid after parent resize since they're relative
      container:update_region()
    end
  end
end

-- ============================================================================
-- Cleanup
-- ============================================================================

---Close all containers
function ContainerManager:close_all()
  -- Close in reverse order
  for i = #self._container_order, 1, -1 do
    local name = self._container_order[i]
    local container = self._containers[name]
    if container then
      container:close()
    end
  end
  self._containers = {}
  self._container_order = {}
  self._focused_name = nil
end

return ContainerManager
