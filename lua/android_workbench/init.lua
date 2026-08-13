local M = {}

local config = require 'android_workbench.config'
local Notify = require 'android_workbench.notify'

local instance

---@class AndroidWorkbenchContext
---@field bufnr? integer
---@field path? string
---@field root? string

---@class AndroidWorkbenchError
---@field code string
---@field message string
---@field root? string
---@field details? any

---@class AndroidWorkbenchOperationHandle
---@field cancel fun(self: AndroidWorkbenchOperationHandle): boolean

---@class AndroidWorkbenchLogcatHandle
---@field show fun(self: AndroidWorkbenchLogcatHandle, opts?: table): boolean
---@field stop fun(self: AndroidWorkbenchLogcatHandle): boolean

---@class AndroidWorkbenchAppIdentity
---@field build_path string
---@field project_path string

---@class AndroidWorkbenchDeviceIdentity
---@field serial? string
---@field avd_name? string
---@field state? string

---@class AndroidWorkbenchSelection
---@field app? AndroidWorkbenchAppIdentity
---@field variant? string
---@field device? AndroidWorkbenchDeviceIdentity

---@class AndroidWorkbenchStatus
---@field root string
---@field wrapper string
---@field phase 'idle'|'discovering'|'ready'|'error'
---@field authorized boolean
---@field targets integer
---@field selection AndroidWorkbenchSelection
---@field operation? string
---@field logcat 'stopped'|'starting'|'running'
---@field task_output boolean
---@field error? AndroidWorkbenchError

---@class AndroidWorkbenchTarget
---@field id string
---@field build_path string
---@field build_root string
---@field project_path string
---@field project_dir string
---@field variant string
---@field application_id string
---@field assemble_task string
---@field install_task? string

---@class AndroidWorkbenchGradleTask
---@field id string
---@field build_path string
---@field project_path string
---@field name string

---@class AndroidWorkbenchTaskTerminal
---@field status 'success'
---@field name string
---@field metadata table
---@field code? integer
---@field signal? integer
---@field stdout? string
---@field stderr? string
---@field stdout_truncated? boolean
---@field stderr_truncated? boolean
---@field output_truncated? boolean
---@field problems table[]
---@field problems_truncated boolean

---@class AndroidWorkbenchLauncherComponent
---@field component string
---@field package string
---@field activity? string

---@class AndroidWorkbenchBuildResult
---@field kind 'build'
---@field target AndroidWorkbenchTarget
---@field task AndroidWorkbenchTaskTerminal

---@class AndroidWorkbenchRunResult
---@field kind 'run'
---@field target AndroidWorkbenchTarget
---@field device AndroidWorkbenchDeviceIdentity
---@field component AndroidWorkbenchLauncherComponent
---@field task AndroidWorkbenchTaskTerminal

---@class AndroidWorkbenchGradleTaskResult
---@field kind 'gradle_task'
---@field gradle_task AndroidWorkbenchGradleTask
---@field task AndroidWorkbenchTaskTerminal

---@class AndroidWorkbenchStopResult
---@field kind 'stop'
---@field target AndroidWorkbenchTarget
---@field device AndroidWorkbenchDeviceIdentity

---@class AndroidWorkbenchEmulatorResult
---@field kind 'emulator_start'|'emulator_stop'
---@field device AndroidWorkbenchDeviceIdentity

---@class AndroidWorkbenchLogcatResult
---@field kind 'logcat'
---@field target AndroidWorkbenchTarget
---@field device AndroidWorkbenchDeviceIdentity
---@field handle AndroidWorkbenchLogcatHandle

---@class AndroidWorkbenchLogcatSession
---@field application_id string
---@field device_serial string
---@field current boolean

---@class AndroidWorkbenchLogcatSessionIdentity
---@field application_id string
---@field device_serial string

---@class AndroidWorkbenchStopAllLogcatsResult
---@field stopped integer
---@field refused AndroidWorkbenchLogcatSessionIdentity[]
---@field refused_total integer
---@field refused_truncated boolean

---@class AndroidWorkbenchPorts
---@field adb? AndroidWorkbenchAdbService
---@field picker? AndroidWorkbenchPicker
---@field problems? AndroidWorkbenchProblemSink
---@field runner? AndroidWorkbenchRunner
---@field discovery? table
---@field emulator? table
---@field logcat? table
---@field notifications? table
---@field state? table
---@field trust? table

---@class AndroidWorkbenchSetupOpts
---@field ports? AndroidWorkbenchPorts
---@field logcat? { open_on_run?: boolean }
---@field run? { start_stopped_avd?: boolean }
---@field emulator? { boot_timeout_ms?: integer, poll_interval_ms?: integer }

local function error_message(err)
  if type(err) == 'table' then
    local message = rawget(err, 'message')
    if type(message) == 'string' then return message end
    local code = rawget(err, 'code')
    if type(code) == 'string' then return code end
    return vim.inspect(err)
  end
  return tostring(err)
end

local function device_name(device)
  if type(device) ~= 'table' then return 'none' end
  if device.avd_name and device.serial then return ('%s (%s)'):format(device.avd_name, device.serial) end
  if device.avd_name then return device.avd_name .. ' (stopped)' end
  return device.serial or 'none'
end

local function context(opts)
  if opts ~= nil and type(opts) ~= 'table' then error('android_workbench context must be a table', 3) end
  opts = opts or {}
  for key in pairs(opts) do
    if key ~= 'bufnr' and key ~= 'path' and key ~= 'root' then error(('android_workbench context.%s is not supported'):format(tostring(key)), 3) end
  end
  if opts.bufnr ~= nil and (type(opts.bufnr) ~= 'number' or opts.bufnr < 0 or opts.bufnr % 1 ~= 0) then
    error('android_workbench context.bufnr must be a non-negative integer', 3)
  end
  if opts.path ~= nil and (type(opts.path) ~= 'string' or opts.path == '') then error('android_workbench context.path must be a non-empty string', 3) end
  if opts.root ~= nil and (type(opts.root) ~= 'string' or opts.root == '') then error('android_workbench context.root must be a non-empty string', 3) end

  local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
  local path = opts.path
  if path == nil then
    path = vim.api.nvim_buf_get_name(bufnr)
    if path == '' then path = vim.uv.cwd() end
  end

  return {
    bufnr = bufnr,
    path = path,
    root = opts.root,
  }
end

local function app()
  if instance == nil then instance = require('android_workbench.app').new(config.get()) end
  return instance
end

local function public_error(err)
  if err == nil then return nil end
  if type(err) ~= 'table' then return {
    code = 'operation_failed',
    message = 'Android Workbench operation failed.',
    details = tostring(err),
  } end

  local code = rawget(err, 'code')
  local message = rawget(err, 'message')
  if type(code) ~= 'string' or code == '' or type(message) ~= 'string' or message == '' then
    return {
      code = 'operation_failed',
      message = 'Android Workbench operation failed.',
    }
  end

  local result = {
    code = code,
    message = message,
  }
  local root = rawget(err, 'root')
  if type(root) == 'string' and root ~= '' then result.root = root end
  local details = rawget(err, 'details')
  if details ~= nil then result.details = vim.deepcopy(details) end
  return result
end

local function copy_public_dto(value)
  if type(value) ~= 'table' then return value end
  local copy = {}
  for key, member in pairs(value) do
    if key == 'handle' then
      copy[key] = member
    elseif key == 'error' then
      copy[key] = public_error(member)
    else
      copy[key] = vim.deepcopy(member)
    end
  end
  return copy
end

---@param opts? AndroidWorkbenchSetupOpts
function M.setup(opts)
  if instance ~= nil then error('android_workbench.setup must run before the first Android action', 2) end
  config.setup(opts)
end

---@param opts? AndroidWorkbenchContext
---@return boolean
function M.is_project(opts)
  local action_context = context(opts)
  local resolved = require('android_workbench.root').new():resolve(action_context)
  return resolved ~= nil
end

---@param opts? AndroidWorkbenchContext
---@return AndroidWorkbenchOperationHandle handle
function M.open_actions(opts)
  local action_context = context(opts)
  return app():open_actions(action_context, function(argv, selected_context) require('android_workbench.command').execute(argv, selected_context) end)
end

---@param opts? AndroidWorkbenchContext
---@return AndroidWorkbenchStatus? status
---@return AndroidWorkbenchError? error
function M.status(opts)
  local action_context = context(opts)
  local status, err = app():status(action_context)
  return copy_public_dto(status), public_error(err)
end

---@param opts? AndroidWorkbenchContext
---@return AndroidWorkbenchStatus? status
---@return AndroidWorkbenchError? error
function M.show_status(opts)
  local status, err = M.status(opts)
  if status == nil then
    Notify.emit {
      level = 'error',
      code = 'status_failed',
      message = error_message(err),
    }
    return nil, err
  end

  local selected = status.selection or {}
  local selected_app = selected.app
  local app_name = 'none'
  if selected_app ~= nil then
    local build_path = selected_app.build_path or ':'
    local project_path = selected_app.project_path or ':'
    app_name = build_path == ':' and project_path or build_path .. (project_path == ':' and '' or project_path)
  end

  local lines = {
    ('Root: %s'):format(status.root or 'not attached'),
    ('Wrapper: %s'):format(status.wrapper or 'not found'),
    ('State: %s'):format(status.phase or 'idle'),
    ('Authorized: %s'):format(status.authorized and 'yes' or 'no'),
    ('Targets: %d'):format(status.targets or 0),
    ('App: %s'):format(app_name),
    ('Variant: %s'):format(selected.variant or 'none'),
    ('Device: %s'):format(device_name(selected.device)),
    ('Operation: %s'):format(status.operation or 'none'),
    ('Logcat: %s'):format(status.logcat or 'stopped'),
  }
  if status.error ~= nil then lines[#lines + 1] = 'Error: ' .. error_message(status.error) end

  Notify.emit {
    level = status.error and 'error' or 'info',
    code = 'status',
    message = table.concat(lines, '\n'),
  }
  return status
end

local function callback_or_noop(callback)
  if callback == nil then
    return function() end
  end
  if type(callback) ~= 'function' then error('android_workbench callback must be a function', 3) end
  return function(err, result)
    err = public_error(err)
    callback(err, err == nil and copy_public_dto(result) or nil)
  end
end

---@param opts? AndroidWorkbenchContext
---@param callback? fun(error: AndroidWorkbenchError?, status: AndroidWorkbenchStatus?)
---@return AndroidWorkbenchOperationHandle handle
function M.refresh(opts, callback)
  local action_context = context(opts)
  local done = callback_or_noop(callback)
  return app():refresh(action_context, done)
end

---@param kind 'app'|'variant'|'device'
---@param opts? AndroidWorkbenchContext
---@param callback? fun(error: AndroidWorkbenchError?, status: AndroidWorkbenchStatus?)
---@return AndroidWorkbenchOperationHandle handle
function M.select_target(kind, opts, callback)
  if kind ~= 'app' and kind ~= 'variant' and kind ~= 'device' then error(('unsupported Android target kind: %s'):format(tostring(kind)), 2) end
  local action_context = context(opts)
  local done = callback_or_noop(callback)
  local target_app = app()
  if kind == 'app' then return target_app:select_app(action_context, done) end
  if kind == 'variant' then return target_app:select_variant(action_context, done) end
  return target_app:select_device(action_context, done)
end

---@param opts? AndroidWorkbenchContext
---@param callback? fun(error: AndroidWorkbenchError?, result: AndroidWorkbenchBuildResult?)
---@return AndroidWorkbenchOperationHandle handle
function M.build(opts, callback)
  local action_context = context(opts)
  local done = callback_or_noop(callback)
  return app():build(action_context, done)
end

---@param opts? AndroidWorkbenchContext
---@param callback? fun(error: AndroidWorkbenchError?, result: AndroidWorkbenchRunResult?)
---@return AndroidWorkbenchOperationHandle handle
function M.run(opts, callback)
  local action_context = context(opts)
  local done = callback_or_noop(callback)
  return app():run(action_context, done)
end

---@param opts? AndroidWorkbenchContext
---@param callback? fun(error: AndroidWorkbenchError?, result: AndroidWorkbenchGradleTaskResult?)
---@return AndroidWorkbenchOperationHandle handle
function M.gradle_task(opts, callback)
  local action_context = context(opts)
  local done = callback_or_noop(callback)
  return app():gradle_task(action_context, done)
end

---@param opts? AndroidWorkbenchContext
---@return boolean? shown
---@return AndroidWorkbenchError? error
function M.show_task_output(opts)
  local action_context = context(opts)
  local shown, err = app():show_task_output(action_context)
  err = public_error(err)
  if not shown then Notify.emit {
    level = 'error',
    code = 'task_output_failed',
    message = error_message(err),
  } end
  return shown, err
end

---@param opts? AndroidWorkbenchContext
---@param callback? fun(error: AndroidWorkbenchError?, result: AndroidWorkbenchEmulatorResult?)
---@return AndroidWorkbenchOperationHandle handle
function M.start_emulator(opts, callback)
  local action_context = context(opts)
  local done = callback_or_noop(callback)
  return app():start_emulator(action_context, done)
end

---@param opts? AndroidWorkbenchContext
---@param callback? fun(error: AndroidWorkbenchError?, result: AndroidWorkbenchEmulatorResult?)
---@return AndroidWorkbenchOperationHandle handle
function M.stop_emulator(opts, callback)
  local action_context = context(opts)
  local done = callback_or_noop(callback)
  return app():stop_emulator(action_context, done)
end

---@param opts? AndroidWorkbenchContext
---@param callback? fun(error: AndroidWorkbenchError?, result: AndroidWorkbenchEmulatorResult?)
---@return AndroidWorkbenchOperationHandle handle
function M.manage_emulators(opts, callback)
  local action_context = context(opts)
  local done = callback_or_noop(callback)
  return app():manage_emulators(action_context, done)
end

---@param opts? AndroidWorkbenchContext
---@param callback? fun(error: AndroidWorkbenchError?, result: AndroidWorkbenchStopResult?)
---@return AndroidWorkbenchOperationHandle handle
function M.stop(opts, callback)
  local action_context = context(opts)
  local done = callback_or_noop(callback)
  return app():stop(action_context, done)
end

---@param opts? AndroidWorkbenchContext
---@param callback? fun(error: AndroidWorkbenchError?, result: AndroidWorkbenchLogcatResult?)
---@return AndroidWorkbenchOperationHandle handle
function M.logcat(opts, callback)
  local action_context = context(opts)
  local done = callback_or_noop(callback)
  return app():open_logcat(action_context, done)
end

---@param opts? AndroidWorkbenchContext
---@param callback? fun(error: AndroidWorkbenchError?, result: AndroidWorkbenchLogcatSession?)
---@return AndroidWorkbenchOperationHandle handle
function M.select_logcat_session(opts, callback)
  local action_context = context(opts)
  local done = callback_or_noop(callback)
  return app():select_logcat_session(action_context, done)
end

---@param opts? AndroidWorkbenchContext
---@return boolean? stopped
---@return AndroidWorkbenchError? error
function M.stop_logcat(opts)
  local action_context = context(opts)
  local stopped, err = app():stop_logcat(action_context)
  err = public_error(err)
  if not stopped then Notify.emit {
    level = 'error',
    code = 'logcat_stop_failed',
    message = error_message(err),
  } end
  return stopped, err
end

---@param opts? AndroidWorkbenchContext
---@return AndroidWorkbenchStopAllLogcatsResult? result
---@return AndroidWorkbenchError? error
function M.stop_all_logcats(opts)
  local action_context = context(opts)
  local result, err = app():stop_all_logcats(action_context)
  err = public_error(err)
  if not result then Notify.emit {
    level = 'error',
    code = 'logcat_stop_all_failed',
    message = error_message(err),
  } end
  return copy_public_dto(result), err
end

---@param opts? AndroidWorkbenchContext
---@return boolean? cancelled
---@return AndroidWorkbenchError? error
function M.cancel(opts)
  local action_context = context(opts)
  local cancelled, err = app():cancel(action_context)
  err = public_error(err)
  if not cancelled then Notify.emit {
    level = 'error',
    code = 'cancel_failed',
    message = error_message(err),
  } end
  return cancelled, err
end

function M.shutdown()
  if instance == nil then return end
  instance:shutdown()
  instance = nil
end

return M

-- vim: ts=2 sts=2 sw=2 et
