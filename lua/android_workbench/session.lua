local GradleTask = require 'android_workbench.gradle.task'

local M = {}

local Session = {}
Session.__index = Session

local function workbench_error(code, message, root, details)
  return {
    code = code,
    message = message,
    root = root,
    details = details,
  }
end

local function cancel_handle(handle)
  if type(handle) ~= 'table' or type(handle.cancel) ~= 'function' then return false end
  local ok, result = pcall(handle.cancel, handle)
  return ok and result ~= false
end

local function defer(callback, err, value)
  local done = false
  vim.schedule(function()
    if done then return end
    done = true
    callback(err, value)
  end)

  return {
    cancel = function()
      if done then return false end
      done = true
      vim.schedule(function() callback(workbench_error('cancelled', 'Android Workbench operation was cancelled.')) end)
      return true
    end,
  }
end

local function schedule_waiter(waiter, err, snapshot)
  if waiter.terminal ~= nil then return false end
  waiter.terminal = { err = err, snapshot = snapshot }
  if waiter.delivery_scheduled then return true end
  waiter.delivery_scheduled = true
  vim.schedule(function()
    if waiter.done then return end
    waiter.done = true
    waiter.delivery_scheduled = false
    local terminal = waiter.terminal
    waiter.terminal = nil
    waiter.callback(terminal.err, terminal.snapshot)
  end)
  return true
end

local function copy_selection(selection)
  local app = selection and selection.app
  local device = selection and selection.device
  return {
    app = app and {
      build_path = app.build_path,
      project_path = app.project_path,
    } or nil,
    variant = selection and selection.variant or nil,
    device = device and {
      serial = device.serial,
      avd_name = device.avd_name,
    } or nil,
  }
end

local function notify(notifications, event)
  local ok = pcall(notifications.emit, event)
  return ok
end

local function snapshot_is_stale(discovery, snapshot)
  if type(discovery.is_stale) ~= 'function' then return true end
  local ok, stale = pcall(discovery.is_stale, snapshot)
  return not ok or stale ~= false
end

---@param opts table
---@return table
function M.new(opts)
  assert(type(opts) == 'table', 'android_workbench.session.new requires options')
  assert(type(opts.root) == 'string', 'android_workbench.session.new requires a root')
  assert(type(opts.wrapper) == 'string', 'android_workbench.session.new requires a wrapper')
  assert(type(opts.discovery) == 'table' and type(opts.discovery.discover) == 'function', 'android_workbench.session.new requires discovery.discover')
  assert(type(opts.trust) == 'table' and type(opts.trust.authorize) == 'function', 'android_workbench.session.new requires trust.authorize')
  assert(
    type(opts.state) == 'table' and type(opts.state.load) == 'function' and type(opts.state.save) == 'function',
    'android_workbench.session.new requires state.load/save'
  )
  assert(type(opts.notifications) == 'table' and type(opts.notifications.emit) == 'function', 'android_workbench.session.new requires notifications.emit')

  return setmetatable({
    root = opts.root,
    wrapper = opts.wrapper,
    discovery = opts.discovery,
    trust = opts.trust,
    state = opts.state,
    notifications = opts.notifications,
    closed = false,
    authorized = false,
    phase = 'idle',
    snapshot = nil,
    inflight = nil,
    last_error = nil,
    selection_loaded = false,
    selected = { app = nil, variant = nil, device = nil },
  }, Session)
end

---@return boolean? authorized
---@return table? error
function Session:authorize()
  if self.closed then return nil, workbench_error('session_closed', ('Android Workbench session for %s is closed.'):format(self.root), self.root) end

  local authorized_call, authorized, trust_err = pcall(self.trust.authorize, self.root)
  if not authorized_call then
    trust_err = workbench_error('trust_check_failed', ('Could not check trust for %s.'):format(self.root), self.root, tostring(authorized))
    authorized = nil
  end
  if trust_err and type(trust_err) ~= 'table' then trust_err = workbench_error('trust_check_failed', tostring(trust_err), self.root) end
  if not authorized then
    self.authorized = false
    self.phase = 'error'
    self.last_error = trust_err or workbench_error('project_not_trusted', ('Android project execution was not authorized for %s.'):format(self.root), self.root)
    return nil, self.last_error
  end

  self.authorized = true
  return true
end

function Session:_ensure_selection()
  if self.selection_loaded then return end
  self.selection_loaded = true

  local called, selection, err = pcall(self.state.load, self.root)
  if not called then
    err = workbench_error('state_read_failed', ('Could not load Android Workbench state for %s.'):format(self.root), self.root, tostring(selection))
    selection = nil
  end

  if selection then self.selected = copy_selection(selection) end
  if err then notify(self.notifications, {
    level = 'warn',
    title = 'Android Workbench',
    message = err.message or tostring(err),
  }) end
end

---@return table
function Session:selection()
  self:_ensure_selection()
  return copy_selection(self.selected)
end

---@param selection table
---@param opts? { keep_on_error?: boolean }
---@return boolean? saved
---@return table? error
function Session:set_selection(selection, opts)
  if self.closed then return nil, workbench_error('session_closed', ('Android Workbench session for %s is closed.'):format(self.root), self.root) end
  self:_ensure_selection()
  local previous = self.selected
  self.selected = copy_selection(selection)

  local called, saved, err = pcall(self.state.save, self.root, self.selected)
  if not called then
    if not (opts and opts.keep_on_error) then self.selected = previous end
    return nil, workbench_error('state_write_failed', ('Could not save Android Workbench state for %s.'):format(self.root), self.root, tostring(saved))
  end
  if not saved then
    if not (opts and opts.keep_on_error) then self.selected = previous end
    return nil, err or workbench_error('state_write_failed', ('Could not save Android Workbench state for %s.'):format(self.root), self.root)
  end
  return saved, err
end

---@param app table?
---@param variant string?
---@param opts? { keep_on_error?: boolean }
---@return boolean? saved
---@return table? error
function Session:set_target_selection(app, variant, opts)
  local current = self:selection()
  current.app = app
  current.variant = variant
  return self:set_selection(current, opts)
end

---@param device table?
---@param opts? { keep_on_error?: boolean }
---@return boolean? saved
---@return table? error
function Session:set_device_selection(device, opts)
  local current = self:selection()
  current.device = device
  return self:set_selection(current, opts)
end

---@return table
function Session:status()
  self:_ensure_selection()
  return {
    root = self.root,
    wrapper = self.wrapper,
    phase = self.phase,
    authorized = self.authorized,
    selection = copy_selection(self.selected),
    targets = self.snapshot and type(self.snapshot.targets) == 'table' and #self.snapshot.targets or 0,
    error = self.last_error,
  }
end

function Session:is_snapshot_current(snapshot) return not self.closed and self.inflight == nil and snapshot ~= nil and self.snapshot == snapshot end

function Session:_finish_flight(flight, err, snapshot)
  if self.inflight ~= flight then return end
  self.inflight = nil

  if self.closed then return end
  if err ~= nil then
    if type(err) ~= 'table' then
      err = workbench_error('discovery_failed', tostring(err), self.root)
    elseif type(rawget(err, 'code')) ~= 'string' or type(rawget(err, 'message')) ~= 'string' then
      err = workbench_error('discovery_failed', 'Android discovery returned an invalid error.', self.root)
    end
  end
  if flight.cancelling then
    if err == nil or (type(err) == 'table' and err.code == 'cancelled') then
      err = workbench_error('cancelled', flight.cancel_message or 'Android Workbench discovery was cancelled.', self.root)
    end
    snapshot = nil
  end
  if err then
    self.phase = err.code == 'cancelled' and 'idle' or 'error'
    self.last_error = err.code == 'cancelled' and nil or err
  else
    self.phase = 'ready'
    self.last_error = nil
    self.snapshot = snapshot
  end

  for _, waiter in ipairs(flight.waiters) do
    if not waiter.done then schedule_waiter(waiter, err, snapshot) end
  end
end

function Session:_cancel_flight(message)
  local flight = self.inflight
  if not flight then return end
  flight.cancelling = true
  flight.cancel_message = message
  cancel_handle(flight.handle)
  self.inflight = nil

  local err = workbench_error('cancelled', message or 'Android Workbench discovery was cancelled.', self.root)
  for _, waiter in ipairs(flight.waiters) do
    if not waiter.done then schedule_waiter(waiter, err) end
  end
end

---@param opts? { force?: boolean }
---@param callback fun(err: table?, snapshot: table?)
---@return table handle
function Session:discover(opts, callback)
  opts = opts or {}
  callback = callback or function() end

  if self.closed then
    return defer(callback, workbench_error('session_closed', ('Android Workbench session for %s is closed.'):format(self.root), self.root))
  end
  if opts.force and not self.inflight then
    self.phase = 'idle'
    self.last_error = nil
  elseif self.inflight then
    -- Join below. A retained snapshot may be stale while its replacement is in flight.
  elseif self.snapshot and not snapshot_is_stale(self.discovery, self.snapshot) then
    return defer(callback, nil, self.snapshot)
  end

  local waiter = { callback = callback, done = false }
  if self.inflight then
    self.inflight.waiters[#self.inflight.waiters + 1] = waiter
  else
    local authorized, trust_err = self:authorize()
    if not authorized then return defer(callback, trust_err) end

    self.phase = 'discovering'
    self.last_error = nil
    local flight = {
      waiters = { waiter },
      handle = nil,
    }
    self.inflight = flight

    local started, handle = pcall(self.discovery.discover, { root = self.root }, function(err, snapshot)
      if not err then
        if
          type(snapshot) ~= 'table'
          or snapshot.schema_version ~= 1
          or snapshot.root ~= self.root
          or type(snapshot.builds) ~= 'table'
          or not vim.islist(snapshot.builds)
          or type(snapshot.targets) ~= 'table'
          or not vim.islist(snapshot.targets)
          or type(snapshot.tasks) ~= 'table'
          or not vim.islist(snapshot.tasks)
        then
          err = workbench_error('discovery_invalid', ('Android discovery returned an invalid snapshot for %s.'):format(self.root), self.root)
          snapshot = nil
        else
          local tasks = GradleTask.normalize_catalog(snapshot.tasks)
          if not tasks then
            err = workbench_error('discovery_invalid', ('Android discovery returned an invalid task catalog for %s.'):format(self.root), self.root)
            snapshot = nil
          else
            snapshot.tasks = tasks
          end
        end
      end
      self:_finish_flight(flight, err, snapshot)
    end)
    if not started then
      self:_finish_flight(
        flight,
        workbench_error('discovery_start_failed', ('Could not start Android discovery for %s.'):format(self.root), self.root, tostring(handle))
      )
    elseif self.inflight == flight then
      flight.handle = handle
    end
  end

  return {
    cancel = function()
      if waiter.done or waiter.cancelled then return false end
      if waiter.terminal then
        waiter.terminal = { err = workbench_error('cancelled', 'Android Workbench discovery was cancelled.', self.root) }
        return true
      end
      local flight = self.inflight
      if not flight then
        schedule_waiter(waiter, workbench_error('cancelled', 'Android Workbench discovery was cancelled.', self.root))
        return true
      end
      for _, candidate in ipairs(flight.waiters) do
        if candidate ~= waiter and not candidate.done and candidate.terminal == nil then
          schedule_waiter(waiter, workbench_error('cancelled', 'Android Workbench discovery was cancelled.', self.root))
          return true
        end
      end
      waiter.cancelled = true
      flight.cancelling = true
      flight.cancel_message = 'Android Workbench discovery was cancelled.'
      local accepted = cancel_handle(flight.handle)
      if waiter.done or self.inflight ~= flight then return true end
      if not accepted then
        waiter.cancelled = nil
        flight.cancelling = nil
        flight.cancel_message = nil
        return false
      end
      return true
    end,
  }
end

---@param callback fun(err: table?, snapshot: table?)
---@return table handle
function Session:refresh(callback)
  callback = callback or function() end
  if not self.inflight then return self:discover({ force = true }, callback) end

  local operation = {
    child = nil,
    done = false,
    cancelling = false,
    generation = 0,
  }

  local function finish(err, snapshot)
    if operation.done then return false end
    operation.done = true
    operation.generation = operation.generation + 1
    operation.child = nil
    callback(err, snapshot)
    return true
  end

  local start
  start = function(opts, after)
    if operation.done or operation.cancelling then return false end
    operation.generation = operation.generation + 1
    local token = operation.generation
    operation.child = nil

    local function terminal(err, snapshot)
      if operation.done or operation.generation ~= token then return end
      operation.generation = operation.generation + 1
      operation.child = nil
      if operation.cancelling then
        if err ~= nil and not (type(err) == 'table' and err.code == 'cancelled') then
          finish(type(err) == 'table' and err or workbench_error('discovery_failed', tostring(err), self.root))
        else
          finish(workbench_error('cancelled', 'Android Workbench refresh was cancelled.', self.root))
        end
        return
      end
      after(err, snapshot)
    end

    local called, child = pcall(self.discover, self, opts, terminal)
    if not called then
      if operation.generation == token then finish(workbench_error('discovery_start_failed', tostring(child), self.root)) end
      return false
    end
    if operation.done or operation.generation ~= token then
      cancel_handle(child)
      return true
    end
    if type(child) ~= 'table' or type(child.cancel) ~= 'function' then
      operation.generation = operation.generation + 1
      finish(workbench_error('invalid_operation_handle', 'Android discovery returned an invalid refresh handle.', self.root))
      return false
    end
    operation.child = child
    return true
  end

  start({}, function()
    start({ force = true }, function(err, snapshot) finish(err, snapshot) end)
  end)

  function operation.cancel()
    if operation.done or operation.cancelling then return false end
    operation.cancelling = true
    local child = operation.child
    if not child then return finish(workbench_error('cancelled', 'Android Workbench refresh was cancelled.', self.root)) end
    local accepted = cancel_handle(child)
    if operation.done then return true end
    if not accepted then
      operation.cancelling = false
      return false
    end
    return true
  end

  return operation
end

function Session:close()
  if self.closed then return false end
  self.closed = true
  self.snapshot = nil
  self.phase = 'closed'
  self:_cancel_flight 'Android Workbench session was closed.'
  return true
end

return M

-- vim: ts=2 sts=2 sw=2 et
