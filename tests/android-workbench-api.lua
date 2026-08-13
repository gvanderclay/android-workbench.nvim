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

local PortContracts = dofile(vim.fs.joinpath(vim.env.ANDROID_WORKBENCH_TEST_ROOT, 'tests', 'fixtures', 'port_contracts.lua'))

local function expect_contract(name, value, contract)
  local conforms, err = PortContracts.check(value, contract)
  expect(name .. ' is exact', err, nil)
  expect(name .. ' is complete', conforms, true)
end

local function action_ids(status)
  local ids = {}
  for _, action in ipairs(require('android_workbench.actions').available(status)) do
    ids[#ids + 1] = action.id
  end
  return ids
end

local function make_root()
  local root = vim.fn.tempname()
  assert(vim.fn.mkdir(root, 'p') == 1)
  assert(vim.fn.writefile({ '#!/bin/sh' }, vim.fs.joinpath(root, 'gradlew')) == 0)
  return assert(vim.uv.fs_realpath(root))
end

local root_one = make_root()
local root_two = make_root()
local root_three = make_root()
local root_four = make_root()
local root_five = make_root()
local root_six = make_root()
local notifications = {}
local state_by_root = {}
local state_loads = {}
local state_saves = {}
local trust_calls = {}
local discovery_calls = {}
local trusted = { [root_one] = true, [root_two] = false, [root_three] = true, [root_four] = true, [root_five] = true, [root_six] = true }
local pending_root
local provider_cancellations = 0
local runner_calls = {}
local runner_cancellations = 0
local runner_cancel_mode = 'accept'
local hold_runner = false
local pending_runner
local next_runner_result
local problem_batches = {}
local problem_publish_mode = 'success'
local adb_calls = {}
local adb_resolution_calls = 0
local next_launch_error
local emulator_calls = {}
local emulator_start_cancellations = 0
local hold_emulator_start = false
local pending_emulator_start
local logcat_calls = {}
local logcat_handles = {}
local logcat_shows = 0
local logcat_stops = 0
local logcat_abandons = 0
local current_avd_name = 'Pixel_8_API_35'
local avd_running = true
local hold_device_validation = false
local pending_device_validation
local validated_serial_override
local synchronous_device_validation = false
local validation_handle_cancels = 0
local snapshots_by_root = {}
local raw_snapshots_by_root = {}
local stale_roots = {}
local stale_checks_by_root = {}
local hold_picker = false
local picker_returns_nil = false
local pending_picker
local pending_discovery
local r4_controls = {}

local function complete_snapshot(root, targets, tasks)
  targets = vim.deepcopy(targets or {})
  tasks = vim.deepcopy(tasks or {})
  local application_projects = {}
  local task_ids = {}
  local known_projects = { [':'] = true }
  local seen_applications = {}

  for _, task in ipairs(tasks) do
    task_ids[task.id] = true
    known_projects[task.project_path] = true
  end
  for _, target in ipairs(targets) do
    target.project_id = target.project_id or target.project_path
    if not seen_applications[target.project_path] then
      seen_applications[target.project_path] = true
      application_projects[#application_projects + 1] = target.project_path
    end
    known_projects[target.project_path] = true
    for _, field in ipairs { 'assemble_task', 'install_task' } do
      local id = target[field]
      if id and not task_ids[id] then
        tasks[#tasks + 1] = {
          id = id,
          build_path = target.build_path,
          project_path = target.project_path,
          name = id:match '([^:]+)$',
        }
        task_ids[id] = true
      end
    end
  end

  local project_count = 0
  for _ in pairs(known_projects) do
    project_count = project_count + 1
  end
  return {
    schema_version = 1,
    root = root,
    builds = {
      {
        id = ':',
        build_path = ':',
        build_root = root,
        application_projects = application_projects,
        included_build_roots = {},
        project_count = project_count,
        task_count = #tasks,
      },
    },
    targets = targets,
    tasks = tasks,
  }
end

local function snapshot(root)
  if snapshots_by_root[root] then
    local configured = snapshots_by_root[root]
    return complete_snapshot(root, configured.targets, configured.tasks)
  end
  local targets = {
    {
      id = ':app#debug',
      project_id = ':app',
      build_path = ':',
      build_root = root,
      project_path = ':app',
      project_dir = vim.fs.joinpath(root, 'app'),
      variant = 'debug',
      application_id = 'example.app.debug',
      assemble_task = ':app:assembleDebug',
      install_task = ':app:installDebug',
    },
    {
      id = ':app#release',
      project_id = ':app',
      build_path = ':',
      build_root = root,
      project_path = ':app',
      project_dir = vim.fs.joinpath(root, 'app'),
      variant = 'release',
      application_id = 'example.app',
      assemble_task = ':app:assembleRelease',
      install_task = nil,
    },
  }
  return complete_snapshot(root, targets, {
    { id = ':help', build_path = ':', project_path = ':', name = 'help' },
    { id = ':app:assembleDebug', build_path = ':', project_path = ':app', name = 'assembleDebug' },
  })
end

local ports = {
  picker = {
    select = function(request, callback)
      if hold_picker then
        pending_picker = { request = request, callback = callback }
        if picker_returns_nil then return nil end
        return { cancel = function() return true end }
      end
      local item = request.items[1]
      vim.schedule(function() callback(nil, item) end)
      return { cancel = function() return true end }
    end,
  },
  trust = {
    authorize = function(root)
      trust_calls[root] = (trust_calls[root] or 0) + 1
      if trusted[root] then return true end
      return nil, { code = 'project_not_trusted', message = 'not trusted' }
    end,
  },
  notifications = {
    emit = function(event) notifications[#notifications + 1] = event end,
  },
  problems = {
    publish = function(batch)
      problem_batches[#problem_batches + 1] = vim.deepcopy(batch)
      if problem_publish_mode == 'throw' then error 'problem sink exploded' end
      if problem_publish_mode == 'return_error' then return nil, { code = 'problem_sink_failed', message = 'problem sink rejected the batch' } end
      return true
    end,
  },
  state = {
    load = function(root)
      state_loads[root] = (state_loads[root] or 0) + 1
      return vim.deepcopy(state_by_root[root])
    end,
    save = function(root, selection)
      state_saves[root] = (state_saves[root] or 0) + 1
      state_by_root[root] = vim.deepcopy(selection)
      return true
    end,
  },
  discovery = {
    discover = function(request, callback)
      discovery_calls[request.root] = (discovery_calls[request.root] or 0) + 1
      if request.root == pending_root then
        pending_discovery = { request = request, callback = callback }
        return {
          cancel = function()
            provider_cancellations = provider_cancellations + 1
            return true
          end,
        }
      end
      vim.schedule(function() callback(nil, raw_snapshots_by_root[request.root] or snapshot(request.root)) end)
      return { cancel = function() return true end }
    end,
    is_stale = function(current_snapshot)
      local root = current_snapshot.root
      stale_checks_by_root[root] = (stale_checks_by_root[root] or 0) + 1
      return stale_roots[root] == true
    end,
  },
  runner = {
    start = function(request, callback)
      runner_calls[#runner_calls + 1] = vim.deepcopy(request)
      if hold_runner then
        pending_runner = callback
      else
        local result = next_runner_result or { status = 'success', code = 0 }
        next_runner_result = nil
        vim.schedule(function() callback(nil, vim.deepcopy(result)) end)
      end
      return {
        cancel = function()
          runner_cancellations = runner_cancellations + 1
          if runner_cancel_mode == 'reject' then return false end
          if runner_cancel_mode == 'throw' then error 'runner cancellation exploded' end
          if runner_cancel_mode == 'error_callback' then
            callback { code = 'cancel_failed', message = 'runner could not terminate' }
            return true
          end
          if runner_cancel_mode == 'callback_then_false' then
            callback(nil, { status = 'cancelled', code = 143, signal = 15 })
            return false
          end
          return true
        end,
      }
    end,
  },
  adb = {
    resolve_executable = function()
      adb_resolution_calls = adb_resolution_calls + 1
      return '/sdk/platform-tools/adb'
    end,
    list_devices = function(_, callback)
      adb_calls[#adb_calls + 1] = { kind = 'list' }
      vim.schedule(function() callback(nil, avd_running and { { serial = 'emulator-5554', state = 'online', label = 'Pixel' } } or {}) end)
      return { cancel = function() return true end }
    end,
    validate_serial = function(_, serial, callback)
      adb_calls[#adb_calls + 1] = { kind = 'validate', serial = serial }
      local returned_serial = validated_serial_override or serial
      local function validated_device()
        local device = {
          serial = returned_serial,
          state = 'online',
          label = returned_serial:match '^emulator%-' and 'Pixel' or 'Galaxy S23',
        }
        if returned_serial:match '^emulator%-' then device.avd_name = current_avd_name end
        return device
      end
      if hold_device_validation then
        pending_device_validation = { serial = serial, callback = callback }
      elseif synchronous_device_validation then
        callback(nil, validated_device())
      else
        vim.schedule(function() callback(nil, validated_device()) end)
      end
      return {
        cancel = function()
          validation_handle_cancels = validation_handle_cancels + 1
          return true
        end,
      }
    end,
    resolve_launch_components = function(_, serial, application_id, callback)
      adb_calls[#adb_calls + 1] = { kind = 'resolve', serial = serial, application_id = application_id }
      vim.schedule(
        function() callback(nil, { { component = application_id .. '/.MainActivity', package = application_id, activity = application_id .. '.MainActivity' } }) end
      )
      return { cancel = function() return true end }
    end,
    launch = function(_, serial, application_id, component, callback)
      adb_calls[#adb_calls + 1] = { kind = 'launch', serial = serial, application_id = application_id, component = component }
      local launch_err = next_launch_error
      next_launch_error = nil
      vim.schedule(function()
        if launch_err then
          callback(launch_err)
          return
        end
        callback(nil, {
          serial = serial,
          application_id = application_id,
          component = component,
          status = 'ok',
        })
      end)
      return { cancel = function() return true end }
    end,
    stop = function(_, serial, application_id, callback)
      adb_calls[#adb_calls + 1] = { kind = 'stop', serial = serial, application_id = application_id }
      vim.schedule(function() callback(nil, { serial = serial, application_id = application_id }) end)
      return { cancel = function() return true end }
    end,
  },
  emulator = {
    list_avds = function(_, callback)
      emulator_calls[#emulator_calls + 1] = { kind = 'list' }
      vim.schedule(function() callback(nil, { { avd_name = current_avd_name, label = current_avd_name } }) end)
      return { cancel = function() return true end }
    end,
    start = function(_, avd_name, callback)
      emulator_calls[#emulator_calls + 1] = { kind = 'start', avd_name = avd_name }
      if hold_emulator_start then
        pending_emulator_start = { avd_name = avd_name, callback = callback }
        return {
          cancel = function()
            emulator_start_cancellations = emulator_start_cancellations + 1
            return true
          end,
        }
      end
      vim.schedule(function() callback(nil, { serial = 'emulator-5554', avd_name = avd_name, state = 'online', label = avd_name }) end)
      return { cancel = function() return true end }
    end,
    cold_boot = function(_, avd_name, callback)
      emulator_calls[#emulator_calls + 1] = { kind = 'cold_boot', avd_name = avd_name }
      vim.schedule(function() callback(nil, { serial = 'emulator-5554', avd_name = avd_name, state = 'online', label = avd_name }) end)
      return { cancel = function() return true end }
    end,
    stop = function(_, request, callback)
      emulator_calls[#emulator_calls + 1] = { kind = 'stop', request = vim.deepcopy(request) }
      vim.schedule(function() callback(nil, { serial = request.serial, avd_name = request.avd_name }) end)
      return { cancel = function() return true end }
    end,
  },
  logcat = {
    start = function(request)
      logcat_calls[#logcat_calls + 1] = request
      local stopped = false
      local handle = {}
      function handle:show()
        logcat_shows = logcat_shows + 1
        return true
      end
      function handle:stop()
        if stopped then return false end
        stopped = true
        logcat_stops = logcat_stops + 1
        vim.schedule(function() request.on_exit { status = 'stopped' } end)
        return true
      end
      function handle:_abandon() logcat_abandons = logcat_abandons + 1 end
      logcat_handles[#logcat_handles + 1] = handle
      return handle
    end,
  },
}

local ok, unexpected = xpcall(function()
  expect('Android command is registered', vim.fn.exists ':Android', 2)
  expect('command implementation stays lazy at startup', package.loaded['android_workbench.command'], nil)
  expect('application stays lazy at startup', package.loaded['android_workbench.app'], nil)

  local completion = vim.fn.getcompletion('Android t', 'cmdline')
  expect_true('static command completion includes target', vim.tbl_contains(completion, 'target'))
  expect_true('static command completion includes run', vim.tbl_contains(vim.fn.getcompletion('Android r', 'cmdline'), 'run'))
  expect_true('static command completion includes gradle', vim.tbl_contains(vim.fn.getcompletion('Android g', 'cmdline'), 'gradle'))
  expect_true('static command completion includes emulator', vim.tbl_contains(vim.fn.getcompletion('Android e', 'cmdline'), 'emulator'))
  expect_true('static command completion includes logcat', vim.tbl_contains(vim.fn.getcompletion('Android l', 'cmdline'), 'logcat'))
  expect_true('static command completion includes output', vim.tbl_contains(vim.fn.getcompletion('Android o', 'cmdline'), 'output'))
  expect_true('target completion includes device', vim.tbl_contains(vim.fn.getcompletion('Android target d', 'cmdline'), 'device'))
  expect_true('emulator completion includes start', vim.tbl_contains(vim.fn.getcompletion('Android emulator s', 'cmdline'), 'start'))
  expect_true('emulator completion includes stop', vim.tbl_contains(vim.fn.getcompletion('Android emulator s', 'cmdline'), 'stop'))
  expect_true('logcat completion includes sessions', vim.tbl_contains(vim.fn.getcompletion('Android logcat s', 'cmdline'), 'sessions'))
  expect_true('logcat completion includes stop', vim.tbl_contains(vim.fn.getcompletion('Android logcat s', 'cmdline'), 'stop'))
  expect_true('logcat stop completion includes all', vim.tbl_contains(vim.fn.getcompletion('Android logcat stop a', 'cmdline'), 'all'))
  expect('completion does not construct the application', package.loaded['android_workbench.app'], nil)

  for _, suffix in ipairs { 'm', 'b', 'r', 'g', 'l', 'e', 'M', 'v', 'd', 'E' } do
    expect(('library defines no <leader>i%s mapping'):format(suffix), next(vim.fn.maparg('<leader>i' .. suffix, 'n', false, true)), nil)
  end
  expect('library leaves the Android prefix unmapped', next(vim.fn.maparg('<leader>i', 'n', false, true)), nil)
  expect('Snacks adapter stays lazy by default', package.loaded['android_workbench.integrations.snacks'], nil)
  expect('Telescope adapter stays lazy by default', package.loaded['android_workbench.integrations.telescope'], nil)
  expect('Overseer adapter stays lazy by default', package.loaded['android_workbench.integrations.overseer'], nil)
  expect('diagnostic presenter stays opt-in', package.loaded['android_workbench.integrations.diagnostics'], nil)
  expect('default problem presenter stays lazy before the first action', package.loaded['android_workbench.integrations.quickfix'], nil)

  local android = require 'android_workbench'
  do
    local facade = vim.tbl_keys(android)
    table.sort(facade)
    expect('facade exposes only the supported pre-1.0 functions', facade, {
      'build',
      'cancel',
      'gradle_task',
      'is_project',
      'logcat',
      'manage_emulators',
      'open_actions',
      'refresh',
      'run',
      'select_logcat_session',
      'select_target',
      'setup',
      'show_status',
      'show_task_output',
      'shutdown',
      'start_emulator',
      'status',
      'stop',
      'stop_all_logcats',
      'stop_emulator',
      'stop_logcat',
    })
  end
  do
    local project_buffer = vim.api.nvim_create_buf(false, false)
    vim.api.nvim_buf_set_name(project_buffer, vim.fs.joinpath(root_one, 'app', 'src', 'Main.kt'))
    expect('project query accepts a path below a Gradle wrapper', android.is_project { path = vim.fs.joinpath(root_one, 'settings.gradle.kts') }, true)
    expect('project query accepts a named buffer below a Gradle wrapper', android.is_project { bufnr = project_buffer }, true)
    expect('project query rejects a path without a Gradle wrapper', android.is_project { path = vim.fn.tempname() }, false)
    expect('project query does not construct the application', package.loaded['android_workbench.app'], nil)
    expect('project query does not load private state', package.loaded['android_workbench.state'], nil)

    local valid_context, context_error = pcall(android.is_project, { unknown = true })
    expect('project query rejects an unknown context field', valid_context, false)
    expect_true('project query error names the field', tostring(context_error):find('context.unknown', 1, true))
    expect('invalid project query does not construct the application', package.loaded['android_workbench.app'], nil)
    vim.api.nvim_buf_delete(project_buffer, { force = true })
  end
  do
    local invalid_before_action, invalid_before_action_error = pcall(android.status, { unknown = true })
    expect('invalid context before the first action is rejected', invalid_before_action, false)
    expect_true('early invalid context names the field', tostring(invalid_before_action_error):find('context.unknown', 1, true))
    expect('invalid context does not construct the application', package.loaded['android_workbench.app'], nil)
    android.shutdown()
  end
  local valid, config_error = pcall(android.setup, { unknown = true })
  expect('unknown setup option is rejected', valid, false)
  expect_true('unknown setup error names the option', tostring(config_error):find('options.unknown', 1, true))

  valid, config_error = pcall(android.setup, { ports = { picker = {} } })
  expect('incomplete picker port is rejected', valid, false)
  expect_true('picker validation names missing method', tostring(config_error):find('ports.picker.select', 1, true))

  valid, config_error = pcall(android.setup, { ports = { logcat = {} } })
  expect('incomplete logcat port is rejected', valid, false)
  expect_true('logcat validation names missing method', tostring(config_error):find('ports.logcat.start', 1, true))

  valid, config_error = pcall(android.setup, { ports = { problems = {} } })
  expect('incomplete problem port is rejected', valid, false)
  expect_true('problem validation names missing method', tostring(config_error):find('ports.problems.publish', 1, true))

  valid, config_error = pcall(android.setup, { ports = { emulator = { list_avds = function() end, start = function() end } } })
  expect('incomplete emulator port is rejected', valid, false)
  expect_true('emulator validation names missing method', tostring(config_error):find('ports.emulator.stop', 1, true))

  valid, config_error = pcall(android.setup, {
    ports = { emulator = { list_avds = function() end, start = function() end, stop = function() end } },
  })
  expect('custom emulator without optional Cold Boot remains valid', valid, true)

  valid, config_error = pcall(android.setup, { logcat = { open_on_run = 'yes' } })
  expect('invalid open-on-run option is rejected', valid, false)
  expect_true('open-on-run validation names option', tostring(config_error):find('logcat.open_on_run', 1, true))

  valid, config_error = pcall(android.setup, { problems = {} })
  expect('top-level problem presentation policy is rejected', valid, false)
  expect_true('problem presentation policy routes through the port', tostring(config_error):find('options.problems', 1, true))

  valid, config_error = pcall(android.setup, { run = { start_stopped_avd = 'yes' } })
  expect('invalid Run auto-start option is rejected', valid, false)
  expect_true('Run auto-start validation names option', tostring(config_error):find('run.start_stopped_avd', 1, true))

  for _, case in ipairs {
    { options = { emulator = { boot_timeout_ms = 0 } }, path = 'emulator.boot_timeout_ms' },
    { options = { emulator = { boot_timeout_ms = 1.5 } }, path = 'emulator.boot_timeout_ms' },
    { options = { emulator = { poll_interval_ms = math.huge } }, path = 'emulator.poll_interval_ms' },
  } do
    valid, config_error = pcall(android.setup, case.options)
    expect(case.path .. ' rejects an unbounded value', valid, false)
    expect_true(case.path .. ' validation names option', tostring(config_error):find(case.path, 1, true))
  end

  expect('setup exposes no private configuration result', android.setup {}, nil)
  local default_config = require('android_workbench.config').get()
  expect('Run auto-start defaults on', default_config.run.start_stopped_avd, true)
  expect('default config exposes no top-level problem presentation policy', default_config.problems, nil)
  expect('emulator boot timeout default', default_config.emulator.boot_timeout_ms, 180000)
  expect('emulator poll interval default', default_config.emulator.poll_interval_ms, 1000)
  default_config.run.start_stopped_avd = false
  expect('retrieved config cannot mutate stored Run policy', require('android_workbench.config').get().run.start_stopped_avd, true)

  expect(
    'configured setup exposes no private configuration result',
    android.setup {
      ports = { emulator = ports.emulator, problems = ports.problems },
      run = { start_stopped_avd = false },
      emulator = { boot_timeout_ms = 90000, poll_interval_ms = 250 },
    },
    nil
  )
  local configured = require('android_workbench.config').get()
  expect('custom emulator port is retained', configured.ports.emulator, ports.emulator)
  expect('custom problem presenter is retained as a port', configured.ports.problems, ports.problems)
  expect('Run auto-start can be disabled', configured.run.start_stopped_avd, false)
  expect('emulator boot timeout is configurable', configured.emulator.boot_timeout_ms, 90000)
  expect('emulator poll interval is configurable', configured.emulator.poll_interval_ms, 250)

  local remote_adb = vim.tbl_extend('force', {}, ports.adb)
  remote_adb.resolve_executable = nil
  valid, config_error = pcall(android.setup, { ports = { adb = remote_adb, logcat = ports.logcat } })
  expect('custom Logcat permits an adb adapter without a local executable', valid, true)
  valid, config_error = pcall(android.setup, { ports = { adb = remote_adb } })
  expect('native Logcat requires an adb resolver', valid, false)
  expect_true('native Logcat validation names the resolver', tostring(config_error):find('ports.adb.resolve_executable', 1, true))

  local replacement_starts = 0
  local replacement_app = require('android_workbench.app').new {
    ports = {
      adb = ports.adb,
      emulator = ports.emulator,
      problems = ports.problems,
      logcat = {
        start = function()
          replacement_starts = replacement_starts + 1
          return { show = function() return true end, stop = function() return true end }
        end,
      },
    },
  }
  local old_stops = 0
  local old_entry = {
    identity = 'old-stream',
    selected = 1,
    handle = {
      show = function() return true end,
      stop = function()
        old_stops = old_stops + 1
        return false
      end,
    },
  }
  local replacement_registry = replacement_app:_logcat_registry(root_one, true)
  replacement_registry.entries[old_entry.identity] = old_entry
  replacement_registry.current = old_entry.identity
  replacement_registry.sequence = 1
  local replacement_error
  replacement_app:_open_logcat(
    { root = root_one },
    { id = ':app#debug', application_id = 'example.app.debug', project_dir = root_one, variant = 'debug' },
    { serial = 'physical-device' },
    true,
    function(err) replacement_error = err end
  )
  expect('a sibling presenter starts without replacing the current stream', replacement_error, nil)
  expect('a sibling presenter starts exactly once', replacement_starts, 1)
  expect('a sibling presenter never stops the previous stream', old_stops, 0)
  expect('a sibling presenter retains the previous stream', replacement_registry.entries[old_entry.identity], old_entry)
  replacement_app:shutdown()

  local native_runner_calls = {}
  local native_runner = require('android_workbench.runner').new {
    schedule = function(callback) callback() end,
    system = function(_, options, on_exit)
      native_runner_calls[#native_runner_calls + 1] = { options = options, on_exit = on_exit }
      return { kill = function() return true end }
    end,
  }
  local native_ports = {}
  for name, port in pairs(ports) do
    native_ports[name] = port
  end
  native_ports.runner = native_runner
  local native_problem_batches = {}
  native_ports.problems = {
    publish = function(batch)
      native_problem_batches[#native_problem_batches + 1] = vim.deepcopy(batch)
      return true
    end,
  }
  native_ports.notifications = { emit = function() end }
  native_ports.trust = { authorize = function() return true end }
  native_ports.state = {
    load = function()
      return {
        app = { build_path = ':', project_path = ':app' },
        variant = 'debug',
      }
    end,
    save = function() return true end,
  }
  native_ports.discovery = {
    discover = function(_, callback)
      vim.schedule(function() callback(nil, snapshot(root_five)) end)
      return { cancel = function() return true end }
    end,
    is_stale = function() return false end,
  }
  local native_output_app = require('android_workbench.app').new { ports = native_ports }
  local shown, output_err = native_output_app:show_task_output { root = root_five }
  expect('native output reports an empty root clearly', shown, nil)
  expect('native output reports no prior task', output_err.code, 'no_task_output')
  local native_build
  native_output_app:build({ root = root_five }, function(err, result) native_build = { err = err, result = result } end)
  expect_true('native App build reaches the runner', vim.wait(1000, function() return native_runner_calls[1] ~= nil end, 10))
  local source_path = vim.fs.joinpath(root_five, 'app/src/Main.java')
  native_runner_calls[1].options.stdout(nil, source_path .. ':12: error: cannot find symbol\n')
  native_runner_calls[1].options.stderr(nil, 'Could not resolve dependency com.example:missing:1')
  native_runner_calls[1].on_exit { code = 1, signal = 0 }
  expect_true('native App build reaches its terminal', vim.wait(1000, function() return native_build ~= nil end, 10))
  expect('native App preserves the Gradle failure', native_build.err.code, 'build_failed')
  expect('recognized native output still reaches the configured problem sink', native_problem_batches[1], {
    root = root_five,
    kind = 'build',
    name = 'Android build :app · debug',
    status = 'failure',
    items = {
      {
        path = source_path,
        line = 12,
        message = 'cannot find symbol',
        severity = 'error',
      },
    },
    truncated = false,
  })
  expect('native task output becomes visible in root status', assert(native_output_app:status { root = root_five }).task_output, true)
  local native_output_buf
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(bufnr) and vim.bo[bufnr].filetype == 'androidtaskoutput' then native_output_buf = bufnr end
  end
  local native_output_win = native_output_buf and vim.fn.bufwinid(native_output_buf) or -1
  if native_output_buf then
    expect_true(
      'locationless native failure remains in complete task output',
      table.concat(vim.api.nvim_buf_get_lines(native_output_buf, 0, -1, false), '\n'):find('Could not resolve dependency', 1, true) ~= nil
    )
  end
  if native_output_win ~= -1 then vim.api.nvim_win_close(native_output_win, true) end
  expect('App reopens the latest native root output', native_output_app:show_task_output { root = root_five }, true)
  expect('App reopens only the native output buffer', vim.api.nvim_get_current_buf(), native_output_buf)
  native_output_app:shutdown()
  expect('App shutdown clears native task output ownership', native_runner._has_output(root_five), false)

  local custom_output_app = require('android_workbench.app').new { ports = ports }
  shown, output_err = custom_output_app:show_task_output { root = root_five }
  expect('custom runner output is not taken over', shown, nil)
  expect('custom runner keeps output ownership', output_err.code, 'task_output_unavailable')
  custom_output_app:shutdown()

  android.setup { ports = ports, logcat = { open_on_run = true } }
  expect('setup performs no trust check', next(trust_calls), nil)
  expect('setup performs no discovery', next(discovery_calls), nil)
  expect('setup performs no adb work', #adb_calls, 0)
  expect('setup performs no emulator work', #emulator_calls, 0)
  expect('custom problem presenter receives no setup-time batch', #problem_batches, 0)

  expect(
    'idle palette actions',
    action_ids {
      operation = nil,
      logcat = 'stopped',
      selection = {},
    },
    { 'build', 'run', 'gradle_task', 'manage_emulators', 'start_emulator', 'open_logcat', 'select_app', 'select_device', 'refresh', 'status' }
  )
  expect(
    'selected palette actions',
    action_ids {
      operation = nil,
      logcat = 'running',
      selection = { app = {}, variant = 'debug', device = { serial = 'emulator-5554', avd_name = current_avd_name } },
    },
    {
      'build',
      'run',
      'gradle_task',
      'stop',
      'manage_emulators',
      'start_emulator',
      'stop_emulator',
      'show_logcat',
      'select_logcat_session',
      'stop_logcat',
      'stop_all_logcats',
      'select_app',
      'select_variant',
      'select_device',
      'refresh',
      'status',
    }
  )
  expect(
    'stopped AVD palette actions',
    action_ids {
      operation = nil,
      logcat = 'stopped',
      selection = { app = {}, variant = 'debug', device = { avd_name = current_avd_name } },
    },
    { 'build', 'run', 'gradle_task', 'manage_emulators', 'start_emulator', 'open_logcat', 'select_app', 'select_variant', 'select_device', 'refresh', 'status' }
  )
  expect(
    'active build palette actions',
    action_ids {
      operation = 'build',
      logcat = 'running',
      selection = { app = {}, variant = 'debug', device = {} },
    },
    { 'cancel_build', 'show_logcat', 'select_logcat_session', 'stop_logcat', 'stop_all_logcats', 'status' }
  )
  expect(
    'active run palette actions',
    action_ids {
      operation = 'run',
      logcat = 'stopped',
      selection = { app = {}, variant = 'debug', device = {} },
    },
    { 'cancel_run', 'open_logcat', 'status' }
  )
  expect(
    'active Gradle-task palette actions',
    action_ids {
      operation = 'gradle_task',
      logcat = 'stopped',
      selection = {},
    },
    { 'cancel_gradle_task', 'open_logcat', 'status' }
  )
  expect(
    'starting Logcat palette actions',
    action_ids {
      operation = 'stop',
      logcat = 'starting',
      selection = { app = {}, variant = 'debug', device = {} },
    },
    { 'cancel_stop', 'stop_logcat', 'status' }
  )
  expect(
    'active emulator-manager palette actions',
    action_ids {
      operation = 'emulator_manage',
      logcat = 'stopped',
      selection = {},
    },
    { 'cancel_emulator_manage', 'open_logcat', 'status' }
  )
  expect(
    'active emulator-cold-boot palette actions',
    action_ids {
      operation = 'emulator_cold_boot',
      logcat = 'stopped',
      selection = {},
    },
    { 'cancel_emulator_cold_boot', 'open_logcat', 'status' }
  )
  expect(
    'active emulator-start palette actions',
    action_ids {
      operation = 'emulator_start',
      logcat = 'stopped',
      selection = { device = { avd_name = current_avd_name } },
    },
    { 'cancel_emulator_start', 'open_logcat', 'status' }
  )
  expect(
    'active emulator-stop palette actions',
    action_ids {
      operation = 'emulator_stop',
      logcat = 'running',
      selection = { device = { serial = 'emulator-5554', avd_name = current_avd_name } },
    },
    { 'cancel_emulator_stop', 'show_logcat', 'select_logcat_session', 'stop_logcat', 'stop_all_logcats', 'status' }
  )
  local available_actions = require('android_workbench.actions').available { logcat = 'stopped', selection = {} }
  expect('picker items hide registry predicates', available_actions[1].predicate, nil)
  available_actions[1].argv[1] = 'changed'
  expect(
    'picker items cannot mutate registry argv',
    require('android_workbench.actions').available({ logcat = 'stopped', selection = {} })[1].argv,
    { 'build' }
  )
  expect_true(
    'latest native task output is discoverable in the action palette',
    vim.tbl_contains(action_ids { logcat = 'stopped', task_output = true, selection = {} }, 'show_task_output')
  )

  local command = require 'android_workbench.command'
  local original_execute = command.execute
  local original_start_emulator = android.start_emulator
  local original_stop_emulator = android.stop_emulator
  local original_gradle_task = android.gradle_task
  local original_show_task_output = android.show_task_output
  local emulator_command_calls = {
    original_manage_emulators = android.manage_emulators,
    original_select_logcat_session = android.select_logcat_session,
    original_stop_logcat = android.stop_logcat,
    original_stop_all_logcats = android.stop_all_logcats,
  }
  android.start_emulator = function(captured_context) emulator_command_calls[#emulator_command_calls + 1] = { action = 'start', context = captured_context } end
  android.stop_emulator = function(captured_context) emulator_command_calls[#emulator_command_calls + 1] = { action = 'stop', context = captured_context } end
  android.manage_emulators = function(captured_context) emulator_command_calls[#emulator_command_calls + 1] = { action = 'manage', context = captured_context } end
  android.gradle_task = function(captured_context) emulator_command_calls[#emulator_command_calls + 1] = { action = 'gradle', context = captured_context } end
  android.show_task_output = function(captured_context) emulator_command_calls[#emulator_command_calls + 1] = { action = 'output', context = captured_context } end
  android.select_logcat_session = function(captured_context)
    emulator_command_calls[#emulator_command_calls + 1] = { action = 'logcat_sessions', context = captured_context }
  end
  android.stop_logcat = function(captured_context) emulator_command_calls[#emulator_command_calls + 1] = { action = 'logcat_stop', context = captured_context } end
  android.stop_all_logcats = function(captured_context)
    emulator_command_calls[#emulator_command_calls + 1] = { action = 'logcat_stop_all', context = captured_context }
  end
  local command_context = { root = root_one, path = '/captured/android/source.kt', bufnr = 37 }
  expect('bare emulator command dispatches', original_execute({ 'emulator' }, command_context), true)
  expect('bare emulator command uses manager facade', emulator_command_calls[1], { action = 'manage', context = command_context })
  expect('emulator start command dispatches', original_execute({ 'emulator', 'start' }, command_context), true)
  expect('emulator start command uses facade', emulator_command_calls[2], { action = 'start', context = command_context })
  expect('emulator stop command dispatches', original_execute({ 'emulator', 'stop' }, command_context), true)
  expect('emulator stop command uses facade', emulator_command_calls[3], { action = 'stop', context = command_context })
  expect('Gradle command dispatches', original_execute({ 'gradle' }, command_context), true)
  expect('Gradle command uses facade', emulator_command_calls[4], { action = 'gradle', context = command_context })
  do
    local invalid_notifications = #notifications
    expect('Gradle command rejects raw arguments', original_execute({ 'gradle', '--info' }, command_context), false)
    expect('invalid command still uses the configured notification port', notifications[invalid_notifications + 1].code, 'invalid_command')
  end
  expect('output command dispatches', original_execute({ 'output' }, command_context), true)
  expect('output command uses facade', emulator_command_calls[5], { action = 'output', context = command_context })
  expect('Logcat sessions command dispatches', original_execute({ 'logcat', 'sessions' }, command_context), true)
  expect('Logcat sessions command uses facade', emulator_command_calls[6], { action = 'logcat_sessions', context = command_context })
  expect('Logcat current stop command dispatches', original_execute({ 'logcat', 'stop' }, command_context), true)
  expect('Logcat current stop command uses facade', emulator_command_calls[7], { action = 'logcat_stop', context = command_context })
  expect('Logcat stop-all command dispatches', original_execute({ 'logcat', 'stop', 'all' }, command_context), true)
  expect('Logcat stop-all command uses facade', emulator_command_calls[8], { action = 'logcat_stop_all', context = command_context })
  do
    local invalid_notifications = #notifications
    expect('Logcat stop rejects unknown actions', original_execute({ 'logcat', 'stop', 'later' }, command_context), false)
    expect('invalid Logcat command uses the configured notification port', notifications[invalid_notifications + 1].code, 'invalid_command')
  end
  android.start_emulator = original_start_emulator
  android.stop_emulator = original_stop_emulator
  android.manage_emulators = emulator_command_calls.original_manage_emulators
  android.gradle_task = original_gradle_task
  android.show_task_output = original_show_task_output
  android.select_logcat_session = emulator_command_calls.original_select_logcat_session
  android.stop_logcat = emulator_command_calls.original_stop_logcat
  android.stop_all_logcats = emulator_command_calls.original_stop_all_logcats
  do
    command.execute = function() error 'command exploded' end
    local failed_command_notifications = #notifications
    vim.cmd.Android()
    expect('command failures still use the configured notification port', notifications[failed_command_notifications + 1].code, 'command_failed')
    command.execute = original_execute
  end
  expect('emulator start facade is public', type(android.start_emulator), 'function')
  expect('emulator stop facade is public', type(android.stop_emulator), 'function')
  expect('emulator manager facade is public', type(android.manage_emulators), 'function')
  expect('Gradle-task facade is public', type(android.gradle_task), 'function')
  expect('task-output facade is public', type(android.show_task_output), 'function')
  expect('Logcat-session facade is public', type(android.select_logcat_session), 'function')
  expect('Logcat stop-all facade is public', type(android.stop_all_logcats), 'function')
  hold_picker = true
  pending_picker = nil
  local notification_count = #notifications
  local palette_handle = android.open_actions { root = root_one, path = '/captured/android/source.kt', bufnr = 37 }
  expect_true('action palette opens configured picker', pending_picker ~= nil)
  expect('action palette prompt', pending_picker.request.prompt, 'Android')
  expect_contract('supported picker request contract', pending_picker.request, PortContracts.picker_request)
  expect('action palette opening performs no trust check', next(trust_calls), nil)
  expect('action palette opening performs no discovery', next(discovery_calls), nil)
  expect('action palette opening performs no adb work', #adb_calls, 0)
  expect('action palette opening performs no emulator work', #emulator_calls, 0)
  expect('action palette opening performs no runner work', #runner_calls, 0)
  expect('action palette opening performs no logcat work', #logcat_calls, 0)
  expect('action palette cancellation succeeds', palette_handle.cancel(), true)
  expect('action palette cancellation is quiet', #notifications, notification_count)

  local dispatched
  command.execute = function(argv, captured_context)
    dispatched = { argv = argv, context = captured_context }
    return true
  end
  pending_picker = nil
  expect('bare command opens action palette', original_execute({}, { root = root_one, path = '/captured/android/source.kt', bufnr = 37 }), true)
  expect_true('bare command reaches configured picker', pending_picker ~= nil)
  local selected_action
  for _, action in ipairs(pending_picker.request.items) do
    if action.id == 'build' then selected_action = action end
  end
  pending_picker.callback(nil, selected_action)
  expect('palette dispatch waits for picker close', dispatched, nil)
  expect_true('selected palette action dispatches', vim.wait(1000, function() return dispatched ~= nil end, 10))
  command.execute = original_execute
  expect('palette dispatch uses canonical argv', dispatched.argv, { 'build' })
  expect('palette dispatch preserves canonical root', dispatched.context.root, root_one)
  expect('palette dispatch preserves captured path', dispatched.context.path, '/captured/android/source.kt')
  expect('palette dispatch preserves captured buffer', dispatched.context.bufnr, 37)
  hold_picker = false
  pending_picker = nil

  do
    hold_picker = true
    local adb_calls_before_manager = #adb_calls
    local emulator_calls_before_manager = #emulator_calls
    local notifications_before_manager = #notifications
    local manager_result
    local manager_state_saves = state_saves[root_one] or 0
    local manager_handle = android.manage_emulators({ root = root_one }, function(err, result) manager_result = { err = err, result = result } end)
    expect_true('emulator manager returns a cancel handle', type(manager_handle) == 'table' and type(manager_handle.cancel) == 'function')
    expect_true('emulator manager reaches the AVD picker', vim.wait(1000, function() return pending_picker ~= nil end, 10))
    local avd_picker = pending_picker
    expect('emulator manager AVD prompt', avd_picker.request.prompt, 'Android emulator')
    expect('emulator manager lists running state', avd_picker.request.format_item(avd_picker.request.items[1]), 'Pixel_8_API_35 (running: emulator-5554)')
    pending_picker = nil
    avd_picker.callback(nil, avd_picker.request.items[1])
    expect_true('emulator manager reaches the contextual action picker', vim.wait(1000, function() return pending_picker ~= nil end, 10))
    local manager_action_picker = pending_picker
    expect('running emulator action prompt', manager_action_picker.request.prompt, 'Pixel_8_API_35')
    expect('running emulator offers only Stop', manager_action_picker.request.items, { { id = 'stop', label = 'Stop' } })
    manager_action_picker.callback(nil, manager_action_picker.request.items[1])
    expect_true('emulator manager Stop reaches its terminal', vim.wait(1000, function() return manager_result ~= nil end, 10))
    expect('emulator manager Stop succeeds', manager_result.err, nil)
    expect('emulator manager reports the exact stopped AVD', manager_result.result, {
      kind = 'emulator_stop',
      device = { avd_name = 'Pixel_8_API_35', state = 'stopped', label = 'Pixel_8_API_35' },
    })
    expect('emulator manager does not change project device selection', state_saves[root_one] or 0, manager_state_saves)

    avd_running = false
    manager_result = nil
    pending_picker = nil
    android.manage_emulators({ root = root_one }, function(err, result) manager_result = { err = err, result = result } end)
    expect_true('emulator manager reaches the stopped AVD picker', vim.wait(1000, function() return pending_picker ~= nil end, 10))
    avd_picker = pending_picker
    expect('emulator manager lists stopped state', avd_picker.request.format_item(avd_picker.request.items[1]), 'Pixel_8_API_35 (stopped)')
    pending_picker = nil
    avd_picker.callback(nil, avd_picker.request.items[1])
    expect_true('stopped emulator reaches the contextual action picker', vim.wait(1000, function() return pending_picker ~= nil end, 10))
    manager_action_picker = pending_picker
    expect('stopped emulator offers Start and Cold Boot', manager_action_picker.request.items, {
      { id = 'start', label = 'Start' },
      { id = 'cold_boot', label = 'Cold Boot' },
    })
    manager_action_picker.callback(nil, manager_action_picker.request.items[1])
    expect_true('emulator manager Start reaches its terminal', vim.wait(1000, function() return manager_result ~= nil end, 10))
    expect('emulator manager Start succeeds', manager_result.err, nil)
    expect('emulator manager reports the exact started AVD', manager_result.result, {
      kind = 'emulator_start',
      device = { serial = 'emulator-5554', avd_name = 'Pixel_8_API_35', state = 'online', label = 'Pixel_8_API_35' },
    })
    expect('emulator manager Start does not change project device selection', state_saves[root_one] or 0, manager_state_saves)

    manager_result = nil
    pending_picker = nil
    android.manage_emulators({ root = root_one }, function(err, result) manager_result = { err = err, result = result } end)
    expect_true('emulator manager reaches the stopped AVD picker before Cold Boot', vim.wait(1000, function() return pending_picker ~= nil end, 10))
    avd_picker = pending_picker
    pending_picker = nil
    avd_picker.callback(nil, avd_picker.request.items[1])
    expect_true('stopped emulator reaches the Cold Boot action', vim.wait(1000, function() return pending_picker ~= nil end, 10))
    manager_action_picker = pending_picker
    manager_action_picker.callback(nil, manager_action_picker.request.items[2])
    expect_true('emulator manager Cold Boot reaches its terminal', vim.wait(1000, function() return manager_result ~= nil end, 10))
    expect('emulator manager Cold Boot succeeds', manager_result.err, nil)
    expect('emulator manager reports the exact cold-booted AVD', manager_result.result, {
      kind = 'emulator_cold_boot',
      device = { serial = 'emulator-5554', avd_name = 'Pixel_8_API_35', state = 'online', label = 'Pixel_8_API_35' },
    })
    expect('emulator manager Cold Boot uses its port capability', emulator_calls[#emulator_calls], {
      kind = 'cold_boot',
      avd_name = 'Pixel_8_API_35',
    })
    expect('emulator manager Cold Boot does not change project device selection', state_saves[root_one] or 0, manager_state_saves)

    local cold_boot = ports.emulator.cold_boot
    ports.emulator.cold_boot = nil
    manager_result = nil
    pending_picker = nil
    android.manage_emulators({ root = root_one }, function(err, result) manager_result = { err = err, result = result } end)
    expect_true('manager with a basic custom emulator reaches the AVD picker', vim.wait(1000, function() return pending_picker ~= nil end, 10))
    avd_picker = pending_picker
    pending_picker = nil
    avd_picker.callback(nil, avd_picker.request.items[1])
    expect_true('basic custom emulator reaches the action picker', vim.wait(1000, function() return pending_picker ~= nil end, 10))
    manager_action_picker = pending_picker
    manager_action_picker.callback(nil, nil)
    ports.emulator.cold_boot = cold_boot
    expect('basic custom emulator omits optional Cold Boot', manager_action_picker.request.items, { { id = 'start', label = 'Start' } })
    expect_true('basic custom emulator action dismissal reaches its terminal', vim.wait(1000, function() return manager_result ~= nil end, 10))
    expect('basic custom emulator action dismissal is quiet', manager_result, { err = nil, result = nil })

    avd_running = true
    manager_result = nil
    pending_picker = nil
    android.manage_emulators({ root = root_one }, function(err, result) manager_result = { err = err, result = result } end)
    expect_true('emulator manager reaches the picker before forged selection', vim.wait(1000, function() return pending_picker ~= nil end, 10))
    local forged_picker = pending_picker
    local emulator_calls_before_forged_selection = #emulator_calls
    forged_picker.callback(nil, { id = 'avd:forged' })
    expect_true('forged emulator selection reaches its terminal', vim.wait(1000, function() return manager_result ~= nil end, 10))
    expect('forged emulator selection is rejected', manager_result.err.code, 'invalid_selection')
    expect('forged emulator selection starts no emulator action', #emulator_calls, emulator_calls_before_forged_selection)

    manager_result = nil
    pending_picker = nil
    android.manage_emulators({ root = root_one }, function(err, result) manager_result = { err = err, result = result } end)
    expect_true('emulator manager reaches the picker before forged action', vim.wait(1000, function() return pending_picker ~= nil end, 10))
    avd_picker = pending_picker
    pending_picker = nil
    avd_picker.callback(nil, avd_picker.request.items[1])
    expect_true('emulator manager reaches the action picker before forged action', vim.wait(1000, function() return pending_picker ~= nil end, 10))
    local emulator_calls_before_forged_action = #emulator_calls
    pending_picker.callback(nil, { id = 'delete' })
    expect_true('forged emulator action reaches its terminal', vim.wait(1000, function() return manager_result ~= nil end, 10))
    expect('forged emulator action is rejected', manager_result.err.code, 'invalid_selection')
    expect('forged emulator action starts no emulator action', #emulator_calls, emulator_calls_before_forged_action)

    manager_result = nil
    pending_picker = nil
    local cancelled_manager = android.manage_emulators({ root = root_one }, function(err, result) manager_result = { err = err, result = result } end)
    expect_true('emulator manager reaches the picker before cancellation', vim.wait(1000, function() return pending_picker ~= nil end, 10))
    local cancelled_picker = pending_picker
    expect('emulator manager owns the active root slot', assert(android.status { root = root_one }).operation, 'emulator_manage')
    expect('emulator manager cancellation is accepted', cancelled_manager.cancel(), true)
    cancelled_picker.callback { code = 'cancelled', message = 'picker cancelled' }
    expect_true('cancelled emulator manager reaches its terminal', vim.wait(1000, function() return manager_result ~= nil end, 10))
    expect('emulator manager cancellation is classified', manager_result.err.code, 'cancelled')
    expect('emulator manager cancellation releases the root slot', assert(android.status { root = root_one }).operation, nil)

    while #adb_calls > adb_calls_before_manager do
      table.remove(adb_calls)
    end
    while #emulator_calls > emulator_calls_before_manager do
      table.remove(emulator_calls)
    end
    while #notifications > notifications_before_manager do
      table.remove(notifications)
    end
    hold_picker = false
    pending_picker = nil
  end

  local task_notifications = {}
  local task_problem_batches = {}
  local task_picker_pending
  local task_runner_pending
  local task_runner_requests = {}
  local task_snapshots = {}
  local task_current_snapshot
  local task_events = {}
  local task_discovery_calls = 0
  local task_picker_cancellations = 0
  local task_runner_cancellations = 0
  local task_authorizations = 0
  local task_state_saves = 0
  local task_authorized = true

  local function gradle_task(id, build_path, project_path, name)
    return {
      id = id,
      build_path = build_path,
      project_path = project_path,
      name = name,
    }
  end

  local function gradle_snapshot(tasks)
    return {
      schema_version = 1,
      root = root_four,
      builds = {},
      targets = {},
      tasks = vim.deepcopy(tasks),
    }
  end

  local task_session = {
    root = root_four,
    wrapper = vim.fs.joinpath(root_four, 'gradlew'),
    discover = function(_, _, callback)
      task_discovery_calls = task_discovery_calls + 1
      task_events[#task_events + 1] = 'discover'
      local next_snapshot = table.remove(task_snapshots, 1)
      assert(next_snapshot ~= nil, 'Gradle-task test did not provide a discovery snapshot')
      vim.schedule(function()
        task_current_snapshot = next_snapshot
        callback(nil, next_snapshot)
      end)
      return { cancel = function() return true end }
    end,
    is_snapshot_current = function(_, candidate) return candidate == task_current_snapshot end,
    authorize = function()
      task_authorizations = task_authorizations + 1
      task_events[#task_events + 1] = 'authorize'
      if task_authorized then return true end
      return nil, { code = 'project_not_trusted', message = 'Gradle task execution was not authorized.' }
    end,
    status = function()
      return {
        root = root_four,
        wrapper = vim.fs.joinpath(root_four, 'gradlew'),
        phase = 'ready',
        authorized = task_authorized,
        selection = {},
        targets = 0,
      }
    end,
    close = function() end,
  }

  local task_app = require('android_workbench.app').new {
    ports = {
      picker = {
        select = function(request, callback)
          task_events[#task_events + 1] = 'picker'
          task_picker_pending = { request = request, callback = callback }
          return {
            cancel = function()
              task_picker_cancellations = task_picker_cancellations + 1
              return true
            end,
          }
        end,
      },
      runner = {
        start = function(request, callback)
          task_events[#task_events + 1] = 'runner'
          task_runner_requests[#task_runner_requests + 1] = vim.deepcopy(request)
          task_runner_pending = callback
          return {
            cancel = function()
              task_runner_cancellations = task_runner_cancellations + 1
              return true
            end,
          }
        end,
      },
      adb = ports.adb,
      emulator = ports.emulator,
      logcat = ports.logcat,
      discovery = { discover = function() error 'Gradle-task fixture must use its injected session' end },
      trust = ports.trust,
      problems = {
        publish = function(batch)
          task_events[#task_events + 1] = 'problems'
          task_problem_batches[#task_problem_batches + 1] = vim.deepcopy(batch)
          return true
        end,
      },
      state = {
        load = function() return nil end,
        save = function()
          task_state_saves = task_state_saves + 1
          return true
        end,
      },
      notifications = { emit = function(event) task_notifications[#task_notifications + 1] = vim.deepcopy(event) end },
    },
  }
  task_app.sessions[root_four] = task_session

  local function prepare_gradle_task_case(...)
    task_snapshots = { ... }
    task_current_snapshot = nil
    task_picker_pending = nil
    task_runner_pending = nil
    task_events = {}
  end

  local app_task = gradle_task(':app:lintDebug', ':', ':app', 'lintDebug')
  local root_task = gradle_task(':help', ':', ':', 'help')
  local adb_before_gradle_tasks = #adb_calls
  local emulator_before_gradle_tasks = #emulator_calls

  prepare_gradle_task_case(gradle_snapshot { root_task, app_task })
  local picker_cancelled
  local notices_before_picker_cancel = #task_notifications
  task_app:gradle_task({ root = root_four }, function(err, result) picker_cancelled = { err = err, result = result } end)
  expect_true('Gradle-task picker opens', vim.wait(1000, function() return task_picker_pending ~= nil end, 10))
  expect('Gradle-task picker prompt', task_picker_pending.request.prompt, 'Gradle task')
  expect('Gradle-task picker sorts exact ids', task_picker_pending.request.items, { app_task, root_task })
  expect('Gradle-task picker labels the exact qualified id', task_picker_pending.request.format_item(task_picker_pending.request.items[1]), app_task.id)
  task_picker_pending.callback(nil, nil)
  expect_true('Gradle-task picker cancellation completes', vim.wait(1000, function() return picker_cancelled ~= nil end, 10))
  expect('Gradle-task picker cancellation is not an error', picker_cancelled.err, nil)
  expect('Gradle-task picker cancellation returns no result', picker_cancelled.result, nil)
  expect('Gradle-task picker cancellation emits only loading feedback', #task_notifications, notices_before_picker_cancel + 1)
  expect('Gradle-task loading feedback', task_notifications[notices_before_picker_cancel + 1].message, 'Loading Gradle tasks…')

  prepare_gradle_task_case(gradle_snapshot { app_task })
  local root_cancelled_task
  task_app:gradle_task({ root = root_four }, function(err, result) root_cancelled_task = { err = err, result = result } end)
  expect_true('single Gradle task still opens a picker', vim.wait(1000, function() return task_picker_pending ~= nil end, 10))
  expect('Gradle-task picker owns the root operation slot', assert(task_app:status { root = root_four }).operation, 'gradle_task')
  local picker_cancellations_before_root_cancel = task_picker_cancellations
  expect('public app cancellation accepts Gradle-task picker cancellation', task_app:cancel { root = root_four }, true)
  expect('Gradle-task cancellation reaches the picker leaf', task_picker_cancellations, picker_cancellations_before_root_cancel + 1)
  expect('Gradle-task cancellation retains the root slot until terminal', assert(task_app:status { root = root_four }).operation, 'gradle_task')
  expect('Gradle-task cancellation waits for picker terminal', root_cancelled_task, nil)
  task_picker_pending.callback { code = 'cancelled', message = 'picker closed' }
  expect_true('Gradle-task root cancellation completes', vim.wait(1000, function() return root_cancelled_task ~= nil end, 10))
  expect('Gradle-task root cancellation stays classified', root_cancelled_task.err.code, 'cancelled')
  expect('Gradle-task root cancellation clears the slot', assert(task_app:status { root = root_four }).operation, nil)

  prepare_gradle_task_case(gradle_snapshot { app_task })
  local forged_task
  local discoveries_before_forgery = task_discovery_calls
  local authorizations_before_forgery = task_authorizations
  local runners_before_forgery = #task_runner_requests
  task_app:gradle_task({ root = root_four }, function(err, result) forged_task = { err = err, result = result } end)
  expect_true('forged Gradle-task fixture reaches picker', vim.wait(1000, function() return task_picker_pending ~= nil end, 10))
  task_picker_pending.callback(nil, setmetatable({ id = ':forged:task' }, { __index = function() error 'picker result must not invoke __index' end }))
  expect_true('forged Gradle-task selection completes', vim.wait(1000, function() return forged_task ~= nil end, 10))
  expect('forged Gradle-task id is rejected', forged_task.err.code, 'invalid_selection')
  expect('forged Gradle-task selection performs no second discovery', task_discovery_calls, discoveries_before_forgery + 1)
  expect('forged Gradle-task selection performs no execution trust check', task_authorizations, authorizations_before_forgery)
  expect('forged Gradle-task selection starts no runner', #task_runner_requests, runners_before_forgery)

  prepare_gradle_task_case(gradle_snapshot { app_task }, gradle_snapshot {})
  local stale_task
  local authorizations_before_stale_task = task_authorizations
  local runners_before_stale_task = #task_runner_requests
  task_app:gradle_task({ root = root_four }, function(err, result) stale_task = { err = err, result = result } end)
  expect_true('stale Gradle-task fixture reaches picker', vim.wait(1000, function() return task_picker_pending ~= nil end, 10))
  task_picker_pending.callback(nil, task_picker_pending.request.items[1])
  expect_true('disappeared Gradle task completes', vim.wait(1000, function() return stale_task ~= nil end, 10))
  expect('disappeared Gradle task is stale', stale_task.err.code, 'task_stale')
  expect('stale Gradle task is rejected before trust', task_authorizations, authorizations_before_stale_task)
  expect('stale Gradle task starts no runner', #task_runner_requests, runners_before_stale_task)

  local current_app_task = gradle_task(':app:lintDebug', ':', ':app', 'lintDebug')
  prepare_gradle_task_case(gradle_snapshot { root_task, app_task }, gradle_snapshot { current_app_task, root_task })
  local completed_task
  local notices_before_success = #task_notifications
  local authorizations_before_success = task_authorizations
  task_app:gradle_task({ root = root_four }, function(err, result) completed_task = { err = err, result = result } end)
  expect_true('Gradle-task execution fixture reaches picker', vim.wait(1000, function() return task_picker_pending ~= nil end, 10))
  local copied_choice = vim.deepcopy(task_picker_pending.request.items[1])
  copied_choice.build_path = ':forged'
  copied_choice.project_path = ':forged'
  copied_choice.name = 'forged'
  task_picker_pending.callback(nil, copied_choice)
  expect_true('selected Gradle task reaches runner', vim.wait(1000, function() return task_runner_pending ~= nil end, 10))
  expect('Gradle-task flow discovers, picks, rediscovers, authorizes, then runs', task_events, {
    'discover',
    'picker',
    'discover',
    'authorize',
    'runner',
  })
  expect('Gradle-task execution reauthorizes exactly once after selection', task_authorizations, authorizations_before_success + 1)
  expect('Gradle-task runner receives exact direct argv', task_runner_requests[#task_runner_requests].argv, {
    vim.fs.joinpath(root_four, 'gradlew'),
    '--console=plain',
    app_task.id,
  })
  expect('Gradle-task runner uses canonical root', task_runner_requests[#task_runner_requests].cwd, root_four)
  expect('Gradle-task picker fields cannot replace the canonical current DTO', task_runner_requests[#task_runner_requests].metadata, {
    kind = 'gradle_task',
    root = root_four,
    task_id = app_task.id,
    build_path = ':',
    project_path = ':app',
    task_name = 'lintDebug',
  })
  task_runner_pending(nil, { status = 'success', code = 0 })
  expect_true('Gradle-task execution completes', vim.wait(1000, function() return completed_task ~= nil end, 10))
  expect('Gradle-task execution succeeds', completed_task.err, nil)
  expect('Gradle-task result returns the current canonical task', completed_task.result.gradle_task, current_app_task)
  expect('successful Gradle task publishes a root-scoped clear batch', task_problem_batches[#task_problem_batches], {
    root = root_four,
    kind = 'gradle_task',
    name = 'Gradle task ' .. app_task.id,
    status = 'success',
    items = {},
    truncated = false,
  })
  expect('Gradle-task success loading feedback', task_notifications[notices_before_success + 1].message, 'Loading Gradle tasks…')
  expect('Gradle-task running feedback', task_notifications[notices_before_success + 2].message, 'Running Gradle task ' .. app_task.id .. '…')
  expect('Gradle-task completion feedback', task_notifications[notices_before_success + 3].message, 'Gradle task ' .. app_task.id .. ' completed.')

  prepare_gradle_task_case(gradle_snapshot { app_task }, gradle_snapshot { app_task })
  local cancelled_running_task
  local runner_cancellations_before_task_cancel = task_runner_cancellations
  local task_batches_before_cancel = #task_problem_batches
  task_app:gradle_task({ root = root_four }, function(err, result) cancelled_running_task = { err = err, result = result } end)
  expect_true('cancellable Gradle task reaches runner', vim.wait(1000, function() return task_picker_pending ~= nil end, 10))
  task_picker_pending.callback(nil, task_picker_pending.request.items[1])
  expect_true('cancellable Gradle task starts runner', vim.wait(1000, function() return task_runner_pending ~= nil end, 10))
  expect('running Gradle task owns the root operation slot', assert(task_app:status { root = root_four }).operation, 'gradle_task')
  expect('running Gradle-task cancellation is accepted', task_app:cancel { root = root_four }, true)
  expect('Gradle-task cancellation reaches runner', task_runner_cancellations, runner_cancellations_before_task_cancel + 1)
  expect('Gradle-task cancellation waits for runner terminal', cancelled_running_task, nil)
  task_runner_pending(nil, { status = 'cancelled', code = 143, signal = 15 })
  expect_true('cancelled running Gradle task completes', vim.wait(1000, function() return cancelled_running_task ~= nil end, 10))
  expect('cancelled running Gradle task stays classified', cancelled_running_task.err.code, 'cancelled')
  expect('cancelled Gradle task publishes no problem batch', #task_problem_batches, task_batches_before_cancel)
  expect('cancelled running Gradle task clears the root slot', assert(task_app:status { root = root_four }).operation, nil)

  prepare_gradle_task_case(gradle_snapshot { app_task }, gradle_snapshot { app_task })
  task_authorized = false
  local denied_task
  local runners_before_denied_task = #task_runner_requests
  local task_batches_before_denial = #task_problem_batches
  task_app:gradle_task({ root = root_four }, function(err, result) denied_task = { err = err, result = result } end)
  expect_true('trust-denied Gradle task reaches picker', vim.wait(1000, function() return task_picker_pending ~= nil end, 10))
  task_picker_pending.callback(nil, task_picker_pending.request.items[1])
  expect_true('trust-denied Gradle task completes', vim.wait(1000, function() return denied_task ~= nil end, 10))
  expect('Gradle-task trust denial remains primary', denied_task.err.code, 'project_not_trusted')
  expect('trust-denied Gradle task starts no runner', #task_runner_requests, runners_before_denied_task)
  expect('trust-denied Gradle task publishes no problem batch', #task_problem_batches, task_batches_before_denial)
  task_authorized = true

  prepare_gradle_task_case(gradle_snapshot {})
  local empty_tasks
  task_app:gradle_task({ root = root_four }, function(err, result) empty_tasks = { err = err, result = result } end)
  expect_true('empty Gradle-task inventory completes', vim.wait(1000, function() return empty_tasks ~= nil end, 10))
  expect('empty Gradle-task inventory is actionable', empty_tasks.err.code, 'no_gradle_tasks')
  expect_true('empty Gradle-task inventory names the root', empty_tasks.err.message:find(root_four, 1, true))

  expect('Gradle-task workflow performs no ADB work', #adb_calls, adb_before_gradle_tasks)
  expect('Gradle-task workflow performs no emulator work', #emulator_calls, emulator_before_gradle_tasks)
  expect('Gradle-task workflow never persists target or device state', task_state_saves, 0)
  task_app:shutdown()

  local initial = assert(android.status { root = root_one })
  expect('status resolves canonical root', initial.root, root_one)
  expect('status does not authorize project code', trust_calls[root_one], nil)
  expect('status does not discover targets', discovery_calls[root_one], nil)
  expect('status performs no adb work', #adb_calls, 0)
  expect('status performs no emulator work', #emulator_calls, 0)
  expect('state loads once for a root session', state_loads[root_one], 1)

  local refreshed
  android.refresh({ root = root_one }, function(err, status) refreshed = { err = err, status = status } end)
  expect_true('refresh completes', vim.wait(1000, function() return refreshed ~= nil end, 10))
  expect('refresh succeeds', refreshed.err, nil)
  expect('refresh authorizes once', trust_calls[root_one], 1)
  expect('refresh discovers once', discovery_calls[root_one], 1)
  expect('refresh publishes targets', refreshed.status.targets, 2)

  hold_picker = true
  for _, malformed in ipairs {
    false,
    42,
    setmetatable({}, { __index = function() error 'picker result must not invoke __index' end }),
  } do
    pending_picker = nil
    local malformed_selection
    android.select_target('app', { root = root_one }, function(err) malformed_selection = err end)
    expect_true('malformed app selection reaches picker', vim.wait(1000, function() return pending_picker ~= nil end, 10))
    pending_picker.callback(nil, malformed)
    expect_true('malformed app selection completes', vim.wait(1000, function() return malformed_selection ~= nil end, 10))
    expect('malformed app selection is rejected safely', malformed_selection.code, 'invalid_selection')
  end
  do
    pending_picker = nil
    local malformed_picker_terminal
    android.select_target('app', { root = root_one }, function(err, result) malformed_picker_terminal = { err = err, result = result } end)
    expect_true('malformed picker error reaches the adapter boundary', vim.wait(1000, function() return pending_picker ~= nil end, 10))
    pending_picker.callback { unexpected = 'private adapter data' }
    expect_true('malformed picker error completes', vim.wait(1000, function() return malformed_picker_terminal ~= nil end, 10))
    expect('malformed picker error gets a stable public code', malformed_picker_terminal.err.code, 'operation_failed')
    expect('malformed picker error gets a stable public message', malformed_picker_terminal.err.message, 'Android Workbench operation failed.')
    expect('failed public callback returns no result', malformed_picker_terminal.result, nil)
  end

  do
    pending_picker = nil
    local extended_picker_error
    android.select_target('app', { root = root_one }, function(err) extended_picker_error = err end)
    expect_true('extended picker error reaches the adapter boundary', vim.wait(1000, function() return pending_picker ~= nil end, 10))
    pending_picker.callback {
      code = 'picker_failed',
      message = 'The picker failed.',
      root = root_one,
      details = { reason = 'closed' },
      adapter_private = true,
    }
    expect_true('extended picker error completes', vim.wait(1000, function() return extended_picker_error ~= nil end, 10))
    expect('public errors expose only supported fields', extended_picker_error, {
      code = 'picker_failed',
      message = 'The picker failed.',
      root = root_one,
      details = { reason = 'closed' },
    })
  end

  pending_picker = nil
  local mutated_selection
  android.select_target('app', { root = root_one }, function(err) mutated_selection = err end)
  expect_true('mutating picker reaches app selection', vim.wait(1000, function() return pending_picker ~= nil end, 10))
  local mutated_item = pending_picker.request.items[1]
  mutated_item.project_path = ':picker-mutated'
  pending_picker.callback(nil, mutated_item)
  expect_true('mutated picker selection completes', vim.wait(1000, function() return mutated_selection ~= nil end, 10))
  expect('picker cannot mutate canonical candidates', mutated_selection.code, 'invalid_selection')
  hold_picker = false
  pending_picker = nil

  local selected_app
  android.select_target('app', { root = root_one }, function(err, status) selected_app = { err = err, status = status } end)
  expect_true('app selection completes', vim.wait(1000, function() return selected_app ~= nil end, 10))
  expect('app selection succeeds', selected_app.err, nil)
  expect('app selection persists identity', state_by_root[root_one].app, { build_path = ':', project_path = ':app' })

  local selected_variant
  android.select_target('variant', { root = root_one }, function(err, status) selected_variant = { err = err, status = status } end)
  expect_true('variant selection completes', vim.wait(1000, function() return selected_variant ~= nil end, 10))
  expect('variant selection succeeds', selected_variant.err, nil)
  expect('variant selection persists', state_by_root[root_one].variant, 'debug')
  expect('cached target selection avoids rediscovery', discovery_calls[root_one], 1)
  selected_variant.status.selection.app.project_path = ':caller-mutated'
  expect('public status cannot mutate persisted target identity', state_by_root[root_one].app.project_path, ':app')
  expect('public status cannot mutate later target identity', assert(android.status { root = root_one }).selection.app.project_path, ':app')

  local built
  local stale_checks_before_build = stale_checks_by_root[root_one] or 0
  android.build({ root = root_one }, function(err, result) built = { err = err, result = result } end)
  expect_true('build completes', vim.wait(1000, function() return built ~= nil end, 10))
  expect('build succeeds', built.err, nil)
  expect('build uses selected assemble task', runner_calls[#runner_calls].argv[3], ':app:assembleDebug')
  expect_contract('supported runner request contract', runner_calls[#runner_calls], PortContracts.runner_request)
  expect('build reauthorizes immediately before Gradle execution', trust_calls[root_one], 2)
  expect('build performs one cached metadata freshness check', stale_checks_by_root[root_one], stale_checks_before_build + 1)
  expect('successful build publishes a root-scoped clear batch', problem_batches[1], {
    root = root_one,
    kind = 'build',
    name = 'Android build :app · debug',
    status = 'success',
    items = {},
    truncated = false,
  })
  expect_contract('supported problem batch contract', problem_batches[1], PortContracts.problem_batch)

  local assemble_task = built.result.target.assemble_task
  built.result.target.assemble_task = ':app:callerMutated'
  local rebuilt
  android.build({ root = root_one }, function(err, result) rebuilt = { err = err, result = result } end)
  expect_true('build after public target mutation completes', vim.wait(1000, function() return rebuilt ~= nil end, 10))
  expect('build after public target mutation succeeds', rebuilt.err, nil)
  local rebuilt_argv = runner_calls[#runner_calls].argv[3]
  local rebuilt_target_task = rebuilt.result and rebuilt.result.target.assemble_task
  built.result.target.assemble_task = assemble_task
  expect('public target cannot mutate later Gradle argv', rebuilt_argv, ':app:assembleDebug')
  expect('public target cannot mutate later target resolution', rebuilt_target_task, ':app:assembleDebug')

  local ran
  local stale_checks_before_run = stale_checks_by_root[root_one] or 0
  android.run({ root = root_one }, function(err, result) ran = { err = err, result = result } end)
  expect_true('run completes', vim.wait(1000, function() return ran ~= nil end, 10))
  expect('run succeeds', ran.err, nil)
  expect('public Run result excludes private ADB launch details', ran.result.launch, nil)
  expect('first run remembers the sole online device', state_by_root[root_one].device.serial, 'emulator-5554')
  expect('first run remembers the emulator AVD identity', state_by_root[root_one].device.avd_name, current_avd_name)
  expect('run uses selected install task', runner_calls[#runner_calls].argv[3], ':app:installDebug')
  expect('run scopes Gradle install to selected device', runner_calls[#runner_calls].env.ANDROID_SERIAL, 'emulator-5554')
  expect('run reauthorizes immediately before Gradle execution', trust_calls[root_one], 4)
  expect('run performs one cached metadata freshness check', stale_checks_by_root[root_one], stale_checks_before_run + 1)
  expect('run launches exact selected package', adb_calls[#adb_calls].application_id, 'example.app.debug')
  expect('configured Run opens Logcat once', #logcat_calls, 1)
  expect('automatic Logcat preserves source focus', logcat_calls[1].focus, false)
  expect('successful install publishes a root-scoped clear batch', problem_batches[3], {
    root = root_one,
    kind = 'run',
    name = 'Android run :app · debug',
    status = 'success',
    items = {},
    truncated = false,
  })

  ran.result.device.serial = 'caller-mutated'
  ran.result.device.avd_name = 'Caller_Mutated'
  local status_after_device_mutation = assert(android.status { root = root_one })
  expect('public device cannot mutate persisted device identity', state_by_root[root_one].device.serial, 'emulator-5554')
  expect('public device cannot mutate later device identity', status_after_device_mutation.selection.device, {
    serial = 'emulator-5554',
    avd_name = current_avd_name,
  })

  local logcat_opened
  android.logcat({ root = root_one }, function(err, result) logcat_opened = { err = err, result = result } end)
  expect_true('logcat opens', vim.wait(1000, function() return logcat_opened ~= nil end, 10))
  expect('logcat open succeeds', logcat_opened.err, nil)
  expect('manual logcat reuses the automatic presenter', #logcat_calls, 1)
  expect('custom Logcat does not resolve adb unless requested', adb_resolution_calls, 0)
  expect_true('custom Logcat receives an optional lazy adb resolver', type(logcat_calls[1].resolve_adb) == 'function')
  expect('custom Logcat can resolve adb on demand', logcat_calls[1].resolve_adb(), '/sdk/platform-tools/adb')
  expect('lazy adb resolver runs only on demand', adb_resolution_calls, 1)
  expect('logcat uses selected applicationId', logcat_calls[1].application_id, 'example.app.debug')
  expect('logcat uses remembered device', logcat_calls[1].device_serial, 'emulator-5554')
  expect('logcat does not reauthorize project execution', trust_calls[root_one], 4)
  expect_true('public logcat result preserves handle identity', rawequal(logcat_opened.result.handle, logcat_handles[1]))
  expect('status exposes running logcat independently', assert(android.status { root = root_one }).logcat, 'running')
  expect('existing logcat shows its view', logcat_shows, 1)

  do
    hold_picker = true
    pending_picker = nil
    r4_controls.selected = nil
    android.select_logcat_session({ root = root_one }, function(err, session) r4_controls.selected = { err = err, session = session } end)
    expect_true('public Logcat-session selection reaches the picker', pending_picker ~= nil)
    expect_contract('Logcat-session picker request contract', pending_picker.request, PortContracts.picker_request)
    expect('public Logcat-session picker owns a closed item', pending_picker.request.items, {
      { application_id = 'example.app.debug', device_serial = 'emulator-5554', current = true },
    })
    expect('public Logcat-session picker marks current', pending_picker.request.current, pending_picker.request.items[1])
    pending_picker.callback(nil, pending_picker.request.items[1])
    expect_true('public Logcat-session selection completes', vim.wait(1000, function() return r4_controls.selected ~= nil end, 10))
    expect('public Logcat-session selection succeeds', r4_controls.selected.err, nil)
    expect('public Logcat-session result is closed', r4_controls.selected.session, {
      application_id = 'example.app.debug',
      device_serial = 'emulator-5554',
      current = true,
    })
    r4_controls.selected.session.application_id = 'caller-mutated'
    pending_picker = nil
    r4_controls.owned = nil
    android.select_logcat_session({ root = root_one }, function(err, session) r4_controls.owned = { err = err, session = session } end)
    expect_true('second public Logcat-session selection reaches the picker', pending_picker ~= nil)
    expect('public result mutation cannot alter a later picker item', pending_picker.request.items[1].application_id, 'example.app.debug')
    pending_picker.callback(nil, nil)
    expect_true('second public Logcat-session selection dismisses', vim.wait(1000, function() return r4_controls.owned ~= nil end, 10))
    expect('public Logcat-session dismissal succeeds', r4_controls.owned.err, nil)
    expect('public Logcat-session dismissal returns no result', r4_controls.owned.session, nil)
    hold_picker = false
    pending_picker = nil
  end

  local stopped
  android.stop({ root = root_one }, function(err, result) stopped = { err = err, result = result } end)
  expect_true('stop completes', vim.wait(1000, function() return stopped ~= nil end, 10))
  expect('stop succeeds', stopped.err, nil)
  expect('public Stop result excludes private ADB stop details', stopped.result.result, nil)
  expect('stop validates remembered device', adb_calls[#adb_calls - 1].kind, 'validate')
  expect('stop preserves remembered device identity after result mutation', adb_calls[#adb_calls - 1].serial, 'emulator-5554')
  expect('stop targets exact selected package', adb_calls[#adb_calls].application_id, 'example.app.debug')
  expect('stop does not authorize project execution', trust_calls[root_one], 4)

  local batches_before_launch_failure = #problem_batches
  next_launch_error = { code = 'launch_failed', message = 'ADB could not launch the installed application' }
  local failed_launch
  android.run({ root = root_one }, function(err, result) failed_launch = { err = err, result = result } end)
  expect_true('post-install ADB failure completes', vim.wait(1000, function() return failed_launch ~= nil end, 10))
  expect('post-install ADB failure remains primary', failed_launch.err.code, 'launch_failed')
  expect('successful install publishes before a later ADB failure', #problem_batches, batches_before_launch_failure + 1)
  expect('post-install ADB failure publishes a successful Gradle clear', problem_batches[#problem_batches], {
    root = root_one,
    kind = 'run',
    name = 'Android run :app · debug',
    status = 'success',
    items = {},
    truncated = false,
  })

  local adb_count_before_changed_device = #adb_calls
  local batches_before_changed_device = #problem_batches
  current_avd_name = 'Pixel_9_API_36'
  local changed_device
  android.stop({ root = root_one }, function(err, result) changed_device = { err = err, result = result } end)
  expect_true('changed emulator identity completes', vim.wait(1000, function() return changed_device ~= nil end, 10))
  expect('reused emulator serial is rejected', changed_device.err.code, 'device_changed')
  expect('reused emulator serial only performs validation', #adb_calls, adb_count_before_changed_device + 1)
  expect('reused emulator serial never stops the new AVD', adb_calls[#adb_calls].kind, 'validate')
  expect('ADB-only application Stop failure publishes no Gradle batch', #problem_batches, batches_before_changed_device)
  current_avd_name = 'Pixel_8_API_35'

  stale_roots[root_one] = true
  pending_root = root_one
  pending_discovery = nil
  local runner_count_before_rebound = #runner_calls
  local batches_before_rebound = #problem_batches
  local rebound_run
  android.run({ root = root_one }, function(err, result) rebound_run = { err = err, result = result } end)
  expect_true('run waits for stale project refresh', vim.wait(1000, function() return pending_discovery ~= nil end, 10))
  current_avd_name = 'Pixel_9_API_36'
  pending_root = nil
  stale_roots[root_one] = false
  local complete_rebound_discovery = pending_discovery.callback
  pending_discovery = nil
  complete_rebound_discovery(nil, snapshot(root_one))
  expect_true('device rebound run completes', vim.wait(1000, function() return rebound_run ~= nil end, 10))
  expect('device is validated after stale project refresh', rebound_run.err.code, 'device_changed')
  expect('device rebound starts no Gradle install', #runner_calls, runner_count_before_rebound)
  expect('preflight device failure publishes no Gradle batch', #problem_batches, batches_before_rebound)
  current_avd_name = 'Pixel_8_API_35'

  hold_runner = true
  local batches_before_cancelled_build = #problem_batches
  local cancelled_build
  local build_handle = android.build({ root = root_one }, function(err) cancelled_build = err end)
  expect_true('pending build reaches runner', vim.wait(1000, function() return pending_runner ~= nil end, 10))
  local active = assert(android.status { root = root_one })
  expect('status exposes contextual active operation', active.operation, 'build')
  local did_cancel, cancel_err = android.cancel { root = root_one }
  expect('public cancel succeeds', did_cancel, true)
  expect('public cancel error', cancel_err, nil)
  expect('cancelled build waits for configured runner exit', cancelled_build, nil)
  expect('cancel reaches configured runner', runner_cancellations, 1)
  expect('status retains cancelling operation', assert(android.status { root = root_one }).operation, 'build')
  local blocked_while_cancelling
  android.build({ root = root_one }, function(err) blocked_while_cancelling = err end)
  expect_true('second workflow is rejected while cancellation drains', vim.wait(1000, function() return blocked_while_cancelling ~= nil end, 10))
  expect('cancelling operation keeps the root slot', blocked_while_cancelling.code, 'operation_active')
  expect('build cancellation leaves logcat running', assert(android.status { root = root_one }).logcat, 'running')
  expect('build cancellation never stops logcat', logcat_stops, 0)
  expect('duplicate cancellation is rejected while draining', build_handle.cancel(), false)
  pending_runner(nil, { status = 'cancelled', code = 143, signal = 15 })
  expect_true('cancelled build completes after runner exit', vim.wait(1000, function() return cancelled_build ~= nil end, 10))
  expect('cancelled build is classified', cancelled_build.code, 'cancelled')
  expect('cancelled Gradle task publishes no problem batch', #problem_batches, batches_before_cancelled_build)
  expect('status clears operation after child exit', assert(android.status { root = root_one }).operation, nil)
  hold_runner = false

  local batches_before_malformed_runner = #problem_batches
  next_runner_result = {}
  local malformed_runner_build
  android.build({ root = root_one }, function(err, result) malformed_runner_build = { err = err, result = result } end)
  expect_true('malformed runner Build completes', vim.wait(1000, function() return malformed_runner_build ~= nil end, 10))
  expect('malformed runner result stays primary', malformed_runner_build.err.code, 'invalid_runner_result')
  expect('malformed runner result publishes no problem batch', #problem_batches, batches_before_malformed_runner)

  local parsed_problem = {
    path = vim.fs.joinpath(root_one, 'app/src/main/java/example/Main.java'),
    line = 12,
    message = 'cannot find symbol',
    severity = 'error',
  }
  problem_publish_mode = 'return_error'
  next_runner_result = {
    status = 'failure',
    code = 1,
    problems = { parsed_problem },
    problems_truncated = true,
  }
  local notifications_before_sink_error = #notifications
  local failed_build
  android.build({ root = root_one }, function(err, result) failed_build = { err = err, result = result } end)
  expect_true('failed Build survives problem sink error', vim.wait(1000, function() return failed_build ~= nil end, 10))
  expect('problem sink error does not replace Gradle failure', failed_build.err.code, 'build_failed')
  expect('failed Build publishes neutral parsed problems', problem_batches[#problem_batches], {
    root = root_one,
    kind = 'build',
    name = 'Android build :app · debug',
    status = 'failure',
    items = { parsed_problem },
    truncated = true,
  })
  expect('problem sink returned error warns through notification port', notifications[notifications_before_sink_error + 1].level, 'warn')
  expect_true(
    'problem sink returned error warning is actionable',
    notifications[notifications_before_sink_error + 1].message:find('problem sink rejected the batch', 1, true)
  )

  problem_publish_mode = 'throw'
  local notifications_before_sink_throw = #notifications
  local build_after_sink_throw
  android.build({ root = root_one }, function(err, result) build_after_sink_throw = { err = err, result = result } end)
  expect_true('successful Build survives problem sink exception', vim.wait(1000, function() return build_after_sink_throw ~= nil end, 10))
  expect('problem sink exception does not replace Gradle success', build_after_sink_throw.err, nil)
  expect('problem sink exception warns through notification port', notifications[notifications_before_sink_throw + 1].level, 'warn')
  expect_true('problem sink exception warning is actionable', notifications[notifications_before_sink_throw + 1].message:find('problem sink exploded', 1, true))
  problem_publish_mode = 'success'

  next_runner_result = { status = 'failure', code = 1 }
  local empty_failed_build
  android.build({ root = root_one }, function(err, result) empty_failed_build = { err = err, result = result } end)
  expect_true('locationless failed Build completes', vim.wait(1000, function() return empty_failed_build ~= nil end, 10))
  expect('locationless failed Build keeps its primary error', empty_failed_build.err.code, 'build_failed')
  expect('locationless failed Build still publishes an empty terminal batch', problem_batches[#problem_batches], {
    root = root_one,
    kind = 'build',
    name = 'Android build :app · debug',
    status = 'failure',
    items = {},
    truncated = false,
  })

  for _, mode in ipairs { 'reject', 'throw' } do
    runner_cancel_mode = mode
    hold_runner = true
    pending_runner = nil
    local naturally_completed
    android.build({ root = root_one }, function(err, result) naturally_completed = { err = err, result = result } end)
    expect_true(mode .. ' cancellation reaches runner', vim.wait(1000, function() return pending_runner ~= nil end, 10))
    local rejected, rejected_err = android.cancel { root = root_one }
    expect(mode .. ' cancellation reports failure', rejected, nil)
    expect(mode .. ' cancellation returns structured error', rejected_err.code, 'cancel_failed')
    expect(mode .. ' cancellation retains active slot', assert(android.status { root = root_one }).operation, 'build')
    expect(mode .. ' cancellation does not complete callback', naturally_completed, nil)
    pending_runner(nil, { status = 'success', code = 0 })
    expect_true(mode .. ' cancellation permits terminal completion', vim.wait(1000, function() return naturally_completed ~= nil end, 10))
    expect(mode .. ' cancellation preserves natural result', naturally_completed.err, nil)
    expect(mode .. ' terminal completion clears slot', assert(android.status { root = root_one }).operation, nil)
  end
  runner_cancel_mode = 'accept'
  hold_runner = false

  for _, case in ipairs {
    { mode = 'error_callback', code = 'cancel_failed', label = 'child cancellation failure' },
    { mode = 'callback_then_false', code = 'cancelled', label = 'synchronous terminal cancellation' },
  } do
    runner_cancel_mode = case.mode
    hold_runner = true
    pending_runner = nil
    local terminal_cancel
    android.build({ root = root_one }, function(err) terminal_cancel = err end)
    expect_true(case.label .. ' reaches runner', vim.wait(1000, function() return pending_runner ~= nil end, 10))
    expect(case.label .. ' wins over the cancel return value', android.cancel { root = root_one }, true)
    expect_true(case.label .. ' completes exactly once', vim.wait(1000, function() return terminal_cancel ~= nil end, 10))
    expect(case.label .. ' preserves the terminal classification', terminal_cancel.code, case.code)
    expect(case.label .. ' clears the root slot', assert(android.status { root = root_one }).operation, nil)
  end
  runner_cancel_mode = 'accept'
  hold_runner = false

  synchronous_device_validation = true
  hold_runner = true
  pending_runner = nil
  local synchronous_run_cancelled
  android.run({ root = root_one }, function(err) synchronous_run_cancelled = err end)
  expect_true('synchronous device validation reaches runner', vim.wait(1000, function() return pending_runner ~= nil end, 10))
  expect_true('completed synchronous validation handle is discarded', validation_handle_cancels > 0)
  local runner_cancellations_before_sync_cancel = runner_cancellations
  expect('synchronous transition public cancel succeeds', android.cancel { root = root_one }, true)
  expect('synchronous transition cancellation reaches runner', runner_cancellations, runner_cancellations_before_sync_cancel + 1)
  expect('synchronous transition waits for runner exit', synchronous_run_cancelled, nil)
  pending_runner(nil, { status = 'cancelled', code = 143, signal = 15 })
  expect_true('synchronous transition cancellation completes', vim.wait(1000, function() return synchronous_run_cancelled ~= nil end, 10))
  expect('synchronous transition cancellation is classified', synchronous_run_cancelled.code, 'cancelled')
  synchronous_device_validation = false
  hold_runner = false

  local stopped_logcat, stop_logcat_err = android.stop_logcat { root = root_one }
  expect('public logcat stop succeeds', stopped_logcat, true)
  expect('public logcat stop error', stop_logcat_err, nil)
  expect('logcat stop reaches only its presenter', logcat_stops, 1)
  expect('status clears stopped logcat', assert(android.status { root = root_one }).logcat, 'stopped')

  local trust_before_emulator_lifecycle = trust_calls[root_one]
  local discovery_before_emulator_lifecycle = discovery_calls[root_one]
  local emulator_calls_before_lifecycle = #emulator_calls
  local stopped_emulator
  android.stop_emulator({ root = root_one }, function(err, result) stopped_emulator = { err = err, result = result } end)
  expect_true('explicit emulator stop completes', vim.wait(1000, function() return stopped_emulator ~= nil end, 10))
  expect('explicit emulator stop succeeds', stopped_emulator.err, nil)
  expect('explicit emulator stop uses the selected exact identity', emulator_calls[#emulator_calls], {
    kind = 'stop',
    request = { serial = 'emulator-5554', avd_name = current_avd_name },
  })
  expect('explicit emulator stop remembers only the stable AVD name', state_by_root[root_one].device, { avd_name = current_avd_name })
  expect('emulator stop does not authorize Gradle', trust_calls[root_one], trust_before_emulator_lifecycle)
  expect('emulator stop does not discover Gradle', discovery_calls[root_one], discovery_before_emulator_lifecycle)

  local started_emulator
  android.start_emulator({ root = root_one }, function(err, result) started_emulator = { err = err, result = result } end)
  expect_true('explicit emulator start completes', vim.wait(1000, function() return started_emulator ~= nil end, 10))
  expect('explicit emulator start succeeds', started_emulator.err, nil)
  expect('explicit emulator start uses the remembered AVD without a picker', emulator_calls[#emulator_calls], {
    kind = 'start',
    avd_name = current_avd_name,
  })
  expect('explicit emulator start persists its current serial', state_by_root[root_one].device, {
    serial = 'emulator-5554',
    avd_name = current_avd_name,
  })
  expect('emulator start does not authorize Gradle', trust_calls[root_one], trust_before_emulator_lifecycle)
  expect('emulator start does not discover Gradle', discovery_calls[root_one], discovery_before_emulator_lifecycle)

  stopped_emulator = nil
  android.stop_emulator({ root = root_one }, function(err, result) stopped_emulator = { err = err, result = result } end)
  expect_true('second emulator stop completes', vim.wait(1000, function() return stopped_emulator ~= nil end, 10))
  expect('second emulator stop leaves a stopped remembered AVD', state_by_root[root_one].device, { avd_name = current_avd_name })

  local runner_calls_before_auto_start = #runner_calls
  local auto_started_run
  android.run({ root = root_one }, function(err, result) auto_started_run = { err = err, result = result } end)
  expect_true('Run auto-starts a remembered stopped AVD', vim.wait(1000, function() return auto_started_run ~= nil end, 10))
  expect('Run after automatic emulator start succeeds', auto_started_run.err, nil)
  local lifecycle_start_count = 0
  for index = emulator_calls_before_lifecycle + 1, #emulator_calls do
    if emulator_calls[index].kind == 'start' then lifecycle_start_count = lifecycle_start_count + 1 end
  end
  expect('explicit Start and Run each invoke the emulator lifecycle once', lifecycle_start_count, 2)
  expect('Run auto-start targets the remembered AVD', emulator_calls[#emulator_calls], {
    kind = 'start',
    avd_name = current_avd_name,
  })
  expect('Run begins Gradle only after the emulator is ready', #runner_calls, runner_calls_before_auto_start + 1)
  expect('Run installs to the new emulator serial', runner_calls[#runner_calls].env.ANDROID_SERIAL, 'emulator-5554')
  expect('Run persists the ready emulator identity', state_by_root[root_one].device, {
    serial = 'emulator-5554',
    avd_name = current_avd_name,
  })

  state_by_root[root_two] = { device = { avd_name = current_avd_name } }
  hold_emulator_start = true
  pending_emulator_start = nil
  local cancelled_emulator_start
  android.start_emulator({ root = root_two }, function(err, result) cancelled_emulator_start = { err = err, result = result } end)
  expect_true('pending public emulator Start reaches its adapter', vim.wait(1000, function() return pending_emulator_start ~= nil end, 10))
  expect('emulator Start owns the root operation slot', assert(android.status { root = root_two }).operation, 'emulator_start')
  expect('public cancel accepts emulator Start cancellation', android.cancel { root = root_two }, true)
  expect('emulator Start cancellation reaches only its leaf', emulator_start_cancellations, 1)
  expect('accepted emulator Start cancellation keeps the root slot', assert(android.status { root = root_two }).operation, 'emulator_start')
  expect('accepted emulator Start cancellation waits for leaf terminal', cancelled_emulator_start, nil)
  pending_emulator_start.callback { code = 'cancelled', message = 'emulator start cancelled' }
  expect_true('emulator Start cancellation completes after leaf terminal', vim.wait(1000, function() return cancelled_emulator_start ~= nil end, 10))
  expect('emulator Start cancellation remains classified', cancelled_emulator_start.err.code, 'cancelled')
  expect('emulator Start cancellation clears the root slot', assert(android.status { root = root_two }).operation, nil)
  expect('cancelled emulator Start preserves the stopped AVD selection', state_by_root[root_two].device, { avd_name = current_avd_name })
  expect('emulator Start never authorizes Gradle', trust_calls[root_two], nil)
  expect('emulator Start never discovers Gradle', discovery_calls[root_two], nil)
  hold_emulator_start = false
  pending_emulator_start = nil

  state_by_root[root_five] = {
    app = { build_path = ':', project_path = ':app' },
    variant = 'debug',
    device = { serial = 'R58M321' },
  }
  local physical_runner_count = #runner_calls
  local physical_logcat_count = #logcat_calls
  local physical_emulator_count = #emulator_calls
  local physical_problem_count = #problem_batches
  local physical_run
  android.run({ root = root_five }, function(err, result) physical_run = { err = err, result = result } end)
  expect_true('public Run completes against a physical device', vim.wait(1000, function() return physical_run ~= nil end, 10))
  expect('public physical-device Run succeeds', physical_run.err, nil)
  expect('physical-device Run starts one Gradle task', #runner_calls, physical_runner_count + 1)
  expect('physical-device Run scopes installation to the phone serial', runner_calls[#runner_calls].env.ANDROID_SERIAL, 'R58M321')
  expect('physical-device Run launches on the phone serial', adb_calls[#adb_calls].serial, 'R58M321')
  expect('physical-device Run opens app-scoped Logcat on the phone', #logcat_calls, physical_logcat_count + 1)
  expect('physical-device Logcat uses the exact phone serial', logcat_calls[#logcat_calls].device_serial, 'R58M321')
  expect('physical-device Run publishes one Gradle batch', #problem_batches, physical_problem_count + 1)
  expect('problem publication stays isolated to the physical-device project root', problem_batches[#problem_batches].root, root_five)

  local physical_stop
  android.stop({ root = root_five }, function(err, result) physical_stop = { err = err, result = result } end)
  expect_true('public application Stop completes against a physical device', vim.wait(1000, function() return physical_stop ~= nil end, 10))
  expect('public physical-device application Stop succeeds', physical_stop.err, nil)
  expect('physical-device application Stop targets the phone serial', adb_calls[#adb_calls].serial, 'R58M321')
  expect('physical-device application Stop preserves the selected phone', state_by_root[root_five].device, { serial = 'R58M321' })
  expect('physical-device workflow never invokes emulator lifecycle', #emulator_calls, physical_emulator_count)
  expect('physical-device Logcat can be stopped independently', android.stop_logcat { root = root_five }, true)

  local custom_target = {
    id = ':app#debug',
    project_id = ':app',
    build_path = ':',
    build_root = root_six,
    project_path = ':app',
    project_dir = vim.fs.joinpath(root_six, 'app'),
    variant = 'debug',
    application_id = 'example.custom',
    assemble_task = ':app:assembleDebug',
    install_task = ':app:installDebug',
  }
  local partial_custom_snapshot = complete_snapshot(root_six, { custom_target })
  partial_custom_snapshot.builds[1].application_projects = {}
  raw_snapshots_by_root[root_six] = partial_custom_snapshot
  local runners_before_partial = #runner_calls
  local adb_before_partial = #adb_calls
  local partial_run
  android.run({ root = root_six }, function(err, result) partial_run = { err = err, result = result } end)
  expect_true('partial custom discovery completes', vim.wait(1000, function() return partial_run ~= nil end, 10))
  expect('partial custom discovery is rejected', partial_run.err and partial_run.err.code, 'discovery_invalid')
  expect('partial custom discovery starts no runner', #runner_calls, runners_before_partial)
  expect('partial custom discovery reaches no ADB service', #adb_calls, adb_before_partial)
  expect('partial custom discovery persists no selection', state_saves[root_six], nil)
  expect('partial custom discovery does not become current', assert(android.status { root = root_six }).targets, 0)

  local mutable_custom_snapshot = complete_snapshot(root_six, { custom_target })
  raw_snapshots_by_root[root_six] = mutable_custom_snapshot
  local custom_refresh
  android.refresh({ root = root_six }, function(err, status) custom_refresh = { err = err, status = status } end)
  expect_true('complete custom discovery refreshes', vim.wait(1000, function() return custom_refresh ~= nil end, 10))
  expect('complete custom discovery succeeds', custom_refresh.err, nil)
  mutable_custom_snapshot.targets[1].application_id = 'caller.mutated'
  mutable_custom_snapshot.targets[1].install_task = ':app:mutatedInstall'
  mutable_custom_snapshot.tasks[2].name = 'mutatedByProvider'
  mutable_custom_snapshot.builds[1].application_projects = {}
  local custom_run
  android.run({ root = root_six }, function(err, result) custom_run = { err = err, result = result } end)
  expect_true('later-mutated custom discovery Run completes', vim.wait(1000, function() return custom_run ~= nil end, 10))
  expect('later-mutated custom discovery Run succeeds', custom_run.err, nil)
  expect('later provider mutation cannot change Gradle argv', runner_calls[#runner_calls].argv[3], ':app:installDebug')
  expect('later provider mutation cannot change ADB targeting', adb_calls[#adb_calls].application_id, 'example.custom')
  expect('later provider mutation cannot change persisted target identity', state_by_root[root_six].app, { build_path = ':', project_path = ':app' })
  expect('later provider mutation cannot change the current snapshot', assert(android.status { root = root_six }).targets, 1)
  expect('later provider mutation does not force rediscovery', discovery_calls[root_six], 2)
  do
    r4_controls.stopped, r4_controls.stop_err = android.stop_all_logcats { root = root_six }
    expect('custom containment Logcat stop-all succeeds', r4_controls.stop_err, nil)
    expect('custom containment Logcat stop-all reports its result', r4_controls.stopped, {
      stopped = 1,
      refused = {},
      refused_total = 0,
      refused_truncated = false,
    })
  end

  local logcat_count_before_shutdown = #logcat_calls
  local logcat_stops_before_shutdown = logcat_stops
  local logcat_abandons_before_shutdown = logcat_abandons
  local logcat_for_shutdown
  android.logcat({ root = root_one }, function(err, result) logcat_for_shutdown = { err = err, result = result } end)
  expect_true('logcat reopens before shutdown', vim.wait(1000, function() return logcat_for_shutdown ~= nil end, 10))
  expect('shutdown fixture reuses the current logcat presenter', #logcat_calls, logcat_count_before_shutdown)

  snapshots_by_root[root_four] = {
    schema_version = 1,
    root = root_four,
    builds = {},
    tasks = {},
    targets = {
      {
        id = ':first#debug',
        build_path = ':',
        build_root = root_four,
        project_path = ':first',
        project_dir = vim.fs.joinpath(root_four, 'first'),
        variant = 'debug',
        application_id = 'example.first',
        assemble_task = ':first:assembleDebug',
        install_task = ':first:installDebug',
      },
      {
        id = ':second#debug',
        build_path = ':',
        build_root = root_four,
        project_path = ':second',
        project_dir = vim.fs.joinpath(root_four, 'second'),
        variant = 'debug',
        application_id = 'example.second',
        assemble_task = ':second:assembleDebug',
        install_task = ':second:installDebug',
      },
    },
  }
  hold_picker = true
  pending_picker = nil
  local raced_app
  android.select_target('app', { root = root_four }, function(err, status) raced_app = { err = err, status = status } end)
  expect_true('raced app selection reaches picker', vim.wait(1000, function() return pending_picker ~= nil end, 10))
  local app_picker = pending_picker
  hold_picker = false
  local raced_device
  android.select_target('device', { root = root_four }, function(err, status) raced_device = { err = err, status = status } end)
  expect_true('device selection completes while app picker is open', vim.wait(1000, function() return raced_device ~= nil end, 10))
  app_picker.callback(nil, app_picker.request.items[1])
  expect_true('raced app selection completes', vim.wait(1000, function() return raced_app ~= nil end, 10))
  expect('late app selection preserves newer device', state_by_root[root_four].device.serial, 'emulator-5554')

  hold_device_validation = true
  pending_device_validation = nil
  local late_device
  android.select_target('device', { root = root_four }, function(err, status) late_device = { err = err, status = status } end)
  expect_true('held device selection reaches validation', vim.wait(1000, function() return pending_device_validation ~= nil end, 10))
  hold_picker = true
  pending_picker = nil
  local newer_app
  android.select_target('app', { root = root_four }, function(err, status) newer_app = { err = err, status = status } end)
  expect_true('newer app selection reaches picker', vim.wait(1000, function() return pending_picker ~= nil end, 10))
  pending_picker.callback(nil, pending_picker.request.items[2])
  expect_true('newer app selection completes first', vim.wait(1000, function() return newer_app ~= nil end, 10))
  hold_picker = false
  hold_device_validation = false
  pending_device_validation.callback(nil, {
    serial = pending_device_validation.serial,
    state = 'online',
    label = 'Pixel',
    avd_name = current_avd_name,
  })
  expect_true('late device selection completes', vim.wait(1000, function() return late_device ~= nil end, 10))
  expect('late device selection preserves newer app', state_by_root[root_four].app.project_path, ':second')

  local raced_variant
  android.select_target('variant', { root = root_four }, function(err, status) raced_variant = { err = err, status = status } end)
  expect_true('raced fixture variant selection completes', vim.wait(1000, function() return raced_variant ~= nil end, 10))
  validated_serial_override = 'emulator-7777'
  local adb_count_before_wrong_serial = #adb_calls
  local runner_count_before_wrong_serial = #runner_calls
  local wrong_serial_stop
  android.stop({ root = root_four }, function(err) wrong_serial_stop = err end)
  expect_true('wrong-serial validation completes', vim.wait(1000, function() return wrong_serial_stop ~= nil end, 10))
  expect('custom ADB cannot substitute another serial', wrong_serial_stop.code, 'device_changed')
  expect('wrong serial starts no task runner', #runner_calls, runner_count_before_wrong_serial)
  expect('wrong serial reaches validation only', #adb_calls, adb_count_before_wrong_serial + 1)
  expect('wrong serial starts no stop command', adb_calls[#adb_calls].kind, 'validate')
  validated_serial_override = nil

  snapshots_by_root[root_three] = {
    schema_version = 1,
    root = root_three,
    builds = {},
    tasks = {},
    targets = {
      {
        id = ':old#debug',
        build_path = ':',
        build_root = root_three,
        project_path = ':old',
        project_dir = vim.fs.joinpath(root_three, 'old'),
        variant = 'debug',
        application_id = 'example.old',
        assemble_task = ':old:assembleDebug',
        install_task = ':old:installDebug',
      },
      {
        id = ':other#debug',
        build_path = ':',
        build_root = root_three,
        project_path = ':other',
        project_dir = vim.fs.joinpath(root_three, 'other'),
        variant = 'debug',
        application_id = 'example.other',
        assemble_task = ':other:assembleDebug',
        install_task = ':other:installDebug',
      },
    },
  }
  hold_picker = true
  pending_picker = nil
  local cancelled_picker_build
  android.build({ root = root_three }, function(err, result) cancelled_picker_build = { err = err, result = result } end)
  expect_true('cancellable workflow reaches target picker', vim.wait(1000, function() return pending_picker ~= nil end, 10))
  local cancelled_picker = pending_picker
  expect('target picker owns the active root slot', assert(android.status { root = root_three }).operation, 'build')
  expect('target picker cancellation is accepted', android.cancel { root = root_three }, true)
  expect('accepted picker cancellation waits for terminal callback', cancelled_picker_build, nil)
  expect('accepted picker cancellation retains root slot', assert(android.status { root = root_three }).operation, 'build')
  cancelled_picker.callback { code = 'cancelled', message = 'picker closed' }
  expect_true('terminal picker cancellation completes workflow', vim.wait(1000, function() return cancelled_picker_build ~= nil end, 10))
  expect('terminal picker cancellation is classified', cancelled_picker_build.err and cancelled_picker_build.err.code, 'cancelled')
  expect('terminal picker cancellation clears root slot', assert(android.status { root = root_three }).operation, nil)
  hold_picker = false
  pending_picker = nil

  hold_picker = true
  picker_returns_nil = true
  local uncancellable_picker_build
  android.build({ root = root_three }, function(err, result) uncancellable_picker_build = { err = err, result = result } end)
  expect_true('nil-handle workflow reaches target picker', vim.wait(1000, function() return pending_picker ~= nil end, 10))
  local cancelled, cancel_err = android.cancel { root = root_three }
  expect('nil-handle picker cancellation is refused', cancelled, nil)
  expect('nil-handle picker cancellation is actionable', cancel_err and cancel_err.code, 'cancel_failed')
  expect('nil-handle picker retains root slot', assert(android.status { root = root_three }).operation, 'build')
  pending_picker.callback(nil, nil)
  expect_true('nil-handle picker remains observable', vim.wait(1000, function() return uncancellable_picker_build ~= nil end, 10))
  expect('nil-handle picker reports user cancellation', uncancellable_picker_build.err and uncancellable_picker_build.err.code, 'cancelled')
  expect('nil-handle picker terminal clears root slot', assert(android.status { root = root_three }).operation, nil)
  picker_returns_nil = false
  hold_picker = false
  pending_picker = nil

  hold_picker = true
  pending_picker = nil
  local stale_build
  local runner_count_before_stale = #runner_calls
  android.build({ root = root_three }, function(err, result) stale_build = { err = err, result = result } end)
  expect_true('pending workflow reaches target picker', vim.wait(1000, function() return pending_picker ~= nil end, 10))

  snapshots_by_root[root_three] = {
    schema_version = 1,
    root = root_three,
    builds = {},
    tasks = {},
    targets = {
      {
        id = ':new#debug',
        build_path = ':',
        build_root = root_three,
        project_path = ':new',
        project_dir = vim.fs.joinpath(root_three, 'new'),
        variant = 'debug',
        application_id = 'example.new',
        assemble_task = ':new:assembleDebug',
        install_task = ':new:installDebug',
      },
    },
  }
  local concurrent_refresh
  android.refresh({ root = root_three }, function(err, status) concurrent_refresh = { err = err, status = status } end)
  expect_true('concurrent refresh completes', vim.wait(1000, function() return concurrent_refresh ~= nil end, 10))
  expect('concurrent refresh succeeds', concurrent_refresh.err, nil)

  local stale_choice = pending_picker.request.items[1]
  pending_picker.callback(nil, stale_choice)
  expect_true('superseded workflow completes', vim.wait(1000, function() return stale_build ~= nil end, 10))
  expect('superseded target is rejected', stale_build.err and stale_build.err.code, 'target_stale')
  expect('superseded target starts no runner', #runner_calls, runner_count_before_stale)
  expect('superseded selection is reconciled', state_by_root[root_three].app, nil)
  hold_picker = false
  pending_picker = nil

  local PreflightApp = require 'android_workbench.app'
  local preflight_picker
  local preflight_discovery
  local preflight_runner_calls = 0
  local preflight_snapshot = snapshot(root_three)
  preflight_snapshot.targets = {
    vim.tbl_extend('force', preflight_snapshot.targets[1], {
      id = ':first#debug',
      project_path = ':first',
      project_dir = vim.fs.joinpath(root_three, 'first'),
      application_id = 'example.first',
      assemble_task = ':first:assembleDebug',
    }),
    vim.tbl_extend('force', preflight_snapshot.targets[1], {
      id = ':second#debug',
      project_path = ':second',
      project_dir = vim.fs.joinpath(root_three, 'second'),
      application_id = 'example.second',
      assemble_task = ':second:assembleDebug',
    }),
  }
  local preflight_selection = { app = nil, variant = nil, device = nil }
  local preflight_session = {
    root = root_three,
    wrapper = vim.fs.joinpath(root_three, 'gradlew'),
    discover = function(_, _, callback)
      if not preflight_picker then
        callback(nil, preflight_snapshot)
      else
        preflight_discovery = callback
      end
      return { cancel = function() return true end }
    end,
    selection = function() return vim.deepcopy(preflight_selection) end,
    set_target_selection = function(_, app, variant)
      preflight_selection.app = vim.deepcopy(app)
      preflight_selection.variant = variant
      return true
    end,
    is_snapshot_current = function(_, candidate) return candidate == preflight_snapshot end,
    authorize = function() return true end,
    status = function() return { root = root_three, selection = vim.deepcopy(preflight_selection), targets = 2 } end,
  }
  local preflight_app = PreflightApp.new {
    ports = {
      picker = {
        select = function(request, callback)
          preflight_picker = { request = request, callback = callback }
          return { cancel = function() return true end }
        end,
      },
      runner = {
        start = function(_, callback)
          preflight_runner_calls = preflight_runner_calls + 1
          callback(nil, { status = 'success', code = 0 })
          return { cancel = function() return false end }
        end,
      },
      adb = ports.adb,
      emulator = ports.emulator,
      discovery = { discover = function() error 'unexpected discovery adapter call' end },
      trust = { authorize = function() return true end },
      problems = ports.problems,
      state = { load = function() end, save = function() return true end },
      notifications = { emit = function() end },
    },
  }
  preflight_app.sessions[root_three] = preflight_session
  local selection_race_build
  preflight_app:build({ root = root_three }, function(err, result) selection_race_build = { err = err, result = result } end)
  expect_true('selection-race build reaches target picker', preflight_picker ~= nil)
  preflight_picker.callback(nil, preflight_picker.request.items[1])
  expect_true('selection-race build waits for target revalidation', preflight_discovery ~= nil)
  preflight_selection = {
    app = { build_path = ':', project_path = ':second' },
    variant = 'debug',
    device = nil,
  }
  preflight_discovery(nil, preflight_snapshot)
  expect('selection-only change rejects Build preflight', selection_race_build.err.code, 'target_stale')
  expect('selection-only change starts no runner', preflight_runner_calls, 0)
  preflight_app:shutdown()

  local denied
  android.refresh({ root = root_two }, function(err, status) denied = { err = err, status = status } end)
  expect_true('denied refresh completes', vim.wait(1000, function() return denied ~= nil end, 10))
  expect('denied refresh returns trust error', denied.err.code, 'project_not_trusted')
  expect('denied refresh never starts Gradle', discovery_calls[root_two], nil)
  denied.err.message = 'caller-mutated callback error'
  expect('public callback error cannot mutate retained status error', assert(android.status { root = root_two }).error.message, 'not trusted')
  denied.err.message = 'not trusted'
  local denied_status = assert(android.status { root = root_two })
  denied_status.error.message = 'caller-mutated status error'
  expect('public status error cannot mutate later status error', assert(android.status { root = root_two }).error.message, 'not trusted')
  denied_status.error.message = 'not trusted'

  local batches_before_denied_build = #problem_batches
  local denied_build
  android.build({ root = root_two }, function(err, result) denied_build = { err = err, result = result } end)
  expect_true('trust-denied Build completes', vim.wait(1000, function() return denied_build ~= nil end, 10))
  expect('trust-denied Build keeps its preflight error', denied_build.err.code, 'project_not_trusted')
  expect('trust-denied Build publishes no problem batch', #problem_batches, batches_before_denied_build)

  trusted[root_two] = true
  pending_root = root_two
  pending_discovery = nil
  local cancelled
  local handle = android.refresh({ root = root_two }, function(err) cancelled = err end)
  expect('public operation dot cancellation succeeds', handle.cancel(), true)
  expect('public cancellation waits for provider exit', cancelled, nil)
  pending_discovery.callback { code = 'cancelled', message = 'provider cancelled' }
  expect_true('public cancellation completes', vim.wait(1000, function() return cancelled ~= nil end, 10))
  expect('public cancellation is classified', cancelled.code, 'cancelled')
  expect('public cancellation reaches provider', provider_cancellations, 1)

  valid, config_error = pcall(android.setup, {})
  expect('setup is frozen after first action', valid, false)
  expect_true('late setup error is actionable', tostring(config_error):find('before the first Android action', 1, true))

  for _, case in ipairs {
    { label = 'unknown context field', context = { root = root_one, unknown = true }, field = 'context.unknown' },
    { label = 'invalid context root', context = { root = false }, field = 'context.root' },
    { label = 'invalid context path', context = { path = 42 }, field = 'context.path' },
    { label = 'invalid context buffer', context = { bufnr = -1 }, field = 'context.bufnr' },
  } do
    valid, config_error = pcall(android.status, case.context)
    expect(case.label .. ' is rejected', valid, false)
    expect_true(case.label .. ' names the field', tostring(config_error):find(case.field, 1, true))
  end
  valid, config_error = pcall(android.build, { root = root_one }, false)
  expect('invalid callback is rejected', valid, false)
  expect_true('invalid callback error is actionable', tostring(config_error):find('callback must be a function', 1, true))
  valid, config_error = pcall(android.select_target, 'unknown', { root = root_one })
  expect('unknown target kind is rejected', valid, false)
  expect_true('unknown target kind error is actionable', tostring(config_error):find('unsupported Android target kind', 1, true))

  runner_cancel_mode = 'reject'
  hold_runner = true
  pending_runner = nil
  local abandoned_run_callbacks = 0
  android.run({ root = root_one }, function() abandoned_run_callbacks = abandoned_run_callbacks + 1 end)
  expect_true('shutdown-refusal Run reaches runner', vim.wait(1000, function() return pending_runner ~= nil end, 10))
  local abandoned_runner_terminal = pending_runner
  local runner_cancellations_before_shutdown = runner_cancellations
  android.shutdown()
  expect('shutdown attempts refused runner cancellation once', runner_cancellations, runner_cancellations_before_shutdown + 1)

  runner_cancel_mode = 'accept'
  pending_runner = nil
  local replacement_build_callbacks = 0
  local replacement_build
  android.build({ root = root_one }, function(err, result)
    replacement_build_callbacks = replacement_build_callbacks + 1
    replacement_build = { err = err, result = result }
  end)
  expect_true('replacement App reaches its own runner', vim.wait(1000, function() return pending_runner ~= nil end, 10))
  local replacement_runner_terminal = pending_runner
  local adb_calls_before_late_success = #adb_calls
  local logcats_before_late_success = #logcat_calls
  local batches_before_late_success = #problem_batches
  local notifications_before_late_success = #notifications

  abandoned_runner_terminal(nil, { status = 'success', code = 0 })
  vim.wait(100, function() return abandoned_run_callbacks > 0 end, 10)
  expect('shutdown suppresses late Run ADB work', #adb_calls, adb_calls_before_late_success)
  expect('shutdown suppresses late Run Logcat', #logcat_calls, logcats_before_late_success)
  expect('shutdown suppresses late Run problem publication', #problem_batches, batches_before_late_success)
  expect('shutdown suppresses late Run notifications', #notifications, notifications_before_late_success)
  expect('shutdown suppresses late Run public callback', abandoned_run_callbacks, 0)
  expect('late old Run leaves replacement App operation active', assert(android.status { root = root_one }).operation, 'build')

  replacement_runner_terminal(nil, { status = 'success', code = 0 })
  expect_true('replacement App operation completes', vim.wait(1000, function() return replacement_build ~= nil end, 10))
  expect('replacement App operation succeeds', replacement_build.err, nil)
  expect('replacement App operation completes once', replacement_build_callbacks, 1)
  hold_runner = false

  hold_picker = true
  pending_picker = nil
  local shutdown_palette = android.open_actions { root = root_one }
  expect_true('shutdown palette reaches picker', pending_picker ~= nil)
  android.shutdown()
  expect('shutdown cancels an open action palette', shutdown_palette.cancel(), false)
  expect('shutdown stops the remaining logcat once', logcat_stops, logcat_stops_before_shutdown + 1)
  expect('shutdown abandons retained Logcat storage once', logcat_abandons, logcat_abandons_before_shutdown + 1)
end, debug.traceback)

vim.fn.delete(root_one, 'rf')
vim.fn.delete(root_two, 'rf')
vim.fn.delete(root_three, 'rf')
vim.fn.delete(root_four, 'rf')
vim.fn.delete(root_five, 'rf')
vim.fn.delete(root_six, 'rf')
if not ok then fail('unexpected test error', unexpected) end

if #failures > 0 then
  vim.api.nvim_err_writeln('Android Workbench API validation failed:\n- ' .. table.concat(failures, '\n- '))
  vim.cmd 'cquit 1'
end

print 'Android Workbench API validation passed'
vim.cmd 'qa!'
