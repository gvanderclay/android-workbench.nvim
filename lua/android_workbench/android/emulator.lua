local Adb = require 'android_workbench.android.adb'

local M = {}

local Emulator = {}
Emulator.__index = Emulator

local DEFAULT_LIST_TIMEOUT_MS = 30000
local DEFAULT_BOOT_TIMEOUT_MS = 180000
local DEFAULT_STOP_TIMEOUT_MS = 30000
local DEFAULT_POLL_INTERVAL_MS = 500
local DEFAULT_KILL_GRACE_MS = 1000
local MAX_AVDS = 1024
local MAX_EMULATORS = 128
local MAX_AVD_NAME_BYTES = 1024
local MAX_STDOUT_BYTES = 256 * 1024
local MAX_STDERR_BYTES = 64 * 1024

local function failure(code, message, details)
  return {
    code = code,
    message = message,
    details = details,
  }
end

local function valid_positive_integer(value) return type(value) == 'number' and value == value and value > 0 and value <= 2147483647 and value % 1 == 0 end

local function valid_avd_name(avd_name)
  if type(avd_name) ~= 'string' or avd_name == '' or #avd_name > MAX_AVD_NAME_BYTES or avd_name:find '[%s%c]' then
    return nil, failure('invalid_avd_name', 'Android AVD name must be a non-empty string without whitespace or control characters.')
  end
  return avd_name
end

local function valid_serial(serial) return type(serial) == 'string' and serial:match '^emulator%-%d+$' ~= nil and #serial <= 1024 end

local function valid_device_serial(serial) return type(serial) == 'string' and serial ~= '' and #serial <= 1024 and serial:find '%c' == nil end

local function valid_optional_string(value, max_bytes, allow_empty)
  return value == nil or (type(value) == 'string' and (allow_empty or value ~= '') and #value <= max_bytes and value:find '[%c]' == nil)
end

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

local function close_timer(timer)
  if not timer then return end
  pcall(timer.stop, timer)
  local ok, closing = pcall(timer.is_closing, timer)
  if not ok or not closing then pcall(timer.close, timer) end
end

local function close_process(process)
  if process and type(process.close) == 'function' then pcall(process.close, process) end
end

local function safe_schedule(service, callback)
  local invoked = false
  local function once()
    if invoked then return end
    invoked = true
    callback()
  end
  local ok = pcall(service.schedule, once)
  if not ok and not invoked then once() end
end

local function default_emulator()
  local path = vim.fn.exepath 'emulator'
  if path == '' then return nil, failure('emulator_not_found', 'Could not find the Android emulator executable on PATH.') end
  return path
end

local function default_spawn(argv, _, on_exit)
  local uv = vim.uv or vim.loop
  local process
  local closed = false
  local handle, pid_or_error, error_name = uv.spawn(argv[1], {
    args = vim.list_slice(argv, 2),
    detached = true,
    hide = true,
    stdio = { nil, nil, nil },
  }, function(code, signal)
    on_exit { code = code, signal = signal }
    if process then process:close() end
  end)
  if not handle then
    return nil,
      failure('emulator_spawn_failed', 'Could not start the Android emulator.', {
        error = tostring(pid_or_error),
        error_name = error_name,
      })
  end

  process = {}

  function process.kill(_, signal)
    if closed then return false end
    local ok, result = pcall(handle.kill, handle, signal)
    return ok and result ~= false
  end

  function process.close()
    if closed then return false end
    closed = true
    local ok, closing = pcall(handle.is_closing, handle)
    if not ok or not closing then pcall(handle.close, handle) end
    return true
  end

  pcall(handle.unref, handle)
  return process
end

local function parse_avds(stdout)
  local avds = {}
  local seen = {}
  for _, line in ipairs(lines(stdout)) do
    if line ~= '' then
      if #avds >= MAX_AVDS then return nil, failure('invalid_avd_list', 'Android emulator returned too many AVDs.') end
      local avd_name, name_err = valid_avd_name(line)
      if not avd_name then
        return nil,
          failure('invalid_avd_list', 'Android emulator returned an invalid AVD name.', {
            entry = excerpt(line),
            reason = name_err.message,
          })
      end
      if seen[avd_name] then return nil, failure('invalid_avd_list', 'Android emulator returned the same AVD more than once.', { avd_name = avd_name }) end
      seen[avd_name] = true
      avds[#avds + 1] = {
        avd_name = avd_name,
        label = avd_name,
      }
    end
  end
  table.sort(avds, function(left, right) return left.avd_name < right.avd_name end)
  return avds
end

local function deferred(service, callback, err, value)
  local claimed = false
  local handle = {}

  safe_schedule(service, function()
    if claimed then return end
    claimed = true
    callback(err, value)
  end)

  function handle.cancel()
    if claimed then return false end
    claimed = true
    safe_schedule(service, function() callback(failure('cancelled', 'Android emulator operation was cancelled.')) end)
    return true
  end

  return handle
end

function Emulator:_resolve_tool()
  local ok, path, resolve_err = pcall(self.resolve_emulator)
  if not ok then return nil, failure('emulator_not_found', 'Could not resolve the Android emulator executable.', { error = tostring(path) }) end
  if type(path) ~= 'string' or path == '' or path:find('\0', 1, true) then
    if type(resolve_err) == 'table' and resolve_err.code then return nil, resolve_err end
    return nil,
      failure('emulator_not_found', 'Could not find the Android emulator executable on PATH.', resolve_err and { error = tostring(resolve_err) } or nil)
  end
  return path
end

function Emulator:_run_avd_list(callback)
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
    safe_schedule(self, function()
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
      kill_timer = self.defer_fn(function()
        kill_timer = nil
        if not exited and process then pcall(process.kill, process, 9) end
      end, self.kill_grace_ms)
    end
    return true
  end

  local handle = {}
  function handle.cancel()
    if delivered then return false end
    if done then
      pending_err = failure('cancelled', 'Android AVD discovery was cancelled.')
      pending_result = nil
      return true
    end
    return terminate(failure('cancelled', 'Android AVD discovery was cancelled.'), true)
  end

  local emulator, tool_err = self:_resolve_tool()
  if not emulator then
    finish(tool_err)
    return handle
  end

  local function consume(stream, err, data)
    if done or terminal_error then return end
    if err then
      terminate(failure('stream_error', ('Failed reading Android emulator %s.'):format(stream), { error = tostring(err) }))
      return
    end
    if data == nil or data == '' then return end
    if type(data) ~= 'string' then
      terminate(failure('invalid_process_output', ('Android emulator returned invalid %s.'):format(stream)))
      return
    end

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
      terminate(failure('output_limit', ('Android emulator %s exceeded the output limit.'):format(stream)))
      return
    end
    chunks[#chunks + 1] = data
  end

  local ok, spawned = pcall(self.system, { emulator, '-list-avds' }, {
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
    if type(completed) ~= 'table' or type(completed.code) ~= 'number' or (completed.signal ~= nil and type(completed.signal) ~= 'number') then
      finish(failure('invalid_process_result', 'Android emulator returned an invalid AVD-list completion result.'))
      return
    end
    if completed.code ~= 0 or (completed.signal ~= nil and completed.signal ~= 0) then
      finish(failure('avd_list_failed', 'Could not list Android AVDs.', {
        exit_code = completed.code,
        signal = completed.signal,
        stdout = excerpt(table.concat(stdout_chunks)),
        stderr = excerpt(table.concat(stderr_chunks)),
      }))
      return
    end

    local parsed, parse_err = parse_avds(table.concat(stdout_chunks))
    if not parsed then
      finish(parse_err)
      return
    end
    finish(nil, parsed)
  end)

  if not ok or type(spawned) ~= 'table' or type(spawned.kill) ~= 'function' then
    finish(failure('emulator_spawn_failed', 'Could not run Android AVD discovery.', { error = tostring(spawned) }))
    return handle
  end
  process = spawned
  if terminal_error then send_term() end

  if not done then
    timeout_timer = self.defer_fn(function()
      timeout_timer = nil
      terminate(failure('avd_list_timeout', ('Android AVD discovery timed out after %d ms.'):format(self.list_timeout_ms)))
    end, self.list_timeout_ms)
  end
  return handle
end

function Emulator:list_avds(callback)
  assert(type(callback) == 'function', 'android_workbench.android.emulator: callback is required')
  return self:_run_avd_list(callback)
end

local function adb_capability(service, methods)
  if type(service.adb) ~= 'table' then
    return nil, failure('unsupported_adb_service', 'The configured ADB service does not support emulator lifecycle operations.')
  end
  local missing = {}
  for _, method in ipairs(methods) do
    if type(service.adb[method]) ~= 'function' then missing[#missing + 1] = method end
  end
  if #missing > 0 then
    return nil,
      failure('unsupported_adb_service', 'The configured ADB service does not support emulator lifecycle operations.', {
        missing_methods = missing,
      })
  end
  return true
end

local function finish_operation(operation, err, value)
  if operation.done then return false end
  operation.done = true
  operation.generation = operation.generation + 1
  close_timer(operation.deadline_timer)
  close_timer(operation.poll_timer)
  close_timer(operation.kill_timer)
  operation.deadline_timer = nil
  operation.poll_timer = nil
  operation.kill_timer = nil
  operation.child = nil
  operation.pending_err = err
  operation.pending_value = value
  if operation.on_finish then operation.on_finish(operation) end
  safe_schedule(operation.service, function()
    if operation.delivered then return end
    operation.delivered = true
    operation.callback(operation.pending_err, operation.pending_value)
  end)
  return true
end

local function release_process(operation)
  if not operation.process then return end
  close_process(operation.process)
  operation.process = nil
end

local function cancel_current(operation)
  operation.generation = operation.generation + 1
  close_timer(operation.poll_timer)
  operation.poll_timer = nil
  local child = operation.child
  operation.child = nil
  if child and type(child.cancel) == 'function' then pcall(child.cancel, child) end
end

local function termination_failure(operation, reason)
  return failure('emulator_termination_failed', 'Could not terminate the Android emulator process started by this operation.', {
    avd_name = operation.avd_name,
    reason = reason,
  })
end

local function arm_kill_timer(operation)
  local fired = false
  local ok, timer = pcall(operation.service.defer_fn, function()
    fired = true
    operation.kill_timer = nil
    if operation.done or operation.process_exited or not operation.process then return end
    local kill_ok, killed = pcall(operation.process.kill, operation.process, 9)
    if not kill_ok or killed == false then
      local failed = termination_failure(operation, tostring(not kill_ok and killed or 'SIGKILL refused'))
      release_process(operation)
      finish_operation(operation, failed)
    end
  end, operation.service.kill_grace_ms)
  if operation.done or operation.process_exited or fired then
    close_timer(timer)
    return true
  end
  if not ok or timer == nil then
    release_process(operation)
    finish_operation(operation, termination_failure(operation, tostring(timer or 'invalid kill timer')))
    return false
  end
  operation.kill_timer = timer
  return true
end

local function complete_intent(operation)
  if operation.done or not operation.intent then return end
  if not operation.process or operation.process_exited then
    release_process(operation)
    finish_operation(operation, operation.intent)
    return
  end
  if operation.term_sent then return end
  operation.term_sent = true
  local called, accepted = pcall(operation.process.kill, operation.process, 15)
  if not called or accepted == false then
    release_process(operation)
    finish_operation(operation, termination_failure(operation, tostring(not called and accepted or 'signal refused')))
    return
  end
  if operation.done or operation.process_exited then return end
  arm_kill_timer(operation)
end

local function fail_operation(operation, err)
  if operation.done then return end
  operation.intent = err
  cancel_current(operation)
  complete_intent(operation)
end

local function start_child(operation, description, starter, on_terminal)
  if operation.done or operation.intent then return end
  operation.generation = operation.generation + 1
  local token = operation.generation
  operation.child = nil

  local function terminal(err, value)
    if operation.done or operation.generation ~= token then return end
    operation.generation = operation.generation + 1
    operation.child = nil
    if operation.intent then
      complete_intent(operation)
      return
    end
    on_terminal(err, value)
  end

  local started, handle = pcall(starter, terminal)
  if operation.done or operation.generation ~= token then
    if type(handle) == 'table' and type(handle.cancel) == 'function' then pcall(handle.cancel, handle) end
    return
  end
  if not started then
    operation.generation = operation.generation + 1
    fail_operation(operation, failure('adb_adapter_failed', ('Could not start %s.'):format(description), { error = tostring(handle) }))
    return
  end
  if type(handle) ~= 'table' or type(handle.cancel) ~= 'function' then
    operation.generation = operation.generation + 1
    fail_operation(operation, failure('invalid_operation_handle', ('ADB %s returned an invalid operation handle.'):format(description)))
    return
  end
  operation.child = handle
end

local function start_poll(operation, callback)
  if operation.done or operation.intent then return end
  operation.generation = operation.generation + 1
  local token = operation.generation
  operation.poll_timer = nil
  local fired = false
  local ok, timer = pcall(operation.service.defer_fn, function()
    fired = true
    if operation.done or operation.generation ~= token then return end
    operation.generation = operation.generation + 1
    operation.poll_timer = nil
    callback()
  end, operation.service.poll_interval_ms)
  if not ok then
    if operation.generation == token then
      operation.generation = operation.generation + 1
      fail_operation(operation, failure('timer_failed', 'Could not schedule Android emulator polling.', { error = tostring(timer) }))
    end
    return
  end
  if operation.done or operation.generation ~= token or fired then
    close_timer(timer)
    return
  end
  if timer == nil then
    operation.generation = operation.generation + 1
    fail_operation(operation, failure('invalid_timer_handle', 'Android emulator polling returned an invalid timer handle.'))
    return
  end
  operation.poll_timer = timer
end

local function new_operation(service, kind, timeout_ms, callback)
  local operation = {
    callback = callback,
    child = nil,
    delivered = false,
    done = false,
    generation = 0,
    intent = nil,
    process = nil,
    process_exited = false,
    service = service,
    term_sent = false,
  }

  function operation.cancel()
    local cancelled = failure('cancelled', ('Android emulator %s was cancelled.'):format(kind), { operation = kind })
    if operation.done then
      if operation.delivered or operation.pending_err ~= nil then return false end
      operation.pending_err = cancelled
      operation.pending_value = nil
      return true
    end
    if operation.intent then return false end
    local child = operation.child
    if child then
      operation.intent = cancelled
      local called, accepted = pcall(child.cancel, child)
      if operation.done or operation.child ~= child then return true end
      if not called or accepted == false then
        operation.intent = nil
        return false
      end
      return true
    end

    if operation.process and not operation.process_exited then
      operation.intent = cancelled
      local called, accepted = pcall(operation.process.kill, operation.process, 15)
      if operation.done or operation.process_exited then return true end
      if not called or accepted == false then
        operation.intent = nil
        return false
      end
      operation.term_sent = true
      close_timer(operation.poll_timer)
      operation.poll_timer = nil
      arm_kill_timer(operation)
      return true
    end

    operation.intent = cancelled
    cancel_current(operation)
    finish_operation(operation, cancelled)
    return true
  end

  local ok, timer = pcall(service.defer_fn, function()
    if operation.done then return end
    operation.intent = failure(
      kind == 'start' and 'boot_timeout' or 'stop_timeout',
      ('Android emulator %s timed out after %d ms.'):format(kind, timeout_ms),
      { operation = kind, timeout_ms = timeout_ms }
    )
    cancel_current(operation)
    complete_intent(operation)
  end, timeout_ms)
  if not ok or timer == nil then
    finish_operation(operation, failure('timer_failed', ('Could not schedule Android emulator %s deadline.'):format(kind), { error = tostring(timer) }))
  elseif not operation.done then
    operation.deadline_timer = timer
  else
    close_timer(timer)
  end
  return operation
end

local function validate_device_list(devices)
  if type(devices) ~= 'table' or not vim.islist(devices) then return nil, failure('invalid_device_list', 'ADB returned an invalid device list.') end
  local emulator_devices = {}
  local seen = {}
  for _, device in ipairs(devices) do
    if type(device) ~= 'table' then return nil, failure('invalid_device_list', 'ADB returned an invalid connected-device entry.') end
    local serial = rawget(device, 'serial')
    local state = rawget(device, 'state')
    local raw_state = rawget(device, 'raw_state')
    local label = rawget(device, 'label')
    local details = rawget(device, 'details')
    if
      not valid_device_serial(serial)
      or type(state) ~= 'string'
      or state == ''
      or #state > 64
      or state:find '[%s%c]'
      or not valid_optional_string(raw_state, 64, false)
      or not valid_optional_string(label, 1024, false)
      or not valid_optional_string(details, 4096, true)
    then
      return nil, failure('invalid_device_list', 'ADB returned an invalid connected-device entry.')
    end
    if seen[serial] then return nil, failure('invalid_device_list', 'ADB returned a duplicate device serial.', { serial = serial }) end
    seen[serial] = true
    if serial:match '^emulator%-%d+$' then
      if #emulator_devices >= MAX_EMULATORS then return nil, failure('invalid_device_list', 'ADB returned too many Android emulators.') end
      emulator_devices[#emulator_devices + 1] = {
        serial = serial,
        state = state,
        raw_state = raw_state,
        label = label,
        details = details,
      }
    end
  end
  return emulator_devices
end

local function validate_ready_device(value, expected_serial, expected_avd_name)
  if type(value) ~= 'table' then return nil end
  local serial = rawget(value, 'serial')
  local avd_name = rawget(value, 'avd_name')
  local state = rawget(value, 'state')
  local raw_state = rawget(value, 'raw_state')
  local label = rawget(value, 'label')
  local details = rawget(value, 'details')
  if
    serial ~= expected_serial
    or not valid_serial(serial)
    or avd_name ~= expected_avd_name
    or not valid_avd_name(avd_name)
    or state ~= 'online'
    or not valid_optional_string(raw_state, 64, false)
    or not valid_optional_string(label, 1024, false)
    or not valid_optional_string(details, 4096, true)
  then
    return nil
  end
  local device = {
    serial = serial,
    avd_name = avd_name,
    state = 'online',
  }
  if raw_state ~= nil then device.raw_state = raw_state end
  if label ~= nil then device.label = label end
  if details ~= nil then device.details = details end
  return device
end

local TRANSIENT_ADB_ERRORS = {
  adb_failed = true,
  avd_name_query_failed = true,
  boot_query_failed = true,
  device_not_found = true,
  device_not_ready = true,
  timeout = true,
}

local function transient_adb_error(err) return type(err) == 'table' and TRANSIENT_ADB_ERRORS[err.code] == true end

function Emulator:_find_instances(operation, avd_name, callback)
  start_child(operation, 'device listing', function(done) return self.adb:list_devices(done) end, function(err, devices)
    if err then
      callback(err)
      return
    end
    local emulator_devices, devices_err = validate_device_list(devices)
    if not emulator_devices then
      callback(devices_err)
      return
    end

    local matches = {}
    local identities = {}
    local unresolved = {}
    local index = 1
    local function advance()
      if operation.done or operation.intent then return end
      local device = emulator_devices[index]
      if not device then
        if #unresolved > 0 then
          callback(failure('emulator_identity_unavailable', 'Could not safely resolve every connected emulator AVD identity.', {
            serials = unresolved,
          }))
          return
        end
        callback(nil, matches, identities)
        return
      end
      index = index + 1
      start_child(operation, 'AVD identity query', function(done) return self.adb:resolve_avd_name(device.serial, done) end, function(name_err, found_name)
        if name_err then
          if transient_adb_error(name_err) then
            unresolved[#unresolved + 1] = device.serial
          else
            callback(name_err)
            return
          end
        else
          local valid_name = valid_avd_name(found_name)
          if not valid_name then
            callback(failure('invalid_adb_result', 'ADB returned an invalid emulator AVD identity.', { serial = device.serial }))
            return
          end
          identities[device.serial] = found_name
          if found_name == avd_name then
            matches[#matches + 1] = {
              serial = device.serial,
              avd_name = found_name,
              state = device.state,
              raw_state = device.raw_state,
              label = device.label or found_name,
              details = device.details,
            }
          end
        end
        safe_schedule(self, advance)
      end)
    end
    advance()
  end)
end

function Emulator:_complete_ready(operation, match, poll)
  start_child(operation, 'boot-completion query', function(done) return self.adb:boot_completed(match.serial, done) end, function(err, completed)
    if err then
      if transient_adb_error(err) then
        start_poll(operation, poll)
      else
        fail_operation(operation, err)
      end
      return
    end
    if type(completed) ~= 'boolean' then
      fail_operation(operation, failure('invalid_adb_result', 'ADB returned an invalid Android boot-completion result.'))
      return
    end
    if not completed then
      start_poll(operation, poll)
      return
    end

    start_child(operation, 'final device validation', function(done) return self.adb:validate_serial(match.serial, done) end, function(validate_err, device)
      if validate_err then
        if transient_adb_error(validate_err) then
          start_poll(operation, poll)
        else
          fail_operation(operation, validate_err)
        end
        return
      end
      local ready_device = validate_ready_device(device, match.serial, operation.avd_name)
      if not ready_device then
        fail_operation(
          operation,
          failure('emulator_identity_changed', 'Android emulator identity changed before boot completed.', {
            expected_serial = match.serial,
            expected_avd_name = operation.avd_name,
            device = device,
          })
        )
        return
      end
      release_process(operation)
      finish_operation(operation, nil, ready_device)
    end)
  end)
end

function Emulator:_spawn_for_start(operation, poll)
  local executable, resolve_err = self:_resolve_tool()
  if not executable then
    fail_operation(operation, resolve_err)
    return
  end
  local argv = { executable, '-avd', operation.avd_name }
  local process_callback_fired = false
  local started, process, spawn_err = pcall(self.spawn, argv, {
    detached = true,
    stdio = 'ignore',
  }, function(completed)
    process_callback_fired = true
    operation.process_exited = true
    release_process(operation)
    if operation.done then return end
    if operation.intent then
      finish_operation(operation, operation.intent)
      return
    end
    cancel_current(operation)
    if type(completed) ~= 'table' or type(completed.code) ~= 'number' or (completed.signal ~= nil and type(completed.signal) ~= 'number') then
      finish_operation(operation, failure('invalid_process_result', 'Android emulator returned an invalid launch completion result.'))
      return
    end
    finish_operation(
      operation,
      failure('emulator_exited', 'Android emulator exited before boot completed.', {
        avd_name = operation.avd_name,
        exit_code = completed.code,
        signal = completed.signal,
      })
    )
  end)
  if operation.done then
    if started and type(process) == 'table' then close_process(process) end
    return
  end
  if not started then
    fail_operation(operation, failure('emulator_spawn_failed', 'Could not start the Android emulator.', { error = tostring(process) }))
    return
  end
  if type(process) ~= 'table' or type(process.kill) ~= 'function' or type(process.close) ~= 'function' then
    fail_operation(
      operation,
      type(spawn_err) == 'table' and spawn_err or failure('invalid_process_handle', 'Android emulator launcher returned an invalid process handle.')
    )
    return
  end
  operation.process = process
  operation.process_exited = process_callback_fired
  if process_callback_fired then
    release_process(operation)
    return
  end
  start_poll(operation, poll)
end

function Emulator:start(avd_name, callback)
  assert(type(callback) == 'function', 'android_workbench.android.emulator: callback is required')
  local valid_name, name_err = valid_avd_name(avd_name)
  if not valid_name then return deferred(self, callback, name_err) end
  local supported, support_err = adb_capability(self, { 'list_devices', 'resolve_avd_name', 'boot_completed', 'validate_serial' })
  if not supported then return deferred(self, callback, support_err) end
  if self.starting[avd_name] then
    return deferred(self, callback, failure('emulator_start_in_progress', ('Android AVD %s is already starting.'):format(avd_name), { avd_name = avd_name }))
  end

  local operation = new_operation(self, 'start', self.boot_timeout_ms, callback)
  operation.avd_name = avd_name
  operation.on_finish = function(current)
    if self.starting[avd_name] == current then self.starting[avd_name] = nil end
  end
  if operation.done then return operation end
  self.starting[avd_name] = operation

  local first_scan = true
  local saw_instance = false
  local poll
  poll = function()
    self:_find_instances(operation, avd_name, function(err, matches)
      if err then
        if transient_adb_error(err) or (type(err) == 'table' and err.code == 'emulator_identity_unavailable') then
          start_poll(operation, poll)
        else
          fail_operation(operation, err)
        end
        return
      end
      if #matches > 1 then
        fail_operation(
          operation,
          failure('duplicate_emulator', ('More than one running emulator uses AVD %s.'):format(avd_name), {
            avd_name = avd_name,
            devices = matches,
          })
        )
        return
      end
      local match = matches[1]
      if match then
        saw_instance = true
        first_scan = false
        if match.state == 'online' then
          self:_complete_ready(operation, match, poll)
        else
          start_poll(operation, poll)
        end
        return
      end
      if first_scan then
        first_scan = false
        self:_spawn_for_start(operation, poll)
      elseif saw_instance and not operation.process then
        fail_operation(operation, failure('emulator_disconnected', ('Android AVD %s disconnected while starting.'):format(avd_name), { avd_name = avd_name }))
      else
        start_poll(operation, poll)
      end
    end)
  end
  poll()
  return operation
end

function Emulator:_poll_stopped(operation, target, kill_err)
  start_child(operation, 'stop verification device listing', function(done) return self.adb:list_devices(done) end, function(err, devices)
    if err then
      fail_operation(operation, err)
      return
    end
    local emulator_devices, devices_err = validate_device_list(devices)
    if not emulator_devices then
      fail_operation(operation, devices_err)
      return
    end
    local present
    for _, device in ipairs(emulator_devices) do
      if device.serial == target.serial then
        present = device
        break
      end
    end
    if not present then
      finish_operation(operation, nil, { avd_name = target.avd_name, serial = target.serial })
      return
    end

    start_child(
      operation,
      'stop verification AVD identity query',
      function(done) return self.adb:resolve_avd_name(target.serial, done) end,
      function(name_err, avd_name)
        if not name_err then
          if valid_avd_name(avd_name) == nil then
            fail_operation(operation, failure('invalid_adb_result', 'ADB returned an invalid emulator AVD identity while stopping.'))
            return
          end
          if avd_name ~= target.avd_name then
            finish_operation(operation, nil, { avd_name = target.avd_name, serial = target.serial })
            return
          end
        elseif not transient_adb_error(name_err) and (type(name_err) ~= 'table' or name_err.code ~= 'invalid_avd_name_output') then
          fail_operation(operation, name_err)
          return
        end
        if kill_err then
          fail_operation(operation, kill_err)
          return
        end
        start_poll(operation, function() self:_poll_stopped(operation, target) end)
      end
    )
  end)
end

function Emulator:stop(request, callback)
  assert(type(callback) == 'function', 'android_workbench.android.emulator: callback is required')
  if type(request) ~= 'table' then return deferred(self, callback, failure('invalid_stop_request', 'Android emulator stop request must be a table.')) end
  local avd_name, name_err = valid_avd_name(request.avd_name)
  if not avd_name then return deferred(self, callback, name_err) end
  if not valid_serial(request.serial) then
    return deferred(self, callback, failure('invalid_emulator_serial', 'Android emulator serial must use the emulator console-port form.'))
  end
  local supported, support_err = adb_capability(self, { 'list_devices', 'resolve_avd_name', 'kill_emulator' })
  if not supported then return deferred(self, callback, support_err) end

  local operation = new_operation(self, 'stop', self.stop_timeout_ms, callback)
  operation.avd_name = avd_name
  if operation.done then return operation end

  self:_find_instances(operation, avd_name, function(err, matches, identities)
    if err then
      fail_operation(operation, err)
      return
    end
    local target
    for _, match in ipairs(matches) do
      if match.serial == request.serial then
        target = match
        break
      end
    end
    if not target and #matches > 0 then
      fail_operation(
        operation,
        failure('emulator_identity_mismatch', 'The selected emulator serial no longer belongs to the remembered AVD.', {
          avd_name = avd_name,
          serial = request.serial,
          devices = matches,
        })
      )
      return
    end
    if not target and identities and identities[request.serial] and identities[request.serial] ~= avd_name then
      fail_operation(
        operation,
        failure('emulator_identity_mismatch', 'The selected emulator serial no longer belongs to the remembered AVD.', {
          avd_name = avd_name,
          serial = request.serial,
          actual_avd_name = identities[request.serial],
        })
      )
      return
    end
    if not target then
      fail_operation(
        operation,
        failure('emulator_not_running', ('Android AVD %s is not running.'):format(avd_name), {
          avd_name = avd_name,
          serial = request.serial,
        })
      )
      return
    end

    start_child(
      operation,
      'final stop identity query',
      function(done) return self.adb:resolve_avd_name(target.serial, done) end,
      function(identity_err, current_name)
        if identity_err then
          fail_operation(operation, identity_err)
          return
        end
        local validated_name = valid_avd_name(current_name)
        if not validated_name then
          fail_operation(operation, failure('invalid_adb_result', 'ADB returned an invalid emulator AVD identity before stopping.'))
          return
        end
        if validated_name ~= target.avd_name then
          fail_operation(
            operation,
            failure('emulator_identity_mismatch', 'The selected emulator serial changed identity before it could be stopped.', {
              expected_avd_name = target.avd_name,
              actual_avd_name = validated_name,
              serial = target.serial,
            })
          )
          return
        end

        start_child(operation, 'targeted emulator stop', function(done) return self.adb:kill_emulator(target.serial, done) end, function(kill_err, killed)
          if not kill_err and (type(killed) ~= 'table' or rawget(killed, 'serial') ~= target.serial) then
            fail_operation(operation, failure('invalid_adb_result', 'ADB returned an invalid targeted emulator-stop result.'))
            return
          end
          self:_poll_stopped(operation, target, kill_err)
        end)
      end
    )
  end)
  return operation
end

---@param opts? { adb?: table, emulator?: string, system?: function, spawn?: function, schedule?: function, defer_fn?: function, list_timeout_ms?: integer, boot_timeout_ms?: integer, stop_timeout_ms?: integer, poll_interval_ms?: integer, kill_grace_ms?: integer }
---@return table
function M.new(opts)
  opts = opts or {}
  if type(opts) ~= 'table' then error('android_workbench.android.emulator.new: options must be a table', 2) end
  if opts.emulator ~= nil and (type(opts.emulator) ~= 'string' or opts.emulator == '' or opts.emulator:find('\0', 1, true)) then
    error('android_workbench.android.emulator.new: emulator must be a non-empty string without NUL bytes', 2)
  end
  for name, value in pairs {
    system = opts.system,
    spawn = opts.spawn,
    schedule = opts.schedule,
    defer_fn = opts.defer_fn,
  } do
    if value ~= nil and type(value) ~= 'function' then error(('android_workbench.android.emulator.new: %s must be a function'):format(name), 2) end
  end
  for name, value in pairs {
    list_timeout_ms = opts.list_timeout_ms,
    boot_timeout_ms = opts.boot_timeout_ms,
    stop_timeout_ms = opts.stop_timeout_ms,
    poll_interval_ms = opts.poll_interval_ms,
    kill_grace_ms = opts.kill_grace_ms,
  } do
    if value ~= nil and not valid_positive_integer(value) then
      error(('android_workbench.android.emulator.new: %s must be a positive integer'):format(name), 2)
    end
  end

  local resolve_emulator = default_emulator
  if opts.emulator then
    local configured = opts.emulator
    resolve_emulator = function() return configured end
  end

  return setmetatable({
    adb = opts.adb or Adb.new(),
    resolve_emulator = resolve_emulator,
    system = opts.system or vim.system,
    spawn = opts.spawn or default_spawn,
    schedule = opts.schedule or vim.schedule,
    defer_fn = opts.defer_fn or vim.defer_fn,
    list_timeout_ms = opts.list_timeout_ms or DEFAULT_LIST_TIMEOUT_MS,
    boot_timeout_ms = opts.boot_timeout_ms or DEFAULT_BOOT_TIMEOUT_MS,
    stop_timeout_ms = opts.stop_timeout_ms or DEFAULT_STOP_TIMEOUT_MS,
    poll_interval_ms = opts.poll_interval_ms or DEFAULT_POLL_INTERVAL_MS,
    kill_grace_ms = opts.kill_grace_ms or DEFAULT_KILL_GRACE_MS,
    starting = {},
  }, Emulator)
end

return M

-- vim: ts=2 sts=2 sw=2 et
