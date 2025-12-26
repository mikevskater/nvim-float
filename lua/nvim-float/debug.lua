---@module nvim-float.debug
---Debug logger with buffered async writes
---Buffers messages in memory and flushes periodically to reduce I/O blocking
local Debug = {}

-- Log file path
local log_file = vim.fn.stdpath("data") .. "/nvim_float_debug.log"

-- Buffer for pending log messages
local log_buffer = {}

-- Flush timer (nil if not running)
local flush_timer = nil

-- Flush interval in milliseconds
local FLUSH_INTERVAL_MS = 100

-- Whether the module has been initialized
local initialized = false

-- Whether debug logging is enabled
local enabled = false

---Flush buffered messages to file
---@param sync boolean? Force synchronous write (for VimLeavePre)
local function flush_buffer(sync)
  if #log_buffer == 0 then
    return
  end

  -- Capture and clear buffer atomically
  local messages = log_buffer
  log_buffer = {}

  local content = table.concat(messages, "")

  if sync then
    -- Synchronous write (used during shutdown)
    local f = io.open(log_file, "a")
    if f then
      f:write(content)
      f:close()
    end
  else
    -- Async write using libuv
    vim.schedule(function()
      local uv = vim.loop or vim.uv
      uv.fs_open(log_file, "a", 438, function(err_open, fd)
        if err_open or not fd then
          return
        end
        uv.fs_write(fd, content, -1, function(err_write)
          if err_write then
            -- Silently ignore write errors
          end
          uv.fs_close(fd, function() end)
        end)
      end)
    end)
  end
end

---Start the flush timer
local function start_flush_timer()
  if flush_timer then
    return
  end

  flush_timer = vim.fn.timer_start(FLUSH_INTERVAL_MS, function()
    flush_buffer(false)
  end, { ["repeat"] = -1 })
end

---Stop the flush timer
local function stop_flush_timer()
  if flush_timer then
    vim.fn.timer_stop(flush_timer)
    flush_timer = nil
  end
end

---Initialize log file (truncate on first load)
local function init_log()
  if initialized then
    return
  end
  initialized = true

  if not enabled then
    return
  end

  -- Synchronous init write (only happens once at startup)
  local f = io.open(log_file, "w")
  if f then
    f:write("=== nvim-float Debug Log ===\n")
    f:write(os.date("%Y-%m-%d %H:%M:%S") .. "\n\n")
    f:close()
  end

  -- Start the flush timer
  start_flush_timer()

  -- Register VimLeavePre to flush remaining messages
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = vim.api.nvim_create_augroup("NvimFloatDebugFlush", { clear = true }),
    callback = function()
      stop_flush_timer()
      flush_buffer(true) -- Synchronous flush on exit
    end,
  })
end

---Enable debug logging
function Debug.enable()
  enabled = true
  if initialized then
    -- Re-initialize if already initialized but was disabled
    initialized = false
    init_log()
  end
end

---Disable debug logging
function Debug.disable()
  enabled = false
  stop_flush_timer()
end

---Check if debug logging is enabled
---@return boolean
function Debug.is_enabled()
  return enabled
end

---Write debug message to log buffer (will be flushed async)
---@param message string The debug message
function Debug.log(message)
  if not enabled then
    return
  end

  init_log()

  local timestamp = os.date("%H:%M:%S")
  local formatted = timestamp .. " | " .. message .. "\n"
  table.insert(log_buffer, formatted)
end

---Force immediate flush of buffer (for debugging)
function Debug.flush()
  flush_buffer(false)
end

---Force synchronous flush of buffer
function Debug.flush_sync()
  flush_buffer(true)
end

---Get log file path
---@return string
function Debug.get_log_path()
  return log_file
end

---Get number of pending messages in buffer
---@return number
function Debug.get_buffer_size()
  return #log_buffer
end

return Debug
