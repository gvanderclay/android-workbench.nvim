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

local function count(values)
  local result = 0
  for _ in pairs(values or {}) do
    result = result + 1
  end
  return result
end

local ROOT_ONE = '/fixture/root-one'
local ROOT_TWO = '/fixture/root-two'

local function target(root, application_id, variant)
  variant = variant or 'debug'
  return {
    id = (':app#%s'):format(variant),
    project_dir = root .. '/app',
    variant = variant,
    application_id = application_id,
  }
end

local function device(serial) return { serial = serial, avd_name = 'Pixel_API_36' } end

local function new_harness(opts)
  opts = opts or {}
  local harness = {
    preflights = {},
    starts = {},
    notifications = {},
    sessions = {},
  }

  local function add_root(root)
    harness.sessions[root] = {
      root = root,
      status = function() return { root = root, selection = {} } end,
      selection = function() return {} end,
      authorize = function() return true end,
      close = function() end,
    }
  end
  add_root(ROOT_ONE)
  add_root(ROOT_TWO)

  local presenter = {
    start = function(request)
      local record = {
        request = request,
        shows = 0,
        stop_attempts = 0,
        stops = 0,
        abandons = 0,
        stopped = false,
        stop_mode = 'accept',
      }
      local handle = {}
      function handle:show()
        record.shows = record.shows + 1
        return record.show_result ~= false
      end
      function handle:stop()
        record.stop_attempts = record.stop_attempts + 1
        if record.stop_mode == 'reject' then return false end
        if record.stop_mode == 'throw' then error 'stop failed' end
        if record.stopped then return false end
        record.stopped = true
        record.stops = record.stops + 1
        return true
      end
      function handle:_abandon() record.abandons = record.abandons + 1 end
      record.handle = handle
      harness.starts[#harness.starts + 1] = record
      if opts.shutdown_during_start then harness.app:shutdown() end
      if opts.synchronous_exit then
        request.on_exit {
          status = 'failure',
          error = { code = 'sync_exit', message = 'synchronous presenter exit' },
        }
      end
      return handle
    end,
  }

  harness.app = require('android_workbench.app').new {
    ports = {
      logcat = presenter,
      notifications = { emit = function(event) harness.notifications[#harness.notifications + 1] = event end },
    },
    logcat = { open_on_run = opts.open_on_run == true },
  }
  harness.app._session = function(self, context)
    if self.closed then return nil, { code = 'app_closed', message = 'closed' } end
    return harness.sessions[context.root]
  end
  harness.app._preflight = function(_, session, operation, _, callback)
    harness.preflights[#harness.preflights + 1] = {
      session = session,
      operation = operation,
      callback = callback,
    }
  end

  function harness:open(root)
    local result = { calls = 0 }
    self.app:open_logcat({ root = root }, function(err, value)
      result.calls = result.calls + 1
      result.err = err
      result.value = value
    end)
    return result, #self.preflights
  end

  function harness:resolve(index, selected_target, selected_device) self.preflights[index].callback(nil, selected_target, selected_device) end

  function harness:entry(root, application_id, serial)
    local registry = self.app:_logcat_registry(root, false)
    return registry and registry.entries[application_id .. '\0' .. serial] or nil
  end

  return harness
end

local ok, unexpected = xpcall(function()
  local harness = new_harness()
  local first, first_preflight = harness:open(ROOT_ONE)
  local second, second_preflight = harness:open(ROOT_ONE)

  expect('different identities may preflight concurrently', #harness.preflights, 2)
  expect('aggregate status reports only pending starts', harness.app:status({ root = ROOT_ONE }).logcat, 'starting')
  harness:resolve(first_preflight, target(ROOT_ONE, 'example.first'), device 'device-1')
  harness:resolve(second_preflight, target(ROOT_ONE, 'example.second'), device 'device-1')
  expect('first concurrent session completes once', first.calls, 1)
  expect('second concurrent session completes once', second.calls, 1)
  expect('first concurrent session succeeds', first.err, nil)
  expect('second concurrent session succeeds', second.err, nil)
  expect('different app identities start independent presenters', #harness.starts, 2)
  expect('starting a sibling never stops the first reader', harness.starts[1].stop_attempts, 0)
  expect('aggregate status remains running', harness.app:status({ root = ROOT_ONE }).logcat, 'running')

  local reused, reused_preflight = harness:open(ROOT_ONE)
  harness:resolve(reused_preflight, target(ROOT_ONE, 'example.first', 'release'), device 'device-1')
  expect('same app and device reuse ignores target and variant identity', #harness.starts, 2)
  expect('exact identity reuse shows the existing presenter', harness.starts[1].shows, 1)
  expect_true('exact identity reuse preserves handle identity', reused.value and rawequal(reused.value.handle, harness.starts[1].handle))

  local duplicate_one, duplicate_one_preflight = harness:open(ROOT_ONE)
  local duplicate_two, duplicate_two_preflight = harness:open(ROOT_ONE)
  harness:resolve(duplicate_one_preflight, target(ROOT_ONE, 'example.third'), device 'device-1')
  harness:resolve(duplicate_two_preflight, target(ROOT_ONE, 'example.third'), device 'device-1')
  expect('concurrent exact identities start one presenter', #harness.starts, 3)
  expect('second concurrent exact identity reveals the first', harness.starts[3].shows, 1)
  expect_true('concurrent exact identities return one handle', rawequal(duplicate_one.value.handle, duplicate_two.value.handle))

  local other_device, other_device_preflight = harness:open(ROOT_ONE)
  harness:resolve(other_device_preflight, target(ROOT_ONE, 'example.first'), device 'device-2')
  expect('same app on another device starts a distinct session', #harness.starts, 4)
  expect('same-device sibling remains independently live', harness.starts[1].stop_attempts, 0)

  local registry = harness.app:_logcat_registry(ROOT_ONE, false)
  local notifications_before_sibling_exit = #harness.notifications
  harness.starts[2].request.on_exit {
    status = 'failure',
    error = { code = 'reader_failed', message = 'second reader failed' },
  }
  expect_true(
    'presenter exit removes only its exact identity',
    vim.wait(1000, function() return harness:entry(ROOT_ONE, 'example.second', 'device-1') == nil end, 10)
  )
  expect('presenter exit retains every sibling', count(registry.entries), 3)
  expect_true('presenter exit retains the first app', harness:entry(ROOT_ONE, 'example.first', 'device-1') ~= nil)
  expect('presenter failure emits exactly one error', #harness.notifications, notifications_before_sibling_exit + 1)

  harness.starts[4].stop_mode = 'reject'
  local stopped, stop_err = harness.app:stop_logcat { root = ROOT_ONE }
  expect('refused current stop returns no success', stopped, nil)
  expect('refused current stop is classified', stop_err and stop_err.code, 'logcat_stop_failed')
  expect_true('refused current stop retains exact ownership', harness:entry(ROOT_ONE, 'example.first', 'device-2') ~= nil)
  expect('refused current stop never touches a sibling', harness.starts[3].stop_attempts, 0)
  harness.starts[4].stop_mode = 'accept'
  expect('accepted current stop succeeds', harness.app:stop_logcat { root = ROOT_ONE }, true)
  expect('accepted current stop removes only that identity', count(registry.entries), 2)

  local select_first, select_first_preflight = harness:open(ROOT_ONE)
  harness:resolve(select_first_preflight, target(ROOT_ONE, 'example.first'), device 'device-1')
  expect('existing first session is selected again', select_first.err, nil)
  expect('selected first session stops independently', harness.app:stop_logcat { root = ROOT_ONE }, true)
  local successor, successor_preflight = harness:open(ROOT_ONE)
  harness:resolve(successor_preflight, target(ROOT_ONE, 'example.first'), device 'device-1')
  expect('stopped identity can start a successor', #harness.starts, 5)
  local notifications_before_stale_exit = #harness.notifications
  harness.starts[1].request.on_exit {
    status = 'failure',
    error = { code = 'late_failure', message = 'late old reader' },
  }
  vim.wait(50)
  expect_true('late old exit cannot remove its successor', rawequal(harness:entry(ROOT_ONE, 'example.first', 'device-1').handle, successor.value.handle))
  expect('late old exit emits no stale failure', #harness.notifications, notifications_before_stale_exit)

  harness.starts[5].request.on_exit { status = 'stopped' }
  expect_true(
    'current presenter exit selects a surviving sibling',
    vim.wait(1000, function()
      local current = harness.app:_logcat_registry(ROOT_ONE, false)
      return current and current.current == 'example.third\0device-1'
    end, 10)
  )
  expect('aggregate status stays running while a sibling survives', harness.app:status({ root = ROOT_ONE }).logcat, 'running')
  expect('current stop reaches the selected surviving sibling', harness.app:stop_logcat { root = ROOT_ONE }, true)
  expect('root status stops after its last sibling stops', harness.app:status({ root = ROOT_ONE }).logcat, 'stopped')

  local root_one_live, root_one_preflight = harness:open(ROOT_ONE)
  local root_two_live, root_two_preflight = harness:open(ROOT_TWO)
  harness:resolve(root_one_preflight, target(ROOT_ONE, 'example.rootone'), device 'device-1')
  harness:resolve(root_two_preflight, target(ROOT_TWO, 'example.roottwo'), device 'device-1')
  expect('two roots retain independent registries', {
    harness.app:status({ root = ROOT_ONE }).logcat,
    harness.app:status({ root = ROOT_TWO }).logcat,
  }, { 'running', 'running' })
  expect('stopping root one succeeds', harness.app:stop_logcat { root = ROOT_ONE }, true)
  expect('stopping root one leaves root two running', harness.app:status({ root = ROOT_TWO }).logcat, 'running')
  expect('stopping root one never touches root two', harness:entry(ROOT_TWO, 'example.roottwo', 'device-1').handle, root_two_live.value.handle)

  harness.app.logcat_options.open_on_run = true
  harness.app.execution.run = function(_, request, callback)
    callback(nil, { kind = 'run', target = request.target, device = request.device })
    return { cancel = function() return true end }
  end
  local run_result
  harness.app:run({ root = ROOT_ONE }, function(err, result) run_result = { err = err, result = result } end)
  local run_preflight = #harness.preflights
  harness:resolve(run_preflight, target(ROOT_ONE, 'example.run'), device 'device-1')
  expect_true('Run with automatic Logcat completes', run_result ~= nil)
  expect('Run automatic Logcat succeeds', run_result and run_result.err, nil)
  expect_true('Run starts its own app session', harness:entry(ROOT_ONE, 'example.run', 'device-1') ~= nil)
  expect('Run automatic Logcat preserves source focus', harness.starts[#harness.starts].request.focus, false)
  expect('Run automatic Logcat never stops the other root', harness:entry(ROOT_TWO, 'example.roottwo', 'device-1').handle, root_two_live.value.handle)

  local pending_one = harness:open(ROOT_ONE)
  local pending_two = harness:open(ROOT_TWO)
  local starts_before_shutdown = #harness.starts
  local root_one_record = harness.starts[#harness.starts]
  local root_two_record = harness.starts[#harness.starts - 1]
  expect('shutdown succeeds once', harness.app:shutdown(), true)
  expect('duplicate shutdown is ignored', harness.app:shutdown(), false)
  expect('shutdown stops root-one live session once', root_one_record.stops, 1)
  expect('shutdown abandons root-one live session once', root_one_record.abandons, 1)
  expect('shutdown stops root-two live session once', root_two_record.stops, 1)
  expect('shutdown abandons root-two live session once', root_two_record.abandons, 1)
  expect('shutdown suppresses pending public callbacks', { pending_one.calls, pending_two.calls }, { 0, 0 })
  harness:resolve(#harness.preflights - 1, target(ROOT_ONE, 'example.late'), device 'device-1')
  harness:resolve(#harness.preflights, target(ROOT_TWO, 'example.late'), device 'device-1')
  expect('shutdown suppresses late pending starts', #harness.starts, starts_before_shutdown)
  expect('shutdown keeps pending callbacks suppressed', { pending_one.calls, pending_two.calls }, { 0, 0 })

  local fresh = new_harness()
  local fresh_result, fresh_preflight = fresh:open(ROOT_ONE)
  fresh:resolve(fresh_preflight, target(ROOT_ONE, 'example.fresh'), device 'device-1')
  expect('replacement App starts independently', fresh_result.err, nil)
  harness.starts[starts_before_shutdown].request.on_exit {
    status = 'failure',
    error = { code = 'late_shutdown', message = 'late shutdown exit' },
  }
  vim.wait(50)
  expect_true('late old-App exit cannot mutate replacement App', fresh:entry(ROOT_ONE, 'example.fresh', 'device-1') ~= nil)
  fresh.app:shutdown()

  local pending = new_harness()
  local pending_first = pending:open(ROOT_ONE)
  local pending_second = pending:open(ROOT_ONE)
  expect('stop cancels only the latest pending start', pending.app:stop_logcat { root = ROOT_ONE }, true)
  expect('latest pending start completes as cancelled', pending_second.err and pending_second.err.code, 'cancelled')
  expect('older pending start remains starting', pending.app:status({ root = ROOT_ONE }).logcat, 'starting')
  expect('second stop cancels the remaining pending start', pending.app:stop_logcat { root = ROOT_ONE }, true)
  expect('older pending start completes as cancelled', pending_first.err and pending_first.err.code, 'cancelled')
  expect('pending-only root returns to stopped', pending.app:status({ root = ROOT_ONE }).logcat, 'stopped')
  pending.app:shutdown()

  local refusing = new_harness()
  local refused, refused_preflight = refusing:open(ROOT_ONE)
  local refused_operation = refusing.preflights[refused_preflight].operation
  refused_operation:start_child(function()
    return { cancel = function() return false end }
  end, function() end)
  local refused_stop, refused_stop_err = refusing.app:stop_logcat { root = ROOT_ONE }
  expect('refused pending cancellation returns no success', refused_stop, nil)
  expect('refused pending cancellation is classified', refused_stop_err and refused_stop_err.code, 'cancel_failed')
  expect('refused pending cancellation retains startup ownership', refusing.app:status({ root = ROOT_ONE }).logcat, 'starting')
  expect('refused pending cancellation does not complete its callback', refused.calls, 0)
  refused_operation:finish { code = 'cancelled', message = 'cancelled after refusal' }
  expect('later pending terminal completes once', refused.calls, 1)
  expect('later pending terminal releases startup ownership', refusing.app:status({ root = ROOT_ONE }).logcat, 'stopped')
  refusing.app:shutdown()

  local synchronous = new_harness { synchronous_exit = true }
  local sync_result, sync_preflight = synchronous:open(ROOT_ONE)
  synchronous:resolve(sync_preflight, target(ROOT_ONE, 'example.sync'), device 'device-1')
  expect('synchronously exiting presenter returns its handle once', sync_result.calls, 1)
  expect_true(
    'synchronous presenter exit removes the exact session',
    vim.wait(1000, function() return synchronous.app:status({ root = ROOT_ONE }).logcat == 'stopped' end, 10)
  )
  local synchronous_errors = 0
  for _, event in ipairs(synchronous.notifications) do
    if event.level == 'error' then synchronous_errors = synchronous_errors + 1 end
  end
  expect('synchronous presenter exit emits one terminal error', synchronous_errors, 1)
  synchronous.app:shutdown()

  local shutdown_start = new_harness { open_on_run = true, shutdown_during_start = true }
  shutdown_start.app.execution.run = function(_, request, callback)
    callback(nil, { kind = 'run', target = request.target, device = request.device })
    return { cancel = function() return true end }
  end
  local shutdown_run_calls = 0
  shutdown_start.app:run({ root = ROOT_ONE }, function() shutdown_run_calls = shutdown_run_calls + 1 end)
  shutdown_start:resolve(1, target(ROOT_ONE, 'example.shutdown'), device 'device-1')
  expect('synchronous shutdown suppresses the Run callback', shutdown_run_calls, 0)
  expect('synchronous shutdown stops the unadopted presenter', shutdown_start.starts[1].stops, 1)
  expect('synchronous shutdown abandons the unadopted presenter', shutdown_start.starts[1].abandons, 1)
  expect('synchronous shutdown emits no late Logcat warning', #shutdown_start.notifications, 1)
end, debug.traceback)

if not ok then fail('unexpected test error', unexpected) end

if #failures > 0 then
  vim.api.nvim_err_writeln('Android Workbench Logcat session validation failed:\n- ' .. table.concat(failures, '\n- '))
  vim.cmd 'cquit 1'
end

print 'Android Workbench Logcat session validation passed'
vim.cmd 'qa!'
