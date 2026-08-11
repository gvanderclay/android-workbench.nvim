local M = {}

local config = require 'android_workbench.config'

local instance

local function error_message(err)
  if type(err) == 'table' then return err.message or err.code or vim.inspect(err) end
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

---@param event { level?: 'info'|'warn'|'error', title?: string, message: string, code?: string }
function M._notify(event)
  event = {
    level = event.level or 'info',
    title = event.title or 'Android Workbench',
    message = event.message,
    code = event.code,
  }

  local notifications = config.get().ports.notifications
  if notifications ~= nil then
    local ok, err = pcall(notifications.emit, event)
    if ok then return end
    event = {
      level = 'error',
      title = 'Android Workbench',
      message = ('Notification adapter failed: %s'):format(error_message(err)),
    }
  end

  local levels = {
    info = vim.log.levels.INFO,
    warn = vim.log.levels.WARN,
    error = vim.log.levels.ERROR,
  }
  vim.notify(event.message, levels[event.level] or vim.log.levels.INFO, { title = event.title })
end

---@param opts? table
---@return AndroidWorkbenchConfig
function M.setup(opts)
  if instance ~= nil then error('android_workbench.setup must run before the first Android action', 2) end
  return config.setup(opts)
end

---@param opts? table
---@return table handle
function M.open_actions(opts)
  return app():open_actions(context(opts), function(argv, action_context) require('android_workbench.command').execute(argv, action_context) end)
end

---@param opts? table
---@return table? status
---@return table|string? error
function M.status(opts) return app():status(context(opts)) end

---@param opts? table
---@return table? status
---@return table|string? error
function M.show_status(opts)
  local status, err = M.status(opts)
  if status == nil then
    M._notify {
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

  M._notify {
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
  return callback
end

---@param opts? table
---@param callback? fun(error: table|string|nil, status: table|nil)
---@return table? handle
function M.refresh(opts, callback) return app():refresh(context(opts), callback_or_noop(callback)) end

---@param kind 'app'|'variant'|'device'
---@param opts? table
---@param callback? fun(error: table|string|nil, status: table|nil)
---@return table? handle
function M.select_target(kind, opts, callback)
  local target_app = app()
  local done = callback_or_noop(callback)
  if kind == 'app' then return target_app:select_app(context(opts), done) end
  if kind == 'variant' then return target_app:select_variant(context(opts), done) end
  if kind == 'device' then return target_app:select_device(context(opts), done) end
  error(('unsupported Android target kind: %s'):format(tostring(kind)), 2)
end

---@param opts? table
---@param callback? fun(error: table|string|nil, result: table|nil)
---@return table? handle
function M.build(opts, callback) return app():build(context(opts), callback_or_noop(callback)) end

---@param opts? table
---@param callback? fun(error: table|string|nil, result: table|nil)
---@return table? handle
function M.run(opts, callback) return app():run(context(opts), callback_or_noop(callback)) end

---@param opts? table
---@param callback? fun(error: table|string|nil, result: table|nil)
---@return table? handle
function M.gradle_task(opts, callback) return app():gradle_task(context(opts), callback_or_noop(callback)) end

---@param opts? table
---@param callback? fun(error: table|string|nil, result: table|nil)
---@return table? handle
function M.start_emulator(opts, callback) return app():start_emulator(context(opts), callback_or_noop(callback)) end

---@param opts? table
---@param callback? fun(error: table|string|nil, result: table|nil)
---@return table? handle
function M.stop_emulator(opts, callback) return app():stop_emulator(context(opts), callback_or_noop(callback)) end

---@param opts? table
---@param callback? fun(error: table|string|nil, result: table|nil)
---@return table? handle
function M.stop(opts, callback) return app():stop(context(opts), callback_or_noop(callback)) end

---@param opts? table
---@param callback? fun(error: table|string|nil, result: table|nil)
---@return table? handle
function M.logcat(opts, callback) return app():open_logcat(context(opts), callback_or_noop(callback)) end

---@param opts? table
---@return boolean? stopped
---@return table|string? error
function M.stop_logcat(opts)
  local stopped, err = app():stop_logcat(context(opts))
  if not stopped then M._notify {
    level = 'error',
    code = 'logcat_stop_failed',
    message = error_message(err),
  } end
  return stopped, err
end

---@param opts? table
---@return boolean? cancelled
---@return table|string? error
function M.cancel(opts)
  local cancelled, err = app():cancel(context(opts))
  if not cancelled then M._notify {
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
