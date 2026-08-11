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

local calls = {}
local pending_runner
local pending_resolve
local runner_cancellations = 0
local runner = {
  start = function(request, callback)
    calls[#calls + 1] = { kind = 'runner', request = request }
    pending_runner = callback
    return {
      cancel = function()
        runner_cancellations = runner_cancellations + 1
        return true
      end,
    }
  end,
}

local adb = {}
function adb:resolve_launch_components(serial, application_id, callback)
  calls[#calls + 1] = { kind = 'resolve', serial = serial, application_id = application_id }
  pending_resolve = callback
  return { cancel = function() return true end }
end

function adb:launch(serial, application_id, component, callback)
  calls[#calls + 1] = { kind = 'launch', serial = serial, application_id = application_id, component = component }
  vim.schedule(function() callback(nil, { stdout = 'Starting: Intent' }) end)
  return { cancel = function() return true end }
end

function adb:stop(serial, application_id, callback)
  calls[#calls + 1] = { kind = 'stop', serial = serial, application_id = application_id }
  vim.schedule(function() callback(nil, { code = 0 }) end)
  return { cancel = function() return true end }
end

local target = {
  id = ':app#debug',
  build_path = ':',
  project_path = ':app',
  variant = 'debug',
  application_id = 'example.app.debug',
  assemble_task = ':app:assembleDebug',
  install_task = ':app:installDebug',
}
local request = {
  root = '/project',
  wrapper = '/project/gradlew',
  target = target,
  device = { serial = 'emulator-5554' },
}
local gradle_task = {
  id = ':app:lintDebug',
  build_path = ':',
  project_path = ':app',
  name = 'lintDebug',
}

local Execution = require 'android_workbench.execution'
local Runner = require 'android_workbench.runner'
local execution = Execution.new { runner = runner, adb = adb }

local ok, unexpected = xpcall(function()
  local built
  local build_order = {}
  local observed_build
  execution:build(
    vim.tbl_extend('force', request, {
      on_task_complete = function(kind, result)
        build_order[#build_order + 1] = 'task'
        observed_build = { kind = kind, result = result }
      end,
    }),
    function(err, result)
      build_order[#build_order + 1] = 'workflow'
      built = { err = err, result = result }
    end
  )
  expect('build argv', calls[#calls].request.argv, { '/project/gradlew', '--console=plain', ':app:assembleDebug' })
  expect('build cwd', calls[#calls].request.cwd, '/project')
  expect('build metadata kind', calls[#calls].request.metadata.kind, 'android-build')
  pending_runner(nil, { status = 'success', code = 0 })
  expect('build succeeds', built.err, nil)
  expect('build result kind', built.result.kind, 'build')
  expect('accepted task observer runs before workflow completion', build_order, { 'task', 'workflow' })
  expect('accepted task observer receives the action kind', observed_build.kind, 'build')
  expect_true('accepted task observer receives a stable task name', type(observed_build.result.name) == 'string' and observed_build.result.name ~= '')
  expect('accepted task observer receives canonical metadata', observed_build.result.metadata.root, '/project')
  expect('accepted task observer receives an empty problem batch on success', observed_build.result.problems, {})
  expect('accepted task observer receives problem completeness', observed_build.result.problems_truncated, false)

  local build_failed
  local observed_failure
  execution:build(
    vim.tbl_extend('force', request, {
      on_task_complete = function(kind, result) observed_failure = { kind = kind, result = result } end,
    }),
    function(err) build_failed = err end
  )
  calls[#calls].request.on_output {
    stream = 'stderr',
    data = 'e: file:///project/app/src/main/java/example/Main.kt:17:4 Unresolved ',
  }
  calls[#calls].request.on_output { stream = 'stderr', data = 'reference\n' }
  pending_runner(nil, { status = 'failure', code = 1, stderr = 'failed' })
  expect('build failure code', build_failed.code, 'build_failed')
  expect('build failure retains runner result', build_failed.details.stderr, 'failed')
  expect('build failure is observed before translation', observed_failure.kind, 'build')
  expect('native and custom runners collect the same neutral problem shape', observed_failure.result.problems, {
    {
      path = '/project/app/src/main/java/example/Main.kt',
      line = 17,
      column = 4,
      message = 'Unresolved reference',
      severity = 'error',
    },
  })
  expect('translated build failure retains parsed problems', build_failed.details.problems, observed_failure.result.problems)

  local observed_late_provider_output
  execution:build(
    vim.tbl_extend('force', request, {
      on_task_complete = function(_, result) observed_late_provider_output = result end,
    }),
    function() end
  )
  calls[#calls].request.on_output {
    stream = 'stderr',
    data = 'e: file:///project/app/src/main/java/example/Late.kt:23:5 Late provider result\n',
  }
  pending_runner(nil, {
    status = 'failure',
    code = 1,
    problems = {},
    problems_truncated = false,
  })
  expect('shared collector supplements an empty provider terminal parse', observed_late_provider_output.problems, {
    {
      path = '/project/app/src/main/java/example/Late.kt',
      line = 23,
      column = 5,
      message = 'Late provider result',
      severity = 'error',
    },
  })

  local native_parsed
  Execution.new({
    runner = Runner.new {
      schedule = function(callback) callback() end,
      system = function(_, options, on_exit)
        options.stderr(nil, 'e: file:///project/app/src/main/java/example/Native.kt:9:2 Native failure\n')
        on_exit { code = 1, signal = 0 }
        return { kill = function() return false end }
      end,
    },
    adb = adb,
  }):build(request, function(err) native_parsed = err end)
  expect('native runner output reaches the shared problem collector', native_parsed.details.problems, {
    {
      path = '/project/app/src/main/java/example/Native.kt',
      line = 9,
      column = 2,
      message = 'Native failure',
      severity = 'error',
    },
  })

  local selected_task = vim.deepcopy(gradle_task)
  local task_result
  local task_order = {}
  local observed_task
  local observed_task_count = 0
  local forwarded_output
  execution:gradle_task({
    root = request.root,
    wrapper = request.wrapper,
    task = selected_task,
    on_output = function(event) forwarded_output = event end,
    on_task_complete = function(kind, result)
      observed_task_count = observed_task_count + 1
      task_order[#task_order + 1] = 'task'
      observed_task = { kind = kind, result = result }
    end,
  }, function(err, result)
    task_order[#task_order + 1] = 'workflow'
    task_result = { err = err, result = result }
  end)
  local task_spec = calls[#calls].request
  expect('Gradle task uses exact direct argv', task_spec.argv, { '/project/gradlew', '--console=plain', ':app:lintDebug' })
  expect('Gradle task uses the canonical root as cwd', task_spec.cwd, '/project')
  expect('Gradle task does not carry an environment', task_spec.env, nil)
  expect('Gradle task does not request a shell', task_spec.shell, nil)
  expect('Gradle task does not carry an Android target', task_spec.target, nil)
  expect('Gradle task does not carry an Android device', task_spec.device, nil)
  expect('Gradle task metadata is neutral and exact', task_spec.metadata, {
    kind = 'gradle_task',
    root = '/project',
    task_id = ':app:lintDebug',
    build_path = ':',
    project_path = ':app',
    task_name = 'lintDebug',
  })
  task_spec.on_output {
    stream = 'stderr',
    data = 'e: file:///project/app/src/main/java/example/Task.kt:12:3 Task failure candidate\n',
  }
  expect('Gradle task forwards optional output', forwarded_output, {
    stream = 'stderr',
    data = 'e: file:///project/app/src/main/java/example/Task.kt:12:3 Task failure candidate\n',
  })
  selected_task.id = ':mutated'
  selected_task.name = 'mutated'
  local task_terminal = pending_runner
  task_terminal(nil, { status = 'success', code = 0 })
  task_terminal(nil, { status = 'failure', code = 1 })
  expect('Gradle task succeeds', task_result.err, nil)
  expect('Gradle task result kind is neutral', task_result.result.kind, 'gradle_task')
  expect('Gradle task result retains a defensive selected DTO', task_result.result.gradle_task, gradle_task)
  expect('Gradle task result retains the normalized runner task', task_result.result.task, observed_task.result)
  expect('Gradle task observer runs before workflow completion', task_order, { 'task', 'workflow' })
  expect('Gradle task observer kind is neutral', observed_task.kind, 'gradle_task')
  expect('Gradle task success is observed once despite a late terminal callback', observed_task_count, 1)
  expect('Gradle task output reaches the bounded problem collector', observed_task.result.problems, {
    {
      path = '/project/app/src/main/java/example/Task.kt',
      line = 12,
      column = 3,
      message = 'Task failure candidate',
      severity = 'error',
    },
  })

  local long_task_name = string.rep('界', 200)
  local long_task_id = ':app:' .. long_task_name
  local long_task_result
  execution:gradle_task({
    root = request.root,
    wrapper = request.wrapper,
    task = {
      id = long_task_id,
      build_path = ':',
      project_path = ':app',
      name = long_task_name,
    },
  }, function(err, result) long_task_result = { err = err, result = result } end)
  local long_task_spec = calls[#calls].request
  expect('overlong multibyte task display name is capped', #long_task_spec.name, 512)
  expect('overlong multibyte task display name ends on a character boundary', long_task_spec.name, 'Gradle task :app:' .. string.rep('界', 164) .. '…')
  expect('overlong task argv retains the exact id', long_task_spec.argv[3], long_task_id)
  expect('overlong task metadata retains the exact id', long_task_spec.metadata.task_id, long_task_id)
  pending_runner(nil, { status = 'success', code = 0 })
  expect('overlong task succeeds', long_task_result.err, nil)
  expect('overlong task result retains the exact DTO id', long_task_result.result.gradle_task.id, long_task_id)

  local task_failure
  local observed_task_failure
  local observed_task_failure_count = 0
  execution:gradle_task({
    root = request.root,
    wrapper = request.wrapper,
    task = gradle_task,
    on_task_complete = function(kind, result)
      observed_task_failure_count = observed_task_failure_count + 1
      observed_task_failure = { kind = kind, result = result }
    end,
  }, function(err) task_failure = err end)
  calls[#calls].request.on_output {
    stream = 'stderr',
    data = '/project/app/src/main/java/example/Failure.java:7: error: exact task failure\n',
  }
  local failure_terminal = pending_runner
  failure_terminal(nil, { status = 'failure', code = 1, stderr = 'failed' })
  failure_terminal(nil, { status = 'success', code = 0 })
  expect('Gradle task failure code is neutral', task_failure.code, 'gradle_task_failed')
  expect('Gradle task failure identifies the exact task', task_failure.message, 'Gradle task :app:lintDebug failed. See task output.')
  expect('Gradle task failure retains runner output', task_failure.details.stderr, 'failed')
  expect('Gradle task failure retains normalized metadata', task_failure.details.metadata, observed_task_failure.result.metadata)
  expect('Gradle task failure observer kind is neutral', observed_task_failure.kind, 'gradle_task')
  expect('Gradle task failure is observed once despite a late terminal callback', observed_task_failure_count, 1)
  expect('Gradle task failure propagates collected problems', task_failure.details.problems, {
    {
      path = '/project/app/src/main/java/example/Failure.java',
      line = 7,
      message = 'exact task failure',
      severity = 'error',
    },
  })

  local task_cancel_terminal
  local task_cancel_calls = 0
  local task_cancel_callbacks = 0
  local task_cancel_observed = 0
  local task_cancelled
  local task_handle = Execution.new({
    runner = {
      start = function(_, callback)
        task_cancel_terminal = callback
        return {
          cancel = function()
            task_cancel_calls = task_cancel_calls + 1
            return true
          end,
        }
      end,
    },
    adb = adb,
  }):gradle_task({
    root = request.root,
    wrapper = request.wrapper,
    task = gradle_task,
    on_task_complete = function() task_cancel_observed = task_cancel_observed + 1 end,
  }, function(err)
    task_cancel_callbacks = task_cancel_callbacks + 1
    task_cancelled = err
  end)
  expect('Gradle task cancellation is accepted', task_handle:cancel(), true)
  expect('Gradle task cancellation reaches the runner', task_cancel_calls, 1)
  expect('Gradle task cancellation waits for terminal delivery', task_cancelled, nil)
  task_cancel_terminal(nil, { status = 'success', code = 0 })
  task_cancel_terminal(nil, { status = 'failure', code = 1 })
  expect('Gradle task cancellation is classified', task_cancelled.code, 'cancelled')
  expect('Gradle task cancellation completes once', task_cancel_callbacks, 1)
  expect('cancelled Gradle task is not observed', task_cancel_observed, 0)

  local runner_cancelled
  local runner_cancelled_observed = 0
  Execution.new({
    runner = {
      start = function(_, callback) callback(nil, { status = 'cancelled', code = 143 }) end,
    },
    adb = adb,
  }):gradle_task({
    root = request.root,
    wrapper = request.wrapper,
    task = gradle_task,
    on_task_complete = function() runner_cancelled_observed = runner_cancelled_observed + 1 end,
  }, function(err) runner_cancelled = err end)
  expect('runner-cancelled Gradle task is classified', runner_cancelled.code, 'cancelled')
  expect('runner-cancelled Gradle task identifies the exact task', runner_cancelled.message, 'Gradle task :app:lintDebug was cancelled.')
  expect('runner-cancelled Gradle task is not observed', runner_cancelled_observed, 0)

  local synchronous_task
  local synchronous_task_observed = 0
  local stale_task_cancels = 0
  local synchronous_task_handle = Execution.new({
    runner = {
      start = function(_, callback)
        callback(nil, { status = 'success', code = 0 })
        return {
          cancel = function()
            stale_task_cancels = stale_task_cancels + 1
            return false
          end,
        }
      end,
    },
    adb = adb,
  }):gradle_task({
    root = request.root,
    wrapper = request.wrapper,
    task = gradle_task,
    on_task_complete = function() synchronous_task_observed = synchronous_task_observed + 1 end,
  }, function(err, result) synchronous_task = { err = err, result = result } end)
  expect('synchronous Gradle task completes successfully', synchronous_task.result.kind, 'gradle_task')
  expect('synchronous Gradle task observes once', synchronous_task_observed, 1)
  expect('synchronous Gradle task rejects its returned handle as stale', stale_task_cancels, 1)
  expect('completed synchronous Gradle task cannot be cancelled', synchronous_task_handle:cancel(), false)

  local malformed_task_result
  local malformed_task_observed = 0
  Execution.new({
    runner = {
      start = function(_, callback) callback(nil, true) end,
    },
    adb = adb,
  }):gradle_task({
    root = request.root,
    wrapper = request.wrapper,
    task = gradle_task,
    on_task_complete = function() malformed_task_observed = malformed_task_observed + 1 end,
  }, function(err) malformed_task_result = err end)
  expect('malformed Gradle task runner result is contained', malformed_task_result.code, 'invalid_runner_result')
  expect('malformed Gradle task runner result is not observed', malformed_task_observed, 0)

  local task_spawn_error
  local task_spawn_observed = 0
  Execution.new({
    runner = { start = function() error 'task runner exploded' end },
    adb = adb,
  }):gradle_task({
    root = request.root,
    wrapper = request.wrapper,
    task = gradle_task,
    on_task_complete = function() task_spawn_observed = task_spawn_observed + 1 end,
  }, function(err) task_spawn_error = err end)
  expect('throwing Gradle task runner is contained', task_spawn_error.code, 'adapter_failed')
  expect('throwing Gradle task runner is not observed', task_spawn_observed, 0)

  local task_adapter_error
  local task_adapter_observed = 0
  Execution.new({
    runner = {
      start = function(_, callback) callback { code = 'spawn_failed', message = 'could not spawn Gradle' } end,
    },
    adb = adb,
  }):gradle_task({
    root = request.root,
    wrapper = request.wrapper,
    task = gradle_task,
    on_task_complete = function() task_adapter_observed = task_adapter_observed + 1 end,
  }, function(err) task_adapter_error = err end)
  expect('Gradle task adapter error is preserved', task_adapter_error.code, 'spawn_failed')
  expect('Gradle task adapter error is not observed', task_adapter_observed, 0)

  local invalid_task_starts = 0
  local invalid_task_result
  local invalid_task_observed = 0
  Execution.new({
    runner = {
      start = function() invalid_task_starts = invalid_task_starts + 1 end,
    },
    adb = adb,
  }):gradle_task({
    root = request.root,
    wrapper = request.wrapper,
    task = vim.tbl_extend('force', gradle_task, { unsupported = true }),
    on_task_complete = function() invalid_task_observed = invalid_task_observed + 1 end,
  }, function(err) invalid_task_result = err end)
  expect_true('invalid Gradle task completes', vim.wait(1000, function() return invalid_task_result ~= nil end, 10))
  expect('invalid Gradle task is rejected before spawning', invalid_task_starts, 0)
  expect('invalid Gradle task has a structured error', invalid_task_result.code, 'invalid_gradle_task')
  expect('invalid Gradle task is not observed', invalid_task_observed, 0)

  local inconsistent_task_result
  Execution.new({
    runner = {
      start = function() invalid_task_starts = invalid_task_starts + 1 end,
    },
    adb = adb,
  }):gradle_task({
    root = request.root,
    wrapper = request.wrapper,
    task = vim.tbl_extend('force', gradle_task, { id = ':forged:task' }),
  }, function(err) inconsistent_task_result = err end)
  expect_true('inconsistent Gradle task completes', vim.wait(1000, function() return inconsistent_task_result ~= nil end, 10))
  expect('inconsistent Gradle task is rejected before spawning', invalid_task_starts, 0)
  expect('inconsistent Gradle task has a structured error', inconsistent_task_result.code, 'invalid_gradle_task')

  local post_install_failure
  local observed_install
  execution:run(
    vim.tbl_extend('force', request, {
      on_task_complete = function(kind, result) observed_install = { kind = kind, result = result } end,
    }),
    function(err) post_install_failure = err end
  )
  pending_runner(nil, { status = 'success', code = 0 })
  expect('successful install is observable before ADB follow-up', observed_install.kind, 'run')
  expect('successful install task carries an empty problem batch', observed_install.result.problems, {})
  pending_resolve { code = 'adb_failed', message = 'Could not inspect launcher activities.' }
  expect('later ADB failure remains the workflow outcome', post_install_failure.code, 'adb_failed')

  local ran
  execution:run(request, function(err, result) ran = { err = err, result = result } end)
  local run_spec = calls[#calls].request
  expect('run uses install task', run_spec.argv, { '/project/gradlew', '--console=plain', ':app:installDebug' })
  expect('run scopes selected device', run_spec.env, { ANDROID_SERIAL = 'emulator-5554' })
  pending_runner(nil, { status = 'success', code = 0 })
  pending_resolve(nil, {
    { component = 'example.app.debug/.MainActivity', package = 'example.app.debug', activity = 'example.app.debug.MainActivity' },
  })
  expect_true('run launch pipeline completes', vim.wait(1000, function() return ran ~= nil end, 10))
  expect('run succeeds', ran.err, nil)
  expect('run resolves exact package', calls[#calls - 1].application_id, 'example.app.debug')
  expect('run launches selected component', calls[#calls].component, 'example.app.debug/.MainActivity')

  local no_install
  execution:run(
    vim.tbl_extend('force', request, {
      target = vim.tbl_extend('force', target, { install_task = false }),
    }),
    function(err) no_install = err end
  )
  expect_true('missing install result completes', vim.wait(1000, function() return no_install ~= nil end, 10))
  expect('missing install is actionable', no_install.code, 'run_unavailable')

  local stopped
  execution:stop(request, function(err, result) stopped = { err = err, result = result } end)
  expect_true('stop completes', vim.wait(1000, function() return stopped ~= nil end, 10))
  expect('stop succeeds', stopped.err, nil)
  expect('stop uses selected serial', calls[#calls].serial, 'emulator-5554')
  expect('stop uses selected package', calls[#calls].application_id, 'example.app.debug')

  local cancelled
  local callback_count = 0
  local cancelled_observed = 0
  local handle = execution:build(
    vim.tbl_extend('force', request, {
      on_task_complete = function() cancelled_observed = cancelled_observed + 1 end,
    }),
    function(err)
      callback_count = callback_count + 1
      cancelled = err
    end
  )
  expect('execution cancellation succeeds', handle:cancel(), true)
  expect('execution cancellation reaches runner', runner_cancellations, 1)
  expect('execution cancellation waits for runner exit', cancelled, nil)
  pending_runner(nil, { status = 'success', code = 0 })
  expect('execution cancellation code', cancelled.code, 'cancelled')
  expect('execution cancellation completes once', callback_count, 1)
  expect('cancelled task is not observed', cancelled_observed, 0)

  local calls_before_late_run = #calls
  local cancelled_run
  handle = execution:run(request, function(err) cancelled_run = err end)
  local late_runner = pending_runner
  expect('run cancellation succeeds', handle:cancel(), true)
  expect('run cancellation waits for runner exit', cancelled_run, nil)
  late_runner(nil, { status = 'success', code = 0 })
  expect('run cancellation is classified', cancelled_run.code, 'cancelled')
  expect('late runner success starts no resolver', #calls, calls_before_late_run + 1)

  local scheduled = {}
  local deferred_exit
  local deferred_runner = Runner.new {
    schedule = function(callback) scheduled[#scheduled + 1] = callback end,
    system = function(_, _, on_exit)
      deferred_exit = on_exit
      return { kill = function() return true end }
    end,
  }
  local deferred_resolves = 0
  local deferred_execution = Execution.new {
    runner = deferred_runner,
    adb = {
      resolve_launch_components = function()
        deferred_resolves = deferred_resolves + 1
        return { cancel = function() return true end }
      end,
    },
  }
  local deferred_cancel
  handle = deferred_execution:run(request, function(err) deferred_cancel = err end)
  deferred_exit { code = 0, signal = 0 }
  expect('terminal runner callback remains queued', #scheduled, 1)
  expect('workflow cancellation wins before queued runner delivery', handle:cancel(), true)
  table.remove(scheduled, 1)()
  expect('queued runner cancellation is classified', deferred_cancel and deferred_cancel.code, 'cancelled')
  expect('queued runner success starts no resolver after cancellation', deferred_resolves, 0)

  local cancelled_resolution
  handle = execution:run(request, function(err) cancelled_resolution = err end)
  local resolution_runner = pending_runner
  resolution_runner(nil, { status = 'success', code = 0 })
  local late_resolve = pending_resolve
  local calls_before_cancelled_resolve = #calls
  expect('resolution cancellation succeeds', handle:cancel(), true)
  expect('resolution cancellation waits for resolver exit', cancelled_resolution, nil)
  late_resolve(nil, {
    { component = 'example.app.debug/.MainActivity', package = 'example.app.debug', activity = 'example.app.debug.MainActivity' },
  })
  expect('resolution cancellation is classified', cancelled_resolution.code, 'cancelled')
  expect('late resolver success starts no launch', #calls, calls_before_cancelled_resolve)

  local resolver_callback
  local resolver_cancels = 0
  local stale_runner_cancels = 0
  local synchronous = Execution.new {
    runner = {
      start = function(_, callback)
        callback(nil, { status = 'success', code = 0 })
        return {
          cancel = function()
            stale_runner_cancels = stale_runner_cancels + 1
            return false
          end,
        }
      end,
    },
    adb = {
      resolve_launch_components = function(_, _, _, callback)
        resolver_callback = callback
        return {
          cancel = function()
            resolver_cancels = resolver_cancels + 1
            return true
          end,
        }
      end,
    },
  }
  local synchronous_cancelled
  handle = synchronous:run(request, function(err) synchronous_cancelled = err end)
  expect('completed synchronous runner handle is rejected as stale', stale_runner_cancels, 1)
  expect('synchronous transition cancellation succeeds', handle:cancel(), true)
  expect('synchronous transition cancellation reaches current resolver', resolver_cancels, 1)
  expect('synchronous transition waits for resolver exit', synchronous_cancelled, nil)
  resolver_callback(nil, {})
  expect('synchronous transition cancellation is classified', synchronous_cancelled.code, 'cancelled')

  local rejecting_callback
  local rejecting = Execution.new {
    runner = {
      start = function(_, callback)
        rejecting_callback = callback
        return { cancel = function() return false end }
      end,
    },
    adb = adb,
  }
  local rejected_result
  handle = rejecting:build(request, function(err, result) rejected_result = { err = err, result = result } end)
  expect('rejected child cancellation is observable', handle:cancel(), false)
  expect('rejected cancellation keeps operation pending', rejected_result, nil)
  rejecting_callback(nil, { status = 'success', code = 0 })
  expect('rejected cancellation permits natural completion', rejected_result.result.kind, 'build')

  local cancel_error_result
  local cancel_error_execution = Execution.new {
    runner = {
      start = function(_, callback)
        return {
          cancel = function()
            callback { code = 'cancel_failed', message = 'runner could not terminate' }
            return true
          end,
        }
      end,
    },
    adb = adb,
  }
  handle = cancel_error_execution:build(request, function(err) cancel_error_result = err end)
  expect('terminal callback during cancellation wins', handle:cancel(), true)
  expect('cancellation preserves child failure', cancel_error_result.code, 'cancel_failed')

  local synchronous_cancel_result
  local synchronous_cancel_execution = Execution.new {
    runner = {
      start = function(_, callback)
        return {
          cancel = function()
            callback(nil, { status = 'cancelled', code = 143 })
            return false
          end,
        }
      end,
    },
    adb = adb,
  }
  handle = synchronous_cancel_execution:build(request, function(err) synchronous_cancel_result = err end)
  expect('synchronous terminal cancellation wins over false return', handle:cancel(), true)
  expect('synchronous terminal cancellation is classified', synchronous_cancel_result.code, 'cancelled')

  local thrown_start
  local throwing = Execution.new {
    runner = { start = function() error 'runner exploded' end },
    adb = adb,
  }
  throwing:build(request, function(err) thrown_start = err end)
  expect('throwing runner is contained', thrown_start.code, 'adapter_failed')

  local malformed_result
  local malformed_observed = 0
  local malformed = Execution.new {
    runner = {
      start = function(_, callback)
        callback(nil, true)
        return { cancel = function() return false end }
      end,
    },
    adb = adb,
  }
  malformed:build(
    vim.tbl_extend('force', request, {
      on_task_complete = function() malformed_observed = malformed_observed + 1 end,
    }),
    function(err) malformed_result = err end
  )
  expect('malformed runner result is contained', malformed_result.code, 'invalid_runner_result')
  expect('malformed runner result is not observed', malformed_observed, 0)

  local invalid_problems
  Execution.new({
    runner = {
      start = function(_, callback)
        callback(nil, {
          status = 'failure',
          problems = { { path = 'relative/Main.kt', line = 1, message = 'bad path', severity = 'error' } },
        })
      end,
    },
    adb = adb,
  }):build(request, function(err) invalid_problems = err end)
  expect('malformed custom-runner problems are contained', invalid_problems.code, 'invalid_runner_result')

  local observer_failure
  execution:build(
    vim.tbl_extend('force', request, {
      on_task_complete = function(_, task_result)
        task_result.status = 'failure'
        task_result.metadata.root = '/mutated'
        error 'problem sink exploded'
      end,
    }),
    function(err, result) observer_failure = { err = err, result = result } end
  )
  pending_runner(nil, { status = 'success', code = 0 })
  expect('task observer failure does not replace task success', observer_failure.err, nil)
  expect('task observer failure leaves the workflow result intact', observer_failure.result.kind, 'build')
  expect('task observer cannot mutate the workflow task result', observer_failure.result.task.status, 'success')
  expect('task observer cannot mutate task metadata', observer_failure.result.task.metadata.root, '/project')

  local incomplete_output
  execution:build(
    vim.tbl_extend('force', request, {
      on_task_complete = function(_, result) incomplete_output = result end,
    }),
    function() end
  )
  calls[#calls].request.on_output(true)
  pending_runner(nil, { status = 'success', code = 0 })
  expect('malformed custom output marks problem collection incomplete', incomplete_output.problems_truncated, true)

  local nil_handle_callback
  local nil_handle_result
  local nil_handle_execution = Execution.new {
    runner = {
      start = function(_, callback)
        nil_handle_callback = callback
        return nil
      end,
    },
    adb = adb,
  }
  handle = nil_handle_execution:build(request, function(err, result) nil_handle_result = { err = err, result = result } end)
  expect('optional nil runner handle refuses cancellation', handle:cancel(), false)
  expect('optional nil runner handle stays observable', nil_handle_result, nil)
  nil_handle_callback(nil, { status = 'success', code = 0 })
  expect('optional nil runner handle completes normally', nil_handle_result.result.kind, 'build')

  local adb_start_error
  Execution.new({
    runner = {
      start = function(_, callback)
        callback(nil, { status = 'success', code = 0 })
        return { cancel = function() return false end }
      end,
    },
    adb = { resolve_launch_components = function() error 'ADB adapter exploded' end },
  }):run(request, function(err) adb_start_error = err end)
  expect('throwing ADB adapter is contained', adb_start_error.code, 'adapter_failed')

  local malformed_components
  Execution.new({
    runner = {
      start = function(_, callback)
        callback(nil, { status = 'success', code = 0 })
        return { cancel = function() return false end }
      end,
    },
    adb = {
      resolve_launch_components = function(_, _, _, callback)
        callback(nil, { true })
        return { cancel = function() return false end }
      end,
    },
  }):run(request, function(err) malformed_components = err end)
  expect('malformed launcher item is contained', malformed_components.code, 'invalid_adb_result')
end, debug.traceback)

if not ok then fail('unexpected test error', unexpected) end

if #failures > 0 then
  vim.api.nvim_err_writeln('Android Workbench execution validation failed:\n- ' .. table.concat(failures, '\n- '))
  vim.cmd 'cquit 1'
end

print 'Android Workbench execution validation passed'
vim.cmd 'qa!'
