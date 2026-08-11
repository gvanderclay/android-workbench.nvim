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

local discovery = require 'android_workbench.gradle.discovery'
local metadata = require 'android_workbench.gradle.metadata'
local model = require 'android_workbench.gradle.model'
local original_system = vim.system
local nonce = '0123456789abcdef0123456789abcdef'
local protocol_root = '/tmp/android-workbench-root'
local temporary_root

local function jsonl(records, value)
  local lines = {}
  for _, record in ipairs(records) do
    record.schema = 1
    record.nonce = value or nonce
    lines[#lines + 1] = model.marker .. vim.json.encode(record)
  end
  return table.concat(lines, '\n') .. '\n'
end

local function fixture(root, install_task, included_root)
  local app_tasks = { 'assembleRelease' }
  if install_task ~= false then app_tasks[#app_tasks + 1] = 'installRelease' end
  local records = {
    {
      type = 'target',
      build_path = ':',
      build_root = root,
      project_path = ':app',
      project_dir = root .. '/app',
      variant = 'release',
      application_id = 'example.app',
      assemble_task = ':app:assembleRelease',
      install_task = install_task == false and vim.NIL or ':app:installRelease',
    },
    { type = 'project_complete', build_path = ':', project_path = ':app', target_count = 1 },
    {
      type = 'build_complete',
      build_path = ':',
      build_root = root,
      application_projects = { ':app' },
      included_build_roots = included_root and { included_root } or {},
      project_count = 2,
      task_count = 1 + #app_tasks,
    },
  }
  if included_root then
    records[#records + 1] = {
      type = 'build_complete',
      build_path = ':build-logic',
      build_root = included_root,
      application_projects = {},
      included_build_roots = {},
      project_count = 1,
      task_count = 1,
    }
  end
  records[#records + 1] = { type = 'task_chunk', build_path = ':', project_path = ':', chunk_index = 1, names = { 'help' } }
  records[#records + 1] = { type = 'task_project_complete', build_path = ':', project_path = ':', chunk_count = 1, task_count = 1 }
  records[#records + 1] = { type = 'task_chunk', build_path = ':', project_path = ':app', chunk_index = 1, names = app_tasks }
  records[#records + 1] = {
    type = 'task_project_complete',
    build_path = ':',
    project_path = ':app',
    chunk_count = 1,
    task_count = #app_tasks,
  }
  if included_root then
    records[#records + 1] = { type = 'task_chunk', build_path = ':build-logic', project_path = ':', chunk_index = 1, names = { 'help' } }
    records[#records + 1] = {
      type = 'task_project_complete',
      build_path = ':build-logic',
      project_path = ':',
      chunk_count = 1,
      task_count = 1,
    }
  end
  records[#records + 1] = { type = 'tree_complete', build_path = ':' }
  return records
end

local ok, unexpected = xpcall(function()
  local snapshot, err = model.decode(jsonl(fixture(protocol_root, false)), nonce, protocol_root)
  expect('valid model has no error', err, nil)
  expect('JSON null install task normalizes to nil', snapshot.targets[1].install_task, nil)

  local records = fixture(protocol_root, true)
  table.remove(records)
  snapshot, err = model.decode(jsonl(records), nonce, protocol_root)
  expect('incomplete tree is rejected', err.code, 'incomplete_tree')

  snapshot, err = model.decode(jsonl(fixture(protocol_root, true)), 'ffffffffffffffffffffffffffffffff', protocol_root)
  expect('nonce mismatch is rejected', err.code, 'invalid_record')

  local root = vim.fn.tempname()
  temporary_root = root
  assert(vim.fn.mkdir(root, 'p') == 1)
  local wrapper = vim.fs.joinpath(root, 'gradlew')
  assert(vim.fn.writefile({ '#!/bin/sh' }, wrapper) == 0)
  assert(vim.uv.fs_chmod(wrapper, tonumber('700', 8)))
  local build_file = vim.fs.joinpath(root, 'build.gradle.kts')
  assert(vim.fn.writefile({ 'plugins { id("com.android.application") version "1.0" apply false }' }, build_file) == 0)
  root = assert(vim.uv.fs_realpath(root))
  wrapper = vim.fs.joinpath(root, 'gradlew')
  build_file = vim.fs.joinpath(root, 'build.gradle.kts')
  local included_root = vim.fs.joinpath(root, 'build-logic')
  assert(vim.fn.mkdir(included_root, 'p') == 1)

  local invocations = {}
  local mode = 'success'
  local pending_exit
  local kills = {}
  local kill_mode = 'accept'
  vim.system = function(argv, opts, on_exit)
    if type(argv) ~= 'table' or argv[1] ~= wrapper then return original_system(argv, opts, on_exit) end
    invocations[#invocations + 1] = { argv = vim.deepcopy(argv), opts = opts }
    local process = {
      kill = function(_, signal)
        if kill_mode == 'throw' then error 'signal refused' end
        if kill_mode == 'false' then return false end
        if kill_mode == 'synchronous_false' then
          on_exit { code = 143, signal = 15 }
          return false
        end
        kills[#kills + 1] = signal
        return true
      end,
    }

    if mode == 'success' then
      opts.stdout(nil, jsonl(fixture(root, false, included_root), opts.env.ANDROID_WORKBENCH_DISCOVERY_NONCE))
      on_exit { code = 0, signal = 0 }
    elseif mode == 'provider_error' then
      opts.stdout(nil, jsonl({ { type = 'error', code = 'unsupported_project', message = 'unsupported' } }, opts.env.ANDROID_WORKBENCH_DISCOVERY_NONCE))
      on_exit { code = 1, signal = 0 }
    elseif mode == 'invalid_completion' then
      on_exit(true)
    elseif mode == 'invalid_process' then
      return true
    else
      pending_exit = on_exit
    end
    return process
  end

  local result
  discovery.discover({ root = root }, function(callback_err, callback_snapshot) result = { err = callback_err, snapshot = callback_snapshot } end)
  expect_true('discovery callback completes', vim.wait(1000, function() return result ~= nil end, 10))
  expect('discovery process succeeds', result.err, nil)
  expect('discovery returns canonical root', result.snapshot.root, root)
  expect('wrapper is executed directly', invocations[1].argv[1], wrapper)
  expect_true('bundled init script is passed', vim.tbl_contains(invocations[1].argv, '--init-script'))
  expect_true('full discovery disables configuration on demand', vim.tbl_contains(invocations[1].argv, '--no-configure-on-demand'))
  expect('default discovery respects the project configuration-cache policy', vim.tbl_contains(invocations[1].argv, '--configuration-cache'), false)
  expect('default discovery does not force configuration-cache off', vim.tbl_contains(invocations[1].argv, '--no-configuration-cache'), false)
  expect('discovery runs from the project root', invocations[1].opts.cwd, root)
  expect_true('nonce is scoped to the child environment', invocations[1].opts.env.ANDROID_WORKBENCH_DISCOVERY_NONCE:match '^[a-f0-9]+$')
  expect('unchanged Gradle metadata is fresh', discovery.is_stale(result.snapshot), false)
  expect('fingerprinted metadata reports freshness explicitly', metadata.freshness(result.snapshot, invocations[1].argv[3]), 'fresh')

  local unverifiable = metadata.stamp(vim.deepcopy(result.snapshot), vim.fs.joinpath(root, 'missing-provider.gradle'))
  expect('unverifiable metadata is modeled explicitly', metadata.freshness(unverifiable, invocations[1].argv[3]), 'unverifiable')
  expect('explicitly unverifiable metadata avoids repeated discovery', metadata.is_stale(unverifiable, invocations[1].argv[3]), false)
  expect('unstamped metadata refreshes conservatively', metadata.is_stale {}, true)

  assert(vim.fn.writefile({ 'plugins { id("com.android.application") version "2.0" apply false }' }, build_file) == 0)
  expect('changed Gradle metadata is stale', discovery.is_stale(result.snapshot), true)

  result = nil
  local configured_discovery = discovery.new { configuration_cache = false, timeout_ms = false }
  configured_discovery.discover({ root = root }, function(callback_err, callback_snapshot) result = { err = callback_err, snapshot = callback_snapshot } end)
  expect_true('configured discovery completes', vim.wait(1000, function() return result ~= nil end, 10))
  expect('configured discovery succeeds', result.err, nil)
  expect_true('configuration cache can be disabled per adapter', vim.tbl_contains(invocations[2].argv, '--no-configuration-cache'))
  expect('configured adapter exposes fresh snapshot check', configured_discovery.is_stale(result.snapshot), false)

  result = nil
  local cache_enabled_discovery = discovery.new { configuration_cache = true, timeout_ms = false }
  cache_enabled_discovery.discover({ root = root }, function(callback_err, callback_snapshot) result = { err = callback_err, snapshot = callback_snapshot } end)
  expect_true('explicit cache-enabled discovery completes', vim.wait(1000, function() return result ~= nil end, 10))
  expect('explicit cache-enabled discovery succeeds', result.err, nil)
  expect_true('configuration cache can be enabled per adapter', vim.tbl_contains(invocations[3].argv, '--configuration-cache'))
  expect_true('explicit cache policy fails on cache problems', vim.tbl_contains(invocations[3].argv, '--configuration-cache-problems=fail'))

  local source_directory = vim.fs.joinpath(root, 'app', 'src', 'main', 'kotlin')
  assert(vim.fn.mkdir(source_directory, 'p') == 1)
  assert(vim.fn.writefile({ 'class MainActivity' }, vim.fs.joinpath(source_directory, 'MainActivity.kt')) == 0)
  expect('ordinary application source does not invalidate discovery', configured_discovery.is_stale(result.snapshot), false)

  local manifest = vim.fs.joinpath(root, 'app', 'src', 'main', 'AndroidManifest.xml')
  assert(vim.fn.writefile({ '<manifest package="com.example.changed" />' }, manifest) == 0)
  expect('Android manifest changes invalidate discovery', configured_discovery.is_stale(result.snapshot), true)

  result = nil
  configured_discovery.discover({ root = root }, function(callback_err, callback_snapshot) result = { err = callback_err, snapshot = callback_snapshot } end)
  expect_true('discovery refreshes changed Android manifest', vim.wait(1000, function() return result ~= nil end, 10))
  expect('refreshed Android manifest snapshot is fresh', configured_discovery.is_stale(result.snapshot), false)

  local build_source_directory = vim.fs.joinpath(root, 'buildSrc', 'src', 'main', 'kotlin')
  assert(vim.fn.mkdir(build_source_directory, 'p') == 1)
  assert(vim.fn.writefile({ 'class AndroidConventionPlugin' }, vim.fs.joinpath(build_source_directory, 'AndroidConventionPlugin.kt')) == 0)
  expect('buildSrc changes invalidate discovery', configured_discovery.is_stale(result.snapshot), true)

  result = nil
  configured_discovery.discover({ root = root }, function(callback_err, callback_snapshot) result = { err = callback_err, snapshot = callback_snapshot } end)
  expect_true('discovery refreshes changed buildSrc metadata', vim.wait(1000, function() return result ~= nil end, 10))
  expect('refreshed buildSrc snapshot is fresh', configured_discovery.is_stale(result.snapshot), false)

  local included_source_directory = vim.fs.joinpath(included_root, 'src', 'main', 'kotlin')
  assert(vim.fn.mkdir(included_source_directory, 'p') == 1)
  assert(vim.fn.writefile({ 'class IncludedConventionPlugin' }, vim.fs.joinpath(included_source_directory, 'IncludedConventionPlugin.kt')) == 0)
  expect('included build source changes invalidate discovery', configured_discovery.is_stale(result.snapshot), true)

  local configured, timeout_error = pcall(discovery.new, { timeout_ms = 1.5 })
  expect('fractional constructor timeout is rejected', configured, false)
  expect_true('timeout validation is actionable', tostring(timeout_error):find('positive integer', 1, true))

  result = nil
  local invocation_count = #invocations
  discovery.discover(
    { root = root, timeout_ms = math.huge },
    function(callback_err, callback_snapshot) result = { err = callback_err, snapshot = callback_snapshot } end
  )
  expect_true('invalid direct timeout completes', vim.wait(1000, function() return result ~= nil end, 10))
  expect('invalid direct timeout is classified', result.err.code, 'invalid_options')
  expect('invalid timeout never starts Gradle', #invocations, invocation_count)

  mode = 'provider_error'
  result = nil
  discovery.discover({ root = root }, function(callback_err, callback_snapshot) result = { err = callback_err, snapshot = callback_snapshot } end)
  expect_true('provider error callback completes', vim.wait(1000, function() return result ~= nil end, 10))
  expect('structured provider error wins over generic exit', result.err.code, 'unsupported_project')

  mode = 'pending'
  result = nil
  local handle = discovery.discover(
    { root = root },
    function(callback_err, callback_snapshot) result = { err = callback_err, snapshot = callback_snapshot } end
  )
  expect('cancellation starts once', handle.cancel(), true)
  expect('cancellation sends SIGTERM', kills[#kills], 15)
  expect('cancelled discovery waits for child exit', result, nil)
  pending_exit { code = 0, signal = 15 }
  expect_true('cancelled discovery completes', vim.wait(1000, function() return result ~= nil end, 10))
  expect('cancelled discovery is classified', result.err.code, 'cancelled')

  result = nil
  kill_mode = 'throw'
  local refused = discovery.discover(
    { root = root },
    function(callback_err, callback_snapshot) result = { err = callback_err, snapshot = callback_snapshot } end
  )
  expect('Gradle signal failure rejects cancellation', refused:cancel(), false)
  expect('Gradle signal failure keeps result pending', result, nil)
  local refused_invocation = invocations[#invocations]
  refused_invocation.opts.stdout(nil, jsonl(fixture(root, false), refused_invocation.opts.env.ANDROID_WORKBENCH_DISCOVERY_NONCE))
  pending_exit { code = 0, signal = 0 }
  expect_true('Gradle remains observable after rejected cancellation', vim.wait(1000, function() return result ~= nil end, 10))
  expect('Gradle rejected cancellation preserves natural result', result.err, nil)

  result = nil
  kill_mode = 'false'
  local false_refused = discovery.discover(
    { root = root },
    function(callback_err, callback_snapshot) result = { err = callback_err, snapshot = callback_snapshot } end
  )
  expect('Gradle false signal result rejects cancellation', false_refused:cancel(), false)
  expect('Gradle false signal result keeps result pending', result, nil)
  local false_refused_invocation = invocations[#invocations]
  false_refused_invocation.opts.stdout(nil, jsonl(fixture(root, false), false_refused_invocation.opts.env.ANDROID_WORKBENCH_DISCOVERY_NONCE))
  pending_exit { code = 0, signal = 0 }
  expect_true('Gradle false signal result preserves natural completion', vim.wait(1000, function() return result ~= nil end, 10))
  expect('Gradle false signal result keeps natural result', result.err, nil)
  kill_mode = 'accept'

  result = nil
  kill_mode = 'synchronous_false'
  local synchronous_cancel = discovery.discover(
    { root = root },
    function(callback_err, callback_snapshot) result = { err = callback_err, snapshot = callback_snapshot } end
  )
  expect('Gradle synchronous exit wins over false signal result', synchronous_cancel:cancel(), true)
  expect_true('Gradle synchronous cancellation completes', vim.wait(1000, function() return result ~= nil end, 10))
  expect('Gradle synchronous cancellation is classified', result.err.code, 'cancelled')
  kill_mode = 'accept'

  mode = 'success'
  result = nil
  local post_exit_cancel = discovery.discover(
    { root = root },
    function(callback_err, callback_snapshot) result = { err = callback_err, snapshot = callback_snapshot } end
  )
  kill_mode = 'false'
  expect('post-exit metadata cancellation succeeds', post_exit_cancel:cancel(), true)
  expect_true('post-exit metadata cancellation completes', vim.wait(1000, function() return result ~= nil end, 10))
  expect('post-exit metadata cancellation is classified', result.err.code, 'cancelled')
  kill_mode = 'accept'

  result = nil
  local pending_invalid = discovery.discover(
    { root = root .. '/missing' },
    function(callback_err, callback_snapshot) result = { err = callback_err, snapshot = callback_snapshot } end
  )
  expect('undelivered Gradle validation result can be cancelled', pending_invalid:cancel(), true)
  expect_true('undelivered Gradle cancellation completes', vim.wait(1000, function() return result ~= nil end, 10))
  expect('undelivered Gradle cancellation replaces validation error', result.err.code, 'cancelled')

  mode = 'invalid_completion'
  result = nil
  discovery.discover({ root = root }, function(callback_err) result = callback_err end)
  expect_true('invalid Gradle completion is contained', vim.wait(1000, function() return result ~= nil end, 10))
  expect('invalid Gradle completion is classified', result.code, 'invalid_process_result')

  mode = 'invalid_process'
  result = nil
  discovery.discover({ root = root }, function(callback_err) result = callback_err end)
  expect_true('invalid Gradle process is contained', vim.wait(1000, function() return result ~= nil end, 10))
  expect('invalid Gradle process is classified', result.code, 'spawn_failed')

  mode = 'pending'
  result = nil
  local kills_before_timeout = #kills
  discovery.discover(
    { root = root, timeout_ms = 10 },
    function(callback_err, callback_snapshot) result = { err = callback_err, snapshot = callback_snapshot } end
  )
  expect_true('timeout sends termination signal', vim.wait(1000, function() return #kills > kills_before_timeout end, 10))
  expect('timed out discovery waits for child exit', result, nil)
  expect('timeout sends SIGTERM', kills[#kills], 15)
  pending_exit { code = 0, signal = 15 }
  expect_true('timed out discovery completes', vim.wait(1000, function() return result ~= nil end, 10))
  expect('timed out discovery is classified', result.err.code, 'timeout')
end, debug.traceback)

vim.system = original_system
if temporary_root then vim.fn.delete(temporary_root, 'rf') end
if not ok then fail('unexpected test error', unexpected) end

if #failures > 0 then
  vim.api.nvim_err_writeln('Android Workbench discovery validation failed:\n- ' .. table.concat(failures, '\n- '))
  vim.cmd 'cquit 1'
end

print 'Android Workbench discovery validation passed'
vim.cmd 'qa!'
