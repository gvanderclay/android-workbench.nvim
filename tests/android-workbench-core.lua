local failures = {}

local function fail(name, message) failures[#failures + 1] = ('%s: %s'):format(name, message) end

local function expect(name, actual, expected)
  if vim.deep_equal(actual, expected) then return end
  fail(name, ('expected %s, got %s'):format(vim.inspect(expected), vim.inspect(actual)))
end

local Session = require 'android_workbench.session'
local State = require 'android_workbench.state'
local GradleTask = require 'android_workbench.gradle.task'

local original_schedule = vim.schedule
local scheduled = {}
vim.schedule = function(callback) scheduled[#scheduled + 1] = callback end

local function flush()
  while #scheduled > 0 do
    local callbacks = scheduled
    scheduled = {}
    for _, callback in ipairs(callbacks) do
      callback()
    end
  end
end

local discovery_calls = 0
local discovery_callback
local discovery_cancels = 0
local discovery_cancel_mode = 'accept'
local stale = false
local stale_checks = 0
local trust_calls = 0
local state_selection = {
  app = { build_path = ':', project_path = ':app' },
  variant = 'debug',
}
local save_error
local notifications = {}

local function complete_snapshot(root, project_paths, tasks)
  local targets = {}
  local application_projects = vim.deepcopy(project_paths or {})
  tasks = tasks and vim.deepcopy(tasks) or {}
  local known_projects = { [':'] = true }

  for _, project_path in ipairs(application_projects) do
    local project_name = project_path:sub(2):gsub('[^%w_]', '_')
    targets[#targets + 1] = {
      id = project_path .. '#debug',
      project_id = project_path,
      build_path = ':',
      build_root = root,
      project_path = project_path,
      project_dir = vim.fs.joinpath(root, project_name),
      variant = 'debug',
      application_id = 'example.' .. project_name,
      assemble_task = project_path .. ':assembleDebug',
      install_task = project_path .. ':installDebug',
    }
    tasks[#tasks + 1] = { id = project_path .. ':assembleDebug', build_path = ':', project_path = project_path, name = 'assembleDebug' }
    tasks[#tasks + 1] = { id = project_path .. ':installDebug', build_path = ':', project_path = project_path, name = 'installDebug' }
    known_projects[project_path] = true
  end
  for _, task in ipairs(tasks) do
    known_projects[task.project_path] = true
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

local session = Session.new {
  root = '/tmp/android-workbench-root',
  wrapper = '/tmp/android-workbench-root/gradlew',
  discovery = {
    discover = function(_, callback)
      discovery_calls = discovery_calls + 1
      discovery_callback = callback
      return {
        cancel = function()
          discovery_cancels = discovery_cancels + 1
          if discovery_cancel_mode == 'reject' then return false end
          if discovery_cancel_mode == 'throw' then error 'provider cancellation exploded' end
          return true
        end,
      }
    end,
    is_stale = function()
      stale_checks = stale_checks + 1
      return stale
    end,
  },
  trust = {
    authorize = function()
      trust_calls = trust_calls + 1
      return true
    end,
  },
  state = {
    load = function() return vim.deepcopy(state_selection) end,
    save = function(_, selection)
      if save_error then return nil, save_error end
      state_selection = vim.deepcopy(selection)
      return true
    end,
  },
  notifications = {
    emit = function(event) notifications[#notifications + 1] = event end,
  },
}

local ok, unexpected = xpcall(function()
  expect('status does not authorize project code', session:status().authorized, false)
  expect('status does not call trust adapter', trust_calls, 0)

  local completed = {}
  session:discover({}, function(err, snapshot) completed[#completed + 1] = { name = 'first', err = err, snapshot = snapshot } end)
  session:discover({}, function(err, snapshot) completed[#completed + 1] = { name = 'second', err = err, snapshot = snapshot } end)
  expect('coalesced discovery starts once', discovery_calls, 1)
  expect('trust checked immediately before discovery once', trust_calls, 1)

  local snapshot = complete_snapshot('/tmp/android-workbench-root', { ':remembered' })
  discovery_callback(nil, snapshot)
  expect('waiters remain deferred', #completed, 0)
  flush()
  expect('both discovery waiters complete independently', vim.tbl_map(function(item) return item.name end, completed), { 'first', 'second' })
  expect('first waiter receives snapshot', completed[1].snapshot, snapshot)
  expect('second waiter receives snapshot', completed[2].snapshot, snapshot)

  local cached_snapshot
  session:discover({}, function(err, value)
    expect('fresh cache has no error', err, nil)
    cached_snapshot = value
  end)
  expect('fresh cache avoids another Gradle invocation', discovery_calls, 1)
  expect('fresh cache avoids another trust prompt', trust_calls, 1)
  expect('fresh cache checks provider staleness once', stale_checks, 1)
  flush()
  expect('fresh cache returns the complete snapshot', cached_snapshot, snapshot)

  stale = true
  local stale_failure = {}
  session:discover({}, function(err) stale_failure[#stale_failure + 1] = err end)
  session:discover({}, function(err) stale_failure[#stale_failure + 1] = err end)
  expect('stale cache starts one replacement discovery', discovery_calls, 2)
  expect('stale replacement checks trust immediately before Gradle', trust_calls, 2)
  expect('stale callers coalesce without duplicate checks', stale_checks, 2)
  expect('old snapshot remains visible while replacement runs', session:status().targets, 1)
  discovery_callback { code = 'simulated_stale_refresh_failure', message = 'simulated stale refresh failure' }
  flush()
  expect('all stale waiters receive the refresh failure', vim.tbl_map(function(err) return err.code end, stale_failure), {
    'simulated_stale_refresh_failure',
    'simulated_stale_refresh_failure',
  })
  expect('failed stale refresh retains last complete snapshot', session:status().targets, 1)

  local stale_cancelled
  local stale_handle = session:discover({}, function(err) stale_cancelled = err end)
  expect('stale retry starts another discovery', discovery_calls, 3)
  expect('stale retry cancellation succeeds', stale_handle.cancel(), true)
  expect('stale retry cancellation waits for provider termination', stale_cancelled, nil)
  discovery_callback { code = 'cancelled', message = 'provider cancelled' }
  flush()
  expect('stale retry cancellation reaches provider', discovery_cancels, 1)
  expect('stale retry cancellation is reported', stale_cancelled.code, 'cancelled')
  expect('cancelled stale refresh retains last complete snapshot', session:status().targets, 1)

  stale = false
  local refreshed = {}
  session:refresh(function(err, value) refreshed[#refreshed + 1] = { err = err, snapshot = value } end)
  session:discover({}, function(err, value) refreshed[#refreshed + 1] = { err = err, snapshot = value } end)
  expect('normal caller joins forced replacement instead of receiving old cache', discovery_calls, 4)
  local replacement = complete_snapshot('/tmp/android-workbench-root', { ':new', ':newer' })
  discovery_callback(nil, replacement)
  flush()
  expect('forced and normal waiters receive replacement', vim.tbl_map(function(item) return item.snapshot end, refreshed), {
    replacement,
    replacement,
  })
  expect('replacement becomes active snapshot', session:status().targets, 2)

  local failed_refresh
  session:refresh(function(err) failed_refresh = err end)
  discovery_callback { code = 'simulated_discovery_failure', message = 'simulated discovery failure' }
  flush()
  expect('forced discovery failure is reported', failed_refresh.code, 'simulated_discovery_failure')
  expect('failed refresh retains last complete snapshot', session:status().targets, 2)

  local cancelled_refresh
  local refresh_handle = session:refresh(function(err) cancelled_refresh = err end)
  expect('refresh cancellation succeeds', refresh_handle.cancel(), true)
  expect('refresh cancellation waits for provider termination', cancelled_refresh, nil)
  discovery_callback { code = 'cancelled', message = 'provider cancelled' }
  flush()
  expect('refresh cancellation is reported', cancelled_refresh.code, 'cancelled')
  expect('cancelled refresh retains last complete snapshot', session:status().targets, 2)

  session.discovery.is_stale = nil
  local discovery_count_before_unversioned_provider = discovery_calls
  local unversioned_provider_result
  session:discover({}, function(err, value) unversioned_provider_result = { err = err, snapshot = value } end)
  expect('provider without staleness policy refreshes conservatively', discovery_calls, discovery_count_before_unversioned_provider + 1)
  discovery_callback(nil, replacement)
  flush()
  expect('provider without staleness policy still returns a valid snapshot', unversioned_provider_result.snapshot, replacement)

  session.discovery.is_stale = function() return true end
  for _, mode in ipairs { 'reject', 'throw' } do
    discovery_cancel_mode = mode
    local pending_result
    local pending_handle = session:discover({}, function(err, value) pending_result = { err = err, snapshot = value } end)
    expect(mode .. ' provider cancellation is observable', pending_handle.cancel(), false)
    expect(mode .. ' provider cancellation retains waiter', pending_result, nil)
    discovery_callback(nil, replacement)
    flush()
    expect(mode .. ' provider remains observable after failed cancellation', pending_result.snapshot, replacement)
  end
  discovery_cancel_mode = 'accept'

  save_error = { code = 'simulated_save_failure', message = 'simulated save failure' }
  local saved, err = session:set_selection {
    app = { build_path = ':included', project_path = ':demo' },
    variant = 'release',
  }
  expect('failed state save reports failure', saved, nil)
  expect('failed state save preserves error', err, save_error)
  expect('failed state save rolls back active selection', session:selection(), {
    app = { build_path = ':', project_path = ':app' },
    variant = 'debug',
  })

  save_error = nil
  expect('device-only update saves', session:set_device_selection { serial = 'emulator-5554', avd_name = 'Pixel_8_API_35' }, true)
  expect('device-only update preserves target selection', session:selection(), {
    app = { build_path = ':', project_path = ':app' },
    variant = 'debug',
    device = { serial = 'emulator-5554', avd_name = 'Pixel_8_API_35' },
  })

  expect('stopped AVD update saves without a serial', session:set_device_selection { avd_name = 'Pixel_8_API_35' }, true)
  expect('stopped AVD update preserves target selection', session:selection(), {
    app = { build_path = ':', project_path = ':app' },
    variant = 'debug',
    device = { avd_name = 'Pixel_8_API_35' },
  })

  expect(
    'running AVD can replace the stopped AVD identity',
    session:set_device_selection {
      serial = 'emulator-5554',
      avd_name = 'Pixel_8_API_35',
    },
    true
  )

  expect('target-only update saves', session:set_target_selection({ build_path = ':included', project_path = ':demo' }, 'release'), true)
  expect('target-only update preserves device selection', session:selection(), {
    app = { build_path = ':included', project_path = ':demo' },
    variant = 'release',
    device = { serial = 'emulator-5554', avd_name = 'Pixel_8_API_35' },
  })

  save_error = { code = 'simulated_scoped_save_failure', message = 'simulated scoped save failure' }
  saved, err = session:set_device_selection { serial = 'physical-device' }
  expect('failed scoped update reports failure', saved, nil)
  expect('failed scoped update preserves error', err, save_error)
  expect('failed scoped update rolls back all selection fields', session:selection(), {
    app = { build_path = ':included', project_path = ':demo' },
    variant = 'release',
    device = { serial = 'emulator-5554', avd_name = 'Pixel_8_API_35' },
  })
  save_error = nil

  local state_directory = vim.fn.tempname()
  local state = State.new { directory = state_directory }
  local persisted = {
    app = { build_path = ':included', project_path = ':demo' },
    variant = 'release',
  }
  expect('versioned state saves', state.save('/tmp/android-workbench-state-root', persisted), true)
  expect('versioned state round trips', state.load '/tmp/android-workbench-state-root', persisted)
  vim.fn.delete(state_directory, 'rf')

  local queued_calls = 0
  local queued_callback
  local queued_session = Session.new {
    root = '/tmp/android-workbench-queued-refresh',
    wrapper = '/tmp/android-workbench-queued-refresh/gradlew',
    discovery = {
      discover = function(_, callback)
        queued_calls = queued_calls + 1
        queued_callback = callback
        return { cancel = function() return true end }
      end,
      is_stale = function() return true end,
    },
    trust = { authorize = function() return true end },
    state = { load = function() end, save = function() return true end },
    notifications = { emit = function() end },
  }
  local ordinary_result
  local refresh_result
  queued_session:discover({}, function(err, value) ordinary_result = { err = err, snapshot = value } end)
  local first_flight_callback = queued_callback
  queued_session:refresh(function(err, value) refresh_result = { err = err, snapshot = value } end)
  expect('refresh during discovery does not start concurrently', queued_calls, 1)
  local first_snapshot = complete_snapshot(queued_session.root, { ':first' })
  first_flight_callback(nil, first_snapshot)
  flush()
  expect('ordinary caller receives the first flight', ordinary_result.snapshot, first_snapshot)
  expect('queued refresh starts a distinct replacement', queued_calls, 2)
  expect('queued refresh does not receive the superseded flight', refresh_result, nil)
  local replacement_callback = queued_callback
  local queued_replacement = complete_snapshot(queued_session.root, { ':replacement' })
  replacement_callback(nil, queued_replacement)
  flush()
  expect('queued refresh receives only its replacement', refresh_result.snapshot, queued_replacement)
  expect('queued refresh installs its replacement snapshot', queued_session:status().targets, 1)

  local cancellation_callback
  local cancellation_session = Session.new {
    root = '/tmp/android-workbench-cancel-race',
    wrapper = '/tmp/android-workbench-cancel-race/gradlew',
    discovery = {
      discover = function(_, callback)
        cancellation_callback = callback
        return {
          cancel = function()
            callback { code = 'cancel_failed', message = 'provider failed while cancelling' }
            return false
          end,
        }
      end,
      is_stale = function() return true end,
    },
    trust = { authorize = function() return true end },
    state = { load = function() end, save = function() return true end },
    notifications = { emit = function() end },
  }
  local cancellation_result
  local cancellation_handle = cancellation_session:discover({}, function(err) cancellation_result = err end)
  expect('cancellation fixture owns a provider callback', cancellation_callback ~= nil, true)
  expect('provider terminal callback wins over false cancellation return', cancellation_handle:cancel(), true)
  flush()
  expect('provider terminal cancellation failure is preserved', cancellation_result.code, 'cancel_failed')

  local repeated_cancel_callback
  local repeated_cancel_calls = 0
  local repeated_cancel_session = Session.new {
    root = '/tmp/android-workbench-repeated-cancel',
    wrapper = '/tmp/android-workbench-repeated-cancel/gradlew',
    discovery = {
      discover = function(_, callback)
        repeated_cancel_callback = callback
        return {
          cancel = function()
            repeated_cancel_calls = repeated_cancel_calls + 1
            return repeated_cancel_calls == 1
          end,
        }
      end,
      is_stale = function() return true end,
    },
    trust = { authorize = function() return true end },
    state = { load = function() end, save = function() return true end },
    notifications = { emit = function() end },
  }
  local repeated_cancel_result
  local repeated_cancel_handle = repeated_cancel_session:discover({}, function(err, value) repeated_cancel_result = { err = err, value = value } end)
  expect('first provider cancellation is accepted', repeated_cancel_handle:cancel(), true)
  expect('repeated provider cancellation is ignored', repeated_cancel_handle:cancel(), false)
  expect('provider receives one cancellation request', repeated_cancel_calls, 1)
  repeated_cancel_callback(nil, complete_snapshot(repeated_cancel_session.root, {}))
  flush()
  expect('accepted cancellation survives later provider success', repeated_cancel_result.err.code, 'cancelled')
  expect('accepted cancellation does not expose provider success', repeated_cancel_result.value, nil)
  expect('accepted cancellation restores idle phase', repeated_cancel_session:status().phase, 'idle')

  local malformed_session = Session.new {
    root = '/tmp/android-workbench-malformed-cancel',
    wrapper = '/tmp/android-workbench-malformed-cancel/gradlew',
    discovery = {
      discover = function(_, callback)
        return {
          cancel = function()
            callback(true)
            return false
          end,
        }
      end,
      is_stale = function() return true end,
    },
    trust = { authorize = function() return true end },
    state = { load = function() end, save = function() return true end },
    notifications = { emit = function() end },
  }
  local malformed_result
  local malformed_handle = malformed_session:discover({}, function(err) malformed_result = err end)
  expect('malformed terminal callback wins over false cancellation return', malformed_handle:cancel(), true)
  flush()
  expect('malformed terminal cancellation is normalized', malformed_result.code, 'discovery_failed')
  expect('malformed terminal cancellation leaves the session observable', malformed_session:status().phase, 'error')

  local pending_delivery_callback
  local pending_delivery_session = Session.new {
    root = '/tmp/android-workbench-pending-delivery',
    wrapper = '/tmp/android-workbench-pending-delivery/gradlew',
    discovery = {
      discover = function(_, callback)
        pending_delivery_callback = callback
        return { cancel = function() return true end }
      end,
      is_stale = function() return true end,
    },
    trust = { authorize = function() return true end },
    state = { load = function() end, save = function() return true end },
    notifications = { emit = function() end },
  }
  local pending_delivery_result
  local pending_delivery_handle = pending_delivery_session:discover({}, function(err, value) pending_delivery_result = { err = err, value = value } end)
  pending_delivery_callback(nil, complete_snapshot(pending_delivery_session.root, {}))
  expect('terminal-but-undelivered discovery cancellation succeeds', pending_delivery_handle:cancel(), true)
  flush()
  expect('terminal-but-undelivered discovery is cancelled', pending_delivery_result.err.code, 'cancelled')
  expect('cancelled delivery retains the completed snapshot', pending_delivery_session:status().phase, 'ready')

  local mixed_callback
  local mixed_session = Session.new {
    root = '/tmp/android-workbench-mixed-waiters',
    wrapper = '/tmp/android-workbench-mixed-waiters/gradlew',
    discovery = {
      discover = function(_, callback)
        mixed_callback = callback
        return { cancel = function() return true end }
      end,
      is_stale = function() return true end,
    },
    trust = { authorize = function() return true end },
    state = { load = function() end, save = function() return true end },
    notifications = { emit = function() end },
  }
  local mixed_cancelled
  local mixed_live
  local mixed_cancel_handle = mixed_session:discover({}, function(err, value) mixed_cancelled = { err = err, value = value } end)
  mixed_session:discover({}, function(err, value) mixed_live = { err = err, value = value } end)
  expect('one coalesced waiter can cancel independently', mixed_cancel_handle:cancel(), true)
  local mixed_snapshot = complete_snapshot(mixed_session.root, {})
  mixed_callback(nil, mixed_snapshot)
  flush()
  expect('provider success cannot overwrite accepted waiter cancellation', mixed_cancelled.err.code, 'cancelled')
  expect('live coalesced waiter still receives provider success', mixed_live.value, mixed_snapshot)

  local coalesced_cancel_callback
  local coalesced_provider_cancels = 0
  local coalesced_cancel_session = Session.new {
    root = '/tmp/android-workbench-coalesced-cancel',
    wrapper = '/tmp/android-workbench-coalesced-cancel/gradlew',
    discovery = {
      discover = function(_, callback)
        coalesced_cancel_callback = callback
        return {
          cancel = function()
            coalesced_provider_cancels = coalesced_provider_cancels + 1
            return true
          end,
        }
      end,
      is_stale = function() return true end,
    },
    trust = { authorize = function() return true end },
    state = { load = function() end, save = function() return true end },
    notifications = { emit = function() end },
  }
  local first_cancel_result
  local second_cancel_result
  local first_cancel_handle = coalesced_cancel_session:discover({}, function(err) first_cancel_result = err end)
  local second_cancel_handle = coalesced_cancel_session:discover({}, function(err) second_cancel_result = err end)
  expect('first coalesced waiter cancellation succeeds', first_cancel_handle:cancel(), true)
  expect('second coalesced waiter cancellation reaches the provider', second_cancel_handle:cancel(), true)
  expect('coalesced provider cancellation runs once', coalesced_provider_cancels, 1)
  flush()
  expect('first coalesced waiter can complete independently', first_cancel_result.code, 'cancelled')
  expect('last coalesced waiter waits for provider termination', second_cancel_result, nil)
  expect('cancelled coalesced flight retains ownership', coalesced_cancel_session:status().phase, 'discovering')
  coalesced_cancel_callback { code = 'cancelled', message = 'provider cancelled' }
  flush()
  expect('last coalesced waiter completes after provider termination', second_cancel_result.code, 'cancelled')
  expect('cancelled coalesced flight releases ownership', coalesced_cancel_session:status().phase, 'idle')

  local valid_shape = complete_snapshot('/tmp/android-workbench-snapshot-shape', {})
  local oversized_task_catalog = {}
  for index = 1, GradleTask.limits.max_tasks + 1 do
    oversized_task_catalog[index] = false
  end
  for name, mutate in pairs {
    ['missing builds array'] = function(value) value.builds = nil end,
    ['non-array builds'] = function(value) value.builds = { root = {} } end,
    ['malformed build DTO'] = function(value) value.builds = { { id = ':' } } end,
    ['missing targets array'] = function(value) value.targets = nil end,
    ['non-array targets'] = function(value) value.targets = { app = {} } end,
    ['malformed target DTO'] = function(value) value.targets = { { id = ':app#debug' } } end,
    ['missing tasks array'] = function(value) value.tasks = nil end,
    ['non-array tasks'] = function(value) value.tasks = { task = {} } end,
    ['malformed task DTO'] = function(value) value.tasks = { { id = ':other', build_path = ':', project_path = ':', name = 'help' } } end,
    ['task DTO with extra fields'] = function(value)
      value.tasks = { { id = ':help', build_path = ':', project_path = ':', name = 'help', description = 'extra' } }
    end,
    ['duplicate task identity'] = function(value)
      value.tasks = {
        { id = ':help', build_path = ':', project_path = ':', name = 'help' },
        { id = ':help', build_path = ':', project_path = ':', name = 'help' },
      }
    end,
    ['oversized task catalog'] = function(value) value.tasks = oversized_task_catalog end,
  } do
    local candidate = vim.deepcopy(valid_shape)
    mutate(candidate)
    local invalid_session = Session.new {
      root = valid_shape.root,
      wrapper = valid_shape.root .. '/gradlew',
      discovery = {
        discover = function(_, callback)
          callback(nil, candidate)
          return { cancel = function() return false end }
        end,
        is_stale = function() return true end,
      },
      trust = { authorize = function() return true end },
      state = { load = function() end, save = function() return true end },
      notifications = { emit = function() end },
    }
    local invalid_result
    invalid_session:discover({}, function(err, value) invalid_result = { err = err, value = value } end)
    flush()
    expect(name .. ' is rejected', invalid_result.err and invalid_result.err.code, 'discovery_invalid')
    expect(name .. ' exposes no partial snapshot', invalid_result.value, nil)
  end

  local normalized_candidate = complete_snapshot(valid_shape.root, {}, {
    { id = ':z:last', build_path = ':', project_path = ':z', name = 'last' },
    { id = ':a:first', build_path = ':', project_path = ':a', name = 'first' },
  })
  local normalized_discovery_calls = 0
  local normalized_stale = true
  local stale_candidate
  local normalized_session = Session.new {
    root = valid_shape.root,
    wrapper = valid_shape.root .. '/gradlew',
    discovery = {
      discover = function(_, callback)
        normalized_discovery_calls = normalized_discovery_calls + 1
        callback(nil, normalized_candidate)
        return { cancel = function() return false end }
      end,
      is_stale = function(candidate)
        stale_candidate = candidate
        candidate.builds[1].task_count = 0
        candidate.tasks[1].name = 'mutatedByStalenessCheck'
        return normalized_stale
      end,
    },
    trust = { authorize = function() return true end },
    state = { load = function() end, save = function() return true end },
    notifications = { emit = function() end },
  }
  local normalized_result
  normalized_session:discover({}, function(err, value) normalized_result = { err = err, value = value } end)
  flush()
  expect('custom task catalog normalizes successfully', normalized_result.err, nil)
  expect('custom task catalog is sorted and copied into exact DTOs', normalized_result.value.tasks, {
    { id = ':a:first', build_path = ':', project_path = ':a', name = 'first' },
    { id = ':z:last', build_path = ':', project_path = ':z', name = 'last' },
  })
  normalized_candidate.builds[1].task_count = 0
  normalized_candidate.tasks[1].name = 'mutatedByProvider'
  normalized_stale = false
  local cached_normalized_result
  normalized_session:discover({}, function(err, value) cached_normalized_result = { err = err, value = value } end)
  flush()
  expect('custom snapshot mutation does not force rediscovery', normalized_discovery_calls, 1)
  expect('custom staleness receives an owned snapshot', stale_candidate ~= nil and not rawequal(stale_candidate, normalized_result.value), true)
  expect('custom provider mutation cannot change the current build', cached_normalized_result.value.builds[1].task_count, 2)
  expect('custom provider mutation cannot change the current task', cached_normalized_result.value.tasks[1].name, 'first')
  expect('custom staleness mutation cannot change the current task', normalized_result.value.tasks[1].name, 'first')

  local metatable_candidate = vim.deepcopy(valid_shape)
  metatable_candidate.tasks = {
    setmetatable({ id = ':help', build_path = ':', project_path = ':', name = 'help' }, {
      __pairs = function() error 'malformed task iterator' end,
    }),
  }
  local metatable_session = Session.new {
    root = valid_shape.root,
    wrapper = valid_shape.root .. '/gradlew',
    discovery = {
      discover = function(_, callback)
        vim.schedule(function() callback(nil, metatable_candidate) end)
        return { cancel = function() return true end }
      end,
      is_stale = function() return true end,
    },
    trust = { authorize = function() return true end },
    state = { load = function() end, save = function() return true end },
    notifications = { emit = function() end },
  }
  local metatable_result
  metatable_session:discover({}, function(err, value) metatable_result = { err = err, value = value } end)
  expect('asynchronous malformed task result remains pending before delivery', metatable_result, nil)
  flush()
  expect('asynchronous metatable task DTO is contained', metatable_result.err.code, 'discovery_invalid')
  expect('asynchronous metatable task DTO exposes no snapshot', metatable_result.value, nil)
end, debug.traceback)

vim.schedule = original_schedule
if not ok then fail('unexpected test error', unexpected) end

if #failures > 0 then
  vim.api.nvim_err_writeln('Android Workbench core validation failed:\n- ' .. table.concat(failures, '\n- '))
  vim.cmd 'cquit 1'
end

print 'Android Workbench core validation passed'
vim.cmd 'qa!'
