local M = {}

local PORT_METHODS = {
  adb = { 'list_devices', 'validate_serial', 'resolve_launch_components', 'launch', 'stop' },
  emulator = { 'list_avds', 'start', 'stop' },
  logcat = { 'start' },
  runner = { 'start' },
  picker = { 'select' },
  trust = { 'authorize' },
  notifications = { 'emit' },
  problems = { 'publish' },
  state = { 'load', 'save' },
  discovery = { 'discover' },
}

local DEFAULT_BOOT_TIMEOUT_MS = 180000
local DEFAULT_POLL_INTERVAL_MS = 1000
local MAX_TIMER_MS = 2147483647

local function defaults()
  return {
    ports = {},
    logcat = { open_on_run = false },
    run = { start_stopped_avd = true },
    emulator = {
      boot_timeout_ms = DEFAULT_BOOT_TIMEOUT_MS,
      poll_interval_ms = DEFAULT_POLL_INTERVAL_MS,
    },
  }
end

local current = defaults()

local function fail(path, message) error(('android_workbench.setup: %s %s'):format(path, message), 3) end

local function validate_keys(path, value, allowed)
  if type(value) ~= 'table' then fail(path, 'must be a table') end
  for key in pairs(value) do
    if not allowed[key] then fail(('%s.%s'):format(path, tostring(key)), 'is not a supported option') end
  end
end

local function validate_port(name, port)
  if type(port) ~= 'table' then fail('ports.' .. name, 'must be a table') end
  for _, method in ipairs(PORT_METHODS[name]) do
    if type(port[method]) ~= 'function' then fail(('ports.%s.%s'):format(name, method), 'must be a function') end
  end
  if name == 'runner' and (port.has_output ~= nil or port.show_output ~= nil) then
    if type(port.has_output) ~= 'function' then fail('ports.runner.has_output', 'must be a function when runner output is supported') end
    if type(port.show_output) ~= 'function' then fail('ports.runner.show_output', 'must be a function when runner output is supported') end
  end
end

local function validate_timer(path, value)
  if type(value) ~= 'number' or value <= 0 or value > MAX_TIMER_MS or value % 1 ~= 0 then fail(path, 'must be a bounded positive integer') end
end

local function copy(config)
  local result = {
    ports = {},
    logcat = { open_on_run = config.logcat.open_on_run },
    run = { start_stopped_avd = config.run.start_stopped_avd },
    emulator = {
      boot_timeout_ms = config.emulator.boot_timeout_ms,
      poll_interval_ms = config.emulator.poll_interval_ms,
    },
  }
  for name in pairs(PORT_METHODS) do
    result.ports[name] = config.ports[name]
  end
  return result
end

---@class AndroidWorkbenchConfig
---@field ports table<string, table|nil>
---@field logcat { open_on_run: boolean }
---@field run { start_stopped_avd: boolean }
---@field emulator { boot_timeout_ms: integer, poll_interval_ms: integer }

---@param opts? { ports?: table<string, table>, logcat?: { open_on_run?: boolean }, run?: { start_stopped_avd?: boolean }, emulator?: { boot_timeout_ms?: integer, poll_interval_ms?: integer } }
---@return AndroidWorkbenchConfig
function M.setup(opts)
  opts = opts or {}
  validate_keys('options', opts, { ports = true, logcat = true, run = true, emulator = true })

  local next_config = defaults()
  if opts.ports ~= nil then
    validate_keys('ports', opts.ports, PORT_METHODS)
    for name in pairs(PORT_METHODS) do
      local port = opts.ports[name]
      if port ~= nil then
        validate_port(name, port)
        next_config.ports[name] = port
      end
    end
    if next_config.ports.adb and not next_config.ports.logcat and type(next_config.ports.adb.resolve_executable) ~= 'function' then
      fail('ports.adb.resolve_executable', 'must be a function when using the native Logcat presenter')
    end
  end

  if opts.logcat ~= nil then
    validate_keys('logcat', opts.logcat, { open_on_run = true })
    if opts.logcat.open_on_run ~= nil then
      if type(opts.logcat.open_on_run) ~= 'boolean' then fail('logcat.open_on_run', 'must be a boolean') end
      next_config.logcat.open_on_run = opts.logcat.open_on_run
    end
  end

  if opts.run ~= nil then
    validate_keys('run', opts.run, { start_stopped_avd = true })
    if opts.run.start_stopped_avd ~= nil then
      if type(opts.run.start_stopped_avd) ~= 'boolean' then fail('run.start_stopped_avd', 'must be a boolean') end
      next_config.run.start_stopped_avd = opts.run.start_stopped_avd
    end
  end

  if opts.emulator ~= nil then
    validate_keys('emulator', opts.emulator, { boot_timeout_ms = true, poll_interval_ms = true })
    if opts.emulator.boot_timeout_ms ~= nil then
      validate_timer('emulator.boot_timeout_ms', opts.emulator.boot_timeout_ms)
      next_config.emulator.boot_timeout_ms = opts.emulator.boot_timeout_ms
    end
    if opts.emulator.poll_interval_ms ~= nil then
      validate_timer('emulator.poll_interval_ms', opts.emulator.poll_interval_ms)
      next_config.emulator.poll_interval_ms = opts.emulator.poll_interval_ms
    end
  end

  current = next_config
  return copy(current)
end

---@return AndroidWorkbenchConfig
function M.get() return copy(current) end

return M

-- vim: ts=2 sts=2 sw=2 et
