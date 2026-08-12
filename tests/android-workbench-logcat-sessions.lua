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
    picker_cancellations = 0,
    pickers = {},
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
      picker = {
        select = function(request, callback)
          local record = { request = request, callback = callback }
          harness.pickers[#harness.pickers + 1] = record
          if opts.synchronous_picker then callback(nil, request.items[1]) end
          return {
            cancel = function()
              harness.picker_cancellations = harness.picker_cancellations + 1
              return opts.reject_picker_cancel ~= true
            end,
          }
        end,
      },
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

  function harness:select(root)
    local result = { calls = 0 }
    result.handle = self.app:select_logcat_session({ root = root }, function(err, value)
      result.calls = result.calls + 1
      result.err = err
      result.value = value
    end)
    return result, #self.pickers
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

  local empty_controls = new_harness()
  local empty_selection = empty_controls:select(ROOT_ONE)
  expect('session selection without live sessions completes once', empty_selection.calls, 1)
  expect('session selection without live sessions is classified', empty_selection.err and empty_selection.err.code, 'no_logcat_sessions')
  expect('session selection without live sessions opens no picker', #empty_controls.pickers, 0)
  empty_controls.app:shutdown()

  local controls = new_harness()
  local beta, beta_preflight = controls:open(ROOT_ONE)
  local alpha, alpha_preflight = controls:open(ROOT_ONE)
  local other_root, other_root_preflight = controls:open(ROOT_TWO)
  controls:resolve(beta_preflight, target(ROOT_ONE, 'example.beta'), device 'device-1')
  controls:resolve(alpha_preflight, target(ROOT_ONE, 'example.alpha'), device 'device-1')
  controls:resolve(other_root_preflight, target(ROOT_TWO, 'example.other'), device 'device-2')
  expect('session picker fixture starts root-one sessions', { beta.err, alpha.err }, { nil, nil })
  expect('session picker fixture starts another root independently', other_root.err, nil)

  expect('presenter request exposes root-local session selection', type(controls.starts[2].request.select_logcat_session), 'function')
  local presenter_selection = { calls = 0 }
  local presenter_selection_handle = controls.starts[2].request.select_logcat_session(function(err, value)
    presenter_selection.calls = presenter_selection.calls + 1
    presenter_selection.err = err
    presenter_selection.value = value
  end)
  local presenter_picker = controls.pickers[#controls.pickers]
  expect('presenter selector uses the root-local candidates', presenter_picker.request.items, {
    { application_id = 'example.alpha', device_serial = 'device-1', current = true },
    { application_id = 'example.beta', device_serial = 'device-1', current = false },
  })
  local presenter_picker_cancellations = controls.picker_cancellations
  expect('presenter selector cancellation is lifecycle-owned', presenter_selection_handle.cancel(), true)
  expect('presenter selector cancellation reaches its picker', controls.picker_cancellations, presenter_picker_cancellations + 1)
  presenter_picker.callback(nil, presenter_picker.request.items[2])
  expect('cancelled presenter selector suppresses a late choice', presenter_selection.calls, 0)
  expect('cancelled presenter selector never shows a sibling', controls.starts[1].shows, 0)

  local mutated, mutated_picker = controls:select(ROOT_ONE)
  local mutated_request = controls.pickers[mutated_picker].request
  expect('session picker prompt is specific', mutated_request.prompt, 'Android Logcat sessions')
  expect('session picker items are sorted and closed', mutated_request.items, {
    { application_id = 'example.alpha', device_serial = 'device-1', current = true },
    { application_id = 'example.beta', device_serial = 'device-1', current = false },
  })
  expect('session picker marks the current item through the picker port', mutated_request.current, mutated_request.items[1])
  expect('session picker labels the current identity', mutated_request.format_item(mutated_request.items[1]), 'example.alpha · device-1 (current)')
  expect('session picker labels a sibling identity', mutated_request.format_item(mutated_request.items[2]), 'example.beta · device-1')
  mutated_request.items[2].application_id = 'example.mutated'
  controls.pickers[mutated_picker].callback(nil, mutated_request.items[2])
  expect('mutated picker selection is rejected', mutated.err and mutated.err.code, 'invalid_selection')
  expect('mutated picker selection does not show a session', controls.starts[1].shows, 0)

  local cancelled, cancelled_picker = controls:select(ROOT_ONE)
  local public_picker_cancellations = controls.picker_cancellations
  expect('session picker cancellation is accepted', cancelled.handle.cancel(), true)
  expect('session picker cancellation reaches its child', controls.picker_cancellations, public_picker_cancellations + 1)
  controls.pickers[cancelled_picker].callback(nil, nil)
  expect('session picker cancellation completes once', cancelled.calls, 1)
  expect('session picker cancellation is classified', cancelled.err and cancelled.err.code, 'cancelled')
  controls.pickers[cancelled_picker].callback(nil, controls.pickers[cancelled_picker].request.items[1])
  expect('late picker callback is ignored', cancelled.calls, 1)

  local dismissed, dismissed_picker = controls:select(ROOT_ONE)
  controls.pickers[dismissed_picker].callback(nil, nil)
  expect('session picker dismissal completes once', dismissed.calls, 1)
  expect('session picker dismissal is successful', dismissed.err, nil)
  expect('session picker dismissal returns no selection', dismissed.value, nil)

  local stale, stale_picker = controls:select(ROOT_ONE)
  local stale_beta = controls.pickers[stale_picker].request.items[2]
  controls.starts[1].request.on_exit { status = 'stopped' }
  expect_true(
    'selected picker candidate can exit while the picker is open',
    vim.wait(1000, function() return controls:entry(ROOT_ONE, 'example.beta', 'device-1') == nil end, 10)
  )
  local beta_successor, beta_successor_preflight = controls:open(ROOT_ONE)
  controls:resolve(beta_successor_preflight, target(ROOT_ONE, 'example.beta'), device 'device-1')
  expect('same identity can restart before stale picker return', beta_successor.err, nil)
  controls.pickers[stale_picker].callback(nil, stale_beta)
  expect('stale picker generation is rejected', stale.err and stale.err.code, 'stale_logcat_session')
  expect('stale picker generation does not show the successor', controls.starts[4].shows, 0)

  local selected, selected_picker = controls:select(ROOT_ONE)
  local selected_beta = controls.pickers[selected_picker].request.items[2]
  controls.pickers[selected_picker].callback(nil, selected_beta)
  expect('session selection completes once', selected.calls, 1)
  expect('session selection succeeds', selected.err, nil)
  expect('session selection returns a closed identity', selected.value, {
    application_id = 'example.beta',
    device_serial = 'device-1',
    current = true,
  })
  expect('session selection reveals the exact handle', controls.starts[4].shows, 1)
  expect('session selection updates root-local current identity', controls.app:_logcat_registry(ROOT_ONE, false).current, 'example.beta\0device-1')
  selected.value.application_id = 'caller-mutated'
  local owned, owned_picker = controls:select(ROOT_ONE)
  expect('caller mutation cannot alter later picker identity', controls.pickers[owned_picker].request.items[2].application_id, 'example.beta')
  controls.pickers[owned_picker].callback(nil, nil)
  expect('ownership check dismisses normally', owned.err, nil)

  controls.starts[2].show_result = false
  local show_failed, show_failed_picker = controls:select(ROOT_ONE)
  controls.pickers[show_failed_picker].callback(nil, controls.pickers[show_failed_picker].request.items[1])
  expect('session show refusal is classified', show_failed.err and show_failed.err.code, 'logcat_show_failed')
  expect('session show refusal preserves current identity', controls.app:_logcat_registry(ROOT_ONE, false).current, 'example.beta\0device-1')
  controls.starts[2].show_result = true

  local isolated, isolated_picker = controls:select(ROOT_TWO)
  expect('session picker stays root-local', controls.pickers[isolated_picker].request.items, {
    { application_id = 'example.other', device_serial = 'device-2', current = true },
  })
  controls.pickers[isolated_picker].callback(nil, controls.pickers[isolated_picker].request.items[1])
  expect('other-root selection succeeds', isolated.err, nil)
  controls.app:shutdown()

  local synchronous_picker = new_harness { synchronous_picker = true }
  local sync_picker_open, sync_picker_preflight = synchronous_picker:open(ROOT_ONE)
  synchronous_picker:resolve(sync_picker_preflight, target(ROOT_ONE, 'example.syncpicker'), device 'device-1')
  expect('synchronous picker fixture opens', sync_picker_open.err, nil)
  local sync_picker_result = synchronous_picker:select(ROOT_ONE)
  expect('synchronous picker completes once', sync_picker_result.calls, 1)
  expect('synchronous picker selection succeeds', sync_picker_result.err, nil)
  expect('synchronous picker still reveals the session', synchronous_picker.starts[1].shows, 1)
  synchronous_picker.app:shutdown()

  local refusing_picker = new_harness { reject_picker_cancel = true }
  local refusing_picker_open, refusing_picker_preflight = refusing_picker:open(ROOT_ONE)
  refusing_picker:resolve(refusing_picker_preflight, target(ROOT_ONE, 'example.refusingpicker'), device 'device-1')
  expect('refusing picker fixture opens', refusing_picker_open.err, nil)
  local refused_picker_result, refused_picker = refusing_picker:select(ROOT_ONE)
  expect('refused picker cancellation remains observable', refused_picker_result.handle.cancel(), false)
  expect('refused picker cancellation keeps callback pending', refused_picker_result.calls, 0)
  refusing_picker.pickers[refused_picker].callback(nil, refusing_picker.pickers[refused_picker].request.items[1])
  expect('picker may complete normally after refusing cancellation', refused_picker_result.err, nil)
  expect('picker refusal still produces one terminal', refused_picker_result.calls, 1)
  refusing_picker.app:shutdown()

  local stopping = new_harness()
  local accepted, accepted_preflight = stopping:open(ROOT_ONE)
  local rejected, rejected_preflight = stopping:open(ROOT_ONE)
  local throwing, throwing_preflight = stopping:open(ROOT_ONE)
  local untouched, untouched_preflight = stopping:open(ROOT_TWO)
  stopping:resolve(accepted_preflight, target(ROOT_ONE, 'example.accepted'), device 'device-1')
  stopping:resolve(rejected_preflight, target(ROOT_ONE, 'example.rejected'), device 'device-1')
  stopping:resolve(throwing_preflight, target(ROOT_ONE, 'example.throwing'), device 'device-1')
  stopping:resolve(untouched_preflight, target(ROOT_TWO, 'example.untouched'), device 'device-2')
  expect('stop-all fixture starts every session', { accepted.err, rejected.err, throwing.err, untouched.err }, { nil, nil, nil, nil })
  stopping.starts[2].stop_mode = 'reject'
  stopping.starts[3].stop_mode = 'throw'
  local stopped_all, stopped_all_err = stopping.app:stop_all_logcats { root = ROOT_ONE }
  expect('best-effort stop-all returns no operational error', stopped_all_err, nil)
  expect('best-effort stop-all reports accepted and refused sessions', stopped_all, {
    stopped = 1,
    refused = {
      { application_id = 'example.rejected', device_serial = 'device-1' },
      { application_id = 'example.throwing', device_serial = 'device-1' },
    },
    refused_total = 2,
    refused_truncated = false,
  })
  expect('stop-all removes only accepted root-local entries', count(stopping.app:_logcat_registry(ROOT_ONE, false).entries), 2)
  expect_true('stop-all retains rejected identity', stopping:entry(ROOT_ONE, 'example.rejected', 'device-1') ~= nil)
  expect_true('stop-all retains throwing identity', stopping:entry(ROOT_ONE, 'example.throwing', 'device-1') ~= nil)
  expect('stop-all never touches another root', stopping.starts[4].stop_attempts, 0)
  stopped_all.refused[1].application_id = 'caller-mutated'
  expect('stop-all result mutation cannot alter retained identity', stopping:entry(ROOT_ONE, 'example.rejected', 'device-1').application_id, 'example.rejected')
  stopping.starts[2].stop_mode = 'accept'
  stopping.starts[3].stop_mode = 'accept'
  expect('second stop-all removes retained refusals', stopping.app:stop_all_logcats { root = ROOT_ONE }, {
    stopped = 2,
    refused = {},
    refused_total = 0,
    refused_truncated = false,
  })
  local no_sessions, no_sessions_err = stopping.app:stop_all_logcats { root = ROOT_ONE }
  expect('stop-all without live sessions returns no result', no_sessions, nil)
  expect('stop-all without live sessions is classified', no_sessions_err and no_sessions_err.code, 'logcat_not_running')
  stopping.app:shutdown()

  local bounded = new_harness()
  local bounded_registry = bounded.app:_logcat_registry(ROOT_ONE, true)
  for index = 1, 1026 do
    local application_id = ('example.refused.%04d'):format(index)
    local identity = application_id .. '\0device-1'
    bounded_registry.entries[identity] = {
      token = {},
      identity = identity,
      application_id = application_id,
      device_serial = 'device-1',
      selected = index,
      handle = { show = function() return true end, stop = function() return false end },
    }
    bounded_registry.current = identity
  end
  bounded_registry.sequence = 1026
  local bounded_result = assert(bounded.app:stop_all_logcats { root = ROOT_ONE })
  expect('stop-all bounds refusal identities', #bounded_result.refused, 1024)
  expect('stop-all counts every refusal', bounded_result.refused_total, 1026)
  expect('stop-all marks a truncated refusal report', bounded_result.refused_truncated, true)
  expect('bounded refusal report keeps every refused session live', count(bounded_registry.entries), 1026)
  bounded.app:shutdown()
end, debug.traceback)

if not ok then fail('unexpected test error', unexpected) end

if #failures > 0 then
  vim.api.nvim_err_writeln('Android Workbench Logcat session validation failed:\n- ' .. table.concat(failures, '\n- '))
  vim.cmd 'cquit 1'
end

print 'Android Workbench Logcat session validation passed'
vim.cmd 'qa!'
