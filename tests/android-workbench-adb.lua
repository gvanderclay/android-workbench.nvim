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

local Adb = require 'android_workbench.android.adb'

local ok, unexpected = xpcall(function()
  local responses = {}
  local invocations = {}
  local pending

  local function respond(response) responses[#responses + 1] = response end

  local service = Adb.new {
    adb = '/fake/adb',
    timeout_ms = 1000,
    system = function(argv, opts, on_exit)
      local response = table.remove(responses, 1)
      assert(response, 'unexpected adb invocation')
      local invocation = {
        argv = vim.deepcopy(argv),
        opts = opts,
        kills = {},
      }
      invocations[#invocations + 1] = invocation
      local process = {
        kill = function(_, signal)
          invocation.kills[#invocation.kills + 1] = signal
          return true
        end,
      }
      invocation.exit = on_exit

      if response.pending then
        pending = invocation
      else
        if response.stdout then opts.stdout(nil, response.stdout) end
        if response.stderr then opts.stderr(nil, response.stderr) end
        on_exit { code = response.code or 0, signal = response.signal or 0 }
      end
      return process
    end,
  }

  local function await(start)
    local completed
    local callback_count = 0
    local handle = start(function(err, value)
      callback_count = callback_count + 1
      completed = { err = err, value = value }
    end)
    expect_true('operation callback completes', vim.wait(1000, function() return completed ~= nil end, 10))
    return completed, handle, function() return callback_count end
  end

  local devices_output = [[List of devices attached
emulator-5554 device product:sdk_gphone64_arm64 model:Pixel_8_Pro device:emu64a transport_id:1
R58M123 unauthorized usb:1-2 transport_id:2
R58M999 no permissions (user in plugdev group); see [http://developer.android.com/tools/device.html]
R58M321 device product:e1q model:Galaxy_S24 device:e1q transport_id:3
]]

  respond { stdout = devices_output }
  local completed = await(function(callback) return service:list_devices(callback) end)
  expect('device list succeeds', completed.err, nil)
  expect('online state is normalized', completed.value[1].state, 'online')
  expect('online raw state is preserved', completed.value[1].raw_state, 'device')
  expect('device serial is parsed', completed.value[1].serial, 'emulator-5554')
  expect('device label prefers model', completed.value[1].label, 'Pixel_8_Pro')
  expect('device DTO excludes raw ADB properties', completed.value[1], {
    serial = 'emulator-5554',
    state = 'online',
    raw_state = 'device',
    label = 'Pixel_8_Pro',
  })
  expect('unauthorized state is preserved', completed.value[2].state, 'unauthorized')
  expect('no-permissions state is normalized', completed.value[3].state, 'no_permissions')
  expect('no-permissions raw state is preserved', completed.value[3].raw_state, 'no permissions')
  expect('no-permissions explanation is preserved', completed.value[3].details, '(user in plugdev group); see [http://developer.android.com/tools/device.html]')
  expect('device listing uses direct argv', invocations[1].argv, { '/fake/adb', 'devices', '-l' })
  expect('device listing requests text streams', invocations[1].opts.text, true)

  respond { stdout = devices_output }
  respond { stdout = '\r\nPixel_8_API_35\r\nOK\r\n' }
  completed = await(function(callback) return service:validate_serial('emulator-5554', callback) end)
  expect('online remembered device validates', completed.err, nil)
  expect('validated emulator includes its AVD identity', completed.value, {
    serial = 'emulator-5554',
    state = 'online',
    raw_state = 'device',
    label = 'Pixel_8_Pro',
    avd_name = 'Pixel_8_API_35',
  })
  expect('AVD name query uses exact direct argv', invocations[#invocations].argv, {
    '/fake/adb',
    '-s',
    'emulator-5554',
    'emu',
    'avd',
    'name',
  })

  respond { stdout = 'Pixel_8_API_35\nOK\n' }
  completed = await(function(callback) return service:resolve_avd_name('emulator-5554', callback) end)
  expect('direct AVD identity query succeeds', completed.err, nil)
  expect('direct AVD identity is parsed', completed.value, 'Pixel_8_API_35')

  respond { stdout = 'Pixel 8 API 35\nOK\n' }
  completed = await(function(callback) return service:resolve_avd_name('emulator-5554', callback) end)
  expect('whitespace-bearing AVD identity is rejected', completed.err.code, 'invalid_avd_name_output')

  local direct_invocation_count = #invocations
  completed = await(function(callback) return service:resolve_avd_name('R58M321', callback) end)
  expect('physical serial is rejected for an AVD identity query', completed.err.code, 'invalid_emulator_serial')
  expect('invalid AVD identity serial does not start adb', #invocations, direct_invocation_count)

  respond { stdout = '1\n' }
  completed = await(function(callback) return service:boot_completed('emulator-5554', callback) end)
  expect('boot-completion query recognizes readiness', completed.value, true)
  expect('boot-completion query uses exact direct argv', invocations[#invocations].argv, {
    '/fake/adb',
    '-s',
    'emulator-5554',
    'shell',
    'getprop',
    'sys.boot_completed',
  })

  respond { stdout = '\n' }
  completed = await(function(callback) return service:boot_completed('emulator-5554', callback) end)
  expect('missing boot property remains not ready', completed.value, false)

  respond { stdout = '0\n' }
  completed = await(function(callback) return service:boot_completed('emulator-5554', callback) end)
  expect('zero boot property remains not ready', completed.value, false)

  respond { stdout = 'yes\n' }
  completed = await(function(callback) return service:boot_completed('emulator-5554', callback) end)
  expect('unexpected boot property is rejected', completed.err.code, 'invalid_boot_output')

  respond { stdout = 'OK: killing emulator, bye bye\n' }
  completed = await(function(callback) return service:kill_emulator('emulator-5554', callback) end)
  expect('targeted emulator kill succeeds', completed.err, nil)
  expect('targeted emulator kill retains serial identity', completed.value, { serial = 'emulator-5554' })
  expect('targeted emulator kill uses exact direct argv', invocations[#invocations].argv, {
    '/fake/adb',
    '-s',
    'emulator-5554',
    'emu',
    'kill',
  })

  respond { stdout = 'KO: emulator refused shutdown\n' }
  completed = await(function(callback) return service:kill_emulator('emulator-5554', callback) end)
  expect('emulator kill refusal is classified', completed.err.code, 'emulator_kill_failed')

  local invocation_count = #invocations
  respond { stdout = devices_output }
  completed = await(function(callback) return service:validate_serial('R58M321', callback) end)
  expect('online physical device validates without an AVD query', completed.value, {
    serial = 'R58M321',
    state = 'online',
    raw_state = 'device',
    label = 'Galaxy_S24',
  })
  expect('physical device validation only lists devices', #invocations, invocation_count + 1)

  respond { stdout = devices_output }
  completed = await(function(callback) return service:validate_serial('R58M123', callback) end)
  expect('unready remembered device is classified', completed.err.code, 'device_not_ready')
  expect('unready error retains normalized device', completed.err.details.device.state, 'unauthorized')

  respond { stdout = devices_output }
  completed = await(function(callback) return service:validate_serial('missing-serial', callback) end)
  expect('missing remembered device is classified', completed.err.code, 'device_not_found')

  respond { stdout = devices_output }
  respond { stdout = 'OK\n' }
  completed = await(function(callback) return service:validate_serial('emulator-5554', callback) end)
  expect('empty AVD name is rejected', completed.err.code, 'invalid_avd_name_output')

  respond { stdout = devices_output }
  respond { stdout = string.rep('a', 1025) .. '\nOK\n' }
  completed = await(function(callback) return service:validate_serial('emulator-5554', callback) end)
  expect('oversized AVD name is rejected', completed.err.code, 'invalid_avd_name_output')

  respond {
    stdout = [[com.example.app/.MainActivity
com.example.app/com.example.shell.Shell$HomeActivity
com.example.app/.ÉcranActivity
com.example.app/.MainActivity
]],
  }
  completed = await(function(callback) return service:resolve_launch_components('emulator-5554', 'com.example.app', callback) end)
  expect('launch-component query succeeds', completed.err, nil)
  expect('launch components are normalized and deduplicated', completed.value, {
    {
      component = 'com.example.app/.MainActivity',
      package = 'com.example.app',
      activity = 'com.example.app.MainActivity',
    },
    {
      component = 'com.example.app/com.example.shell.Shell$HomeActivity',
      package = 'com.example.app',
      activity = 'com.example.shell.Shell$HomeActivity',
    },
    {
      component = 'com.example.app/.ÉcranActivity',
      package = 'com.example.app',
      activity = 'com.example.app.ÉcranActivity',
    },
  })
  expect('component query accepts a non-ASCII activity class', completed.value[3].activity, 'com.example.app.ÉcranActivity')
  expect('component query uses exact direct argv', invocations[#invocations].argv, {
    '/fake/adb',
    '-s',
    'emulator-5554',
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
    "'com.example.app'",
  })

  respond { stdout = 'No activities found\n' }
  completed = await(function(callback) return service:resolve_launch_components('emulator-5554', 'com.example.app', callback) end)
  expect('application without launcher is an empty result', completed.value, {})

  respond { stdout = 'com.other.app/.MainActivity\n' }
  completed = await(function(callback) return service:resolve_launch_components('emulator-5554', 'com.example.app', callback) end)
  expect('component package mismatch is rejected', completed.err.code, 'invalid_components_output')

  respond {
    stdout = [[Starting: Intent { cmp=com.example.app/.Main$Activity }
Status: ok
LaunchState: COLD
Activity: com.example.app/.Main$Activity
TotalTime: 312
WaitTime: 340
Complete
]],
  }
  completed = await(function(callback) return service:launch('emulator-5554', 'com.example.app', 'com.example.app/.Main$Activity', callback) end)
  expect('application launch succeeds', completed.err, nil)
  expect('launch status is parsed', completed.value.status, 'ok')
  expect('launch state is parsed', completed.value.launch_state, 'COLD')
  expect('launch total time is numeric', completed.value.total_time_ms, 312)
  expect('launch wait time is numeric', completed.value.wait_time_ms, 340)
  expect('launch uses direct bounded argv', invocations[#invocations].argv, {
    '/fake/adb',
    '-s',
    'emulator-5554',
    'shell',
    'am',
    'start',
    '--user',
    'current',
    '-W',
    '-n',
    "'com.example.app/.Main$Activity'",
  })

  for _, case in ipairs {
    { name = 'empty launch output', stdout = '' },
    { name = 'unrelated launch output', stdout = 'Starting something else\nComplete\n' },
    { name = 'missing launch status value', stdout = 'Status:\nComplete\n' },
  } do
    respond { stdout = case.stdout }
    completed = await(function(callback) return service:launch('emulator-5554', 'com.example.app', 'com.example.app/.MainActivity', callback) end)
    expect(case.name .. ' is rejected', completed.err and completed.err.code, 'invalid_launch_output')
  end

  respond { stdout = 'Status: ok\n' }
  completed = await(function(callback) return service:launch('emulator-5554', 'com.example.app', 'com.example.app/.MainActivity', callback) end)
  expect('minimal successful launch status is accepted', completed.err, nil)
  expect('minimal successful launch status is parsed', completed.value.status, 'ok')

  respond { stdout = 'Status: timeout\nComplete\n' }
  completed = await(function(callback) return service:launch('emulator-5554', 'com.example.app', 'com.example.app/.MainActivity', callback) end)
  expect('explicit non-ok launch status is classified', completed.err.code, 'launch_failed')

  respond { stdout = 'Error type 3\nError: Activity class does not exist.\n' }
  completed = await(function(callback) return service:launch('emulator-5554', 'com.example.app', 'com.example.app/.MainActivity', callback) end)
  expect('textual am launch error is classified', completed.err.code, 'launch_failed')

  respond { stdout = '' }
  completed = await(function(callback) return service:stop('emulator-5554', 'com.example.app', callback) end)
  expect('exact package stop succeeds', completed.err, nil)
  expect('stop result retains identity', completed.value, { serial = 'emulator-5554', application_id = 'com.example.app' })
  expect('stop uses direct bounded argv', invocations[#invocations].argv, {
    '/fake/adb',
    '-s',
    'emulator-5554',
    'shell',
    'am',
    'force-stop',
    '--user',
    'current',
    "'com.example.app'",
  })

  invocation_count = #invocations
  completed = await(function(callback) return service:resolve_launch_components('emulator-5554', 'not-a-package', callback) end)
  expect('invalid application id is classified', completed.err.code, 'invalid_application_id')
  expect('invalid application id never starts adb', #invocations, invocation_count)

  respond { stdout = devices_output }
  invocation_count = #invocations
  local between_stages
  local between_stages_count = 0
  local between_stages_handle = service:validate_serial('emulator-5554', function(err, value)
    between_stages_count = between_stages_count + 1
    between_stages = { err = err, value = value }
  end)
  expect('validation cancellation between stages succeeds', between_stages_handle.cancel(), true)
  expect_true('between-stage cancellation callback completes', vim.wait(1000, function() return between_stages ~= nil end, 10))
  vim.wait(20)
  expect('between-stage cancellation is classified', between_stages.err.code, 'cancelled')
  expect('cancelled validation does not start AVD query', #invocations, invocation_count + 1)
  expect('between-stage late callback is ignored', between_stages_count, 1)
  expect('between-stage cancellation cannot repeat', between_stages_handle:cancel(), false)

  respond { stdout = devices_output }
  respond { pending = true }
  invocation_count = #invocations
  local name_cancelled
  local name_callback_count = 0
  local name_handle = service:validate_serial('emulator-5554', function(err, value)
    name_callback_count = name_callback_count + 1
    name_cancelled = { err = err, value = value }
  end)
  expect_true('AVD name query starts', vim.wait(1000, function() return #invocations == invocation_count + 2 end, 10))
  local name_pending = invocations[#invocations]
  expect('validation cancellation during AVD query succeeds', name_handle:cancel(), true)
  expect('AVD query cancellation waits for child exit', name_cancelled, nil)
  expect('AVD query cancellation sends SIGTERM', name_pending.kills[1], 15)
  name_pending.exit { code = 143, signal = 15 }
  expect_true('AVD query cancellation callback completes', vim.wait(1000, function() return name_cancelled ~= nil end, 10))
  expect('AVD query cancellation is classified', name_cancelled.err.code, 'cancelled')
  expect('late AVD query callback is ignored', name_callback_count, 1)

  respond { pending = true }
  local cancelled
  local callback_count = 0
  local handle = service:list_devices(function(err, value)
    callback_count = callback_count + 1
    cancelled = { err = err, value = value }
  end)
  expect('dot cancellation succeeds', handle.cancel(), true)
  expect('cancel waits for child exit', cancelled, nil)
  expect('cancel sends SIGTERM', pending.kills[1], 15)
  expect('pending cancellation cannot repeat', handle:cancel(), false)
  pending.exit { code = 143, signal = 15 }
  expect_true('cancel callback completes', vim.wait(1000, function() return cancelled ~= nil end, 10))
  expect('cancel is classified', cancelled.err.code, 'cancelled')
  expect('cancel callback fires exactly once', callback_count, 1)

  local timeout_pending
  local timeout_service = Adb.new {
    adb = '/fake/adb',
    timeout_ms = 10,
    system = function(_, _, on_exit)
      timeout_pending = {
        exit = on_exit,
        kills = {},
        kill = function(self, signal)
          self.kills[#self.kills + 1] = signal
          return true
        end,
      }
      return timeout_pending
    end,
  }
  local timed_out
  timeout_service:list_devices(function(err) timed_out = err end)
  expect_true('bounded operation requests termination', vim.wait(1000, function() return timeout_pending.kills[1] == 15 end, 10))
  expect('timeout waits for child exit', timed_out, nil)
  expect('timeout sends SIGTERM', timeout_pending.kills[1], 15)
  timeout_pending.exit { code = 143, signal = 15 }
  expect_true('bounded operation times out', vim.wait(1000, function() return timed_out ~= nil end, 10))
  expect('timeout is classified', timed_out.code, 'timeout')

  local refused_exit
  local refused_opts
  local refused_result
  local refused_service = Adb.new {
    adb = '/fake/adb',
    system = function(_, opts, on_exit)
      refused_opts = opts
      refused_exit = on_exit
      return { kill = function() error 'signal refused' end }
    end,
  }
  local refused_handle = refused_service:list_devices(function(err, value) refused_result = { err = err, value = value } end)
  expect('ADB signal failure rejects cancellation', refused_handle:cancel(), false)
  expect('ADB signal failure keeps result pending', refused_result, nil)
  refused_opts.stdout(nil, 'List of devices attached\n')
  refused_exit { code = 0, signal = 0 }
  expect_true('ADB remains observable after rejected cancellation', vim.wait(1000, function() return refused_result ~= nil end, 10))
  expect('ADB rejected cancellation preserves natural result', refused_result.err, nil)

  local false_exit
  local false_opts
  local false_result
  local false_service = Adb.new {
    adb = '/fake/adb',
    system = function(_, opts, on_exit)
      false_opts = opts
      false_exit = on_exit
      return { kill = function() return false end }
    end,
  }
  local false_handle = false_service:list_devices(function(err, value) false_result = { err = err, value = value } end)
  expect('ADB false signal result rejects cancellation', false_handle:cancel(), false)
  expect('ADB false signal result keeps result pending', false_result, nil)
  false_opts.stdout(nil, 'List of devices attached\n')
  false_exit { code = 0, signal = 0 }
  expect_true('ADB false signal result preserves natural completion', vim.wait(1000, function() return false_result ~= nil end, 10))
  expect('ADB false signal result keeps natural result', false_result.err, nil)

  local synchronous_cancel_result
  local synchronous_cancel_service = Adb.new {
    adb = '/fake/adb',
    system = function(_, _, on_exit)
      return {
        kill = function()
          on_exit { code = 143, signal = 15 }
          return false
        end,
      }
    end,
  }
  local synchronous_cancel_handle = synchronous_cancel_service:list_devices(function(err, value) synchronous_cancel_result = { err = err, value = value } end)
  expect('synchronous terminal cancellation wins over false signal result', synchronous_cancel_handle:cancel(), true)
  expect_true('synchronous terminal cancellation completes', vim.wait(1000, function() return synchronous_cancel_result ~= nil end, 10))
  expect('synchronous terminal cancellation is classified', synchronous_cancel_result.err and synchronous_cancel_result.err.code, 'cancelled')

  local child_callback
  local child_result
  local false_child_service = Adb.new { adb = '/fake/adb' }
  function false_child_service:list_devices(callback)
    child_callback = callback
    return { cancel = function() return false end }
  end
  local false_child_handle = false_child_service:validate_serial('R58M321', function(err, value) child_result = { err = err, value = value } end)
  expect('validation child false cancellation is observable', false_child_handle:cancel(), false)
  expect('validation child false cancellation keeps result pending', child_result, nil)
  child_callback(nil, { { serial = 'R58M321', state = 'online', raw_state = 'device', label = 'Galaxy_S24' } })
  expect('validation child remains observable after cancellation refusal', child_result.err, nil)
  expect('validation child preserves its natural result', child_result.value.serial, 'R58M321')

  local invalid_process_result
  Adb.new({ adb = '/fake/adb', system = function() return true end }):list_devices(function(err) invalid_process_result = err end)
  expect_true('scalar ADB process completes', vim.wait(1000, function() return invalid_process_result ~= nil end, 10))
  expect('scalar ADB process is contained', invalid_process_result.code, 'spawn_failed')

  local invalid_completion_result
  Adb.new({
    adb = '/fake/adb',
    system = function(_, _, on_exit)
      on_exit(true)
      return { kill = function() return true end }
    end,
  }):list_devices(function(err) invalid_completion_result = err end)
  expect_true('scalar ADB completion completes', vim.wait(1000, function() return invalid_completion_result ~= nil end, 10))
  expect('scalar ADB completion is contained', invalid_completion_result.code, 'invalid_process_result')
end, debug.traceback)

if not ok then fail('unexpected test error', unexpected) end

if #failures > 0 then
  vim.api.nvim_err_writeln('Android Workbench ADB validation failed:\n- ' .. table.concat(failures, '\n- '))
  vim.cmd 'cquit 1'
end

print 'Android Workbench ADB validation passed'
vim.cmd 'qa!'
