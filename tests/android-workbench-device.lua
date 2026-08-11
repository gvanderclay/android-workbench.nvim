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

local Device = require 'android_workbench.device'

local function noop_handle()
  return { cancel = function() return false end }
end

local function new_session(device)
  local selection = {
    app = { build_path = ':', project_path = ':app' },
    variant = 'debug',
    device = vim.deepcopy(device),
  }
  local saves = {}
  local session = { root = '/tmp/android-workbench-device-root' }

  function session:selection() return vim.deepcopy(selection) end

  function session:set_device_selection(value)
    selection.device = vim.deepcopy(value)
    saves[#saves + 1] = vim.deepcopy(value)
    return true
  end

  function session:replace_device(value) selection.device = vim.deepcopy(value) end

  function session:device() return vim.deepcopy(selection.device) end

  session.saves = saves
  return session
end

local function find(items, field, value)
  for _, item in ipairs(items) do
    if item[field] == value then return item end
  end
end

local function new_adb(devices, validated)
  local calls = { list = 0, validate = {} }
  local adb = {}

  function adb:list_devices(callback)
    calls.list = calls.list + 1
    callback(nil, vim.deepcopy(devices))
    return noop_handle()
  end

  function adb:validate_serial(serial, callback)
    calls.validate[#calls.validate + 1] = serial
    local value = validated[serial]
    if type(value) == 'function' then return value(callback) end
    if type(value) == 'table' and value.error then
      callback(value.error)
    else
      callback(nil, vim.deepcopy(value))
    end
    return noop_handle()
  end

  adb.calls = calls
  return adb
end

local function new_emulator(avds, list_error)
  local calls = { list = 0, start = {}, stop = {} }
  local emulator = {}

  function emulator:list_avds(callback)
    calls.list = calls.list + 1
    callback(vim.deepcopy(list_error), list_error and nil or vim.deepcopy(avds))
    return noop_handle()
  end

  function emulator:start(avd_name, callback)
    calls.start[#calls.start + 1] = avd_name
    callback(nil, {
      serial = 'emulator-5570',
      avd_name = avd_name,
      state = 'online',
      label = avd_name,
    })
    return noop_handle()
  end

  function emulator:stop(request, callback)
    calls.stop[#calls.stop + 1] = vim.deepcopy(request)
    callback(nil, { avd_name = request.avd_name, serial = request.serial })
    return noop_handle()
  end

  emulator.calls = calls
  return emulator
end

local function new_picker(choose)
  local picker = { requests = {} }
  picker.select = function(request, callback)
    picker.requests[#picker.requests + 1] = request
    callback(nil, choose(request))
    return noop_handle()
  end
  return picker
end

local ok, unexpected = xpcall(function()
  do
    local session = new_session()
    local adb = new_adb({
      { serial = 'R58M321', state = 'online', label = 'Galaxy S23' },
    }, {
      R58M321 = { serial = 'R58M321', state = 'online', label = 'Galaxy S23' },
    })
    local emulator = new_emulator({}, { code = 'emulator_not_found', message = 'Android Emulator package is not installed' })
    local picker = new_picker(function() error 'a sole connected device must not open a picker' end)
    local device = Device.new { adb = adb, emulator = emulator, picker = picker }
    local result
    local handle = device:select(session, function(err, value) result = { err = err, value = value } end)

    expect_true('select returns a cancel handle', type(handle) == 'table' and type(handle.cancel) == 'function')
    expect('legacy sole physical device selection succeeds', result.err, nil)
    expect('legacy physical selection returns an online device', result.value, {
      serial = 'R58M321',
      state = 'online',
      label = 'Galaxy S23',
    })
    expect('legacy physical selection persists only the serial', session:device(), { serial = 'R58M321' })
    expect('sole physical selection validates before saving', adb.calls.validate, { 'R58M321' })
    expect('sole physical selection does not open the picker', #picker.requests, 0)
    expect('missing emulator package is treated as no installed AVDs', emulator.calls.list, 1)
  end

  do
    local serial = 'adb-example (2)._adb-tls-connect._tcp'
    local session = new_session()
    local adb = new_adb({
      { serial = serial, state = 'online', label = 'CPH2583' },
    }, {
      [serial] = { serial = serial, state = 'online', label = 'CPH2583' },
    })
    local device = Device.new {
      adb = adb,
      emulator = new_emulator({}, { code = 'emulator_not_found', message = 'Android Emulator package is not installed' }),
      picker = new_picker(function() error 'a sole connected device must not open a picker' end),
    }
    local result
    device:select(session, function(err, value) result = { err = err, value = value } end)

    expect('wireless physical selection succeeds', result.err, nil)
    expect('wireless physical selection returns exact serial', result.value and result.value.serial, serial)
    expect('wireless physical selection persists exact serial', session:device(), { serial = serial })
    expect('wireless physical selection validates exact serial', adb.calls.validate, { serial })
  end

  do
    local session = new_session { serial = 'R58M321' }
    local adb = new_adb({}, {
      R58M321 = { error = { code = 'device_not_found', message = 'disconnected' } },
    })
    local device = Device.new { adb = adb, emulator = new_emulator {}, picker = new_picker(function() end) }
    local result
    device:resolve(session, {}, function(err, value) result = { err = err, value = value } end)
    expect('remembered physical disconnect is reported', result.err.code, 'device_not_found')
    expect('remembered physical disconnect returns no device', result.value, nil)
    expect('remembered physical disconnect keeps the selection', session:device(), { serial = 'R58M321' })
  end

  do
    local session = new_session { serial = 'R58M321' }
    local connected = false
    local adb = new_adb({}, {
      R58M321 = function(callback)
        if connected then
          callback(nil, { serial = 'R58M321', state = 'online', label = 'Galaxy S23' })
        else
          callback { code = 'device_not_found', message = 'disconnected' }
        end
        return noop_handle()
      end,
    })
    local device = Device.new { adb = adb, emulator = new_emulator {}, picker = new_picker(function() end) }
    local result
    device:resolve(session, {}, function(err, value) result = { err = err, value = value } end)
    expect('disconnected physical device fails without replacement', result.err.code, 'device_not_found')
    expect('disconnected physical device remains selected for retry', session:device(), { serial = 'R58M321' })

    connected = true
    result = nil
    device:resolve(session, {}, function(err, value) result = { err = err, value = value } end)
    expect('same physical serial works after reconnect', result.err, nil)
    expect('reconnected physical device returns online identity', result.value, {
      serial = 'R58M321',
      state = 'online',
      label = 'Galaxy S23',
    })
    expect('physical reconnect keeps the stable serial selection', session:device(), { serial = 'R58M321' })
  end

  do
    local session = new_session { serial = 'emulator-5554', avd_name = 'Pixel_8' }
    local adb = new_adb({}, {
      ['emulator-5554'] = { serial = 'emulator-5554', avd_name = 'Pixel_9', state = 'online' },
    })
    local emulator = new_emulator { { avd_name = 'Pixel_8' }, { avd_name = 'Pixel_9' } }
    local device = Device.new { adb = adb, emulator = emulator, picker = new_picker(function() end) }
    local result
    device:resolve(session, { start_stopped_avd = true }, function(err, value) result = { err = err, value = value } end)
    expect('reused emulator serial is rejected before auto-start', result.err.code, 'device_changed')
    expect('reused emulator serial does not query AVD inventory', adb.calls.list, 0)
    expect('reused emulator serial does not start the remembered AVD', emulator.calls.start, {})
    expect('reused emulator serial preserves remembered identity', session:device(), {
      serial = 'emulator-5554',
      avd_name = 'Pixel_8',
    })
  end

  do
    local session = new_session()
    local running = {
      serial = 'emulator-5554',
      avd_name = 'Pixel_8',
      state = 'online',
      label = 'sdk_gphone64_arm64',
    }
    local adb = new_adb({
      { serial = 'R58M321', state = 'online', label = 'Galaxy S23' },
      { serial = 'emulator-5554', state = 'online', label = 'sdk_gphone64_arm64' },
    }, {
      R58M321 = { serial = 'R58M321', state = 'online', label = 'Galaxy S23' },
      ['emulator-5554'] = running,
    })
    local emulator = new_emulator {
      { avd_name = 'Pixel_7', label = 'Pixel_7' },
      { avd_name = 'Pixel_8', label = 'Pixel_8' },
    }
    local picker = new_picker(function(request)
      expect('unified picker contains one physical and two AVD rows', #request.items, 3)
      expect_true('running AVD is merged with its installed AVD row', find(request.items, 'avd_name', 'Pixel_8').serial == 'emulator-5554')
      expect('stopped AVD has no ephemeral serial', find(request.items, 'avd_name', 'Pixel_7').serial, nil)
      expect('stopped AVD is labelled by lifecycle state', request.format_item(find(request.items, 'avd_name', 'Pixel_7')), 'Pixel_7 (stopped)')
      return find(request.items, 'avd_name', 'Pixel_7')
    end)
    local device = Device.new { adb = adb, emulator = emulator, picker = picker }
    local result
    device:select(session, function(err, value) result = { err = err, value = value } end)

    expect('selecting a stopped AVD succeeds without starting it', result.err, nil)
    expect('stopped AVD selection result is stable', result.value, {
      avd_name = 'Pixel_7',
      state = 'stopped',
      label = 'Pixel_7',
    })
    expect('stopped AVD selection persists no serial', session:device(), { avd_name = 'Pixel_7' })
    expect('selection alone does not start the AVD', emulator.calls.start, {})
  end

  do
    local session = new_session { avd_name = 'Pixel_7' }
    local adb = new_adb({}, {})
    local emulator = new_emulator { { avd_name = 'Pixel_7', label = 'Pixel_7' } }
    local device = Device.new { adb = adb, emulator = emulator, picker = new_picker(function() end) }
    local result
    device:resolve(session, {}, function(err, value) result = { err = err, value = value } end)
    expect('resolve does not implicitly start a stopped AVD by default', result.err.code, 'device_not_ready')
    expect('non-starting resolve returns no runtime device', result.value, nil)
    expect('non-starting resolve does not call emulator start', emulator.calls.start, {})

    result = nil
    device:resolve(session, { start_stopped_avd = true }, function(err, value) result = { err = err, value = value } end)
    expect('run-style resolve starts a stopped remembered AVD', result.err, nil)
    expect('run-style resolve returns boot-ready identity', result.value, {
      serial = 'emulator-5570',
      avd_name = 'Pixel_7',
      state = 'online',
      label = 'Pixel_7',
    })
    expect('start success persists stable AVD and current serial', session:device(), {
      avd_name = 'Pixel_7',
      serial = 'emulator-5570',
    })
  end

  do
    local session = new_session { avd_name = 'Pixel_8' }
    local adb = new_adb({
      { serial = 'emulator-5554', state = 'online', label = 'sdk_gphone64_arm64' },
    }, {
      ['emulator-5554'] = { serial = 'emulator-5554', avd_name = 'Pixel_8', state = 'online', label = 'Pixel' },
    })
    local emulator = new_emulator { { avd_name = 'Pixel_8', label = 'Pixel_8' } }
    local device = Device.new { adb = adb, emulator = emulator, picker = new_picker(function() end) }
    local result
    device:resolve(session, {}, function(err, value) result = { err = err, value = value } end)
    expect('serial-less remembered AVD resolves an externally running instance', result.err, nil)
    expect('external instance resolves by stable AVD name', result.value.serial, 'emulator-5554')
    expect('external instance refreshes the ephemeral serial', session:device(), {
      avd_name = 'Pixel_8',
      serial = 'emulator-5554',
    })
    expect('external instance resolution does not call Start', emulator.calls.start, {})
  end

  for _, stale_code in ipairs { 'device_not_found', 'device_not_ready' } do
    local session = new_session { avd_name = 'Pixel_8', serial = 'emulator-5554' }
    local adb = new_adb({
      { serial = 'emulator-5556', state = 'online', label = 'sdk_gphone64_arm64' },
    }, {
      ['emulator-5554'] = { error = { code = stale_code, message = 'remembered serial is stale' } },
      ['emulator-5556'] = { serial = 'emulator-5556', avd_name = 'Pixel_8', state = 'online', label = 'Pixel' },
    })
    local emulator = new_emulator { { avd_name = 'Pixel_8', label = 'Pixel_8' } }
    local device = Device.new { adb = adb, emulator = emulator, picker = new_picker(function() end) }
    local result
    device:resolve(session, {}, function(err, value) result = { err = err, value = value } end)
    expect(stale_code .. ' remembered AVD rebind succeeds without auto-start', result.err, nil)
    expect(stale_code .. ' remembered AVD rebinds by stable name', result.value.serial, 'emulator-5556')
    expect(stale_code .. ' remembered AVD refreshes only its serial', session:device(), {
      avd_name = 'Pixel_8',
      serial = 'emulator-5556',
    })
    expect(stale_code .. ' remembered AVD rebind does not call Start', emulator.calls.start, {})
    expect(stale_code .. ' remembered AVD validates old then rebound serial', adb.calls.validate, {
      'emulator-5554',
      'emulator-5556',
    })
  end

  do
    local session = new_session { avd_name = 'Pixel_7', serial = 'emulator-5554' }
    local adb = new_adb({}, {
      ['emulator-5554'] = { error = { code = 'device_not_found', message = 'old emulator serial is gone' } },
    })
    local emulator = new_emulator { { avd_name = 'Pixel_7' } }
    local device = Device.new { adb = adb, emulator = emulator, picker = new_picker(function() end) }
    local result
    device:resolve(session, { start_stopped_avd = true }, function(err, value) result = { err = err, value = value } end)
    expect('Run auto-starts a remembered AVD after its old serial disappears', result.err, nil)
    expect('Run auto-start keeps the stable AVD identity', emulator.calls.start, { 'Pixel_7' })
    expect('Run auto-start replaces only the stale serial', session:device(), {
      avd_name = 'Pixel_7',
      serial = 'emulator-5570',
    })
  end

  do
    local session = new_session { avd_name = 'Pixel_8', serial = 'emulator-5554' }
    local adb = new_adb({}, {})
    local emulator = new_emulator {}
    local device = Device.new { adb = adb, emulator = emulator, picker = new_picker(function() end) }
    local result
    device:start(session, function(err, value) result = { err = err, value = value } end)
    expect('explicit Start delegates even for a remembered running AVD', emulator.calls.start, { 'Pixel_8' })
    expect('explicit Start adopts the service runtime identity', result.value.serial, 'emulator-5570')
    expect('explicit Start refreshes the persisted serial', session:device(), {
      avd_name = 'Pixel_8',
      serial = 'emulator-5570',
    })
  end

  do
    local session = new_session { serial = 'R58M321' }
    local adb = new_adb({
      { serial = 'R58M321', state = 'online', label = 'Galaxy S23' },
    }, {
      R58M321 = { serial = 'R58M321', state = 'online', label = 'Galaxy S23' },
    })
    local emulator = new_emulator { { avd_name = 'Pixel_8', label = 'Pixel_8' } }
    local picker = new_picker(function(request)
      expect('Start from a physical selection offers only AVDs', #request.items, 1)
      expect_true('Start picker excludes physical devices', find(request.items, 'serial', 'R58M321') == nil)
      return find(request.items, 'avd_name', 'Pixel_8')
    end)
    local device = Device.new { adb = adb, emulator = emulator, picker = picker }
    local result
    device:start(session, function(err, value) result = { err = err, value = value } end)
    expect('starting after a physical selection succeeds', result.err, nil)
    expect('explicit Start opens the picker for a sole eligible AVD', #picker.requests, 1)
    expect('starting after a physical selection remembers the AVD', session:device(), {
      avd_name = 'Pixel_8',
      serial = 'emulator-5570',
    })
  end

  do
    local session = new_session { avd_name = 'Pixel_8', serial = 'emulator-5554' }
    local running = { serial = 'emulator-5554', avd_name = 'Pixel_8', state = 'online', label = 'Pixel_8' }
    local adb = new_adb({
      { serial = 'emulator-5554', state = 'online', label = 'sdk_gphone64_arm64' },
    }, {
      ['emulator-5554'] = running,
    })
    local emulator = new_emulator { { avd_name = 'Pixel_8', label = 'Pixel_8' } }
    local device = Device.new { adb = adb, emulator = emulator, picker = new_picker(function() error 'selected AVD Stop must not open a picker' end) }
    local result
    device:stop(session, function(err, value) result = { err = err, value = value } end)
    expect('Stop targets exact serial plus AVD identity', emulator.calls.stop, {
      { avd_name = 'Pixel_8', serial = 'emulator-5554' },
    })
    expect('Stop succeeds', result.err, nil)
    expect('Stop returns the stopped stable AVD', result.value.avd_name, 'Pixel_8')
    expect('Stop preserves AVD selection and clears the serial', session:device(), { avd_name = 'Pixel_8' })
  end

  do
    local session = new_session { avd_name = 'Pixel_8', serial = 'emulator-5554' }
    local adb = {
      list_devices = function() error 'remembered exact emulator Stop must delegate identity checks to the emulator service' end,
      validate_serial = function() error 'remembered exact emulator Stop must not require online ADB validation' end,
    }
    local emulator = new_emulator { { avd_name = 'Pixel_8' } }
    local device = Device.new { adb = adb, emulator = emulator, picker = new_picker(function() error 'remembered exact emulator Stop must not pick' end) }
    local result
    device:stop(session, function(err, value) result = { err = err, value = value } end)
    expect('remembered booting or offline emulator Stop delegates exact identity', result.err, nil)
    expect('remembered booting or offline emulator Stop targets serial plus AVD', emulator.calls.stop, {
      { avd_name = 'Pixel_8', serial = 'emulator-5554' },
    })
    expect('remembered booting or offline emulator Stop clears only the transient serial', session:device(), { avd_name = 'Pixel_8' })
  end

  do
    local session = new_session { serial = 'R58M321' }
    local running = { serial = 'emulator-5554', avd_name = 'Pixel_8', state = 'online', label = 'Pixel_8' }
    local adb = new_adb({
      { serial = 'R58M321', state = 'online', label = 'Galaxy S23' },
      { serial = 'emulator-5554', state = 'online', label = 'sdk_gphone64_arm64' },
    }, {
      R58M321 = { serial = 'R58M321', state = 'online', label = 'Galaxy S23' },
      ['emulator-5554'] = running,
    })
    local emulator = new_emulator { { avd_name = 'Pixel_8', label = 'Pixel_8' } }
    local picker = new_picker(function(request)
      expect('Stop from a physical selection offers only running AVDs', #request.items, 1)
      return request.items[1]
    end)
    local device = Device.new { adb = adb, emulator = emulator, picker = picker }
    local result
    device:stop(session, function(err, value) result = { err = err, value = value } end)
    expect('Stop can target the sole running AVD from a physical selection', result.err, nil)
    expect('explicit Stop opens the picker before targeting a sole running AVD', #picker.requests, 1)
    expect('Stop from a physical selection targets the exact running AVD', emulator.calls.stop, {
      { avd_name = 'Pixel_8', serial = 'emulator-5554' },
    })
    expect('Stop preserves an unrelated physical selection', session:device(), { serial = 'R58M321' })
  end

  do
    local session = new_session { avd_name = 'Pixel_8' }
    local start_callback
    local start_cancels = 0
    local adb = new_adb({}, {})
    local emulator = new_emulator {}
    function emulator:start(_, callback)
      start_callback = callback
      return {
        cancel = function()
          start_cancels = start_cancels + 1
          callback { code = 'cancelled', message = 'start cancelled' }
          return true
        end,
      }
    end
    local device = Device.new { adb = adb, emulator = emulator, picker = new_picker(function() end) }
    local completions = {}
    local handle = device:start(session, function(err, value) completions[#completions + 1] = { err = err, value = value } end)
    expect_true('pending Start owns a provider callback', start_callback ~= nil)
    expect('Start cancellation is accepted', handle:cancel(), true)
    expect('repeated Start cancellation is terminal', handle:cancel(), false)
    expect('Start cancellation reaches the leaf once', start_cancels, 1)
    expect('Start cancellation completes exactly once', #completions, 1)
    expect('Start cancellation is normalized', completions[1].err.code, 'cancelled')
    start_callback(nil, { serial = 'emulator-5554', avd_name = 'Pixel_8', state = 'online' })
    expect('late Start success is ignored', #completions, 1)
    expect('cancelled Start does not write a serial', session:device(), { avd_name = 'Pixel_8' })
  end

  do
    local session = new_session { avd_name = 'Pixel_8' }
    local start_callback
    local emulator = new_emulator {}
    function emulator:start(_, callback)
      start_callback = callback
      return noop_handle()
    end
    local device = Device.new { adb = new_adb({}, {}), emulator = emulator, picker = new_picker(function() end) }
    local result
    device:start(session, function(err, value) result = { err = err, value = value } end)
    session:replace_device { avd_name = 'Pixel_7' }
    start_callback(nil, { serial = 'emulator-5554', avd_name = 'Pixel_8', state = 'online' })
    expect('stale Start completion is rejected', result.err.code, 'device_changed')
    expect('stale Start does not overwrite a newer selection', session:device(), { avd_name = 'Pixel_7' })
  end

  do
    local session = new_session()
    local adb = new_adb({
      { serial = 'emulator-5554', state = 'online' },
      { serial = 'emulator-5556', state = 'online' },
    }, {
      ['emulator-5554'] = { serial = 'emulator-5554', state = 'online', avd_name = 'Pixel_8' },
      ['emulator-5556'] = { serial = 'emulator-5556', state = 'online', avd_name = 'Pixel_8' },
    })
    local device = Device.new { adb = adb, emulator = new_emulator { { avd_name = 'Pixel_8' } }, picker = new_picker(function() end) }
    local result
    device:select(session, function(err, value) result = { err = err, value = value } end)
    expect('duplicate running instances are rejected as ambiguous', result.err.code, 'emulator_ambiguous')
    expect('ambiguous inventory does not persist a device', session:device(), nil)
  end

  do
    local session = new_session()
    local picker = new_picker(function() return { id = 'avd:forged', avd_name = 'Forged' } end)
    local device = Device.new {
      adb = new_adb({}, {}),
      emulator = new_emulator { { avd_name = 'Pixel_7' }, { avd_name = 'Pixel_8' } },
      picker = picker,
    }
    local completions = 0
    local result
    device:select(session, function(err, value)
      completions = completions + 1
      result = { err = err, value = value }
    end)
    expect('unknown picker result is rejected', result.err.code, 'invalid_selection')
    expect('unknown picker result completes exactly once', completions, 1)
    expect('unknown picker result is not persisted', session:device(), nil)
  end

  do
    local session = new_session()
    local adb = {
      list_devices = function(_, callback)
        callback(nil, 'not-a-list')
        callback(nil, {})
        return noop_handle()
      end,
      validate_serial = function() error 'malformed listing must stop before validation' end,
    }
    local device = Device.new { adb = adb, emulator = new_emulator {}, picker = new_picker(function() end) }
    local completions = 0
    local result
    device:select(session, function(err, value)
      completions = completions + 1
      result = { err = err, value = value }
    end)
    expect('malformed ADB listing is rejected', result.err.code, 'invalid_devices_result')
    expect('duplicate malformed adapter callback is ignored', completions, 1)
  end

  do
    local session = new_session()
    local adb = {
      list_devices = function() return 42 end,
      validate_serial = function() error 'invalid list handle must terminate first' end,
    }
    local device = Device.new { adb = adb, emulator = new_emulator {}, picker = new_picker(function() end) }
    local completions = 0
    local result
    device:select(session, function(err, value)
      completions = completions + 1
      result = { err = err, value = value }
    end)
    expect('malformed asynchronous handle is rejected', result.err.code, 'invalid_operation_handle')
    expect('malformed asynchronous handle completes once', completions, 1)
  end
end, debug.traceback)

if not ok then fail('unexpected test error', unexpected) end

if #failures > 0 then
  vim.api.nvim_err_writeln('Android Workbench device validation failed:\n- ' .. table.concat(failures, '\n- '))
  vim.cmd 'cquit 1'
end

print 'Android Workbench device validation passed'
vim.cmd 'qa!'

-- vim: ts=2 sts=2 sw=2 et
