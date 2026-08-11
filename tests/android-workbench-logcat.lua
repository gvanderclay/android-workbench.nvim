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

local function expect_false(name, value)
  if not value then return end
  fail(name, 'expected a falsy value')
end

local function contains_line(lines, expected)
  for _, line in ipairs(lines) do
    if line == expected then return true end
  end
  return false
end

local function buffer_lines(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then return {} end
  return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
end

local function press(bufnr, lhs)
  local winid = vim.fn.bufwinid(bufnr)
  assert(winid ~= -1, ('buffer %d is not visible'):format(bufnr))
  vim.api.nvim_set_current_win(winid)
  local keys = vim.api.nvim_replace_termcodes(lhs, true, false, true)
  vim.api.nvim_feedkeys(keys, 'mx', false)
end

local function fake_timer()
  local timer = { stops = 0, closes = 0, closing = false }
  function timer:stop() self.stops = self.stops + 1 end
  function timer:is_closing() return self.closing end
  function timer:close()
    self.closes = self.closes + 1
    self.closing = true
  end
  return timer
end

local function fake_runner()
  local fake = { calls = {} }
  fake.adapter = {
    start = function(request, callback)
      local call = {
        request = request,
        callback = callback,
        cancellations = 0,
      }
      fake.calls[#fake.calls + 1] = call
      call.handle = {
        cancel = function()
          call.cancellations = call.cancellations + 1
          return true
        end,
      }
      return call.handle
    end,
  }
  return fake
end

local Model = require 'android_workbench.logcat.model'
local Native = require 'android_workbench.logcat.native'

local temporary_root = vim.fn.tempname()
vim.fn.mkdir(temporary_root, 'p')
temporary_root = assert(vim.uv.fs_realpath(temporary_root))
local project_dir = vim.fs.joinpath(temporary_root, 'app')
local selected_source = vim.fs.joinpath(project_dir, 'src', 'debug', 'kotlin', 'com', 'example', 'Crash.kt')
local source_paths = {
  selected_source,
  vim.fs.joinpath(project_dir, 'src', 'main', 'kotlin', 'com', 'example', 'Crash.kt'),
  vim.fs.joinpath(project_dir, 'src', 'debug', 'kotlin', 'wrong', 'Crash.kt'),
  vim.fs.joinpath(temporary_root, 'library', 'src', 'debug', 'kotlin', 'com', 'example', 'Crash.kt'),
}

for _, path in ipairs(source_paths) do
  vim.fn.mkdir(vim.fs.dirname(path), 'p')
  vim.fn.writefile({ 'package com.example', 'class Crash' }, path)
end

local notifications = {}
local picker_calls = {}
local picker_choice
local input_calls = {}
local input_value
local timers = {}
local device_serial = 'adb-example (2)._adb-tls-connect._tcp'

local picker = {
  select = function(request, callback)
    picker_calls[#picker_calls + 1] = request
    callback(nil, picker_choice)
  end,
}

local function input(request, callback)
  input_calls[#input_calls + 1] = request
  callback(input_value)
end

local function immediate(callback) callback() end

local function defer(callback, timeout_ms)
  local timer = fake_timer()
  timer.callback = callback
  timer.timeout_ms = timeout_ms
  timers[#timers + 1] = timer
  return timer
end

local function request(on_exit)
  return {
    root = temporary_root,
    project_dir = project_dir,
    variant = 'debug',
    resolve_adb = function() return '/fake/adb' end,
    device_serial = device_serial,
    application_id = 'com.example.app',
    focus = true,
    on_exit = on_exit,
  }
end

local buffers_to_delete = {}
local user_ft_group = vim.api.nvim_create_augroup('AndroidWorkbenchLogcatUserFtTest', { clear = true })
vim.api.nvim_create_autocmd('FileType', {
  group = user_ft_group,
  pattern = 'androidlogcat',
  callback = function(args)
    vim.keymap.set('n', 'q', '<Nop>', {
      buffer = args.buf,
      desc = 'User Logcat mapping',
    })
  end,
})

local ok, unexpected = xpcall(function()
  local parsed = Model.parse_line '2026-08-10 12:34:56.789 123 456 W ExampleTag: warning payload'
  expect('threadtime timestamp is parsed', parsed.timestamp, '2026-08-10 12:34:56.789')
  expect('threadtime process identity is parsed', { parsed.pid, parsed.tid }, { 123, 456 })
  expect('threadtime priority is normalized', { parsed.priority, parsed.level, parsed.rank }, { 'W', 'warn', 4 })
  expect('threadtime tag and message are parsed', { parsed.tag, parsed.message }, { 'ExampleTag', 'warning payload' })

  local continuation = Model.parse_line('    at com.example.Crash.fail(Crash.kt:2)', parsed)
  expect('continuation inherits record identity', {
    continuation.continuation,
    continuation.pid,
    continuation.tag,
    continuation.level,
  }, { true, 123, 'ExampleTag', 'warn' })
  local frame = Model.parse_frame(continuation)
  expect('Kotlin stack frame is parsed', frame and {
    frame.class_name,
    frame.method_name,
    frame.file_name,
    frame.line,
  }, { 'com.example.Crash', 'fail', 'Crash.kt', 2 })

  expect_true('minimum level includes equal priority', Model.matches(parsed, { level = 'warn' }))
  expect_false(
    'minimum level excludes lower priority',
    Model.matches(Model.parse_line '2026-08-10 12:34:56.789 123 456 I ExampleTag: warning payload', { level = 'warn' })
  )
  expect_true('tag filter is case-insensitive', Model.matches(parsed, { tag = 'example' }))
  expect_false('tag filter requires a matching tag', Model.matches(parsed, { tag = 'other' }))
  expect_true('text filter is case-insensitive', Model.matches(parsed, { text = 'PAYLOAD' }))
  expect_false('text filter rejects absent text', Model.matches(parsed, { text = 'absent' }))

  expect(
    'source resolution favors selected variant, module, and package',
    Model.best_sources(source_paths, frame, {
      project_dir = project_dir,
      variant = 'debug',
    }),
    { selected_source }
  )

  local runner = fake_runner()
  local exits = {}
  local native = Native.new {
    runner = runner.adapter,
    picker = picker,
    notifications = {
      emit = function(event) notifications[#notifications + 1] = event end,
    },
    input = input,
    schedule = immediate,
    defer_fn = defer,
    initial_lines = 25,
    max_records = 8,
    height = 8,
    uid_timeout_ms = 4321,
  }
  local handle = native.start(request(function(result) exits[#exits + 1] = result end))
  local status = handle:status()
  local bufnr = status.bufnr
  buffers_to_delete[#buffers_to_delete + 1] = bufnr

  local user_mapping
  for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(bufnr, 'n')) do
    if mapping.lhs == 'q' then user_mapping = mapping end
  end
  expect('user ftplugin mappings override native defaults', user_mapping and user_mapping.desc, 'User Logcat mapping')

  expect('UID query uses exact direct argv', runner.calls[1].request.argv, {
    '/fake/adb',
    '-s',
    device_serial,
    'shell',
    'cmd',
    'package',
    'list',
    'packages',
    '-U',
    '--user',
    'current',
    'com.example.app',
  })
  expect('UID query runs from the project root', runner.calls[1].request.cwd, temporary_root)
  expect('UID resolution phase is observable', status.phase, 'resolving-app')
  expect('UID timeout is configured exactly', timers[#timers].timeout_ms, 4321)

  runner.calls[1].callback(nil, {
    status = 'success',
    stdout = 'package:com.example.app.debug uid:10123\r\npackage:com.example.app uid:10101\r\n',
  })
  expect('exact package UID wins over a prefix match', handle:status().uid, 10101)
  expect('UID resolution starts exactly one stream', #runner.calls, 2)
  expect('Logcat stream uses exact UID-scoped argv', runner.calls[2].request.argv, {
    '/fake/adb',
    '-s',
    device_serial,
    'logcat',
    '--uid=10101',
    '-b',
    'main,system,crash',
    '-v',
    'threadtime,year,printable',
    '-T',
    '25',
    '*:V',
  })
  expect('stream metadata retains exact app identity', runner.calls[2].request.metadata, {
    kind = 'android-logcat',
    root = temporary_root,
    application_id = 'com.example.app',
    device_serial = device_serial,
    uid = 10101,
  })

  local debug_line = '2026-08-10 12:00:00.001 101 201 D Startup: boot sequence'
  local info_line = '2026-08-10 12:00:00.002 101 202 I Network: connected'
  local warn_line = '2026-08-10 12:00:00.003 101 203 W CrashTag: warning needle'
  local error_line = '2026-08-10 12:00:00.004 101 204 E CrashTag: IllegalStateException'
  local frame_line = '    at com.example.Crash.fail(Crash.kt:2)'
  local output = runner.calls[2].request.on_output
  output { stream = 'stdout', data = debug_line:sub(1, 27) }
  output { stream = 'stdout', data = debug_line:sub(28) .. '\r' }
  output { stream = 'stdout', data = '\n' .. info_line .. '\r\n' .. warn_line .. '\n' .. error_line:sub(1, 31) }
  output { stream = 'stdout', data = error_line:sub(32) .. '\r\n' .. frame_line .. '\r\n' }
  output { stream = 'stderr', data = 'ignored stderr\n' }

  expect('split chunks and CRLF produce one record per logical line', handle:status().records, 5)
  local lines = buffer_lines(bufnr)
  for name, line in pairs {
    ['debug record is rendered'] = debug_line,
    ['info record is rendered'] = info_line,
    ['warn record is rendered'] = warn_line,
    ['error record is rendered'] = error_line,
    ['continuation record is rendered'] = frame_line,
  } do
    expect_true(name, contains_line(lines, line))
  end

  local log_win = vim.fn.bufwinid(bufnr)
  local frame_row
  for row, line in ipairs(lines) do
    if line == frame_line then frame_row = row end
  end
  expect_true('source frame row is present', frame_row ~= nil)
  if frame_row then
    vim.api.nvim_set_current_win(log_win)
    vim.api.nvim_win_set_cursor(log_win, { frame_row, 0 })
    press(bufnr, 'gf')
    expect('source jump opens selected module and variant', vim.api.nvim_buf_get_name(0), selected_source)
    expect('source jump lands on the parsed line', vim.api.nvim_win_get_cursor(0)[1], 2)
  end

  picker_choice = 'warn'
  press(bufnr, 'l')
  expect('level mapping updates minimum level', handle:status().filters.level, 'warn')
  lines = buffer_lines(bufnr)
  expect_false('level mapping hides lower levels', contains_line(lines, info_line))
  expect_true('level mapping retains equal levels', contains_line(lines, warn_line))
  expect_true('level mapping retains higher levels', contains_line(lines, error_line))

  input_value = 'crashtag'
  press(bufnr, 't')
  expect('tag mapping updates filter', handle:status().filters.tag, 'crashtag')
  lines = buffer_lines(bufnr)
  expect_false('tag mapping hides another tag', contains_line(lines, info_line))
  expect_true('tag mapping matches without case sensitivity', contains_line(lines, warn_line))

  input_value = 'needle'
  press(bufnr, '/')
  expect('text mapping updates filter', handle:status().filters.text, 'needle')
  lines = buffer_lines(bufnr)
  expect_true('text mapping retains matching message', contains_line(lines, warn_line))
  expect_false('text mapping hides nonmatching message', contains_line(lines, error_line))

  press(bufnr, 'x')
  expect('reset mapping restores default filters', handle:status().filters, {
    level = 'verbose',
    tag = nil,
    text = nil,
  })

  press(bufnr, 'p')
  expect('pause mapping updates state', handle:status().paused, true)
  local paused_line = '2026-08-10 12:00:00.005 101 205 I Worker: arrived while paused'
  output { stream = 'stdout', data = paused_line .. '\n' }
  expect('paused stream still captures records', handle:status().records, 6)
  expect_false('paused stream does not mutate visible records', contains_line(buffer_lines(bufnr), paused_line))
  press(bufnr, 'p')
  expect('resume mapping updates state', handle:status().paused, false)
  expect_true('resume renders records captured while paused', contains_line(buffer_lines(bufnr), paused_line))

  press(bufnr, 'f')
  expect('follow mapping disables follow', handle:status().follow, false)
  press(bufnr, 'f')
  expect('follow mapping restores follow', handle:status().follow, true)

  press(bufnr, 'c')
  expect('clear mapping removes history', handle:status().records, 0)
  local retained_after_gap = '2026-08-10 12:00:59.002 101 299 I Gap: retained after truncation'
  output { stream = 'stdout', data = '2026-08-10 12:00:59.001 101 299 I Gap: stale partial' }
  output {
    stream = 'stdout',
    data = 'discarded suffix\n' .. retained_after_gap .. '\n',
    truncated = true,
  }
  expect('truncated output discards cross-gap partial state', handle:status().records, 1)
  expect_true('truncated output retains the next complete record', contains_line(buffer_lines(bufnr), retained_after_gap))
  expect_false('truncated output never stitches stale and retained text', contains_line(buffer_lines(bufnr), 'stale partialdiscarded suffix'))
  press(bufnr, 'c')
  output { stream = 'stdout', data = 'pre-gap partial' }
  output { stream = 'stdout', data = 'discarded post-gap prefix', truncated = true }
  expect('split truncated prefix produces no record', handle:status().records, 0)
  press(bufnr, 'c')
  local split_retained = '2026-08-10 12:00:00.400 101 301 E Gap: split-retained'
  output { stream = 'stdout', data = ' suffix\n' .. split_retained .. '\n' }
  expect('split truncated prefix is discarded through its next newline', handle:status().records, 1)
  expect_true('split gap retains the next complete record', contains_line(buffer_lines(bufnr), split_retained))
  expect_false('split gap never renders its discarded suffix', contains_line(buffer_lines(bufnr), 'discarded post-gap prefix suffix'))
  press(bufnr, 'c')
  for index = 1, 10 do
    output {
      stream = 'stdout',
      data = ('2026-08-10 12:01:00.%03d 101 301 I Bounded: record-%02d\n'):format(index, index),
    }
  end
  expect('history stays within configured bound', handle:status().records, 8)
  lines = buffer_lines(bufnr)
  expect_false('bounded history evicts the oldest record', contains_line(lines, '2026-08-10 12:01:00.001 101 301 I Bounded: record-01'))
  expect_true('bounded history retains the newest record', contains_line(lines, '2026-08-10 12:01:00.010 101 301 I Bounded: record-10'))

  expect('Logcat buffer type is non-file', vim.bo[bufnr].buftype, 'nofile')
  expect('Logcat buffer cannot create a swapfile', vim.bo[bufnr].swapfile, false)
  expect('Logcat buffer is not modifiable after rendering', vim.bo[bufnr].modifiable, false)
  expect('Logcat buffer is readonly', vim.bo[bufnr].readonly, true)
  local write_ok = pcall(vim.api.nvim_buf_set_lines, bufnr, -1, -1, false, { 'unsafe write' })
  expect_false('external writes respect buffer safety', write_ok)

  expect('first stop request succeeds', handle:stop(), true)
  expect('duplicate stop request is ignored', handle:stop(), false)
  expect('stop cancels the stream once', runner.calls[2].cancellations, 1)
  runner.calls[2].callback(nil, { status = 'cancelled' })
  expect('cancelled stream reports a normal stop', exits[1] and exits[1].status, 'stopped')
  expect('stream exit callback runs exactly once', #exits, 1)
  runner.calls[2].callback({ code = 'late_failure' }, { status = 'failure' })
  output { stream = 'stdout', data = 'late output\n' }
  expect('late stream completion cannot finish twice', #exits, 1)
  expect('completed stream cannot stop again', handle:stop(), false)

  local synchronous_calls = {}
  local synchronous_runner = {
    start = function(task, callback)
      local call = { task = task, callback = callback, cancellations = 0 }
      synchronous_calls[#synchronous_calls + 1] = call
      local child = {
        cancel = function()
          call.cancellations = call.cancellations + 1
          return true
        end,
      }
      if #synchronous_calls == 1 then callback(nil, { status = 'success', stdout = 'package:com.example.app uid:20201\n' }) end
      return child
    end,
  }
  local synchronous_exits = {}
  local synchronous_native = Native.new {
    runner = synchronous_runner,
    schedule = immediate,
    defer_fn = defer,
    height = 8,
  }
  local synchronous_handle = synchronous_native.start(request(function(result) synchronous_exits[#synchronous_exits + 1] = result end))
  buffers_to_delete[#buffers_to_delete + 1] = synchronous_handle:status().bufnr
  expect('synchronous UID resolution starts stream', #synchronous_calls, 2)
  expect('completed UID query handle is discarded', synchronous_calls[1].cancellations, 1)
  expect('synchronous Logcat stop succeeds', synchronous_handle:stop(), true)
  expect('synchronous transition cancellation reaches stream', synchronous_calls[2].cancellations, 1)
  expect('synchronous transition waits for stream exit', #synchronous_exits, 0)
  synchronous_calls[2].callback(nil, { status = 'cancelled' })
  expect('synchronous transition exits once after stream', synchronous_exits[1] and synchronous_exits[1].status, 'stopped')

  local restart_runner = fake_runner()
  local restart_exits = {}
  local restart_handle = Native.new({
    runner = restart_runner.adapter,
    schedule = immediate,
    defer_fn = defer,
  }).start(request(function(result) restart_exits[#restart_exits + 1] = result end))
  local restart_bufnr = restart_handle:status().bufnr
  buffers_to_delete[#buffers_to_delete + 1] = restart_bufnr
  expect_true('a stopped stream can restart while its old buffer remains loaded', vim.api.nvim_buf_is_valid(restart_bufnr))
  expect_false('restarted stream gets a distinct buffer name', vim.api.nvim_buf_get_name(restart_bufnr) == vim.api.nvim_buf_get_name(bufnr))
  expect('restart can stop while resolving its UID', restart_handle:stop(), true)
  restart_runner.calls[1].callback(nil, { status = 'cancelled' })
  expect('restart cancellation finishes exactly once', restart_exits[1] and restart_exits[1].status, 'stopped')
  vim.api.nvim_buf_delete(restart_bufnr, { force = true })

  vim.api.nvim_buf_delete(bufnr, { force = true })
  expect('buffer wipe after completion is safe', vim.api.nvim_buf_is_valid(bufnr), false)
  expect('buffer wipe cannot finish twice', #exits, 1)

  local prefix_runner = fake_runner()
  local prefix_exits = {}
  local prefix_handle = Native.new({
    runner = prefix_runner.adapter,
    schedule = immediate,
    defer_fn = defer,
  }).start(request(function(result) prefix_exits[#prefix_exits + 1] = result end))
  buffers_to_delete[#buffers_to_delete + 1] = prefix_handle:status().bufnr
  prefix_runner.calls[1].callback(nil, {
    status = 'success',
    stdout = 'package:com.example.app.debug uid:20202\n',
  })
  expect('prefix-only package output is rejected', prefix_exits[1] and prefix_exits[1].error.code, 'package_not_installed')
  expect('prefix-only package output cannot start Logcat', #prefix_runner.calls, 1)
  prefix_runner.calls[1].callback(nil, { status = 'success', stdout = 'package:com.example.app uid:20201\n' })
  expect('late UID callback cannot finish twice', #prefix_exits, 1)
  vim.api.nvim_buf_delete(prefix_handle:status().bufnr, { force = true })

  local malformed_runner = fake_runner()
  local malformed_exits = {}
  local malformed_handle = Native.new({
    runner = malformed_runner.adapter,
    schedule = immediate,
    defer_fn = defer,
  }).start(request(function(result) malformed_exits[#malformed_exits + 1] = result end))
  buffers_to_delete[#buffers_to_delete + 1] = malformed_handle:status().bufnr
  malformed_runner.calls[1].callback(nil, {
    status = 'success',
    stdout = 'package:com.example.app uid:not-a-number\n',
  })
  expect('malformed exact package UID is classified', malformed_exits[1] and malformed_exits[1].error.code, 'invalid_uid_output')
  expect('malformed exact package UID cannot start Logcat', #malformed_runner.calls, 1)
end, debug.traceback)

vim.api.nvim_del_augroup_by_id(user_ft_group)
for _, bufnr in ipairs(buffers_to_delete) do
  if vim.api.nvim_buf_is_valid(bufnr) then pcall(vim.api.nvim_buf_delete, bufnr, { force = true }) end
end
vim.fn.delete(temporary_root, 'rf')

if not ok then fail('unexpected test error', unexpected) end

if #failures > 0 then
  vim.api.nvim_err_writeln('Android Workbench Logcat validation failed:\n- ' .. table.concat(failures, '\n- '))
  vim.cmd 'cquit 1'
end

print 'Android Workbench Logcat validation passed'
vim.cmd 'qa!'
