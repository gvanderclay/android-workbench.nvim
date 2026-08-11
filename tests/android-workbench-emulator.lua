local failures = {}

local function fail(name, message) failures[#failures + 1] = ('%s: %s'):format(name, message) end

local function expect(name, actual, expected)
  if vim.deep_equal(actual, expected) then return end
  fail(name, ('expected %s, got %s'):format(vim.inspect(expected), vim.inspect(actual)))
end

local function expect_true(name, value)
  if value then return end
  fail(name, 'expected a truthy value')
end

local Emulator = require 'android_workbench.android.emulator'

local function completed(callback, err, value)
  callback(err, value)
  return { cancel = function() return false end }
end

local function device(serial, avd_name, state)
  return {
    serial = serial,
    avd_name = avd_name,
    state = state or 'online',
    raw_state = (state == nil or state == 'online') and 'device' or state,
    label = avd_name,
  }
end

local function fake_process(on_exit, opts)
  opts = opts or {}
  local process = {
    close_count = 0,
    kills = {},
  }
  function process:kill(signal)
    self.kills[#self.kills + 1] = signal
    if opts.kill_result == false then return false end
    if opts.exit_on_kill then on_exit { code = 0, signal = signal } end
    return true
  end
  function process:close()
    self.close_count = self.close_count + 1
    return true
  end
  process.exit = on_exit
  return process
end

local function immediate_schedule(callback) callback() end

local ok, unexpected = xpcall(function()
  do
    local invocations = {}
    local service = Emulator.new {
      emulator = '/fake/emulator',
      schedule = immediate_schedule,
      system = function(argv, opts, on_exit)
        invocations[#invocations + 1] = { argv = vim.deepcopy(argv), opts = opts }
        opts.stdout(nil, 'Zulu_API_35\r\nAlpha_API_24\r\n')
        on_exit { code = 0, signal = 0 }
        return { kill = function() return true end }
      end,
    }
    local result
    local handle = service:list_avds(function(err, value) result = { err = err, value = value } end)
    expect('AVD list succeeds', result.err, nil)
    expect('AVD list is normalized and sorted', result.value, {
      { avd_name = 'Alpha_API_24', label = 'Alpha_API_24' },
      { avd_name = 'Zulu_API_35', label = 'Zulu_API_35' },
    })
    expect('AVD list uses classic direct argv', invocations[1].argv, { '/fake/emulator', '-list-avds' })
    expect('AVD list requests text streams', invocations[1].opts.text, true)
    expect('completed AVD list cannot be cancelled', handle:cancel(), false)
  end

  for _, case in ipairs {
    { name = 'duplicate AVD', output = 'Pixel_API_35\nPixel_API_35\n', code = 'invalid_avd_list' },
    { name = 'whitespace-padded AVD', output = ' Pixel_API_35\n', code = 'invalid_avd_list' },
    { name = 'whitespace-bearing AVD', output = 'Pixel API 35\n', code = 'invalid_avd_list' },
    { name = 'control-bearing AVD', output = 'Pixel\tAPI\n', code = 'invalid_avd_list' },
  } do
    local result
    Emulator.new({
      emulator = '/fake/emulator',
      schedule = immediate_schedule,
      system = function(_, opts, on_exit)
        opts.stdout(nil, case.output)
        on_exit { code = 0, signal = 0 }
        return { kill = function() return true end }
      end,
    }):list_avds(function(err, value) result = { err = err, value = value } end)
    expect(case.name .. ' is rejected', result.err and result.err.code, case.code)
  end

  do
    local pending
    local result
    local callback_count = 0
    local service = Emulator.new {
      emulator = '/fake/emulator',
      schedule = immediate_schedule,
      system = function(_, _, on_exit)
        pending = fake_process(on_exit)
        return pending
      end,
    }
    local handle = service:list_avds(function(err, value)
      callback_count = callback_count + 1
      result = { err = err, value = value }
    end)
    expect('AVD list cancellation is accepted', handle:cancel(), true)
    expect('AVD list cancellation waits for process exit', result, nil)
    expect('AVD list cancellation targets its process', pending.kills, { 15 })
    pending.exit { code = 143, signal = 15 }
    expect('AVD list cancellation is classified', result.err.code, 'cancelled')
    pending.exit { code = 143, signal = 15 }
    expect('AVD list callback is exactly once', callback_count, 1)
  end

  do
    local result
    local legacy_adb = {
      list_devices = function(_, callback) return completed(callback, nil, {}) end,
    }
    local service = Emulator.new { adb = legacy_adb, emulator = '/fake/emulator', schedule = immediate_schedule }
    local constructed = service ~= nil
    service:start('Pixel_API_35', function(err, value) result = { err = err, value = value } end)
    expect_true('legacy custom ADB remains constructible', constructed)
    expect('legacy custom ADB rejects only lifecycle use', result.err.code, 'unsupported_adb_service')
  end

  do
    local spawn_count = 0
    local adb = {}
    function adb:list_devices(callback)
      return completed(callback, nil, {
        { serial = 'adb-example (2)._adb-tls-connect._tcp', state = 'online', label = 'CPH2583' },
        device('emulator-5554', 'Pixel_API_35'),
      })
    end
    function adb:resolve_avd_name(_, callback) return completed(callback, nil, 'Pixel_API_35') end
    function adb:boot_completed(_, callback) return completed(callback, nil, true) end
    function adb:validate_serial(_, callback)
      local value = device('emulator-5554', 'Pixel_API_35')
      value.provider_object = { should = 'not leak' }
      return completed(callback, nil, value)
    end
    local service = Emulator.new {
      adb = adb,
      emulator = '/fake/emulator',
      schedule = immediate_schedule,
      spawn = function()
        spawn_count = spawn_count + 1
        error 'already-running AVD must not launch'
      end,
    }
    local result
    local callback_count = 0
    local handle = service:start('Pixel_API_35', function(err, value)
      callback_count = callback_count + 1
      result = { err = err, value = value }
    end)
    expect('already-running ready AVD is adopted', result.err, nil)
    expect('wireless physical serial does not block emulator discovery', result.value and result.value.serial, 'emulator-5554')
    expect('adopted AVD returns exact connected DTO', result.value, device('emulator-5554', 'Pixel_API_35'))
    expect('adoption never launches another emulator', spawn_count, 0)
    expect('adoption callback is exactly once', callback_count, 1)
    expect('completed adoption cannot be cancelled', handle:cancel(), false)
  end

  do
    local adb = {}
    function adb:list_devices(callback)
      return completed(callback, nil, {
        { serial = 'emulator-5554', state = 'online', label = {} },
      })
    end
    function adb:resolve_avd_name() error 'malformed device must fail before identity query' end
    function adb:boot_completed() error 'not reached' end
    function adb:validate_serial() error 'not reached' end
    local result
    Emulator.new({ adb = adb, emulator = '/fake/emulator', schedule = immediate_schedule })
      :start('Pixel_API_35', function(err, value) result = { err = err, value = value } end)
    expect('malformed custom ADB device row is contained', result.err.code, 'invalid_device_list')
  end

  do
    local scheduled = {}
    local adb = {}
    function adb:list_devices(callback) return completed(callback, nil, { device('emulator-5554', 'Pixel_API_35') }) end
    function adb:resolve_avd_name(_, callback) return completed(callback, nil, 'Pixel_API_35') end
    function adb:boot_completed(_, callback) return completed(callback, nil, true) end
    function adb:validate_serial(_, callback) return completed(callback, nil, device('emulator-5554', 'Pixel_API_35')) end
    local service = Emulator.new {
      adb = adb,
      emulator = '/fake/emulator',
      schedule = function(callback) scheduled[#scheduled + 1] = callback end,
    }
    local result
    local handle = service:start('Pixel_API_35', function(err, value) result = { err = err, value = value } end)
    table.remove(scheduled, 1)()
    expect('ready result remains queued before delivery', result, nil)
    expect('queued ready result can become cancellation', handle:cancel(), true)
    table.remove(scheduled, 1)()
    expect('queued ready result is replaced by cancellation', result.err.code, 'cancelled')
  end

  do
    local lists = {
      {},
      { device('emulator-5556', 'Pixel_API_35') },
    }
    local spawned
    local spawn_argv
    local spawn_opts
    local adb = {}
    function adb:list_devices(callback) return completed(callback, nil, table.remove(lists, 1)) end
    function adb:resolve_avd_name(_, callback) return completed(callback, nil, 'Pixel_API_35') end
    function adb:boot_completed(_, callback) return completed(callback, nil, true) end
    function adb:validate_serial(_, callback) return completed(callback, nil, device('emulator-5556', 'Pixel_API_35')) end
    local service = Emulator.new {
      adb = adb,
      emulator = '/fake/emulator',
      schedule = immediate_schedule,
      boot_timeout_ms = 1000,
      poll_interval_ms = 1,
      spawn = function(argv, opts, on_exit)
        spawn_argv = vim.deepcopy(argv)
        spawn_opts = vim.deepcopy(opts)
        spawned = fake_process(on_exit)
        return spawned
      end,
    }
    local result
    service:start('Pixel_API_35', function(err, value) result = { err = err, value = value } end)
    expect_true('new AVD reaches boot readiness', vim.wait(1000, function() return result ~= nil end, 1))
    expect('new AVD start succeeds', result.err, nil)
    expect('new AVD uses classic direct argv', spawn_argv, { '/fake/emulator', '-avd', 'Pixel_API_35' })
    expect('new AVD process is detached', spawn_opts.detached, true)
    expect('new AVD process ignores unbounded launcher output', spawn_opts.stdio, 'ignore')
    expect('ready AVD releases but does not signal its process', spawned.kills, {})
    expect('ready AVD releases its process handle', spawned.close_count, 1)
  end

  do
    local lists = {
      { device('emulator-5554', 'Pixel_API_35', 'offline') },
      { device('emulator-5554', 'Pixel_API_35') },
    }
    local spawn_count = 0
    local adb = {}
    function adb:list_devices(callback) return completed(callback, nil, table.remove(lists, 1)) end
    function adb:resolve_avd_name(_, callback) return completed(callback, nil, 'Pixel_API_35') end
    function adb:boot_completed(_, callback) return completed(callback, nil, true) end
    function adb:validate_serial(_, callback) return completed(callback, nil, device('emulator-5554', 'Pixel_API_35')) end
    local service = Emulator.new {
      adb = adb,
      emulator = '/fake/emulator',
      schedule = immediate_schedule,
      boot_timeout_ms = 1000,
      poll_interval_ms = 1,
      spawn = function()
        spawn_count = spawn_count + 1
        error 'identifiable booting AVD must be adopted'
      end,
    }
    local result
    service:start('Pixel_API_35', function(err, value) result = { err = err, value = value } end)
    expect_true('identifiable booting AVD completes', vim.wait(1000, function() return result ~= nil end, 1))
    expect('identifiable booting AVD succeeds', result.err, nil)
    expect('identifiable booting AVD is not duplicated', spawn_count, 0)
  end

  do
    local list_count = 0
    local identity_count = 0
    local spawn_count = 0
    local adb = {}
    function adb:list_devices(callback)
      list_count = list_count + 1
      return completed(callback, nil, { device('emulator-5554', 'Pixel_API_35', list_count == 1 and 'offline' or 'online') })
    end
    function adb:resolve_avd_name(_, callback)
      identity_count = identity_count + 1
      if identity_count == 1 then return completed(callback, { code = 'adb_failed', message = 'not ready' }) end
      return completed(callback, nil, 'Pixel_API_35')
    end
    function adb:boot_completed(_, callback) return completed(callback, nil, true) end
    function adb:validate_serial(_, callback) return completed(callback, nil, device('emulator-5554', 'Pixel_API_35')) end
    local service = Emulator.new {
      adb = adb,
      emulator = '/fake/emulator',
      schedule = immediate_schedule,
      boot_timeout_ms = 1000,
      poll_interval_ms = 1,
      spawn = function()
        spawn_count = spawn_count + 1
        error 'unresolved booting AVD must not be duplicated'
      end,
    }
    local result
    service:start('Pixel_API_35', function(err, value) result = { err = err, value = value } end)
    expect_true('temporarily unresolved booting AVD retries', vim.wait(1000, function() return result ~= nil end, 1))
    expect('temporarily unresolved booting AVD succeeds', result.err, nil)
    expect('temporarily unresolved booting AVD is never launched twice', spawn_count, 0)
  end

  do
    local adb = {}
    function adb:list_devices(callback)
      return completed(callback, nil, {
        device('emulator-5554', 'Pixel_API_35'),
        device('emulator-5556', 'Pixel_API_35'),
      })
    end
    function adb:resolve_avd_name(_, callback) return completed(callback, nil, 'Pixel_API_35') end
    function adb:boot_completed(_, callback) return completed(callback, nil, true) end
    function adb:validate_serial(_, callback) return completed(callback, nil, device('emulator-5554', 'Pixel_API_35')) end
    local result
    Emulator.new({ adb = adb, emulator = '/fake/emulator', schedule = immediate_schedule })
      :start('Pixel_API_35', function(err, value) result = { err = err, value = value } end)
    expect('duplicate running AVD is rejected', result.err.code, 'duplicate_emulator')
  end

  do
    local pending_callback
    local pending_cancel_count = 0
    local adb = {}
    function adb:list_devices(callback)
      pending_callback = callback
      return {
        cancel = function()
          pending_cancel_count = pending_cancel_count + 1
          callback { code = 'cancelled', message = 'cancelled' }
          return true
        end,
      }
    end
    function adb:resolve_avd_name() error 'not reached' end
    function adb:boot_completed() error 'not reached' end
    function adb:validate_serial() error 'not reached' end
    local service = Emulator.new { adb = adb, emulator = '/fake/emulator', schedule = immediate_schedule }
    local first
    local second
    local first_handle = service:start('Pixel_API_35', function(err, value) first = { err = err, value = value } end)
    service:start('Pixel_API_35', function(err, value) second = { err = err, value = value } end)
    expect('same-name simultaneous start is rejected', second.err.code, 'emulator_start_in_progress')
    expect('first same-name start remains pending', first, nil)
    expect_true('first same-name start cancellation succeeds', first_handle:cancel())
    expect('first same-name start cancellation is terminal', first.err.code, 'cancelled')
    expect('first same-name start cancels its current child once', pending_cancel_count, 1)
    pending_callback(nil, {})
    expect('late same-name callback is ignored', first.err.code, 'cancelled')
  end

  do
    local spawned
    local adb = {}
    function adb:list_devices(callback) return completed(callback, nil, {}) end
    function adb:resolve_avd_name() error 'not reached' end
    function adb:boot_completed() error 'not reached' end
    function adb:validate_serial() error 'not reached' end
    local service = Emulator.new {
      adb = adb,
      emulator = '/fake/emulator',
      schedule = immediate_schedule,
      boot_timeout_ms = 1000,
      poll_interval_ms = 1000,
      spawn = function(_, _, on_exit)
        spawned = fake_process(on_exit)
        return spawned
      end,
    }
    local result
    local callback_count = 0
    local handle = service:start('Pixel_API_35', function(err, value)
      callback_count = callback_count + 1
      result = { err = err, value = value }
    end)
    expect_true('owned launch cancellation is accepted', handle:cancel())
    expect('owned launch cancellation targets only owned process', spawned.kills, { 15 })
    expect('owned launch cancellation waits for process exit', result, nil)
    spawned.exit { code = 0, signal = 15 }
    expect('owned launch cancellation is classified', result.err.code, 'cancelled')
    spawned.exit { code = 0, signal = 15 }
    expect('owned launch cancellation callback is exactly once', callback_count, 1)
  end

  do
    local spawned
    local adb = {}
    function adb:list_devices(callback) return completed(callback, nil, {}) end
    function adb:resolve_avd_name() error 'not reached' end
    function adb:boot_completed() error 'not reached' end
    function adb:validate_serial() error 'not reached' end
    local service = Emulator.new {
      adb = adb,
      emulator = '/fake/emulator',
      schedule = immediate_schedule,
      boot_timeout_ms = 1000,
      poll_interval_ms = 1000,
      spawn = function(_, _, on_exit)
        spawned = fake_process(on_exit, { kill_result = false })
        return spawned
      end,
    }
    local result
    local handle = service:start('Pixel_API_35', function(err, value) result = { err = err, value = value } end)
    expect('owned launch cancellation refusal is observable', handle:cancel(), false)
    expect('refused cancellation keeps operation pending', result, nil)
    spawned.exit { code = 2, signal = 0 }
    expect('natural exit remains observable after refusal', result.err.code, 'emulator_exited')
  end

  do
    local process
    local adb = {}
    function adb:list_devices(callback) return completed(callback, nil, {}) end
    function adb:resolve_avd_name() error 'not reached' end
    function adb:boot_completed() error 'not reached' end
    function adb:validate_serial() error 'not reached' end
    local result
    Emulator.new({
      adb = adb,
      emulator = '/fake/emulator',
      schedule = immediate_schedule,
      boot_timeout_ms = 5,
      poll_interval_ms = 1000,
      spawn = function(_, _, on_exit)
        process = fake_process(on_exit)
        return process
      end,
    }):start('Pixel_API_35', function(err, value) result = { err = err, value = value } end)
    expect_true('boot deadline terminates owned launch', vim.wait(1000, function() return process.kills[1] == 15 end, 1))
    expect('boot deadline waits for owned launch exit', result, nil)
    process.exit { code = 0, signal = 15 }
    expect('boot deadline is classified', result.err.code, 'boot_timeout')
  end

  do
    local adb = {}
    function adb:list_devices(callback) return completed(callback, nil, {}) end
    function adb:resolve_avd_name() error 'not reached' end
    function adb:boot_completed() error 'not reached' end
    function adb:validate_serial() error 'not reached' end
    local result
    local returned_process
    Emulator.new({
      adb = adb,
      emulator = '/fake/emulator',
      schedule = immediate_schedule,
      spawn = function(_, _, on_exit)
        returned_process = fake_process(on_exit)
        on_exit { code = 1, signal = 0 }
        return returned_process
      end,
    }):start('Pixel_API_35', function(err, value) result = { err = err, value = value } end)
    expect('synchronous early emulator exit is contained', result.err.code, 'emulator_exited')
    expect('synchronous early emulator exit closes returned handle', returned_process.close_count, 1)
  end

  do
    local adb = {}
    function adb:list_devices() return nil end
    function adb:resolve_avd_name() error 'not reached' end
    function adb:boot_completed() error 'not reached' end
    function adb:validate_serial() error 'not reached' end
    local result
    Emulator.new({ adb = adb, emulator = '/fake/emulator', schedule = immediate_schedule })
      :start('Pixel_API_35', function(err, value) result = { err = err, value = value } end)
    expect('malformed ADB operation handle is contained', result.err.code, 'invalid_operation_handle')
  end

  do
    local adb = {}
    function adb:list_devices(callback) return completed(callback, nil, { device('emulator-5554', 'Pixel_API_35') }) end
    function adb:resolve_avd_name(_, callback) return completed(callback, { code = 'invalid_avd_name_output', message = 'malformed identity' }) end
    function adb:boot_completed() error 'not reached' end
    function adb:validate_serial() error 'not reached' end
    local result
    Emulator.new({ adb = adb, emulator = '/fake/emulator', schedule = immediate_schedule })
      :start('Pixel_API_35', function(err, value) result = { err = err, value = value } end)
    expect('non-transient ADB identity error is not retried', result.err.code, 'invalid_avd_name_output')
  end

  do
    local adb_calls = 0
    local adb = {}
    function adb:list_devices()
      adb_calls = adb_calls + 1
      error 'deadline construction must precede ADB work'
    end
    function adb:resolve_avd_name() error 'not reached' end
    function adb:boot_completed() error 'not reached' end
    function adb:validate_serial() error 'not reached' end
    local result
    Emulator.new({
      adb = adb,
      emulator = '/fake/emulator',
      schedule = immediate_schedule,
      defer_fn = function() error 'timer unavailable' end,
    }):start('Pixel_API_35', function(err, value) result = { err = err, value = value } end)
    expect('malformed timer adapter is contained', result.err.code, 'timer_failed')
    expect('malformed timer prevents lifecycle work', adb_calls, 0)
  end

  do
    local adb = {}
    function adb:list_devices(callback) return completed(callback, nil, { device('emulator-5554', 'Pixel_API_35') }) end
    function adb:resolve_avd_name(_, callback) return completed(callback, nil, 'Pixel_API_35') end
    function adb:boot_completed(_, callback) return completed(callback, nil, true) end
    function adb:validate_serial(_, callback) return completed(callback, nil, device('emulator-5554', 'Other_API_35')) end
    local result
    Emulator.new({ adb = adb, emulator = '/fake/emulator', schedule = immediate_schedule })
      :start('Pixel_API_35', function(err, value) result = { err = err, value = value } end)
    expect('final AVD identity change is rejected', result.err.code, 'emulator_identity_changed')
  end

  do
    local adb = {}
    function adb:list_devices() error 'invalid stop must not query ADB' end
    function adb:resolve_avd_name() error 'invalid stop must not query ADB' end
    function adb:kill_emulator() error 'invalid stop must not query ADB' end
    local result
    Emulator.new({ adb = adb, emulator = '/fake/emulator', schedule = immediate_schedule })
      :stop({ avd_name = 'Pixel_API_35' }, function(err, value) result = { err = err, value = value } end)
    expect('emulator stop requires an exact serial', result.err.code, 'invalid_emulator_serial')
  end

  do
    local list_count = 0
    local kill_serial
    local adb = {}
    function adb:list_devices(callback)
      list_count = list_count + 1
      local value = list_count == 1 and { device('emulator-5554', 'Pixel_API_35') } or {}
      return completed(callback, nil, value)
    end
    function adb:resolve_avd_name(_, callback) return completed(callback, nil, 'Pixel_API_35') end
    function adb:kill_emulator(serial, callback)
      kill_serial = serial
      return completed(callback, nil, { serial = serial })
    end
    local result
    Emulator.new({ adb = adb, emulator = '/fake/emulator', schedule = immediate_schedule })
      :stop({ avd_name = 'Pixel_API_35', serial = 'emulator-5554' }, function(err, value) result = { err = err, value = value } end)
    expect('exact emulator stop succeeds after disappearance', result.err, nil)
    expect('exact emulator stop returns stable identity', result.value, { avd_name = 'Pixel_API_35', serial = 'emulator-5554' })
    expect('exact emulator stop targets resolved serial', kill_serial, 'emulator-5554')
  end

  do
    local adb = {}
    function adb:list_devices(callback) return completed(callback, nil, { device('emulator-5554', 'Pixel_API_35') }) end
    function adb:resolve_avd_name(_, callback) return completed(callback, nil, 'Pixel_API_35') end
    function adb:kill_emulator(_, callback) return completed(callback, nil, true) end
    local result
    Emulator.new({ adb = adb, emulator = '/fake/emulator', schedule = immediate_schedule })
      :stop({ avd_name = 'Pixel_API_35', serial = 'emulator-5554' }, function(err, value) result = { err = err, value = value } end)
    expect('malformed targeted-kill result is contained', result.err.code, 'invalid_adb_result')
  end

  do
    local list_count = 0
    local identity_count = 0
    local adb = {}
    function adb:list_devices(callback)
      list_count = list_count + 1
      return completed(callback, nil, { device('emulator-5554', 'Pixel_API_35') })
    end
    function adb:resolve_avd_name(_, callback)
      identity_count = identity_count + 1
      return completed(callback, nil, identity_count <= 2 and 'Pixel_API_35' or nil)
    end
    function adb:kill_emulator(serial, callback) return completed(callback, nil, { serial = serial }) end
    local result
    Emulator.new({ adb = adb, emulator = '/fake/emulator', schedule = immediate_schedule })
      :stop({ avd_name = 'Pixel_API_35', serial = 'emulator-5554' }, function(err, value) result = { err = err, value = value } end)
    expect('malformed stop-verification identity is contained', result.err.code, 'invalid_adb_result')
    expect_true('malformed stop-verification follows the kill', list_count > 1)
  end

  do
    local list_count = 0
    local adb = {}
    function adb:list_devices(callback)
      list_count = list_count + 1
      return completed(callback, nil, list_count < 3 and { device('emulator-5554', 'Pixel_API_35') } or {})
    end
    function adb:resolve_avd_name(_, callback)
      if list_count == 1 then return completed(callback, nil, 'Pixel_API_35') end
      return completed(callback, { code = 'invalid_avd_name_output', message = 'emulator console is shutting down' })
    end
    function adb:kill_emulator(serial, callback) return completed(callback, nil, { serial = serial }) end
    local function defer(callback, timeout_ms)
      if timeout_ms == 1 then
        callback()
        return nil
      end
      return {
        stop = function() end,
        is_closing = function() return false end,
        close = function() end,
      }
    end
    local result
    Emulator.new({
      adb = adb,
      emulator = '/fake/emulator',
      schedule = immediate_schedule,
      defer_fn = defer,
      poll_interval_ms = 1,
    }):stop({ avd_name = 'Pixel_API_35', serial = 'emulator-5554' }, function(err, value) result = { err = err, value = value } end)
    expect('empty shutdown identity is retried until disappearance', result.err, nil)
    expect('shutdown retry preserves exact stable identity', result.value, { avd_name = 'Pixel_API_35', serial = 'emulator-5554' })
    expect('shutdown retry performs one bounded extra poll', list_count, 3)
  end

  do
    local list_count = 0
    local identity_count = 0
    local kill_count = 0
    local adb = {}
    function adb:list_devices(callback)
      list_count = list_count + 1
      return completed(callback, nil, { device('emulator-5554', list_count == 1 and 'Pixel_API_35' or 'Other_API_35') })
    end
    function adb:resolve_avd_name(_, callback)
      identity_count = identity_count + 1
      return completed(callback, nil, identity_count <= 2 and 'Pixel_API_35' or 'Other_API_35')
    end
    function adb:kill_emulator(serial, callback)
      kill_count = kill_count + 1
      return completed(callback, nil, { serial = serial })
    end
    local result
    Emulator.new({ adb = adb, emulator = '/fake/emulator', schedule = immediate_schedule }):stop({
      avd_name = 'Pixel_API_35',
      serial = 'emulator-5554',
    }, function(err, value) result = { err = err, value = value } end)
    expect('serial reuse after targeted stop is safe success', result.err, nil)
    expect('serial reuse does not kill replacement emulator', kill_count, 1)
  end

  do
    local identity_count = 0
    local kill_count = 0
    local adb = {}
    function adb:list_devices(callback) return completed(callback, nil, { device('emulator-5554', 'Pixel_API_35') }) end
    function adb:resolve_avd_name(_, callback)
      identity_count = identity_count + 1
      return completed(callback, nil, identity_count == 1 and 'Pixel_API_35' or 'Other_API_35')
    end
    function adb:kill_emulator()
      kill_count = kill_count + 1
      error 'identity changed before targeted kill'
    end
    local result
    Emulator.new({ adb = adb, emulator = '/fake/emulator', schedule = immediate_schedule }):stop({
      avd_name = 'Pixel_API_35',
      serial = 'emulator-5554',
    }, function(err, value) result = { err = err, value = value } end)
    expect('identity change immediately before kill is rejected', result.err.code, 'emulator_identity_mismatch')
    expect('identity change immediately before kill reaches no destructive command', kill_count, 0)
  end

  do
    local adb = {}
    function adb:list_devices(callback) return completed(callback, nil, { device('emulator-5554', 'Other_API_35') }) end
    function adb:resolve_avd_name(_, callback) return completed(callback, nil, 'Other_API_35') end
    function adb:kill_emulator() error 'identity mismatch must not kill' end
    local result
    Emulator.new({ adb = adb, emulator = '/fake/emulator', schedule = immediate_schedule }):stop({
      avd_name = 'Pixel_API_35',
      serial = 'emulator-5554',
    }, function(err, value) result = { err = err, value = value } end)
    expect('stop rejects reused serial before kill', result.err.code, 'emulator_identity_mismatch')
  end
end, debug.traceback)

if not ok then fail('unexpected test error', unexpected) end

if #failures > 0 then
  vim.api.nvim_err_writeln('Android Workbench emulator validation failed:\n- ' .. table.concat(failures, '\n- '))
  vim.cmd 'cquit 1'
end

print 'Android Workbench emulator validation passed'
vim.cmd 'qa!'
