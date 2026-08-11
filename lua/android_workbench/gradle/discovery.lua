local model = require 'android_workbench.gradle.model'
local metadata = require 'android_workbench.gradle.metadata'

local M = {}

local MAX_STREAM_BYTES = 4 * 1024 * 1024
local MAX_ERROR_BYTES = 64 * 1024
local DEFAULT_TIMEOUT_MS = 300000
local KILL_GRACE_MS = 1000
local TASK_NAME = ':__androidWorkbenchDiscoverV1'
local NONCE_ENV = 'ANDROID_WORKBENCH_DISCOVERY_NONCE'

local function failure(code, message, details) return { code = code, message = message, details = details } end

local function valid_timeout(value)
  return value == false or (type(value) == 'number' and value == value and value > 0 and value <= 2147483647 and value % 1 == 0)
end

local function canonical_root(root)
  if type(root) ~= 'string' or root == '' then return nil, 'root must be a non-empty path' end
  local normalized = vim.fs.normalize(vim.fn.fnamemodify(root, ':p'))
  local resolved = vim.uv.fs_realpath(normalized)
  local stat = resolved and vim.uv.fs_stat(resolved)
  if not stat or stat.type ~= 'directory' then return nil, 'root is not an existing directory' end
  return vim.fs.normalize(resolved)
end

local function init_script_path()
  local source = debug.getinfo(1, 'S').source
  if source:sub(1, 1) ~= '@' then return nil end
  local path = vim.fs.joinpath(vim.fs.dirname(source:sub(2)), 'android_workbench.init.gradle')
  return vim.uv.fs_realpath(path)
end

local function nonce()
  local ok, bytes = pcall(vim.uv.random, 16)
  if ok and type(bytes) == 'string' and #bytes == 16 then
    local encoded = {}
    for index = 1, #bytes do
      encoded[index] = string.format('%02x', bytes:byte(index))
    end
    return table.concat(encoded)
  end
  return vim.fn.sha256(table.concat({ tostring(vim.uv.hrtime()), tostring(vim.uv.os_getpid()), tostring {} }, ':')):sub(1, 32)
end

local function wrapper_path(root)
  local path = vim.fs.joinpath(root, 'gradlew')
  local stat = vim.uv.fs_stat(path)
  if not stat or stat.type ~= 'file' then return nil end
  if vim.fn.executable(path) ~= 1 then return nil, 'Gradle wrapper is not executable: ' .. path end
  return path
end

local function excerpt(value)
  value = value or ''
  if #value > 8192 then value = value:sub(-8192) end
  return vim.trim(value)
end

function M.discover(opts, callback)
  opts = opts or {}
  assert(type(callback) == 'function', 'android_workbench.gradle.discovery: callback is required')

  local done, delivered, cancelled, timed_out, exited = false, false, false, false, false
  local process, terminal_error
  local timeout_timer
  local pending_err, pending_snapshot
  local stdout_chunks, stderr_chunks = {}, {}
  local stdout_bytes, stderr_bytes = 0, 0

  local function finish(err, snapshot)
    if done then return false end
    done = true
    pending_err = err
    pending_snapshot = snapshot
    if timeout_timer then
      pcall(timeout_timer.stop, timeout_timer)
      if not timeout_timer:is_closing() then pcall(timeout_timer.close, timeout_timer) end
      timeout_timer = nil
    end
    vim.schedule(function()
      if delivered then return end
      delivered = true
      callback(pending_err, pending_snapshot)
    end)
    return true
  end

  local function terminate(err, require_signal)
    if done or terminal_error then return false end
    terminal_error = err
    if exited then return true end
    if process then
      local called, sent = pcall(process.kill, process, 15)
      if done then return true end
      if (not called or sent == false) and require_signal then
        terminal_error = nil
        return false
      end
    elseif require_signal then
      terminal_error = nil
      return false
    end
    vim.defer_fn(function()
      if not exited and process then pcall(process.kill, process, 9) end
    end, KILL_GRACE_MS)
    return true
  end

  local function stop_with(err) terminate(err) end

  local handle = {}
  function handle.cancel()
    if delivered or cancelled then return false end
    cancelled = true
    local err = failure('cancelled', 'Gradle discovery was cancelled')
    if done then
      pending_err = err
      pending_snapshot = nil
      return true
    end
    if not terminate(err, true) then
      cancelled = false
      return false
    end
    return true
  end

  if opts.timeout_ms ~= nil and not valid_timeout(opts.timeout_ms) then
    finish(failure('invalid_options', 'timeout_ms must be a positive integer or false'))
    return handle
  end

  local root, root_err = canonical_root(opts.root)
  if not root then
    finish(failure('invalid_root', root_err))
    return handle
  end
  local wrapper, wrapper_err = wrapper_path(root)
  if not wrapper then
    finish(failure('wrapper_not_found', wrapper_err or ('No Gradle wrapper found under ' .. root)))
    return handle
  end
  local script = init_script_path()
  if not script then
    finish(failure('provider_missing', 'Bundled Gradle discovery provider is missing'))
    return handle
  end

  local invocation_nonce = nonce()
  local argv = {
    wrapper,
    '--init-script',
    script,
    '--console=plain',
    '--quiet',
    '--no-configure-on-demand',
  }
  if opts.configuration_cache == true then
    argv[#argv + 1] = '--configuration-cache'
    argv[#argv + 1] = '--configuration-cache-problems=fail'
  elseif opts.configuration_cache == false then
    argv[#argv + 1] = '--no-configuration-cache'
  end
  argv[#argv + 1] = TASK_NAME

  local function collect(chunks, current_size, limit, kind, err, data)
    if err then
      stop_with(failure('stream_error', 'Failed reading Gradle ' .. kind, { error = tostring(err) }))
      return current_size
    end
    if not data then return current_size end
    local new_size = current_size + #data
    if new_size > limit then
      stop_with(failure('output_limit', 'Gradle ' .. kind .. ' exceeded the discovery output limit'))
      return new_size
    end
    chunks[#chunks + 1] = data
    return new_size
  end

  local system_opts = {
    cwd = root,
    text = true,
    env = { [NONCE_ENV] = invocation_nonce },
    stdout = function(err, data) stdout_bytes = collect(stdout_chunks, stdout_bytes, MAX_STREAM_BYTES, 'stdout', err, data) end,
    stderr = function(err, data) stderr_bytes = collect(stderr_chunks, stderr_bytes, MAX_ERROR_BYTES, 'stderr', err, data) end,
  }

  local ok, spawned = pcall(vim.system, argv, system_opts, function(result)
    exited = true
    if cancelled then
      finish(failure('cancelled', 'Gradle discovery was cancelled'))
      return
    end
    if timed_out then
      finish(failure('timeout', 'Gradle discovery timed out'))
      return
    end
    if terminal_error then
      finish(terminal_error)
      return
    end
    if type(result) ~= 'table' or type(result.code) ~= 'number' or (result.signal ~= nil and type(result.signal) ~= 'number') then
      finish(failure('invalid_process_result', 'Gradle discovery returned an invalid completion result'))
      return
    end

    local stdout = table.concat(stdout_chunks)
    local snapshot, decode_err = model.decode(stdout, invocation_nonce, root)
    if decode_err and decode_err.source == 'provider' then
      decode_err.source = nil
      finish(decode_err)
      return
    end
    if result.code ~= 0 or (result.signal ~= nil and result.signal ~= 0) then
      finish(failure('process_failed', 'Gradle discovery failed', {
        exit_code = result.code,
        signal = result.signal,
        stderr = excerpt(table.concat(stderr_chunks)),
      }))
      return
    end
    if decode_err then
      decode_err.source = nil
      finish(decode_err)
      return
    end
    vim.schedule(function()
      if done then return end
      if cancelled then
        finish(failure('cancelled', 'Gradle discovery was cancelled'))
        return
      end
      if timed_out then
        finish(failure('timeout', 'Gradle discovery timed out'))
        return
      end
      if terminal_error then
        finish(terminal_error)
        return
      end
      finish(nil, metadata.stamp(snapshot, script))
    end)
  end)

  if not ok or type(spawned) ~= 'table' or type(spawned.kill) ~= 'function' then
    finish(failure('spawn_failed', 'Could not start the Gradle wrapper', { error = tostring(spawned) }))
    return handle
  end
  process = spawned
  if terminal_error then pcall(process.kill, process, 15) end

  local timeout_ms = opts.timeout_ms
  if timeout_ms == nil then timeout_ms = DEFAULT_TIMEOUT_MS end
  if not done and type(timeout_ms) == 'number' and timeout_ms > 0 then
    timeout_timer = vim.defer_fn(function()
      if done or cancelled then return end
      timed_out = true
      terminate(failure('timeout', ('Gradle discovery timed out after %d ms'):format(timeout_ms)))
    end, timeout_ms)
  end

  return handle
end

function M.is_stale(snapshot)
  local script = init_script_path()
  if not script then return true end
  return metadata.is_stale(snapshot, script)
end

---@param opts? { configuration_cache?: boolean, timeout_ms?: number|false }
---@return { discover: fun(request: { root: string }, callback: function): table, is_stale: fun(snapshot: table): boolean }
function M.new(opts)
  opts = opts or {}
  if opts.configuration_cache ~= nil and type(opts.configuration_cache) ~= 'boolean' then
    error('android_workbench.gradle.discovery.new: configuration_cache must be a boolean', 2)
  end
  if opts.timeout_ms ~= nil and not valid_timeout(opts.timeout_ms) then
    error('android_workbench.gradle.discovery.new: timeout_ms must be a positive integer or false', 2)
  end

  return {
    discover = function(request, callback)
      return M.discover({
        root = request.root,
        configuration_cache = opts.configuration_cache,
        timeout_ms = opts.timeout_ms,
      }, callback)
    end,
    is_stale = M.is_stale,
  }
end

return M
