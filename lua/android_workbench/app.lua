local Actions = require 'android_workbench.actions'
local Adb = require 'android_workbench.android.adb'
local Emulator = require 'android_workbench.android.emulator'
local Device = require 'android_workbench.device'
local Execution = require 'android_workbench.execution'
local GradleTask = require 'android_workbench.gradle.task'
local NativeLogcat = require 'android_workbench.logcat.native'
local Root = require 'android_workbench.root'
local Runner = require 'android_workbench.runner'
local Session = require 'android_workbench.session'
local State = require 'android_workbench.state'
local Target = require 'android_workbench.target'
local Trust = require 'android_workbench.trust'

local M = {}

local MAX_LOGCAT_STOP_REFUSALS = 1024

local function pack(...) return { n = select('#', ...), ... } end

local App = {}
App.__index = App

local function workbench_error(code, message, root, details)
  return {
    code = code,
    message = message,
    root = root,
    details = details,
  }
end

local function error_message(err)
  if type(err) == 'table' then return err.message or err.code or vim.inspect(err) end
  return tostring(err)
end

local function default_notifications()
  return {
    emit = function(event)
      local levels = {
        error = vim.log.levels.ERROR,
        warn = vim.log.levels.WARN,
        info = vim.log.levels.INFO,
      }
      vim.notify(event.message, levels[event.level] or vim.log.levels.INFO, { title = event.title or 'Android Workbench' })
    end,
  }
end

local function default_picker()
  return {
    select = function(opts, callback)
      vim.ui.select(opts.items, {
        prompt = opts.prompt,
        format_item = opts.format_item,
      }, function(item) callback(nil, item) end)
    end,
  }
end

local function cancel_handle(handle)
  if handle == nil then return true end
  if type(handle) ~= 'table' or type(handle.cancel) ~= 'function' then return false, 'operation handle does not expose cancel()' end
  local ok, result = pcall(handle.cancel, handle)
  if not ok then return false, tostring(result) end
  if result == false then return false, 'operation handle rejected cancellation' end
  return true
end

local function abandon_handle(handle)
  if type(handle) == 'table' and type(handle._abandon) == 'function' then
    pcall(handle._abandon, handle)
    return
  end
  cancel_handle(handle)
end

local function raw_string(value, field)
  if type(value) ~= 'table' then return nil end
  local result = rawget(value, field)
  return type(result) == 'string' and result or nil
end

local function new_operation(callback)
  local operation = {
    child = nil,
    done = false,
    cancelled = false,
    cancelling = false,
    generation = 0,
    child_active = false,
  }

  function operation:finish(err, value)
    if self.done then return false end
    self.done = true
    self.generation = self.generation + 1
    self.child = nil
    self.child_active = false
    callback(err, value)
    return true
  end

  function operation:start_child(starter, on_terminal, start_error)
    if self.done or self.cancelling then return false end
    self.generation = self.generation + 1
    local token = self.generation
    self.child = nil
    self.child_active = true

    local function terminal(...)
      if self.done or self.generation ~= token then return end
      self.generation = self.generation + 1
      self.child = nil
      self.child_active = false
      local args = pack(...)
      if self.cancelling then
        local child_err = args[1]
        if child_err ~= nil and not (type(child_err) == 'table' and child_err.code == 'cancelled') then
          self:finish(
            type(child_err) == 'table' and child_err
              or workbench_error('operation_failed', 'Android Workbench operation failed while cancelling.', nil, tostring(child_err))
          )
        else
          self:finish(workbench_error('cancelled', 'Android Workbench operation was cancelled.'))
        end
        return
      end
      local ok, err = xpcall(function() on_terminal(unpack(args, 1, args.n)) end, debug.traceback)
      if not ok and not self.done then
        cancel_handle(self.child)
        self:finish(workbench_error('operation_failed', 'Android Workbench operation failed.', nil, tostring(err)))
      end
    end

    local started, handle = pcall(starter, terminal)
    if not started then
      if self.done or self.generation ~= token then return false end
      self.generation = self.generation + 1
      self.child_active = false
      local err = type(start_error) == 'function' and start_error(handle)
        or workbench_error('adapter_failed', 'Could not start an Android Workbench operation.', nil, tostring(handle))
      self:finish(err)
      return false
    end

    if self.done or self.generation ~= token then
      cancel_handle(handle)
      return true
    end
    if handle ~= nil and (type(handle) ~= 'table' or type(handle.cancel) ~= 'function') then
      self.generation = self.generation + 1
      self.child_active = false
      self:finish(workbench_error('invalid_operation_handle', 'An Android Workbench adapter returned an invalid operation handle.'))
      return false
    end
    self.child = handle
    return true
  end

  function operation.cancel()
    if operation.done or operation.cancelling then return false end
    operation.cancelling = true
    operation.cancelled = true
    local child = operation.child
    if child == nil then
      if operation.child_active then
        operation.cancelling = false
        operation.cancelled = false
        return false
      end
      operation:finish(workbench_error('cancelled', 'Android Workbench operation was cancelled.'))
      return true
    end

    local accepted = cancel_handle(child)
    if operation.done then return true end
    if not accepted then
      operation.cancelling = false
      operation.cancelled = false
      return false
    end
    return true
  end

  function operation:_abandon()
    if self.done then return false end
    self.done = true
    self.cancelled = true
    self.generation = self.generation + 1
    local child = self.child
    self.child = nil
    self.child_active = false
    abandon_handle(child)
    return true
  end

  return operation
end

---@param config? table
---@return table
function M.new(config)
  config = config or {}
  local ports = config.ports or {}
  local discovery = ports.discovery or require 'android_workbench.gradle.discovery'
  local adb = ports.adb or Adb.new()
  local runner = ports.runner or Runner.new()
  local task_output = Runner._is_native(runner) and runner or nil
  local picker = ports.picker or default_picker()
  local notifications = ports.notifications or default_notifications()
  local problems = ports.problems or require('android_workbench.integrations.quickfix').new()
  local logcat = ports.logcat or NativeLogcat.new { picker = picker, notifications = notifications }
  local emulator_options = config.emulator or {}
  local emulator = ports.emulator
    or Emulator.new {
      adb = adb,
      boot_timeout_ms = emulator_options.boot_timeout_ms,
      poll_interval_ms = emulator_options.poll_interval_ms,
    }
  local devices = Device.new {
    adb = adb,
    emulator = emulator,
    picker = picker,
  }

  return setmetatable({
    root_resolver = Root.new(),
    session_factory = Session.new,
    discovery = discovery,
    adb = adb,
    devices = devices,
    execution = Execution.new { runner = runner, adb = adb },
    task_output = task_output,
    logcat = logcat,
    logcat_options = config.logcat or { open_on_run = false },
    run_options = config.run or { start_stopped_avd = true },
    picker = picker,
    problems = problems,
    trust = ports.trust or Trust.new(),
    notifications = notifications,
    state = ports.state or State.new(),
    sessions = {},
    operations = {},
    active = {},
    logcats = {},
    logcat_starts = {},
    closed = false,
  }, App)
end

function App:_has_task_output(root)
  if not self.task_output then return false end
  local ok, available = pcall(self.task_output._has_output, root)
  return ok and available == true
end

function App:_emit(level, message)
  local ok, err = pcall(self.notifications.emit, {
    level = level,
    title = 'Android Workbench',
    message = message,
  })
  if not ok then vim.notify(('Android Workbench notification adapter failed: %s'):format(err), vim.log.levels.ERROR, { title = 'Android Workbench' }) end
end

function App:_publish_task_problems(session, operation, expected_kind, kind, task_result)
  if self.closed or operation.done or operation.cancelled or self.active[session.root] ~= operation then return false end
  if kind ~= expected_kind or (kind ~= 'build' and kind ~= 'run' and kind ~= 'gradle_task') or type(task_result) ~= 'table' then return false end
  if task_result.status ~= 'success' and task_result.status ~= 'failure' then return false end
  if type(task_result.name) ~= 'string' or task_result.name == '' then return false end
  if type(task_result.problems) ~= 'table' or not vim.islist(task_result.problems) then return false end
  if type(task_result.problems_truncated) ~= 'boolean' then return false end

  local items = task_result.status == 'failure' and vim.deepcopy(task_result.problems) or {}
  local called, published, publish_err = pcall(self.problems.publish, {
    root = session.root,
    kind = kind,
    name = task_result.name,
    status = task_result.status,
    items = items,
    truncated = task_result.problems_truncated,
  })
  if not called then
    self:_emit('warn', ('Could not publish Android %s problems: %s'):format(kind, error_message(published)))
    return false
  end
  if published ~= true then
    self:_emit('warn', ('Could not publish Android %s problems: %s'):format(kind, error_message(publish_err or 'problem adapter rejected publication')))
    return false
  end
  return true
end

function App:_complete(callback)
  local operation
  operation = new_operation(function(err, value)
    self.operations[operation] = nil
    if err and type(err) ~= 'table' then err = workbench_error('operation_failed', tostring(err)) end
    if err and err.code ~= 'cancelled' then self:_emit('error', err.message or tostring(err)) end
    callback(err, value)
  end)
  self.operations[operation] = true
  return operation
end

function App:_admit_root_operation(session, kind, callback)
  if self.active[session.root] then
    local rejected = self:_complete(callback)
    vim.schedule(
      function()
        rejected:finish(workbench_error('operation_active', ('Another Android operation is already running for %s.'):format(session.root), session.root))
      end
    )
    return nil, rejected
  end

  local operation
  operation = self:_complete(function(err, result)
    if self.active[session.root] == operation then self.active[session.root] = nil end
    callback(err, result)
  end)
  operation.kind = kind
  self.active[session.root] = operation
  return operation
end

function App:_session(context)
  if self.closed then return nil, workbench_error('app_closed', 'Android Workbench is shut down.') end

  local resolved, err = self.root_resolver:resolve(context)
  if not resolved then return nil, err end

  local session = self.sessions[resolved.root]
  if not session then
    session = self.session_factory {
      root = resolved.root,
      wrapper = resolved.wrapper,
      discovery = self.discovery,
      trust = self.trust,
      state = self.state,
      notifications = self.notifications,
    }
    self.sessions[resolved.root] = session
  end
  return session
end

function App:_logcat_registry(root, create)
  local registry = self.logcats[root]
  if not registry and create then
    registry = { entries = {}, starting = {}, current = nil, sequence = 0 }
    self.logcats[root] = registry
  end
  return registry
end

function App:_logcat_start_registry(root, create)
  local registry = self.logcat_starts[root]
  if not registry and create then
    registry = { operations = {}, current = nil, sequence = 0 }
    self.logcat_starts[root] = registry
  end
  return registry
end

function App:_logcat_status(root)
  local registry = self:_logcat_registry(root, false)
  if registry and next(registry.entries) then return 'running' end
  local starts = self:_logcat_start_registry(root, false)
  if starts and next(starts.operations) then return 'starting' end
  return 'stopped'
end

---@param context? { bufnr?: integer, path?: string, root?: string }
---@return table? status
---@return table? error
function App:status(context)
  local session, err = self:_session(context)
  if not session then return nil, err end
  local status = session:status()
  status.operation = self.active[session.root] and self.active[session.root].kind or nil
  status.logcat = self:_logcat_status(session.root)
  status.task_output = self:_has_task_output(session.root)
  return status
end

function App:show_task_output(context)
  local session, err = self:_session(context)
  if not session then return nil, err end
  if not self.task_output then return nil, workbench_error('task_output_unavailable', 'The configured runner owns its task output.', session.root) end
  if not self:_has_task_output(session.root) then
    return nil, workbench_error('no_task_output', ('No Android task output is available for %s.'):format(session.root), session.root)
  end
  local ok, shown = pcall(self.task_output._show_output, session.root)
  if not ok or shown ~= true then
    return nil, workbench_error('task_output_open_failed', ('Could not open Android task output for %s.'):format(session.root), session.root)
  end
  return true
end

---@param context? table
---@param dispatch fun(argv: string[], context: table)
---@return table handle
function App:open_actions(context, dispatch)
  local action_context
  local operation = self:_complete(function(err, selected)
    if err or selected == nil then return end
    local argv = vim.deepcopy(selected.argv)
    vim.schedule(function()
      if self.closed then return end
      local dispatched, dispatch_err = pcall(dispatch, argv, action_context)
      if not dispatched then self:_emit('error', ('Could not run Android action: %s'):format(dispatch_err)) end
    end)
  end)

  local session, err = self:_session(context)
  if not session then
    vim.schedule(function() operation:finish(err) end)
    return operation
  end

  local status = session:status()
  status.operation = self.active[session.root] and self.active[session.root].kind or nil
  status.logcat = self:_logcat_status(session.root)
  status.task_output = self:_has_task_output(session.root)

  local items = Actions.available(status)
  action_context = {
    bufnr = context and context.bufnr or nil,
    path = context and context.path or nil,
    root = session.root,
  }

  operation:start_child(function(done)
    return self:_pick(session, 'Android', items, function(action) return action.label end, nil, done)
  end, function(picker_err, action)
    if operation.cancelled then return end
    if picker_err then
      operation:finish(picker_err)
      return
    end
    if action == nil then
      operation:finish()
      return
    end

    local selected
    local selected_id = raw_string(action, 'id')
    if selected_id ~= nil then
      for _, candidate in ipairs(items) do
        if candidate.id == selected_id then
          selected = candidate
          break
        end
      end
    end
    if not selected then
      operation:finish(workbench_error('invalid_selection', 'The picker returned an unknown Android action.', session.root))
      return
    end

    operation:finish(nil, selected)
  end, function(err) return workbench_error('picker_failed', 'Could not open the Android action picker.', session.root, tostring(err)) end)
  return operation
end

function App:_reconcile(session, snapshot)
  local selection = session:selection()
  if not selection.app then return end

  local selected_app
  for _, app in ipairs(Target.applications(snapshot)) do
    if Target.same_app(app, selection.app) then
      selected_app = app
      break
    end
  end

  local changed = false
  if not selected_app then
    selection = { app = nil, variant = nil, device = selection.device }
    changed = true
  elseif selection.variant and not Target.contains_variant(Target.variants(snapshot, selected_app), selection.variant) then
    selection.variant = nil
    changed = true
  end

  if changed then
    local _, err = session:set_selection(selection, { keep_on_error = true })
    if err then self:_emit('warn', err.message or tostring(err)) end
  end
end

---@param context? table
---@param callback? fun(err: table?, status: table?)
---@return table handle
function App:refresh(context, callback)
  callback = callback or function() end
  local operation = self:_complete(callback)
  local session, err = self:_session(context)
  if not session then
    vim.schedule(function() operation:finish(err) end)
    return operation
  end

  operation:start_child(function(done) return session:refresh(done) end, function(discovery_err, snapshot)
    if operation.cancelled then return end
    if discovery_err then
      operation:finish(discovery_err, session:status())
      return
    end

    self:_reconcile(session, snapshot)
    local status = session:status()
    self:_emit('info', ('Discovered %d Android target%s for %s.'):format(status.targets, status.targets == 1 and '' or 's', status.root))
    operation:finish(nil, status)
  end, function(start_err) return workbench_error('discovery_start_failed', 'Could not refresh the Android project.', session.root, tostring(start_err)) end)
  return operation
end

function App:_pick(session, prompt, items, format_item, current, callback)
  local operation = new_operation(callback)
  operation:start_child(
    function(done)
      return self.picker.select({
        prompt = prompt,
        items = vim.deepcopy(items),
        format_item = format_item,
        current = current == nil and nil or vim.deepcopy(current),
      }, done)
    end,
    function(err, item)
      if err then
        operation:finish(err, session:status())
        return
      end
      operation:finish(nil, item)
    end,
    function(start_err) return workbench_error('picker_failed', 'Could not open the Android picker.', session.root, tostring(start_err)) end
  )
  return operation
end

function App:_save_target(session, target)
  return session:set_target_selection({
    build_path = target.build_path,
    project_path = target.project_path,
  }, target.variant)
end

function App:_resolve_target(session, snapshot, operation, callback)
  self:_reconcile(session, snapshot)
  local selection = session:selection()
  local selected = Target.find(snapshot, selection)
  if selected then
    callback(nil, selected)
    return
  end

  local items = {}
  for _, target in ipairs(Target.sorted(snapshot)) do
    if not selection.app or Target.same_app(target, selection.app) then items[#items + 1] = target end
  end
  if #items == 0 then
    callback(workbench_error('no_android_targets', ('No Android application targets were found under %s.'):format(session.root), session.root))
    return
  end

  local function accept(target, revalidate)
    local selected_id = raw_string(target, 'id')
    local known
    for _, candidate in ipairs(items) do
      if selected_id ~= nil and candidate.id == selected_id then
        known = candidate
        break
      end
    end
    if not known then
      callback(workbench_error('invalid_selection', 'The picker returned an unknown Android target.', session.root))
      return
    end

    local _, save_err = self:_save_target(session, known)
    if save_err then
      callback(save_err)
      return
    end
    callback(nil, known, revalidate == true)
  end

  if #items == 1 then
    accept(items[1], false)
    return
  end

  operation:start_child(function(done) return self:_pick(session, 'Android target', items, Target.target_label, nil, done) end, function(err, item)
    if err then
      callback(err)
      return
    end
    if item == nil then
      callback(workbench_error('cancelled', 'Android target selection was cancelled.', session.root))
      return
    end
    accept(item, true)
  end, function(start_err) return workbench_error('picker_failed', 'Could not open the Android target picker.', session.root, tostring(start_err)) end)
end

function App:_preflight(session, operation, needs_device, callback, device_options)
  operation:start_child(function(done) return session:discover({}, done) end, function(discovery_err, snapshot)
    if discovery_err then
      callback(discovery_err)
      return
    end

    self:_resolve_target(session, snapshot, operation, function(target_err, target, revalidate)
      if operation.cancelled then return end
      if target_err then
        callback(target_err)
        return
      end

      local function with_current(current_target, current_snapshot)
        local selected = Target.find(current_snapshot, session:selection())
        if not session:is_snapshot_current(current_snapshot) or not selected or selected.id ~= current_target.id then
          callback(workbench_error('target_stale', 'The Android project model or target changed during the operation. Retry the action.', session.root))
          return
        end
        if not needs_device then
          callback(nil, current_target, nil, current_snapshot)
          return
        end

        operation:start_child(
          function(done) return self.devices:resolve(session, device_options or {}, done) end,
          function(device_err, device)
            if operation.cancelled then return end
            if device_err then
              callback(device_err)
              return
            end
            selected = Target.find(current_snapshot, session:selection())
            if not session:is_snapshot_current(current_snapshot) or not selected or selected.id ~= current_target.id then
              callback(workbench_error('target_stale', 'The Android project model or target changed during the operation. Retry the action.', session.root))
              return
            end
            callback(nil, current_target, device, current_snapshot)
          end,
          function(start_err) return workbench_error('device_start_failed', 'Could not resolve the selected Android device.', session.root, tostring(start_err)) end
        )
      end

      if revalidate then
        self:_current_target(session, target, operation, function(current_err, current_target, current_snapshot)
          if operation.cancelled then return end
          if current_err then
            callback(current_err)
            return
          end
          with_current(current_target, current_snapshot)
        end)
        return
      end

      if not session:is_snapshot_current(snapshot) then
        callback(workbench_error('target_stale', 'The Android project model changed during the operation. Retry the action.', session.root))
        return
      end
      with_current(target, snapshot)
    end)
  end, function(start_err) return workbench_error('discovery_start_failed', 'Could not start Android discovery.', session.root, tostring(start_err)) end)
end

function App:_current_target(session, target, operation, callback)
  operation:start_child(function(done) return session:discover({}, done) end, function(err, snapshot)
    if err then
      callback(err)
      return
    end

    local current = Target.find(snapshot, {
      app = {
        build_path = target.build_path,
        project_path = target.project_path,
      },
      variant = target.variant,
    })
    if not current then
      self:_reconcile(session, snapshot)
      callback(workbench_error('target_stale', 'The selected Android target changed during the operation. Select it again and retry.', session.root))
      return
    end
    if not session:is_snapshot_current(snapshot) then
      callback(workbench_error('target_stale', 'The Android project model changed during the operation. Retry the action.', session.root))
      return
    end
    callback(nil, current, snapshot)
  end, function(start_err) return workbench_error('discovery_start_failed', 'Could not revalidate the Android target.', session.root, tostring(start_err)) end)
end

---@param context? table
---@param callback? fun(err: table?, status: table?)
---@return table handle
function App:select_app(context, callback)
  callback = callback or function() end
  local operation = self:_complete(callback)
  local session, err = self:_session(context)
  if not session then
    vim.schedule(function() operation:finish(err) end)
    return operation
  end

  operation:start_child(function(done) return session:discover({}, done) end, function(discovery_err, snapshot)
    if discovery_err then
      operation:finish(discovery_err, session:status())
      return
    end

    self:_reconcile(session, snapshot)
    local items = Target.applications(snapshot)
    if #items == 0 then
      operation:finish(
        workbench_error('no_android_targets', ('No Android application targets were found under %s.'):format(session.root), session.root),
        session:status()
      )
      return
    end

    local selection = session:selection()
    local current
    for _, item in ipairs(items) do
      if Target.same_app(item, selection.app) then
        current = item
        break
      end
    end

    operation:start_child(
      function(done) return self:_pick(session, 'Android application', items, Target.app_label, current, done) end,
      function(picker_err, item)
        if picker_err then
          operation:finish(picker_err, session:status())
          return
        end
        if item == nil then
          operation:finish(nil, session:status())
          return
        end

        local selected_app
        for _, candidate in ipairs(items) do
          if Target.same_app(candidate, item) then
            selected_app = candidate
            break
          end
        end
        if not selected_app then
          operation:finish(workbench_error('invalid_selection', 'The picker returned an unknown Android application.', session.root), session:status())
          return
        end

        local latest = session:selection()
        local variant = Target.same_app(latest.app, selected_app) and latest.variant or nil
        local _, save_err = session:set_target_selection({ build_path = selected_app.build_path, project_path = selected_app.project_path }, variant)
        if save_err then
          operation:finish(save_err, session:status())
          return
        end

        self:_emit('info', ('Selected Android application %s.'):format(Target.app_label(selected_app)))
        operation:finish(nil, session:status())
      end,
      function(start_err) return workbench_error('picker_failed', 'Could not open the Android application picker.', session.root, tostring(start_err)) end
    )
  end, function(start_err) return workbench_error('discovery_start_failed', 'Could not discover Android applications.', session.root, tostring(start_err)) end)
  return operation
end

---@param context? table
---@param callback? fun(err: table?, status: table?)
---@return table handle
function App:select_variant(context, callback)
  callback = callback or function() end
  local operation = self:_complete(callback)
  local session, err = self:_session(context)
  if not session then
    vim.schedule(function() operation:finish(err) end)
    return operation
  end

  operation:start_child(function(done) return session:discover({}, done) end, function(discovery_err, snapshot)
    if discovery_err then
      operation:finish(discovery_err, session:status())
      return
    end

    self:_reconcile(session, snapshot)
    local selection = session:selection()
    if not selection.app then
      operation:finish(workbench_error('application_not_selected', 'Select an Android application before selecting a variant.', session.root), session:status())
      return
    end

    local items = Target.variants(snapshot, selection.app)
    if #items == 0 then
      operation:finish(workbench_error('no_android_variants', 'The selected Android application has no available variants.', session.root), session:status())
      return
    end

    operation:start_child(function(done) return self:_pick(session, 'Android variant', items, tostring, selection.variant, done) end, function(picker_err, item)
      if picker_err then
        operation:finish(picker_err, session:status())
        return
      end
      if item == nil then
        operation:finish(nil, session:status())
        return
      end
      if type(item) ~= 'string' or not Target.contains_variant(items, item) then
        operation:finish(workbench_error('invalid_selection', 'The picker returned an unknown Android variant.', session.root), session:status())
        return
      end

      local latest = session:selection()
      if not Target.same_app(latest.app, selection.app) then
        operation:finish(
          workbench_error('target_stale', 'The selected Android application changed while choosing a variant. Retry the action.', session.root),
          session:status()
        )
        return
      end
      local _, save_err = session:set_target_selection(latest.app, item)
      if save_err then
        operation:finish(save_err, session:status())
        return
      end

      self:_emit('info', ('Selected Android variant %s.'):format(item))
      operation:finish(nil, session:status())
    end, function(start_err) return workbench_error('picker_failed', 'Could not open the Android variant picker.', session.root, tostring(start_err)) end)
  end, function(start_err) return workbench_error('discovery_start_failed', 'Could not discover Android variants.', session.root, tostring(start_err)) end)
  return operation
end

---@param context? table
---@param callback? fun(err: table?, status: table?)
---@return table handle
function App:select_device(context, callback)
  callback = callback or function() end
  local operation = self:_complete(callback)
  local session, err = self:_session(context)
  if not session then
    vim.schedule(function() operation:finish(err) end)
    return operation
  end

  operation:start_child(function(done) return self.devices:select(session, done) end, function(device_err, device)
    if operation.cancelled then return end
    if device_err then
      operation:finish(device_err, session:status())
      return
    end
    local label = raw_string(device, 'label') or raw_string(device, 'avd_name') or raw_string(device, 'serial') or 'device'
    self:_emit('info', ('Selected Android device %s.'):format(label))
    operation:finish(nil, session:status())
  end, function(start_err) return workbench_error('device_start_failed', 'Could not select an Android device.', session.root, tostring(start_err)) end)
  return operation
end

local function logcat_identity(target, device) return table.concat({ target.application_id, device.serial }, '\0') end

local function logcat_session_item(entry, current)
  return {
    application_id = entry.application_id,
    device_serial = entry.device_serial,
    current = current,
  }
end

local function logcat_session_label(item) return ('%s · %s%s'):format(item.application_id, item.device_serial, item.current and ' (current)' or '') end

local function logcat_session_selection(value)
  if type(value) ~= 'table' then return nil end
  for key in next, value do
    if key ~= 'application_id' and key ~= 'device_serial' and key ~= 'current' then return nil end
  end
  local application_id = raw_string(value, 'application_id')
  local device_serial = raw_string(value, 'device_serial')
  local current = rawget(value, 'current')
  if not application_id or not device_serial or type(current) ~= 'boolean' then return nil end
  return {
    application_id = application_id,
    device_serial = device_serial,
    current = current,
  }
end

function App:_select_logcat(registry, identity)
  local entry = registry.entries[identity]
  if not entry then return nil end
  registry.sequence = registry.sequence + 1
  entry.selected = registry.sequence
  registry.current = identity
  return entry
end

function App:_cleanup_logcat_registry(root, registry)
  if self.logcats[root] == registry and not next(registry.entries) and not next(registry.starting) then self.logcats[root] = nil end
end

function App:_remove_logcat(root, identity, token)
  local registry = self:_logcat_registry(root, false)
  local entry = registry and registry.entries[identity] or nil
  if not entry or (token and entry.token ~= token) then return nil end
  registry.entries[identity] = nil
  if registry.current == identity then
    registry.current = nil
    local selected = -1
    for sibling_identity, sibling in pairs(registry.entries) do
      if sibling.selected > selected then
        selected = sibling.selected
        registry.current = sibling_identity
      end
    end
  end
  self:_cleanup_logcat_registry(root, registry)
  return entry
end

function App:_open_logcat(session, target, device, focus, callback)
  local identity = logcat_identity(target, device)
  local registry = self:_logcat_registry(session.root, true)
  local existing = registry.entries[identity]
  if existing then
    local shown, show_result = pcall(existing.handle.show, existing.handle, { focus = focus })
    if not shown or show_result == false then
      callback(workbench_error('logcat_show_failed', 'Could not show Android Logcat.', session.root, shown and nil or tostring(show_result)))
    else
      self:_select_logcat(registry, identity)
      callback(nil, existing)
    end
    return
  end

  if registry.starting[identity] then
    callback(
      workbench_error('logcat_starting', ('Android Logcat is already starting for %s on %s.'):format(target.application_id, device.serial), session.root)
    )
    return
  end

  local token = {}
  registry.starting[identity] = token
  local function clear_starting()
    if registry.starting[identity] == token then registry.starting[identity] = nil end
    self:_cleanup_logcat_registry(session.root, registry)
  end
  local request = {
    key = session.root,
    title = ('Logcat %s'):format(target.application_id),
    root = session.root,
    project_dir = target.project_dir,
    variant = target.variant,
    application_id = target.application_id,
    device_serial = device.serial,
    device = vim.deepcopy(device),
    focus = focus,
    select_logcat_session = function(done)
      local operation = self:select_logcat_session({ root = session.root }, done)
      return {
        cancel = function()
          if operation.done then return false end
          self.operations[operation] = nil
          return operation:_abandon()
        end,
      }
    end,
    on_exit = function(result)
      vim.schedule(function()
        if self.closed then return end
        local removed = self:_remove_logcat(session.root, identity, token)
        if not removed then return end
        if type(result) == 'table' and result.status == 'failure' then
          local err = result.error
          self:_emit('error', type(err) == 'table' and (err.message or err.code) or tostring(err or 'Android Logcat stopped unexpectedly.'))
        end
      end)
    end,
  }
  if type(self.adb.resolve_executable) == 'function' then
    request.resolve_adb = function()
      local resolved, adb, adb_err = pcall(self.adb.resolve_executable, self.adb)
      if not resolved then return nil, workbench_error('adb_not_found', 'Could not resolve adb for Android Logcat.', session.root, tostring(adb)) end
      if type(adb) ~= 'string' or adb == '' then
        return nil, type(adb_err) == 'table' and adb_err or workbench_error('adb_not_found', 'Could not find adb for Android Logcat.', session.root)
      end
      return adb
    end
  end

  local started, handle = pcall(self.logcat.start, request)
  if not started then
    clear_starting()
    callback(workbench_error('logcat_start_failed', 'Could not start Android Logcat.', session.root, tostring(handle)))
    return
  end
  if type(handle) ~= 'table' or type(handle.show) ~= 'function' or type(handle.stop) ~= 'function' then
    if type(handle) == 'table' and type(handle.stop) == 'function' then pcall(handle.stop, handle) end
    clear_starting()
    callback(workbench_error('logcat_start_failed', 'Android Logcat presenter returned an invalid handle.', session.root))
    return
  end

  if self.closed or self.logcats[session.root] ~= registry or registry.starting[identity] ~= token then
    pcall(handle.stop, handle)
    if type(handle._abandon) == 'function' then pcall(handle._abandon, handle) end
    if not self.closed then callback(workbench_error('app_closed', 'Android Workbench is shut down.')) end
    return
  end

  local entry = {
    token = token,
    identity = identity,
    application_id = target.application_id,
    device_serial = device.serial,
    handle = handle,
  }
  registry.starting[identity] = nil
  registry.entries[identity] = entry
  self:_select_logcat(registry, identity)
  callback(nil, entry)
end

function App:_register_logcat_start(root, operation)
  local registry = self:_logcat_start_registry(root, true)
  registry.sequence = registry.sequence + 1
  operation.logcat_sequence = registry.sequence
  registry.operations[operation] = true
  registry.current = operation
end

function App:_unregister_logcat_start(root, operation)
  local registry = self:_logcat_start_registry(root, false)
  if not registry or not registry.operations[operation] then return end
  registry.operations[operation] = nil
  if registry.current == operation then
    registry.current = nil
    local selected = -1
    for candidate in pairs(registry.operations) do
      if candidate.logcat_sequence > selected then
        selected = candidate.logcat_sequence
        registry.current = candidate
      end
    end
  end
  if not next(registry.operations) then self.logcat_starts[root] = nil end
end

---@param context? table
---@param callback? fun(err: table?, result: table?)
---@return table handle
function App:open_logcat(context, callback)
  callback = callback or function() end
  local session, session_err = self:_session(context)
  if not session then
    local operation = self:_complete(callback)
    vim.schedule(function() operation:finish(session_err) end)
    return operation
  end

  local operation
  operation = self:_complete(function(err, result)
    self:_unregister_logcat_start(session.root, operation)
    callback(err, result)
  end)
  self:_register_logcat_start(session.root, operation)

  self:_preflight(session, operation, true, function(preflight_err, current_target, device)
    if operation.cancelled then return end
    if preflight_err then
      operation:finish(preflight_err)
      return
    end

    self:_open_logcat(session, current_target, device, true, function(logcat_err, entry)
      if operation.cancelled then return end
      if logcat_err then
        operation:finish(logcat_err)
        return
      end
      self:_emit('info', ('Streaming Logcat for %s on %s.'):format(current_target.application_id, device.serial))
      operation:finish(nil, {
        kind = 'logcat',
        target = current_target,
        device = device,
        handle = entry.handle,
      })
    end)
  end)

  return operation
end

---@param context? table
---@param callback? fun(err: table?, result: table?)
---@return table handle
function App:select_logcat_session(context, callback)
  callback = callback or function() end
  local operation = self:_complete(callback)
  local session, err = self:_session(context)
  if not session then
    vim.schedule(function() operation:finish(err) end)
    return operation
  end

  local registry = self:_logcat_registry(session.root, false)
  if not registry or not next(registry.entries) then
    operation:finish(workbench_error('no_logcat_sessions', ('No Android Logcat sessions are running for %s.'):format(session.root), session.root))
    return operation
  end

  local candidates = {}
  local offered = {}
  local current
  for identity, entry in pairs(registry.entries) do
    local item = logcat_session_item(entry, registry.current == identity)
    candidates[#candidates + 1] = item
    offered[identity] = { item = item, token = entry.token }
    if item.current then current = item end
  end
  table.sort(candidates, function(left, right)
    if left.application_id ~= right.application_id then return left.application_id < right.application_id end
    return left.device_serial < right.device_serial
  end)

  operation:start_child(
    function(done) return self:_pick(session, 'Android Logcat sessions', candidates, logcat_session_label, current, done) end,
    function(picker_err, selected)
      if operation.cancelled then return end
      if picker_err then
        operation:finish(picker_err)
        return
      end
      if selected == nil then
        operation:finish()
        return
      end

      local picked = logcat_session_selection(selected)
      local identity = picked and table.concat({ picked.application_id, picked.device_serial }, '\0') or nil
      local candidate = identity and offered[identity] or nil
      if not candidate or candidate.item.current ~= picked.current then
        operation:finish(workbench_error('invalid_selection', 'The picker returned an unknown Android Logcat session.', session.root))
        return
      end

      local latest_registry = self:_logcat_registry(session.root, false)
      local entry = latest_registry and latest_registry.entries[identity] or nil
      if latest_registry ~= registry or not entry or entry.token ~= candidate.token then
        operation:finish(workbench_error('stale_logcat_session', 'The selected Android Logcat session changed while the picker was open.', session.root))
        return
      end

      local shown, show_result = pcall(entry.handle.show, entry.handle, { focus = true })
      if not shown or show_result == false then
        operation:finish(workbench_error('logcat_show_failed', 'Could not show Android Logcat.', session.root, shown and nil or tostring(show_result)))
        return
      end
      if self.closed or operation.cancelled then return end

      latest_registry = self:_logcat_registry(session.root, false)
      entry = latest_registry and latest_registry.entries[identity] or nil
      if latest_registry ~= registry or not entry or entry.token ~= candidate.token then
        operation:finish(workbench_error('stale_logcat_session', 'The selected Android Logcat session changed while it was being shown.', session.root))
        return
      end

      self:_select_logcat(registry, identity)
      self:_emit('info', ('Selected Logcat for %s on %s.'):format(entry.application_id, entry.device_serial))
      operation:finish(nil, logcat_session_item(entry, true))
    end,
    function(start_err) return workbench_error('picker_failed', 'Could not open the Android Logcat session picker.', session.root, tostring(start_err)) end
  )
  return operation
end

function App:stop_logcat(context)
  local session, err = self:_session(context)
  if not session then return nil, err end

  local starts = self:_logcat_start_registry(session.root, false)
  local starting = starts and starts.current or nil
  if starting then
    if not starting.cancel() then
      return nil, workbench_error('cancel_failed', ('Android Logcat startup for %s could not be cancelled.'):format(session.root), session.root)
    end
    self:_emit('info', 'Cancelling Android Logcat startup…')
    return true
  end

  local registry = self:_logcat_registry(session.root, false)
  local entry = registry and registry.current and registry.entries[registry.current] or nil
  if not entry then return nil, workbench_error('logcat_not_running', ('Android Logcat is not running for %s.'):format(session.root), session.root) end
  local stopped, result = pcall(entry.handle.stop, entry.handle)
  if not stopped or result == false then
    return nil,
      workbench_error(
        'logcat_stop_failed',
        ('Android Logcat for %s could not be stopped.'):format(session.root),
        session.root,
        stopped and nil or tostring(result)
      )
  end
  self:_remove_logcat(session.root, entry.identity, entry.token)
  self:_emit('info', 'Stopped Android Logcat.')
  return true
end

function App:stop_all_logcats(context)
  local session, err = self:_session(context)
  if not session then return nil, err end

  local registry = self:_logcat_registry(session.root, false)
  if not registry or not next(registry.entries) then
    return nil, workbench_error('logcat_not_running', ('Android Logcat is not running for %s.'):format(session.root), session.root)
  end

  local entries = {}
  for _, entry in pairs(registry.entries) do
    entries[#entries + 1] = entry
  end
  table.sort(entries, function(left, right)
    if left.application_id ~= right.application_id then return left.application_id < right.application_id end
    return left.device_serial < right.device_serial
  end)

  local result = {
    stopped = 0,
    refused = {},
    refused_total = 0,
    refused_truncated = false,
  }
  for _, entry in ipairs(entries) do
    local stopped, stop_result = pcall(entry.handle.stop, entry.handle)
    if stopped and stop_result ~= false then
      if self:_remove_logcat(session.root, entry.identity, entry.token) then result.stopped = result.stopped + 1 end
    else
      result.refused_total = result.refused_total + 1
      if #result.refused < MAX_LOGCAT_STOP_REFUSALS then
        result.refused[#result.refused + 1] = {
          application_id = entry.application_id,
          device_serial = entry.device_serial,
        }
      end
    end
  end
  result.refused_truncated = result.refused_total > #result.refused

  if result.refused_total > 0 then
    self:_emit(
      'warn',
      ('Stopped %d Android Logcat session%s; %d could not be stopped.'):format(result.stopped, result.stopped == 1 and '' or 's', result.refused_total)
    )
  else
    self:_emit('info', ('Stopped %d Android Logcat session%s.'):format(result.stopped, result.stopped == 1 and '' or 's'))
  end
  return result
end

function App:_start_workflow(kind, context, callback)
  callback = callback or function() end
  local session, session_err = self:_session(context)
  if not session then
    local operation = self:_complete(callback)
    vim.schedule(function() operation:finish(session_err) end)
    return operation
  end

  local operation, rejected = self:_admit_root_operation(session, kind, callback)
  if not operation then return rejected end

  local start_stopped_avd = kind == 'run' and self.run_options.start_stopped_avd == true
  local selected_device = session:selection().device
  if start_stopped_avd and selected_device and selected_device.avd_name and not selected_device.serial then
    self:_emit('info', ('Starting Android emulator %s for Run…'):format(selected_device.avd_name))
  end

  self:_preflight(session, operation, kind ~= 'build', function(preflight_err, current_target, device)
    if operation.cancelled then return end
    if preflight_err then
      operation:finish(preflight_err)
      return
    end

    local function execute_current()
      local function complete_execution(execution_err, result)
        if operation.cancelled then return end
        if execution_err then
          operation:finish(execution_err)
          return
        end
        if kind == 'build' then
          self:_emit('info', ('Built %s.'):format(Target.target_label(current_target)))
        elseif kind == 'run' then
          self:_emit('info', ('Launched %s on %s.'):format(current_target.application_id, result.device.serial))
          if self.logcat_options.open_on_run then
            self:_open_logcat(session, current_target, result.device, false, function(logcat_err)
              if logcat_err then self:_emit('warn', logcat_err.message or tostring(logcat_err)) end
            end)
          end
        else
          self:_emit('info', ('Stopped %s on %s.'):format(current_target.application_id, result.device.serial))
        end
        operation:finish(nil, result)
      end

      local request = {
        root = session.root,
        wrapper = session.wrapper,
        target = current_target,
        device = device,
      }
      if kind == 'build' or kind == 'run' then
        request.on_task_complete = function(task_kind, task_result) self:_publish_task_problems(session, operation, kind, task_kind, task_result) end
      end
      if kind == 'build' or kind == 'run' then
        local authorized, authorize_err = session:authorize()
        if not authorized then
          operation:finish(authorize_err)
          return
        end
      end
      if kind == 'build' then
        operation:start_child(
          function(done) return self.execution:build(request, done) end,
          complete_execution,
          function(start_err) return workbench_error('execution_start_failed', 'Could not start the Android build.', session.root, tostring(start_err)) end
        )
      elseif kind == 'run' then
        operation:start_child(
          function(done) return self.execution:run(request, done) end,
          complete_execution,
          function(start_err) return workbench_error('execution_start_failed', 'Could not start the Android run.', session.root, tostring(start_err)) end
        )
      else
        self:_emit('info', ('Stopping %s on %s.'):format(current_target.application_id, device.serial))
        operation:start_child(
          function(done) return self.execution:stop(request, done) end,
          complete_execution,
          function(start_err) return workbench_error('execution_start_failed', 'Could not start the Android stop.', session.root, tostring(start_err)) end
        )
      end
    end

    execute_current()
  end, { start_stopped_avd = start_stopped_avd })

  return operation
end

---@param context? table
---@param callback? fun(err: table?, result: table?)
---@return table handle
function App:gradle_task(context, callback)
  callback = callback or function() end
  local session, session_err = self:_session(context)
  if not session then
    local operation = self:_complete(callback)
    vim.schedule(function() operation:finish(session_err) end)
    return operation
  end

  local operation, rejected = self:_admit_root_operation(session, 'gradle_task', callback)
  if not operation then return rejected end

  self:_emit('info', 'Loading Gradle tasks…')
  operation:start_child(function(done) return session:discover({}, done) end, function(discovery_err, snapshot)
    if operation.cancelled then return end
    if discovery_err then
      operation:finish(discovery_err)
      return
    end

    local items = GradleTask.sorted(snapshot)
    if #items == 0 then
      operation:finish(workbench_error('no_gradle_tasks', ('No Gradle tasks were found under %s.'):format(session.root), session.root))
      return
    end

    operation:start_child(function(done) return self:_pick(session, 'Gradle task', items, GradleTask.label, nil, done) end, function(picker_err, item)
      if operation.cancelled then return end
      if picker_err then
        operation:finish(picker_err)
        return
      end
      if item == nil then
        operation:finish()
        return
      end

      local selected = GradleTask.resolve(items, item)
      if not selected then
        operation:finish(workbench_error('invalid_selection', 'The picker returned an unknown Gradle task.', session.root))
        return
      end

      operation:start_child(function(done) return session:discover({}, done) end, function(current_err, current_snapshot)
        if operation.cancelled then return end
        if current_err then
          operation:finish(current_err)
          return
        end

        local current = GradleTask.find(current_snapshot, selected.id)
        if not session:is_snapshot_current(current_snapshot) or not current then
          operation:finish(workbench_error('task_stale', 'The selected Gradle task changed during the operation. Retry the action.', session.root))
          return
        end

        local request = {
          root = session.root,
          wrapper = session.wrapper,
          task = current,
          on_task_complete = function(task_kind, task_result) self:_publish_task_problems(session, operation, 'gradle_task', task_kind, task_result) end,
        }
        local authorized, authorize_err = session:authorize()
        if not authorized then
          operation:finish(authorize_err)
          return
        end

        self:_emit('info', ('Running Gradle task %s…'):format(current.id))
        operation:start_child(function(done) return self.execution:gradle_task(request, done) end, function(execution_err, result)
          if operation.cancelled then return end
          if execution_err then
            operation:finish(execution_err)
            return
          end
          self:_emit('info', ('Gradle task %s completed.'):format(current.id))
          operation:finish(nil, result)
        end, function(start_err) return workbench_error('execution_start_failed', 'Could not start the Gradle task.', session.root, tostring(start_err)) end)
      end, function(start_err)
        return workbench_error('discovery_start_failed', 'Could not revalidate the Gradle task.', session.root, tostring(start_err))
      end)
    end, function(start_err) return workbench_error('picker_failed', 'Could not open the Gradle task picker.', session.root, tostring(start_err)) end)
  end, function(start_err) return workbench_error('discovery_start_failed', 'Could not discover Gradle tasks.', session.root, tostring(start_err)) end)

  return operation
end

function App:_start_emulator_workflow(kind, context, callback)
  callback = callback or function() end
  local session, session_err = self:_session(context)
  if not session then
    local operation = self:_complete(callback)
    vim.schedule(function() operation:finish(session_err) end)
    return operation
  end

  local operation, rejected = self:_admit_root_operation(session, kind, callback)
  if not operation then return rejected end

  local starting = kind == 'emulator_start'
  local selected = session:selection().device
  local avd_name = selected and selected.avd_name
  self:_emit(
    'info',
    starting and (avd_name and ('Starting Android emulator %s…'):format(avd_name) or 'Starting an Android emulator…')
      or (avd_name and ('Stopping Android emulator %s…'):format(avd_name) or 'Stopping the selected Android emulator…')
  )

  operation:start_child(
    function(done)
      if starting then return self.devices:start(session, done) end
      return self.devices:stop(session, done)
    end,
    function(device_err, device)
      if operation.cancelled then return end
      if device_err then
        operation:finish(device_err)
        return
      end

      local name = raw_string(device, 'avd_name') or avd_name or 'Android emulator'
      if starting then
        self:_emit('info', ('Android emulator %s is ready on %s.'):format(name, raw_string(device, 'serial') or 'ADB'))
      else
        self:_emit('info', ('Stopped Android emulator %s.'):format(name))
      end
      operation:finish(nil, {
        kind = kind,
        device = device,
      })
    end,
    function(start_err)
      return workbench_error(
        'emulator_start_failed',
        starting and 'Could not start the Android emulator workflow.' or 'Could not start the Android emulator stop workflow.',
        session.root,
        tostring(start_err)
      )
    end
  )

  return operation
end

function App:build(context, callback) return self:_start_workflow('build', context, callback) end

function App:run(context, callback) return self:_start_workflow('run', context, callback) end

function App:stop(context, callback) return self:_start_workflow('stop', context, callback) end

function App:start_emulator(context, callback) return self:_start_emulator_workflow('emulator_start', context, callback) end

function App:stop_emulator(context, callback) return self:_start_emulator_workflow('emulator_stop', context, callback) end

function App:cancel(context)
  local session, err = self:_session(context)
  if not session then return nil, err end
  local operation = self.active[session.root]
  if not operation then return nil, workbench_error('no_active_operation', ('No Android operation is running for %s.'):format(session.root), session.root) end
  if not operation.cancel() then
    return nil, workbench_error('cancel_failed', ('The Android operation for %s could not be cancelled.'):format(session.root), session.root)
  end
  self:_emit('info', 'Cancelling the active Android operation…')
  return true
end

function App:shutdown()
  if self.closed then return false end
  self.closed = true
  local task_output = self.task_output
  self.task_output = nil
  if task_output then pcall(task_output._close_output) end
  local operations = self.operations
  self.operations = {}
  self.active = {}
  self.logcat_starts = {}
  for operation in pairs(operations) do
    pcall(operation._abandon, operation)
  end
  local logcats = self.logcats
  self.logcats = {}
  for _, registry in pairs(logcats) do
    for _, entry in pairs(registry.entries) do
      pcall(entry.handle.stop, entry.handle)
      if type(entry.handle._abandon) == 'function' then pcall(entry.handle._abandon, entry.handle) end
    end
  end
  for _, session in pairs(self.sessions) do
    pcall(session.close, session)
  end
  self.sessions = {}
  return true
end

return M

-- vim: ts=2 sts=2 sw=2 et
