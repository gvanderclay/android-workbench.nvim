local M = {}

local Adb = {}
Adb.__index = Adb

local DEFAULT_TIMEOUT_MS = 30000
local MAX_STDOUT_BYTES = 256 * 1024
local MAX_STDERR_BYTES = 64 * 1024
local MAX_DEVICES = 1024
local MAX_COMPONENTS = 1024
local MAX_AVD_NAME_BYTES = 1024
local KILL_GRACE_MS = 1000

---@class AndroidWorkbenchAdbDevice
---@field serial string
---@field state 'online'|'authorizing'|'bootloader'|'connecting'|'detached'|'host'|'offline'|'recovery'|'rescue'|'sideload'|'unauthorized'|'no_permissions'|'unknown'
---@field raw_state? string
---@field label? string
---@field details? string
---@field avd_name? string

---@class AndroidWorkbenchAdbComponent
---@field component string
---@field package string
---@field activity? string

---@class AndroidWorkbenchAdbLaunchResult
---@field serial string
---@field application_id string
---@field component string
---@field status string
---@field activity? string
---@field launch_state? string
---@field total_time_ms? integer
---@field wait_time_ms? integer

---@class AndroidWorkbenchAdbStopResult
---@field serial string
---@field application_id string

---@class AndroidWorkbenchAdbService
---@field list_devices fun(self: AndroidWorkbenchAdbService, callback: fun(error: AndroidWorkbenchError?, devices: AndroidWorkbenchAdbDevice[]?)): AndroidWorkbenchOperationHandle?
---@field validate_serial fun(self: AndroidWorkbenchAdbService, serial: string, callback: fun(error: AndroidWorkbenchError?, device: AndroidWorkbenchAdbDevice?)): AndroidWorkbenchOperationHandle?
---@field resolve_launch_components fun(self: AndroidWorkbenchAdbService, serial: string, application_id: string, callback: fun(error: AndroidWorkbenchError?, components: AndroidWorkbenchAdbComponent[]?)): AndroidWorkbenchOperationHandle?
---@field launch fun(self: AndroidWorkbenchAdbService, serial: string, application_id: string, component: string, callback: fun(error: AndroidWorkbenchError?, result: AndroidWorkbenchAdbLaunchResult?)): AndroidWorkbenchOperationHandle?
---@field stop fun(self: AndroidWorkbenchAdbService, serial: string, application_id: string, callback: fun(error: AndroidWorkbenchError?, result: AndroidWorkbenchAdbStopResult?)): AndroidWorkbenchOperationHandle?

local DEVICE_STATES = {
  authorizing = true,
  bootloader = true,
  connecting = true,
  detached = true,
  device = true,
  host = true,
  offline = true,
  recovery = true,
  rescue = true,
  sideload = true,
  unauthorized = true,
}

local function failure(code, message, details)
  return {
    code = code,
    message = message,
    details = details,
  }
end

local function valid_timeout(value) return type(value) == 'number' and value == value and value > 0 and value <= 2147483647 and value % 1 == 0 end

local function excerpt(value)
  value = value or ''
  if #value > 8192 then value = value:sub(-8192) end
  return vim.trim(value)
end

local function lines(value)
  value = (value or ''):gsub('\r\n', '\n'):gsub('\r', '\n')
  local result = {}
  for line in (value .. '\n'):gmatch '(.-)\n' do
    result[#result + 1] = line
  end
  return result
end

local function shell_quote(value) return "'" .. value:gsub("'", "'\\''") .. "'" end

local function validate_serial(serial)
  if type(serial) ~= 'string' or serial == '' or #serial > 1024 or serial:find '%c' then
    return nil, failure('invalid_serial', 'Android device serial must be a non-empty string without control characters.')
  end
  return serial
end

local function valid_dotted_name(value, segment_pattern)
  if value == '' or value:sub(1, 1) == '.' or value:sub(-1) == '.' or value:find('..', 1, true) then return false end
  local count = 0
  for segment in value:gmatch '[^.]+' do
    if not segment:match(segment_pattern) then return false end
    count = count + 1
  end
  return count > 0
end

local function validate_application_id(application_id)
  if type(application_id) ~= 'string' or #application_id > 512 then
    return nil, failure('invalid_application_id', 'Android applicationId must be a valid dotted package name.')
  end
  if not valid_dotted_name(application_id, '^[A-Za-z][A-Za-z0-9_]*$') or not application_id:find('.', 1, true) then
    return nil, failure('invalid_application_id', 'Android applicationId must be a valid dotted package name.')
  end
  return application_id
end

local function component_parts(application_id, component)
  if type(component) ~= 'string' or component == '' or #component > 2048 or component:find '[%s%c]' then
    return nil, failure('invalid_component', 'Android launch component must be a package/activity pair.')
  end

  local package_name, activity = component:match '^([^/]+)/([^/]+)$'
  if not package_name or package_name ~= application_id then
    return nil,
      failure('invalid_component', 'Android launch component must belong to the selected applicationId.', {
        application_id = application_id,
        component = component,
      })
  end

  local qualified_activity = activity
  if activity:sub(1, 1) == '.' then qualified_activity = application_id .. activity end

  return {
    component = component,
    package = package_name,
    activity = qualified_activity,
  }
end

local function normalized_state(raw_state)
  if raw_state == 'device' then return 'online' end
  if raw_state == 'no permissions' then return 'no_permissions' end
  if DEVICE_STATES[raw_state] then return raw_state end
  return 'unknown'
end

local function split_device_entry(line)
  local cursor = #line
  while cursor > 0 do
    local prefix = line:sub(1, cursor)
    local token_start, _, token = prefix:find '(%S+)%s*$'
    if not token_start then break end

    local raw_state
    local state_start = token_start
    if DEVICE_STATES[token] then
      raw_state = token
    elseif token == 'permissions' then
      local previous_prefix = line:sub(1, token_start - 1)
      local previous_start, _, previous = previous_prefix:find '(%S+)%s*$'
      if previous == 'no' then
        raw_state = 'no permissions'
        state_start = previous_start
      end
    end

    if raw_state then
      local serial = line:sub(1, state_start - 1):gsub('%s+$', '')
      local detail = vim.trim(line:sub(token_start + #token))
      if validate_serial(serial) then return serial, raw_state .. (detail ~= '' and ' ' .. detail or '') end
    end

    cursor = token_start - 1
  end

  local serial, remainder = line:match '^(%S+)%s+(.+)$'
  if serial and validate_serial(serial) then return serial, remainder end
end

local function parse_devices(stdout)
  local output = lines(stdout)
  local header_seen = false
  local devices = {}
  local serials = {}

  for _, line in ipairs(output) do
    local trimmed = vim.trim(line)
    if trimmed ~= '' then
      if not header_seen then
        if trimmed ~= 'List of devices attached' then
          return nil, failure('invalid_devices_output', 'ADB returned an unrecognized device list.', { output = excerpt(stdout) })
        end
        header_seen = true
      else
        if #devices >= MAX_DEVICES then return nil, failure('invalid_devices_output', 'ADB returned too many devices.') end

        local serial, remainder = split_device_entry(line)
        if not serial then return nil, failure('invalid_devices_output', 'ADB returned a malformed device entry.', { entry = line }) end
        if serials[serial] then return nil, failure('invalid_devices_output', 'ADB returned the same device serial more than once.', { serial = serial }) end

        local raw_state, detail
        if remainder:find('no permissions', 1, true) == 1 then
          raw_state = 'no permissions'
          detail = vim.trim(remainder:sub(#raw_state + 1))
        else
          raw_state, detail = remainder:match '^(%S+)%s*(.*)$'
        end
        if not raw_state then return nil, failure('invalid_devices_output', 'ADB returned a malformed device state.', { entry = line }) end

        local properties = {}
        local descriptions = {}
        if raw_state == 'no permissions' then
          if detail ~= '' then descriptions[1] = detail end
        else
          for token in (detail or ''):gmatch '%S+' do
            local key, value = token:match '^([^:]+):(.*)$'
            if key and value ~= '' then
              properties[key] = value
            else
              descriptions[#descriptions + 1] = token
            end
          end
        end

        local device = {
          serial = serial,
          state = normalized_state(raw_state),
          raw_state = raw_state,
          label = properties.model or properties.product or properties.device,
        }
        if #descriptions > 0 then device.details = table.concat(descriptions, ' ') end
        devices[#devices + 1] = device
        serials[serial] = true
      end
    end
  end

  if not header_seen then return nil, failure('invalid_devices_output', 'ADB did not return a device-list header.') end
  return devices
end

local function remote_error(value)
  for _, line in ipairs(lines(value)) do
    line = vim.trim(line)
    if line:match '^Error[%s:]' or line:match '^Exception[%s:]' or line:match '^java%.[%w_.]*Exception[%s:]' then return line end
  end
end

local function parse_avd_name(stdout, stderr)
  local output_error = remote_error(stdout .. '\n' .. stderr)
  if output_error then return nil, failure('avd_name_query_failed', 'ADB could not resolve the emulator AVD name.', { output = output_error }) end

  local output = {}
  for _, line in ipairs(lines(stdout)) do
    line = vim.trim(line)
    if line ~= '' then output[#output + 1] = line end
  end

  local terminal = output[#output]
  if terminal == 'OK' then
    output[#output] = nil
  elseif terminal == 'KO' or (terminal and terminal:match '^KO[%s:]') then
    return nil, failure('avd_name_query_failed', 'ADB could not resolve the emulator AVD name.', { output = excerpt(stdout) })
  end

  if #output ~= 1 or output[1] == '' or #output[1] > MAX_AVD_NAME_BYTES or output[1]:find '[%s%c]' then
    return nil, failure('invalid_avd_name_output', 'ADB returned an invalid emulator AVD name.', { output = excerpt(stdout) })
  end
  return output[1]
end

local function parse_boot_completed(stdout, stderr, context)
  local output_error = remote_error(stdout .. '\n' .. stderr)
  if output_error then
    return nil, failure('boot_query_failed', 'ADB could not query Android boot readiness.', {
      serial = context.serial,
      output = output_error,
    })
  end

  local output = {}
  for _, line in ipairs(lines(stdout)) do
    line = vim.trim(line)
    if line ~= '' then output[#output + 1] = line end
  end
  if #output == 0 then return false end
  if #output == 1 and output[1] == '0' then return false end
  if #output == 1 and output[1] == '1' then return true end
  return nil,
    failure('invalid_boot_output', 'ADB returned an invalid Android boot-completion value.', {
      serial = context.serial,
      output = excerpt(stdout),
    })
end

local function parse_emulator_kill(stdout, stderr, context)
  local output = stdout .. '\n' .. stderr
  local output_error = remote_error(output)
  if output_error or output:match '^%s*KO[%s:]' then
    return nil,
      failure('emulator_kill_failed', 'ADB could not stop the Android emulator.', {
        serial = context.serial,
        output = output_error or excerpt(output),
      })
  end
  return { serial = context.serial }
end

local function parse_components(stdout, stderr, context)
  local output_error = remote_error(stdout .. '\n' .. stderr)
  if output_error then return nil, failure('component_query_failed', 'ADB could not resolve the application launch activity.', { output = output_error }) end

  local components = {}
  local seen = {}
  for _, line in ipairs(lines(stdout)) do
    line = vim.trim(line)
    if line ~= '' and line ~= 'No activities found' then
      if #components >= MAX_COMPONENTS then return nil, failure('invalid_components_output', 'ADB returned too many launch activities.') end
      local component, component_err = component_parts(context.application_id, line)
      if not component then
        return nil,
          failure('invalid_components_output', 'ADB returned an invalid launch component.', {
            component = line,
            reason = component_err.message,
          })
      end
      if not seen[component.component] then
        components[#components + 1] = component
        seen[component.component] = true
      end
    end
  end
  return components
end

local function parse_launch(stdout, stderr, context)
  local output_error = remote_error(stdout .. '\n' .. stderr)
  if output_error then return nil, failure('launch_failed', 'Android application launch failed.', { output = output_error }) end

  local values = {}
  for _, line in ipairs(lines(stdout)) do
    local key, value = line:match '^%s*([A-Za-z]+):%s*(.-)%s*$'
    if key then values[key] = value end
  end
  if values.Status == nil or values.Status == '' then
    return nil, failure('invalid_launch_output', 'ADB did not confirm that the Android application launched.', { output = excerpt(stdout) })
  end
  if values.Status:lower() ~= 'ok' then
    return nil, failure('launch_failed', 'Android application launch did not complete successfully.', { status = values.Status })
  end

  return {
    serial = context.serial,
    application_id = context.application_id,
    component = context.component,
    status = values.Status,
    activity = values.Activity,
    launch_state = values.LaunchState,
    total_time_ms = tonumber(values.TotalTime),
    wait_time_ms = tonumber(values.WaitTime),
  }
end

local function parse_stop(stdout, stderr, context)
  local output_error = remote_error(stdout .. '\n' .. stderr)
  if output_error then return nil, failure('stop_failed', 'Android application stop failed.', { output = output_error }) end
  return {
    serial = context.serial,
    application_id = context.application_id,
  }
end

local function close_timer(timer)
  if not timer then return end
  pcall(timer.stop, timer)
  local ok, closing = pcall(timer.is_closing, timer)
  if not ok or not closing then pcall(timer.close, timer) end
end

local function default_adb()
  local path = vim.fn.exepath 'adb'
  if path == '' then return nil, failure('adb_not_found', 'Could not find adb on PATH.') end
  return path
end

local function deferred(callback, err, value)
  local claimed = false
  local handle = {}

  vim.schedule(function()
    if claimed then return end
    claimed = true
    callback(err, value)
  end)

  function handle.cancel()
    if claimed then return false end
    claimed = true
    vim.schedule(function() callback(failure('cancelled', 'ADB operation was cancelled.')) end)
    return true
  end

  return handle
end

function Adb:_resolve_tool()
  local ok, path, resolve_err = pcall(self.resolve_adb)
  if not ok then return nil, failure('adb_not_found', 'Could not resolve adb.', { error = tostring(path) }) end
  if type(path) ~= 'string' or path == '' or path:find('\0', 1, true) then
    if type(resolve_err) == 'table' and resolve_err.code then return nil, resolve_err end
    return nil, failure('adb_not_found', 'Could not find adb on PATH.', resolve_err and { error = tostring(resolve_err) } or nil)
  end
  return path
end

function Adb:resolve_executable() return self:_resolve_tool() end

function Adb:_run(operation, args, parser, context, callback)
  assert(type(callback) == 'function', 'android_workbench.android.adb: callback is required')

  local done, delivered, exited = false, false, false
  local process, timeout_timer, kill_timer
  local terminal_error
  local pending_err, pending_result
  local term_sent = false
  local stdout_chunks, stderr_chunks = {}, {}
  local stdout_bytes, stderr_bytes = 0, 0

  local function finish(err, result)
    if done then return false end
    done = true
    pending_err = err
    pending_result = result
    close_timer(timeout_timer)
    timeout_timer = nil
    vim.schedule(function()
      if delivered then return end
      delivered = true
      callback(pending_err, pending_result)
    end)
    return true
  end

  local function send_term()
    if term_sent or exited then return true end
    if not process then return false end
    local called, sent = pcall(process.kill, process, 15)
    if not called or sent == false then return false end
    term_sent = true
    return true
  end

  local function terminate(err, require_signal)
    if done or terminal_error then return false end
    terminal_error = err
    local signalled = send_term()
    if done then return true end
    if not signalled and require_signal then
      terminal_error = nil
      return false
    end
    if not exited then
      kill_timer = vim.defer_fn(function()
        kill_timer = nil
        if not exited and process then pcall(process.kill, process, 9) end
      end, KILL_GRACE_MS)
    end
    return true
  end

  local handle = {}
  function handle.cancel()
    if delivered then return false end
    if done then
      pending_err = failure('cancelled', ('ADB %s was cancelled.'):format(operation), { operation = operation })
      pending_result = nil
      return true
    end
    return terminate(failure('cancelled', ('ADB %s was cancelled.'):format(operation), { operation = operation }), true)
  end

  local adb, tool_err = self:_resolve_tool()
  if not adb then
    finish(tool_err)
    return handle
  end

  local argv = { adb }
  for _, argument in ipairs(args) do
    argv[#argv + 1] = argument
  end

  local function consume(stream, err, data)
    if done or terminal_error then return end
    if err then
      terminate(failure('stream_error', ('Failed reading ADB %s.'):format(stream), { operation = operation, error = tostring(err) }))
      return
    end
    if not data or data == '' then return end

    local chunks = stream == 'stdout' and stdout_chunks or stderr_chunks
    local bytes = stream == 'stdout' and stdout_bytes or stderr_bytes
    local limit = stream == 'stdout' and MAX_STDOUT_BYTES or MAX_STDERR_BYTES
    bytes = bytes + #data
    if stream == 'stdout' then
      stdout_bytes = bytes
    else
      stderr_bytes = bytes
    end
    if bytes > limit then
      terminate(failure('output_limit', ('ADB %s exceeded the output limit.'):format(stream), { operation = operation }))
      return
    end
    chunks[#chunks + 1] = data
  end

  local ok, spawned = pcall(self.system, argv, {
    text = true,
    stdout = function(err, data) consume('stdout', err, data) end,
    stderr = function(err, data) consume('stderr', err, data) end,
  }, function(completed)
    exited = true
    close_timer(kill_timer)
    kill_timer = nil
    if done then return end
    if terminal_error then
      finish(terminal_error)
      return
    end

    if type(completed) ~= 'table' or type(completed.code) ~= 'number' then
      finish(failure('invalid_process_result', ('ADB %s returned an invalid completion result.'):format(operation), { operation = operation }))
      return
    end
    if completed.signal ~= nil and type(completed.signal) ~= 'number' then
      finish(failure('invalid_process_result', ('ADB %s returned an invalid completion signal.'):format(operation), { operation = operation }))
      return
    end
    if completed.code ~= 0 or (completed.signal ~= nil and completed.signal ~= 0) then
      finish(failure('adb_failed', ('ADB %s failed.'):format(operation), {
        operation = operation,
        exit_code = completed.code,
        signal = completed.signal,
        stdout = excerpt(table.concat(stdout_chunks)),
        stderr = excerpt(table.concat(stderr_chunks)),
      }))
      return
    end

    local stdout, stderr = table.concat(stdout_chunks), table.concat(stderr_chunks)
    local parse_ok, result, parse_err = pcall(parser, stdout, stderr, context)
    if not parse_ok then
      finish(failure('invalid_adb_output', ('Could not parse ADB %s output.'):format(operation), { error = tostring(result) }))
      return
    end
    if result == nil then
      finish(parse_err or failure('invalid_adb_output', ('Could not parse ADB %s output.'):format(operation)))
      return
    end
    finish(nil, result)
  end)

  if not ok or type(spawned) ~= 'table' or type(spawned.kill) ~= 'function' then
    finish(failure('spawn_failed', 'Could not start adb.', { operation = operation, error = tostring(spawned) }))
    return handle
  end
  process = spawned
  if terminal_error then send_term() end

  if not done then
    timeout_timer = vim.defer_fn(function()
      timeout_timer = nil
      terminate(failure('timeout', ('ADB %s timed out after %d ms.'):format(operation, self.timeout_ms), { operation = operation }))
    end, self.timeout_ms)
  end

  return handle
end

function Adb:list_devices(callback) return self:_run('device listing', { 'devices', '-l' }, parse_devices, {}, callback) end

function Adb:resolve_avd_name(serial, callback)
  assert(type(callback) == 'function', 'android_workbench.android.adb: callback is required')
  local valid, serial_err = validate_serial(serial)
  if not valid then return deferred(callback, serial_err) end
  if not serial:match '^emulator%-%d+$' then
    return deferred(callback, failure('invalid_emulator_serial', 'Android emulator serial must use the emulator console-port form.', { serial = serial }))
  end
  return self:_run('AVD name query', { '-s', serial, 'emu', 'avd', 'name' }, parse_avd_name, { serial = serial }, callback)
end

function Adb:boot_completed(serial, callback)
  assert(type(callback) == 'function', 'android_workbench.android.adb: callback is required')
  local valid, serial_err = validate_serial(serial)
  if not valid then return deferred(callback, serial_err) end
  return self:_run('boot-completion query', { '-s', serial, 'shell', 'getprop', 'sys.boot_completed' }, parse_boot_completed, { serial = serial }, callback)
end

function Adb:kill_emulator(serial, callback)
  assert(type(callback) == 'function', 'android_workbench.android.adb: callback is required')
  local valid, serial_err = validate_serial(serial)
  if not valid then return deferred(callback, serial_err) end
  if not serial:match '^emulator%-%d+$' then
    return deferred(callback, failure('invalid_emulator_serial', 'Android emulator serial must use the emulator console-port form.', { serial = serial }))
  end
  return self:_run('emulator stop', { '-s', serial, 'emu', 'kill' }, parse_emulator_kill, { serial = serial }, callback)
end

function Adb:validate_serial(serial, callback)
  assert(type(callback) == 'function', 'android_workbench.android.adb: callback is required')
  local valid, serial_err = validate_serial(serial)
  if not valid then return deferred(callback, serial_err) end

  local operation = {
    child = nil,
    done = false,
    cancelling = false,
    generation = 0,
  }

  local function finish(err, device)
    if operation.done then return false end
    operation.done = true
    operation.generation = operation.generation + 1
    operation.child = nil
    callback(err, device)
    return true
  end

  local function start_child(starter, on_terminal)
    operation.generation = operation.generation + 1
    local token = operation.generation
    operation.child = nil

    local function terminal(...)
      if operation.done or operation.generation ~= token then return end
      operation.generation = operation.generation + 1
      operation.child = nil
      if operation.cancelling then
        local err = select(1, ...)
        if err ~= nil and not (type(err) == 'table' and err.code == 'cancelled') then
          finish(type(err) == 'table' and err or failure('operation_failed', 'ADB device validation failed while cancelling.', { error = tostring(err) }))
        else
          finish(failure('cancelled', 'ADB device validation was cancelled.', { operation = 'device validation' }))
        end
        return
      end
      on_terminal(...)
    end

    local started, handle = pcall(starter, terminal)
    if not started then
      if operation.generation == token then
        operation.generation = operation.generation + 1
        finish(failure('adapter_failed', 'Could not start ADB device validation.', { error = tostring(handle) }))
      end
      return
    end
    if operation.done or operation.generation ~= token then
      if type(handle) == 'table' and type(handle.cancel) == 'function' then pcall(handle.cancel, handle) end
      return
    end
    if type(handle) ~= 'table' or type(handle.cancel) ~= 'function' then
      operation.generation = operation.generation + 1
      finish(failure('invalid_operation_handle', 'ADB device validation returned an invalid operation handle.'))
      return
    end
    operation.child = handle
  end

  function operation.cancel()
    if operation.done or operation.cancelling then return false end
    operation.cancelling = true
    local child = operation.child
    if not child then return finish(failure('cancelled', 'ADB device validation was cancelled.', { operation = 'device validation' })) end
    local called, accepted = pcall(child.cancel, child)
    if operation.done then return true end
    if not called or accepted == false then
      operation.cancelling = false
      return false
    end
    return true
  end

  start_child(function(done) return self:list_devices(done) end, function(err, devices)
    if err then
      finish(err)
      return
    end
    for _, device in ipairs(devices) do
      if device.serial == serial then
        if device.state ~= 'online' then
          finish(failure('device_not_ready', ('Android device %s is %s.'):format(serial, device.state), { device = device }))
          return
        end
        if not serial:match '^emulator%-%d+$' then
          finish(nil, device)
          return
        end

        start_child(function(done) return self:resolve_avd_name(serial, done) end, function(name_err, avd_name)
          if name_err then
            finish(name_err)
            return
          end
          device.avd_name = avd_name
          finish(nil, device)
        end)
        return
      end
    end
    finish(failure('device_not_found', ('Android device %s is not connected.'):format(serial), { serial = serial }))
  end)
  return operation
end

function Adb:resolve_launch_components(serial, application_id, callback)
  assert(type(callback) == 'function', 'android_workbench.android.adb: callback is required')
  local valid_serial, serial_err = validate_serial(serial)
  if not valid_serial then return deferred(callback, serial_err) end
  local valid_application_id, application_err = validate_application_id(application_id)
  if not valid_application_id then return deferred(callback, application_err) end

  return self:_run('launch-activity query', {
    '-s',
    serial,
    'shell',
    'cmd',
    'package',
    'query-activities',
    '--brief',
    '--components',
    '--user',
    'current',
    '-a',
    'android.intent.action.MAIN',
    '-c',
    'android.intent.category.LAUNCHER',
    '-p',
    shell_quote(application_id),
  }, parse_components, { serial = serial, application_id = application_id }, callback)
end

function Adb:launch(serial, application_id, component, callback)
  assert(type(callback) == 'function', 'android_workbench.android.adb: callback is required')
  local valid_serial, serial_err = validate_serial(serial)
  if not valid_serial then return deferred(callback, serial_err) end
  local valid_application_id, application_err = validate_application_id(application_id)
  if not valid_application_id then return deferred(callback, application_err) end
  local valid_component, component_err = component_parts(application_id, component)
  if not valid_component then return deferred(callback, component_err) end

  return self:_run(
    'application launch',
    {
      '-s',
      serial,
      'shell',
      'am',
      'start',
      '--user',
      'current',
      '-W',
      '-n',
      shell_quote(component),
    },
    parse_launch,
    {
      serial = serial,
      application_id = application_id,
      component = component,
    },
    callback
  )
end

function Adb:stop(serial, application_id, callback)
  assert(type(callback) == 'function', 'android_workbench.android.adb: callback is required')
  local valid_serial, serial_err = validate_serial(serial)
  if not valid_serial then return deferred(callback, serial_err) end
  local valid_application_id, application_err = validate_application_id(application_id)
  if not valid_application_id then return deferred(callback, application_err) end

  return self:_run('application stop', {
    '-s',
    serial,
    'shell',
    'am',
    'force-stop',
    '--user',
    'current',
    shell_quote(application_id),
  }, parse_stop, { serial = serial, application_id = application_id }, callback)
end

---@param opts? { adb?: string, resolve_adb?: function, system?: function, timeout_ms?: integer }
---@return AndroidWorkbenchAdbService
function M.new(opts)
  opts = opts or {}
  if type(opts) ~= 'table' then error('android_workbench.android.adb.new: options must be a table', 2) end
  if opts.adb ~= nil and opts.resolve_adb ~= nil then error('android_workbench.android.adb.new: adb and resolve_adb are mutually exclusive', 2) end
  if opts.adb ~= nil and (type(opts.adb) ~= 'string' or opts.adb == '' or opts.adb:find('\0', 1, true)) then
    error('android_workbench.android.adb.new: adb must be a non-empty string without NUL bytes', 2)
  end
  if opts.resolve_adb ~= nil and type(opts.resolve_adb) ~= 'function' then error('android_workbench.android.adb.new: resolve_adb must be a function', 2) end
  if opts.system ~= nil and type(opts.system) ~= 'function' then error('android_workbench.android.adb.new: system must be a function', 2) end
  if opts.timeout_ms ~= nil and not valid_timeout(opts.timeout_ms) then error('android_workbench.android.adb.new: timeout_ms must be a positive integer', 2) end

  local resolve_adb = opts.resolve_adb or default_adb
  if opts.adb then
    local configured = opts.adb
    resolve_adb = function() return configured end
  end

  return setmetatable({
    resolve_adb = resolve_adb,
    system = opts.system or vim.system,
    timeout_ms = opts.timeout_ms or DEFAULT_TIMEOUT_MS,
  }, Adb)
end

return M

-- vim: ts=2 sts=2 sw=2 et
