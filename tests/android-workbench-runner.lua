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
local Runner = require 'android_workbench.runner'
local TaskOperation = require 'android_workbench.task_operation'
local Overseer = require 'android_workbench.integrations.overseer'

local function immediate(callback) callback() end

local function queued_scheduler()
  local callbacks = {}
  return callbacks,
    function(callback) callbacks[#callbacks + 1] = callback end,
    function()
      local callback = table.remove(callbacks, 1)
      if callback then callback() end
    end
end

local ok, unexpected = xpcall(function()
  local scheduled, schedule, flush_one = queued_scheduler()
  local delivery_order = {}
  local queued_completed
  local queued_operation = TaskOperation.new({
    argv = { '/project/gradlew', ':app:assembleDebug' },
    cwd = '/project',
    on_output = function(event)
      delivery_order[#delivery_order + 1] = {
        stream = event.stream,
        data = event.data,
        truncated = event.truncated,
      }
    end,
  }, function(err, result)
    delivery_order[#delivery_order + 1] = { terminal = true }
    queued_completed = { err = err, result = result }
  end, {
    schedule = schedule,
    max_capture_bytes = 8,
    max_drain_bytes = 6,
  })

  queued_operation:output('stdout', 'abcdef')
  queued_operation:output('stderr', '12')
  queued_operation:output('stdout', '34')
  queued_operation:output('stdout', '5678')
  expect('output burst queues one drain', #scheduled, 1)
  expect('pending output keeps a bounded newest tail', queued_operation:pending_output(), {
    bytes = 8,
    events = 3,
    scheduled = true,
    truncated = true,
  })
  queued_operation:complete(nil, { status = 'success', code = 0, signal = 0 })
  expect('terminal callback shares the pending drain', #scheduled, 1)
  expect('terminal callback waits for pending output', queued_completed, nil)
  flush_one()
  expect('output drain keeps only one follow-up scheduled', #scheduled, 1)
  expect('terminal callback waits for every output drain', queued_completed, nil)
  flush_one()
  expect('pending output preserves stream order and coalesces adjacent chunks', delivery_order, {
    { stream = 'stderr', data = '12', truncated = true },
    { stream = 'stdout', data = '3456' },
    { stream = 'stdout', data = '78' },
    { terminal = true },
  })
  expect('queued operation completes after its output', queued_completed.err, nil)
  expect('queued operation reports delivery truncation', queued_completed.result.output_truncated, true)
  expect('queued operation retains its bounded stdout capture', queued_completed.result.stdout, 'ef345678')

  local problem_completed
  local original_problem = {
    path = '/project/src/../src/Main.kt',
    line = 17,
    column = 4,
    message = 'Unresolved reference',
    severity = 'error',
  }
  local problem_operation = TaskOperation.new({
    argv = { '/project/gradlew', ':app:assembleDebug' },
    cwd = '/project',
  }, function(err, result) problem_completed = { err = err, result = result } end, { schedule = immediate })
  problem_operation:complete(nil, {
    status = 'failure',
    code = 1,
    problems = { original_problem },
    problems_truncated = false,
  })
  original_problem.message = 'mutated after completion'
  expect('task operation accepts neutral problem data', problem_completed.err, nil)
  expect('task operation copies and normalizes neutral problem data', problem_completed.result.problems, {
    {
      path = '/project/src/Main.kt',
      line = 17,
      column = 4,
      message = 'Unresolved reference',
      severity = 'error',
    },
  })
  expect('task operation retains problem truncation state', problem_completed.result.problems_truncated, false)

  local invalid_problem
  TaskOperation.new({
    argv = { '/project/gradlew', ':app:assembleDebug' },
    cwd = '/project',
  }, function(err) invalid_problem = err end, { schedule = immediate }):complete(nil, {
    status = 'failure',
    problems = { { path = 'relative/Main.kt', line = 1, message = 'bad path', severity = 'error' } },
  })
  expect('task operation rejects malformed problem data', invalid_problem.code, 'invalid_task_result')

  local burst_scheduled, burst_schedule, burst_flush = queued_scheduler()
  local burst_output = {}
  local burst_completed
  local burst_operation = TaskOperation.new({
    argv = { '/project/gradlew', ':app:assembleDebug' },
    cwd = '/project',
    on_output = function(event) burst_output[#burst_output + 1] = event end,
  }, function(err, result) burst_completed = { err = err, result = result } end, {
    schedule = burst_schedule,
    max_capture_bytes = 2048,
  })
  for _ = 1, 1100 do
    burst_operation:output('stdout', 'x')
  end
  expect('event-count burst keeps one scheduled drain', #burst_scheduled, 1)
  expect('event-count burst is bounded before delivery', burst_operation:pending_output(), {
    bytes = 1024,
    events = 1024,
    scheduled = true,
    truncated = true,
  })
  burst_operation:complete(nil, { status = 'success', code = 0 })
  while #burst_scheduled > 0 do
    burst_flush()
  end
  expect('event-count burst completes after draining', burst_completed.err, nil)
  expect_true('event-count burst marks the first retained delivery', burst_output[1] and burst_output[1].truncated == true)
  expect('event-count burst retains the newest bounded tail', #table.concat(vim.tbl_map(function(event) return event.data end, burst_output)), 1024)

  local invocation
  local exit
  local kills = {}
  local callback_count = 0
  local output = {}
  local completed
  local native = Runner.new {
    schedule = immediate,
    max_capture_bytes = 8,
    system = function(argv, opts, on_exit)
      invocation = { argv = argv, opts = opts }
      exit = on_exit
      return {
        kill = function(_, signal)
          kills[#kills + 1] = signal
          return true
        end,
      }
    end,
  }

  local request = {
    argv = { '/project/gradlew', ':app:assembleDebug' },
    cwd = '/project',
    env = { ANDROID_SERIAL = 'emulator-5554' },
    name = 'Build app debug',
    metadata = { kind = 'build', target_id = ':app#debug' },
    on_output = function(event) output[#output + 1] = event end,
  }
  local native_handle = native.start(request, function(err, result)
    callback_count = callback_count + 1
    completed = { err = err, result = result }
  end)
  expect('native argv stays direct', invocation.argv, request.argv)
  expect('native cwd is forwarded', invocation.opts.cwd, request.cwd)
  expect('native env is forwarded', invocation.opts.env, request.env)
  expect('native requests text output', invocation.opts.text, true)

  invocation.opts.stdout(nil, '12345')
  invocation.opts.stdout(nil, '67890')
  invocation.opts.stderr(nil, 'warning')
  exit { code = 0, signal = 0 }
  expect('native completion error', completed.err, nil)
  expect('native success status', completed.result.status, 'success')
  expect('native exit code', completed.result.code, 0)
  expect('native keeps bounded stdout tail', completed.result.stdout, '34567890')
  expect('native reports stdout truncation', completed.result.stdout_truncated, true)
  expect('native captures stderr', completed.result.stderr, 'warning')
  expect('native result keeps neutral metadata', completed.result.metadata, request.metadata)
  local runner_result_conforms, runner_result_err = PortContracts.check(completed.result, PortContracts.runner_result)
  expect('native runner result contract is exact', runner_result_err, nil)
  expect('native runner result contract is complete', runner_result_conforms, true)
  expect('native emits neutral output events', output, {
    { stream = 'stdout', data = '12345' },
    { stream = 'stdout', data = '67890' },
    { stream = 'stderr', data = 'warning' },
  })
  local output_event_conforms, output_event_err = PortContracts.check(output[1], PortContracts.runner_output)
  expect('native runner output event contract is exact', output_event_err, nil)
  expect('native runner output event contract is complete', output_event_conforms, true)
  expect('completed native task cannot cancel', native_handle:cancel(), false)
  exit { code = 7, signal = 0 }
  expect('native completion is exactly once', callback_count, 1)

  local cancelled
  native_handle = native.start(request, function(err, result) cancelled = { err = err, result = result } end)
  expect('native dot cancellation succeeds', native_handle.cancel(), true)
  expect('native cancellation sends SIGTERM', kills[#kills], 15)
  expect('native waits for cancelled process exit', cancelled, nil)
  exit { code = 143, signal = 15 }
  expect('native cancellation is a result', cancelled.result.status, 'cancelled')
  expect('native cancellation has no adapter error', cancelled.err, nil)
  expect('cancelled native task stays completed once', cancelled.result.status, 'cancelled')

  local refused_exit
  local refused_result
  local refused_native = Runner.new {
    schedule = immediate,
    system = function(_, _, on_exit)
      refused_exit = on_exit
      return { kill = function() error 'signal refused' end }
    end,
  }
  local refused_handle = refused_native.start(request, function(err, result) refused_result = { err = err, result = result } end)
  expect('native signal failure rejects cancellation', refused_handle:cancel(), false)
  expect('native signal failure keeps completion pending', refused_result, nil)
  refused_exit { code = 0, signal = 0 }
  expect('native process remains observable after rejected cancellation', refused_result.result.status, 'success')

  local false_exit
  local false_result
  local false_native = Runner.new {
    schedule = immediate,
    system = function(_, _, on_exit)
      false_exit = on_exit
      return { kill = function() return false end }
    end,
  }
  local false_handle = false_native.start(request, function(err, result) false_result = { err = err, result = result } end)
  expect('native false signal result rejects cancellation', false_handle:cancel(), false)
  expect('native false signal result keeps completion pending', false_result, nil)
  false_exit { code = 0, signal = 0 }
  expect('native false signal result preserves natural completion', false_result.result.status, 'success')

  local synchronous_kill_callbacks, synchronous_kill_schedule, synchronous_kill_flush = queued_scheduler()
  local synchronous_kill_result
  local synchronous_kill_exit
  local synchronous_kill_native = Runner.new {
    schedule = synchronous_kill_schedule,
    system = function(_, _, on_exit)
      synchronous_kill_exit = on_exit
      return {
        kill = function()
          synchronous_kill_exit { code = 143, signal = 15 }
          return false
        end,
      }
    end,
  }
  local synchronous_kill_handle = synchronous_kill_native.start(request, function(err, result) synchronous_kill_result = { err = err, result = result } end)
  expect('synchronous native exit wins over false signal result', synchronous_kill_handle:cancel(), true)
  expect('synchronous native cancellation callback remains queued', #synchronous_kill_callbacks, 1)
  synchronous_kill_flush()
  expect('synchronous native cancellation is classified', synchronous_kill_result.result.status, 'cancelled')

  local invalid_process
  Runner.new({ schedule = immediate, system = function() return true end }).start(request, function(err) invalid_process = err end)
  expect('native scalar process is contained', invalid_process.code, 'spawn_failed')

  local invalid_completion
  Runner.new({
    schedule = immediate,
    system = function(_, _, on_exit)
      on_exit(true)
      return { kill = function() return true end }
    end,
  }).start(request, function(err) invalid_completion = err end)
  expect('native scalar completion is contained', invalid_completion.code, 'invalid_process_result')

  local invalid_signal
  Runner.new({
    schedule = immediate,
    system = function(_, _, on_exit)
      on_exit { code = 0, signal = 'SIGTERM' }
      return { kill = function() return true end }
    end,
  }).start(request, function(err) invalid_signal = err end)
  expect('native string signal is contained', invalid_signal.code, 'invalid_process_result')

  local invalid_output
  local invalid_output_exit
  local invalid_output_native = Runner.new {
    schedule = immediate,
    system = function(_, options, on_exit)
      invalid_output_exit = on_exit
      options.stdout(nil, true)
      return { kill = function() return true end }
    end,
  }
  invalid_output_native.start(request, function(err) invalid_output = err end)
  invalid_output_exit { code = 143, signal = 15 }
  expect('native non-string output is contained', invalid_output.code, 'invalid_process_output')

  local pending_native_callbacks, pending_native_schedule, pending_native_flush = queued_scheduler()
  local pending_native_exit
  local pending_native_result
  local pending_native = Runner.new {
    schedule = pending_native_schedule,
    system = function(_, _, on_exit)
      pending_native_exit = on_exit
      return { kill = function() return true end }
    end,
  }
  local pending_native_handle = pending_native.start(request, function(err, result) pending_native_result = { err = err, result = result } end)
  pending_native_exit { code = 0, signal = 0 }
  expect('terminal native callback is queued', #pending_native_callbacks, 1)
  expect('terminal-but-undelivered native cancellation succeeds', pending_native_handle:cancel(), true)
  pending_native_flush()
  expect('terminal-but-undelivered native result is cancelled', pending_native_result.result.status, 'cancelled')

  local stubborn_completed
  local stubborn = Runner.new { kill_grace_ms = 20 }
  local stubborn_handle = stubborn.start({
    argv = { '/bin/sh', '-c', "trap '' TERM; exec sleep 10" },
    cwd = assert(vim.uv.cwd()),
    name = 'TERM-ignoring native runner test',
  }, function(err, result) stubborn_completed = { err = err, result = result } end)
  vim.wait(50)
  expect('TERM-ignoring child cancellation starts', stubborn_handle:cancel(), true)
  expect_true('TERM-ignoring child is killed within the bound', vim.wait(1000, function() return stubborn_completed ~= nil end, 10))
  expect('bounded cancellation has no adapter error', stubborn_completed.err, nil)
  expect('bounded cancellation reports cancelled', stubborn_completed.result.status, 'cancelled')
  expect('bounded cancellation escalates to SIGKILL', stubborn_completed.result.signal, 9)

  local invalid
  local before_invalid = invocation
  native.start({ argv = {}, cwd = '/project' }, function(err) invalid = err end)
  expect('invalid request is classified', invalid.code, 'invalid_request')
  expect('invalid request does not spawn', invocation, before_invalid)

  for _, case in ipairs {
    { option = 'max_output_bytes', value = 0 },
    { option = 'max_output_lines', value = 1.5 },
    { option = 'height', value = math.huge },
  } do
    local valid, err = pcall(Runner.new, { [case.option] = case.value })
    expect(case.option .. ' rejects an invalid bound', valid, false)
    expect_true(case.option .. ' error names the option', tostring(err):find(case.option, 1, true) ~= nil)
  end

  local real_completed
  Runner.new().start({
    argv = { '/bin/sh', '-c', "printf 'native-out'; printf 'native-err' >&2" },
    cwd = assert(vim.uv.cwd()),
    env = {},
    name = 'Native runner smoke',
  }, function(err, result) real_completed = { err = err, result = result } end)
  expect_true('real native process completes', vim.wait(1000, function() return real_completed ~= nil end, 10))
  expect('real native process has no adapter error', real_completed.err, nil)
  expect('real native process succeeds', real_completed.result.status, 'success')
  expect('real native stdout is captured', real_completed.result.stdout, 'native-out')
  expect('real native stderr is captured', real_completed.result.stderr, 'native-err')

  local output_calls = {}
  local output_runner = Runner.new {
    schedule = immediate,
    max_output_bytes = 256,
    max_output_lines = 8,
    height = 5,
    system = function(argv, options, on_exit)
      output_calls[#output_calls + 1] = { argv = argv, options = options, on_exit = on_exit }
      return { kill = function() return true end }
    end,
  }
  local origin_win = vim.api.nvim_get_current_win()
  local origin_buf = vim.api.nvim_win_get_buf(origin_win)
  local output_completed
  local downstream_output = {}
  output_runner.start({
    argv = { '/project/gradlew', ':app:assembleDebug' },
    cwd = '/project',
    name = 'Android build :app · debug',
    metadata = { kind = 'android-build', root = '/project' },
    on_output = function(event) downstream_output[#downstream_output + 1] = event end,
  }, function(err, result) output_completed = { err = err, result = result } end)

  local output_buf
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(bufnr) and vim.bo[bufnr].filetype == 'androidtaskoutput' then output_buf = bufnr end
  end
  expect_true('native Gradle task creates an owned output buffer', output_buf ~= nil)
  expect('native output opens without moving focus', vim.api.nvim_get_current_win(), origin_win)
  expect('native output leaves the origin buffer alone', vim.api.nvim_win_get_buf(origin_win), origin_buf)
  expect('native runner exposes an internal reopen operation', type(output_runner._show_output), 'function')

  if output_buf then
    local output_win = vim.fn.bufwinid(output_buf)
    expect_true('native Gradle output is visible while the task runs', output_win ~= -1)
    expect('native output buffer is a scratch buffer', vim.bo[output_buf].buftype, 'nofile')
    expect('native output buffer is not writable', vim.bo[output_buf].modifiable, false)
    local hide_mapping
    local follow_mapping
    for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(output_buf, 'n')) do
      if mapping.lhs == 'q' then hide_mapping = mapping end
      if mapping.lhs == 'f' then follow_mapping = mapping end
    end
    expect('native output has a local hide mapping', hide_mapping and hide_mapping.desc, 'Hide Android task output')
    expect('native output has a local follow mapping', follow_mapping and follow_mapping.desc, 'Toggle Android task output follow')
    expect_true('native output bar shows follow state beside its key', vim.wo[output_win].winbar:find('[f] follow:on', 1, true) ~= nil)
    if follow_mapping and follow_mapping.callback then
      follow_mapping.callback()
      expect_true('native follow mapping visibly turns follow off', vim.wo[output_win].winbar:find('[f] follow:off', 1, true) ~= nil)
      follow_mapping.callback()
      expect_true('native follow mapping visibly turns follow on', vim.wo[output_win].winbar:find('[f] follow:on', 1, true) ~= nil)
    end

    output_calls[1].options.stdout(nil, 'Could not resolve dependency com.example:missing:1\nTry --stacktrace\n')
    output_calls[1].options.stderr(nil, 'BUILD FAILED')
    output_calls[1].on_exit { code = 1, signal = 0 }
    expect('native locationless failure remains inspectable', vim.api.nvim_buf_get_lines(output_buf, 0, -1, false), {
      'Could not resolve dependency com.example:missing:1',
      'Try --stacktrace',
      'BUILD FAILED',
    })
    expect('native locationless failure completes normally', output_completed.result.status, 'failure')
    expect('native output remains available to the downstream parser', downstream_output, {
      { stream = 'stdout', data = 'Could not resolve dependency com.example:missing:1\nTry --stacktrace\n' },
      { stream = 'stderr', data = 'BUILD FAILED' },
    })
    expect_true('native output bar shows failure', vim.wo[output_win].winbar:find('FAILURE', 1, true) ~= nil)

    vim.api.nvim_win_close(output_win, true)
    expect('hiding output preserves its buffer', vim.api.nvim_buf_is_valid(output_buf), true)
    if type(output_runner._show_output) == 'function' then
      expect('latest root output can be reopened', output_runner._show_output '/project', true)
      expect('reopen focuses only the owned output buffer', vim.api.nvim_get_current_buf(), output_buf)
    end

    local succeeded
    output_runner.start({
      argv = { '/project/gradlew', ':app:assembleDebug' },
      cwd = '/project',
      name = 'Android build :app · debug',
      metadata = { kind = 'android-build', root = '/project' },
    }, function(err, result) succeeded = { err = err, result = result } end)
    output_calls[2].options.stdout(nil, 'BUILD SUCCESSFUL')
    output_calls[2].on_exit { code = 0, signal = 0 }
    expect('a newer root task replaces the prior output', vim.api.nvim_buf_get_lines(output_buf, 0, -1, false), { 'BUILD SUCCESSFUL' })
    expect('native successful task completes normally', succeeded.result.status, 'success')
    output_win = vim.fn.bufwinid(output_buf)
    expect_true('native output bar shows success', vim.wo[output_win].winbar:find('SUCCESS', 1, true) ~= nil)
    vim.api.nvim_win_close(output_win, true)
    expect('successful output can be reopened', output_runner._show_output '/project', true)
  end

  local bounded_calls = {}
  local bounded_runner = Runner.new {
    schedule = immediate,
    max_output_bytes = 18,
    max_output_lines = 2,
    system = function(_, options, on_exit)
      bounded_calls[#bounded_calls + 1] = { options = options, on_exit = on_exit }
      return { kill = function() return true end }
    end,
  }
  bounded_runner.start({
    argv = { '/bounded/gradlew', ':app:assembleDebug' },
    cwd = '/bounded',
    name = 'Bounded build',
    metadata = { kind = 'android-build', root = '/bounded' },
  }, function() end)
  local bounded_buf
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_get_name(bufnr):find('android-task-output://', 1, true) then
      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      if #lines == 1 and lines[1] == '' and bufnr ~= output_buf then bounded_buf = bufnr end
    end
  end
  bounded_calls[1].options.stdout(nil, 'first\nsecond\nthird')
  if bounded_buf then
    local lines = vim.api.nvim_buf_get_lines(bounded_buf, 0, -1, false)
    expect('native output line bound keeps the newest lines', lines, { '… earlier output truncated …', 'second', 'third' })
    bounded_calls[1].options.stdout(nil, '012345678901234567890')
    lines = vim.api.nvim_buf_get_lines(bounded_buf, 0, -1, false)
    expect_true('native output byte bound is marked', lines[1] == '… earlier output truncated …')
    expect_true('native output raw text stays byte bounded', #table.concat(vim.list_slice(lines, 2), '\n') <= 18)
  else
    fail('bounded native output buffer', 'expected a root-owned output buffer')
  end
  bounded_calls[1].on_exit { code = 1, signal = 0 }
  bounded_runner._close_output()

  local gap_callbacks, gap_schedule, gap_flush = queued_scheduler()
  local gap_call
  local gap_runner = Runner.new {
    schedule = gap_schedule,
    max_capture_bytes = 8,
    system = function(_, options, on_exit)
      gap_call = { options = options, on_exit = on_exit }
      return { kill = function() return true end }
    end,
  }
  gap_runner.start({
    argv = { '/gap/gradlew', ':app:assembleDebug' },
    cwd = '/gap',
    name = 'Gap build',
    metadata = { kind = 'android-build', root = '/gap' },
  }, function() end)
  gap_call.options.stdout(nil, 'stale partial')
  gap_call.options.stdout(nil, '0123456789')
  expect('native output backlog keeps one scheduled drain', #gap_callbacks, 1)
  gap_flush()
  expect('gap output can be shown', gap_runner._show_output '/gap', true)
  expect('delivery truncation never stitches across the gap', vim.api.nvim_buf_get_lines(0, 0, -1, false), {
    '… earlier output truncated …',
    '23456789',
  })
  gap_call.on_exit { code = 1, signal = 0 }
  gap_flush()
  gap_runner._close_output()

  local late_completed
  output_runner.start({
    argv = { '/project/gradlew', ':app:assembleDebug' },
    cwd = '/project',
    name = 'Late build',
    metadata = { kind = 'android-build', root = '/project' },
  }, function(err, result) late_completed = { err = err, result = result } end)
  local late_buf
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(bufnr) and vim.bo[bufnr].filetype == 'androidtaskoutput' and bufnr ~= bounded_buf then late_buf = bufnr end
  end
  output_runner._close_output()
  expect('closing the native owner deletes its retained output', late_buf and vim.api.nvim_buf_is_valid(late_buf), false)
  output_calls[3].options.stdout(nil, 'late output after shutdown')
  output_calls[3].on_exit { code = 0, signal = 0 }
  expect('late native task still reaches its private terminal', late_completed.result.status, 'success')
  expect('late output cannot recreate a closed root view', output_runner._has_output '/project', false)

  local task_definition
  local task
  local stop_behavior = 'complete'
  local overseer_output = {}
  local overseer_completion_count = 0
  local overseer_completed
  local fake_overseer = {
    STATUS = { SUCCESS = 'SUCCESS', FAILURE = 'FAILURE', CANCELED = 'CANCELED' },
    new_task = function(definition)
      task_definition = definition
      task = {
        exit_code = nil,
        subscriptions = {},
        subscribe = function(self, event, callback) self.subscriptions[event] = callback end,
        start = function() return true end,
        stop = function(self)
          if stop_behavior == 'complete_then_throw' then
            self.subscriptions.on_complete(self, 'CANCELED', {})
            error 'stop failed after task completion'
          end
          if stop_behavior == 'throw' then error 'stop failed' end
          if stop_behavior == 'false' then return false end
          self.subscriptions.on_complete(self, 'CANCELED', {})
          return true
        end,
      }
      return task
    end,
  }
  local overseer = Overseer.new { overseer = fake_overseer, schedule = immediate, max_capture_bytes = 8 }
  local overseer_handle = overseer.start(
    vim.tbl_extend('force', request, {
      on_output = function(event) overseer_output[#overseer_output + 1] = event end,
    }),
    function(err, result)
      overseer_completion_count = overseer_completion_count + 1
      overseer_completed = { err = err, result = result }
    end
  )

  expect('Overseer receives direct argv', task_definition.cmd, request.argv)
  expect('Overseer receives cwd', task_definition.cwd, request.cwd)
  expect('Overseer receives env', task_definition.env, request.env)
  expect('Overseer receives name', task_definition.name, request.name)
  expect('Overseer receives metadata', task_definition.metadata, request.metadata)
  expect('Overseer uses jobstart strategy', task_definition.strategy[1], 'jobstart')
  expect('Overseer uses a plain output buffer', task_definition.strategy.use_terminal, false)
  expect('Overseer default keeps exit status ownership', task_definition.components[1], 'on_exit_set_status')
  expect('Overseer default uses the neutral output parser', task_definition.components[2][1], 'on_output_parse')
  expect_true('Overseer default parser is task-local', type(task_definition.components[2].parser) == 'table')
  local first_overseer_parser = task_definition.components[2].parser
  expect('Overseer default opens output without focus', task_definition.components[3], {
    'open_output',
    direction = 'dock',
    focus = false,
    on_start = 'always',
  })
  expect('Overseer default preserves unseen failures', task_definition.components[4], {
    'on_complete_dispose',
    require_view = { 'FAILURE' },
  })
  for _, component in ipairs(task_definition.components) do
    local name = type(component) == 'table' and component[1] or component
    expect_true(
      'Overseer adds no automatic problem publisher',
      name ~= 'on_output_quickfix' and name ~= 'on_result_diagnostics_quickfix' and name ~= 'on_result_diagnostics' and name ~= 'on_result_diagnostics_trouble'
    )
  end
  task_definition.strategy.wrap_opts.on_stdout(1, { 'assemble' }, 'stdout')
  task_definition.strategy.wrap_opts.on_stderr(1, { 'note' }, 'stderr')
  task.exit_code = 1
  task_definition.strategy.wrap_opts.on_exit(1, 1, 'exit')
  expect('Overseer process exit waits for task completion', overseer_completed, nil)
  task.subscriptions.on_complete(task, 'FAILURE', {
    error = 'Gradle failed',
    problems_truncated = false,
    diagnostics = {
      { filename = '/project/app/src/main/java/example/Main.kt', lnum = 17, col = 4, text = 'Unresolved reference', type = 'E' },
    },
  })
  expect('Overseer failure is a neutral result', overseer_completed.result.status, 'failure')
  expect('Overseer result has exit code', overseer_completed.result.code, 1)
  expect('Overseer result keeps bounded output', overseer_completed.result.stdout, 'assemble')
  expect('Overseer result maps task error to text', overseer_completed.result.error, 'Gradle failed')
  expect('Overseer maps parsed diagnostics to neutral problem data', overseer_completed.result.problems, {
    {
      path = '/project/app/src/main/java/example/Main.kt',
      line = 17,
      column = 4,
      message = 'Unresolved reference',
      severity = 'error',
    },
  })
  expect('Overseer reports complete parsed problem data', overseer_completed.result.problems_truncated, false)
  expect('Overseer emits neutral stream events', overseer_output, {
    { stream = 'stdout', data = 'assemble' },
    { stream = 'stderr', data = 'note' },
  })
  task.subscriptions.on_complete(task, 'SUCCESS', {})
  expect('Overseer completion is exactly once', overseer_completion_count, 1)
  expect('completed Overseer task cannot cancel', overseer_handle.cancel(), false)

  local pending_overseer_callbacks, pending_overseer_schedule, pending_overseer_flush = queued_scheduler()
  local pending_overseer_result
  local pending_overseer = Overseer.new { overseer = fake_overseer, schedule = pending_overseer_schedule }
  local pending_overseer_handle = pending_overseer.start(request, function(err, result) pending_overseer_result = { err = err, result = result } end)
  local pending_overseer_definition = task_definition
  local pending_overseer_task = task
  expect_true('Overseer creates a fresh parser for each default task', pending_overseer_definition.components[2].parser ~= first_overseer_parser)
  pending_overseer_task.exit_code = 0
  pending_overseer_definition.strategy.wrap_opts.on_exit(1, 0, 'exit')
  pending_overseer_task.subscriptions.on_complete(pending_overseer_task, 'SUCCESS', {})
  expect('terminal Overseer callback is queued', #pending_overseer_callbacks, 1)
  expect('terminal-but-undelivered Overseer cancellation succeeds', pending_overseer_handle:cancel(), true)
  pending_overseer_flush()
  expect('terminal-but-undelivered Overseer result is cancelled', pending_overseer_result.result.status, 'cancelled')

  local overseer_cancelled
  overseer_handle = overseer.start(request, function(err, result) overseer_cancelled = { err = err, result = result } end)
  local cancelled_definition = task_definition
  expect('Overseer colon cancellation succeeds', overseer_handle:cancel(), true)
  expect('Overseer cancellation remains pending until process exit', overseer_cancelled, nil)
  expect('duplicate Overseer cancellation is ignored while stopping', overseer_handle:cancel(), false)
  cancelled_definition.strategy.wrap_opts.on_exit(1, 143, 'exit')
  expect('Overseer cancellation has no adapter error', overseer_cancelled.err, nil)
  expect('Overseer cancellation maps status', overseer_cancelled.result.status, 'cancelled')
  expect('Overseer jobstart cancellation has no synthetic signal', overseer_cancelled.result.signal, nil)

  stop_behavior = 'false'
  local refused_completion
  overseer_handle = overseer.start(request, function(err, result) refused_completion = { err = err, result = result } end)
  local refused_definition = task_definition
  local refused_task = task
  expect('Overseer false stop result rejects cancellation', overseer_handle:cancel(), false)
  expect('Overseer false stop result does not complete', refused_completion, nil)
  stop_behavior = 'complete'
  refused_definition.strategy.wrap_opts.on_exit(1, 0, 'exit')
  refused_task.exit_code = 0
  refused_task.subscriptions.on_complete(refused_task, 'SUCCESS', {})
  expect('Overseer task remains observable after rejected cancellation', refused_completion.result.status, 'success')

  stop_behavior = 'throw'
  local thrown_completion
  overseer_handle = overseer.start(request, function(err, result) thrown_completion = { err = err, result = result } end)
  local thrown_definition = task_definition
  local thrown_task = task
  expect('Overseer thrown stop rejects cancellation', overseer_handle:cancel(), false)
  expect('Overseer thrown stop does not complete', thrown_completion, nil)
  stop_behavior = 'complete'
  thrown_definition.strategy.wrap_opts.on_exit(1, 0, 'exit')
  thrown_task.exit_code = 0
  thrown_task.subscriptions.on_complete(thrown_task, 'SUCCESS', {})
  expect('Overseer task can still complete after thrown cancellation', thrown_completion.result.status, 'success')

  stop_behavior = 'complete_then_throw'
  local raced_completion
  overseer_handle = overseer.start(request, function(err, result) raced_completion = { err = err, result = result } end)
  local raced_definition = task_definition
  raced_definition.strategy.wrap_opts.on_exit(1, 0, 'exit')
  expect('Overseer terminal completion wins over a thrown stop result', overseer_handle:cancel(), true)
  expect('Overseer completion race still completes', raced_completion.result.status, 'cancelled')

  local stream_failure
  overseer_handle = overseer.start(request, function(err, result) stream_failure = { err = err, result = result } end)
  local stream_definition = task_definition
  stream_definition.strategy.wrap_opts.on_stdout(1, 'read failed', 'stdout')
  expect('Overseer stream failure waits for raw process exit', stream_failure, nil)
  stream_definition.strategy.wrap_opts.on_exit(1, 143, 'exit')
  expect('Overseer stream failure is classified after process exit', stream_failure.err.code, 'stream_error')

  local invalid_overseer
  Overseer.new({ overseer = true, schedule = immediate }).start(request, function(err) invalid_overseer = err end)
  expect('scalar Overseer module is contained', invalid_overseer.code, 'runner_unavailable')

  local nil_start_result
  Overseer.new({
    overseer = {
      new_task = function()
        return {
          subscribe = function() end,
          start = function() end,
          stop = function() return true end,
          dispose = function() end,
        }
      end,
    },
    schedule = immediate,
  }).start(request, function(err) nil_start_result = err end)
  expect('nil Overseer start result is rejected', nil_start_result.code, 'task_start_failed')

  local scalar_status_definition
  local scalar_status_task
  local scalar_status_result
  Overseer.new({
    overseer = {
      STATUS = true,
      new_task = function(definition)
        scalar_status_definition = definition
        scalar_status_task = {
          exit_code = 0,
          subscribe = function(self, _, callback) self.callback = callback end,
          start = function() return true end,
          stop = function() return true end,
        }
        return scalar_status_task
      end,
    },
    schedule = immediate,
  }).start(request, function(err, result) scalar_status_result = { err = err, result = result } end)
  scalar_status_definition.strategy.wrap_opts.on_exit(1, 0, 'exit')
  scalar_status_task.callback(scalar_status_task, 'SUCCESS', {})
  expect('scalar Overseer status table is contained', scalar_status_result.result.status, 'success')

  local rejected_subscription
  Overseer.new({
    overseer = {
      new_task = function()
        return {
          subscribe = function() return false end,
          start = function() return true end,
          stop = function() return true end,
        }
      end,
    },
    schedule = immediate,
  }).start(request, function(err) rejected_subscription = err end)
  expect('rejected Overseer subscription is contained', rejected_subscription.code, 'task_subscribe_failed')

  local synchronous_starts = 0
  local synchronous_completion
  Overseer.new({
    overseer = {
      STATUS = { SUCCESS = 'SUCCESS' },
      new_task = function()
        local synchronous_task = { exit_code = 0 }
        function synchronous_task:subscribe(_, callback) callback(self, 'SUCCESS', {}) end
        function synchronous_task:start()
          synchronous_starts = synchronous_starts + 1
          return true
        end
        function synchronous_task:stop() return false end
        return synchronous_task
      end,
    },
    schedule = immediate,
  }).start(request, function(err, result) synchronous_completion = { err = err, result = result } end)
  expect('synchronously completed Overseer task is not started', synchronous_starts, 0)
  expect('synchronous Overseer completion remains observable', synchronous_completion.result.status, 'success')

  local invalid_exit
  local invalid_exit_adapter = Overseer.new { overseer = fake_overseer, schedule = immediate }
  invalid_exit_adapter.start(request, function(err) invalid_exit = err end)
  local invalid_exit_definition = task_definition
  local invalid_exit_task = task
  invalid_exit_definition.strategy.wrap_opts.on_exit(1, true, 'exit')
  invalid_exit_task.subscriptions.on_complete(invalid_exit_task, 'FAILURE', {})
  expect('scalar Overseer process completion is contained', invalid_exit.code, 'invalid_process_result')

  local invalid_overseer_output
  local invalid_output_adapter = Overseer.new { overseer = fake_overseer, schedule = immediate }
  invalid_output_adapter.start(request, function(err) invalid_overseer_output = err end)
  local invalid_output_definition = task_definition
  local invalid_output_task = task
  invalid_output_definition.strategy.wrap_opts.on_stdout(1, { true }, 'stdout')
  invalid_output_definition.strategy.wrap_opts.on_exit(1, 143, 'exit')
  invalid_output_task.subscriptions.on_complete(invalid_output_task, 'FAILURE', {})
  expect('non-string Overseer output is contained', invalid_overseer_output.code, 'stream_error')

  local custom_components = {
    'on_exit_set_status',
    { 'open_output', direction = 'float', focus = true },
  }
  local custom_components_result
  Overseer.new({ overseer = fake_overseer, schedule = immediate, components = custom_components })
    .start(request, function(err, result) custom_components_result = { err = err, result = result } end)
  local custom_definition = task_definition
  local custom_task = task
  expect_true('explicit Overseer components pass through unchanged', custom_definition.components == custom_components)
  custom_definition.strategy.wrap_opts.on_exit(1, 0, 'exit')
  custom_task.exit_code = 0
  custom_task.subscriptions.on_complete(custom_task, 'SUCCESS', { diagnostics = { true } })
  expect('explicit Overseer components still complete', custom_components_result.result.status, 'success')
  expect('explicit component diagnostics are not interpreted by Workbench', custom_components_result.result.problems, nil)

  local created = 0
  local unavailable = Overseer.new {
    overseer = {
      new_task = function()
        created = created + 1
        error 'unavailable'
      end,
    },
    schedule = immediate,
  }
  local unavailable_error
  unavailable.start(request, function(err) unavailable_error = err end)
  expect('Overseer creation failure is classified', unavailable_error.code, 'task_create_failed')
  expect('Overseer creation attempted once', created, 1)

  local invalid_task_error
  Overseer.new({
    overseer = { new_task = function() return {} end },
    schedule = immediate,
  }).start(request, function(err) invalid_task_error = err end)
  expect('malformed Overseer task is contained', invalid_task_error.code, 'task_create_failed')
end, debug.traceback)

if not ok then fail('unexpected test error', unexpected) end

if #failures > 0 then
  vim.api.nvim_err_writeln('Android Workbench runner validation failed:\n- ' .. table.concat(failures, '\n- '))
  vim.cmd 'cquit 1'
end

print 'Android Workbench runner validation passed'
vim.cmd 'qa!'
