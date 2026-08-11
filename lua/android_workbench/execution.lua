local Target = require 'android_workbench.target'
local Problems = require 'android_workbench.gradle.problems'
local Task = require 'android_workbench.gradle.task'
local Problem = require 'android_workbench.problem'

local M = {}

local function pack(...) return { n = select('#', ...), ... } end

local Execution = {}
Execution.__index = Execution

local function failure(code, message, details)
  return {
    code = code,
    message = message,
    details = details,
  }
end

local function cancel_handle(handle)
  if type(handle) ~= 'table' or type(handle.cancel) ~= 'function' then return false, 'operation handle does not expose cancel()' end
  local ok, result = pcall(handle.cancel, handle)
  if not ok then return false, tostring(result) end
  if result == false then return false, 'operation handle rejected cancellation' end
  return true
end

local function operation(callback)
  local current = {
    child = nil,
    done = false,
    cancelling = false,
    generation = 0,
    child_active = false,
  }

  function current:finish(err, result)
    if self.done then return false end
    self.done = true
    self.generation = self.generation + 1
    self.child = nil
    self.child_active = false
    callback(err, result)
    return true
  end

  function current:start_child(starter, on_terminal, kind)
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
              or failure('operation_failed', 'Android operation failed while cancelling.', { error = tostring(child_err) })
          )
        else
          self:finish(failure('cancelled', 'Android operation was cancelled.'))
        end
        return
      end
      local ok, err = xpcall(function() on_terminal(unpack(args, 1, args.n)) end, debug.traceback)
      if not ok and not self.done then
        cancel_handle(self.child)
        self:finish(failure('operation_failed', ('Android %s operation failed.'):format(kind), { error = tostring(err) }))
      end
    end

    local started, handle = pcall(starter, terminal)
    if not started then
      if self.done or self.generation ~= token then return false end
      self.generation = self.generation + 1
      self.child_active = false
      self:finish(failure('adapter_failed', ('Could not start Android %s operation.'):format(kind), { error = tostring(handle) }))
      return false
    end
    if self.done or self.generation ~= token then
      if type(handle) == 'table' and type(handle.cancel) == 'function' then pcall(handle.cancel, handle) end
      return true
    end
    if handle ~= nil and (type(handle) ~= 'table' or type(handle.cancel) ~= 'function') then
      self.generation = self.generation + 1
      self.child_active = false
      self:finish(failure('invalid_operation_handle', ('Android %s adapter returned an invalid operation handle.'):format(kind)))
      return false
    end
    self.child = handle
    return true
  end

  function current.cancel()
    if current.done or current.cancelling then return false end
    local child = current.child
    if not child then
      if current.child_active then return false end
      return current:finish(failure('cancelled', 'Android operation was cancelled.'))
    end
    current.cancelling = true
    local accepted = cancel_handle(child)
    if current.done then return true end
    if not accepted then
      current.cancelling = false
      return false
    end
    return true
  end

  return current
end

local function task_error(kind, target, result)
  if result.status == 'cancelled' then return failure('cancelled', ('Android %s was cancelled.'):format(kind), result) end
  return failure(kind .. '_failed', ('Android %s failed for %s.'):format(kind, Target.target_label(target)), result)
end

local function gradle_task_error(task, result)
  if result.status == 'cancelled' then return failure('cancelled', ('Gradle task %s was cancelled.'):format(task.id), result) end
  return failure('gradle_task_failed', ('Gradle task %s failed. See task output.'):format(task.id), result)
end

local function normalize_task_result(result, spec, collection)
  if type(result) ~= 'table' or (result.status ~= 'success' and result.status ~= 'failure' and result.status ~= 'cancelled') then return nil end

  local normalized = {}
  for key, value in pairs(result) do
    normalized[key] = value
  end

  if result.name ~= nil and (type(result.name) ~= 'string' or result.name == '') then return nil end
  if result.metadata ~= nil and type(result.metadata) ~= 'table' then return nil end

  local provided = {}
  local provided_truncated = false
  if result.problems ~= nil or result.problems_truncated ~= nil then
    provided, provided_truncated = Problem.normalize(result.problems == nil and {} or result.problems, result.problems_truncated)
    if not provided then return nil end
  end

  local collected = {}
  local collected_truncated = collection.incomplete
  local collected_ok, collected_result = pcall(collection.parser.finish, collection.parser)
  if collected_ok and type(collected_result) == 'table' then
    collected, collected_truncated = Problem.normalize(collected_result.problems or {}, collected_result.problems_truncated == true or collected_truncated)
  end
  if not collected then
    collected = {}
    collected_truncated = true
  end

  local combined = {}
  vim.list_extend(combined, provided)
  vim.list_extend(combined, collected)
  local problems, problems_truncated = Problem.normalize(combined, provided_truncated or collected_truncated)
  if not problems then return nil end

  normalized.name = result.name or spec.name
  normalized.metadata = spec.metadata
  normalized.problems = problems
  normalized.problems_truncated = problems_truncated
  return normalized
end

local function observe_task(request, kind, result)
  if result.status == 'cancelled' or type(request.on_task_complete) ~= 'function' then return end
  local observed = {
    status = result.status,
    code = result.code,
    signal = result.signal,
    name = result.name,
    metadata = vim.deepcopy(result.metadata),
    problems = vim.deepcopy(result.problems),
    problems_truncated = result.problems_truncated,
  }
  if result.error ~= nil then observed.error = result.error end
  pcall(request.on_task_complete, kind, observed)
end

local function start_task(execution, current, request, kind, spec, collection, invalid_message, on_result)
  current:start_child(function(done) return execution.runner.start(spec, done) end, function(err, result)
    if err then
      current:finish(err)
      return
    end
    result = normalize_task_result(result, spec, collection)
    if not result then
      current:finish(failure('invalid_runner_result', invalid_message))
      return
    end
    observe_task(request, kind, result)
    on_result(result)
  end, kind)
end

local function valid_component(application_id, component)
  return type(component) == 'table' and type(component.component) == 'string' and component.component ~= '' and component.package == application_id
end

local function android_task_spec(kind, request, task, env, collection)
  local downstream_output = request.on_output
  return {
    argv = { request.wrapper, '--console=plain', task },
    cwd = request.root,
    env = env,
    name = ('Android %s %s'):format(kind, Target.target_label(request.target)),
    metadata = {
      kind = 'android-' .. kind,
      root = request.root,
      target_id = request.target.id,
      application_id = request.target.application_id,
      device_serial = request.device and request.device.serial or nil,
    },
    on_output = function(event)
      local called, accepted = pcall(collection.parser.on_output, collection.parser, event)
      if not called or accepted ~= true then collection.incomplete = true end
      if type(downstream_output) == 'function' then pcall(downstream_output, event) end
    end,
  }
end

local function utf8_prefix(value, max_bytes)
  local parts = {}
  local bytes = 0
  for index = 0, vim.fn.strchars(value) - 1 do
    local character = vim.fn.strcharpart(value, index, 1)
    if character == '' or bytes + #character > max_bytes then break end
    parts[#parts + 1] = character
    bytes = bytes + #character
  end
  return table.concat(parts)
end

local function gradle_task_name(task)
  local prefix = 'Gradle task '
  local suffix = '…'
  local name = prefix .. task.id
  if #name <= Problem.limits.name_bytes then return name end
  local available = Problem.limits.name_bytes - #prefix - #suffix
  return prefix .. utf8_prefix(task.id, available) .. suffix
end

local function gradle_task_spec(request, task, collection)
  local downstream_output = request.on_output
  return {
    argv = { request.wrapper, '--console=plain', task.id },
    cwd = request.root,
    name = gradle_task_name(task),
    metadata = {
      kind = 'gradle_task',
      root = request.root,
      task_id = task.id,
      build_path = task.build_path,
      project_path = task.project_path,
      task_name = task.name,
    },
    on_output = function(event)
      local called, accepted = pcall(collection.parser.on_output, collection.parser, event)
      if not called or accepted ~= true then collection.incomplete = true end
      if type(downstream_output) == 'function' then pcall(downstream_output, event) end
    end,
  }
end

---@param opts { runner: table, adb: table }
---@return table
function M.new(opts)
  assert(type(opts) == 'table', 'android_workbench.execution.new requires options')
  assert(type(opts.runner) == 'table' and type(opts.runner.start) == 'function', 'android_workbench.execution.new requires runner.start')
  assert(type(opts.adb) == 'table', 'android_workbench.execution.new requires an adb service')
  return setmetatable({ runner = opts.runner, adb = opts.adb }, Execution)
end

function Execution:build(request, callback)
  local current = operation(callback)
  local collection = { parser = Problems.new(), incomplete = false }
  local spec = android_task_spec('build', request, request.target.assemble_task, nil, collection)
  start_task(self, current, request, 'build', spec, collection, 'Android build runner returned an invalid result.', function(result)
    if result.status ~= 'success' then
      current:finish(task_error('build', request.target, result))
      return
    end
    current:finish(nil, { kind = 'build', target = request.target, task = result })
  end)
  return current
end

function Execution:gradle_task(request, callback)
  local current = operation(callback)
  local task, task_err = Task.normalize(request.task)
  if not task then
    vim.schedule(function() current:finish(failure('invalid_gradle_task', 'Gradle task selection is invalid.', { error = task_err })) end)
    return current
  end

  local collection = { parser = Problems.new(), incomplete = false }
  local spec = gradle_task_spec(request, task, collection)
  start_task(self, current, request, 'gradle_task', spec, collection, 'Gradle task runner returned an invalid result.', function(result)
    if result.status ~= 'success' then
      current:finish(gradle_task_error(task, result))
      return
    end
    current:finish(nil, {
      kind = 'gradle_task',
      gradle_task = vim.deepcopy(task),
      task = result,
    })
  end)
  return current
end

function Execution:run(request, callback)
  local current = operation(callback)
  if not request.target.install_task then
    vim.schedule(function() current:finish(failure('run_unavailable', ('%s does not expose an install task.'):format(Target.target_label(request.target)))) end)
    return current
  end

  local env = { ANDROID_SERIAL = request.device.serial }
  local collection = { parser = Problems.new(), incomplete = false }
  local spec = android_task_spec('run', request, request.target.install_task, env, collection)
  start_task(self, current, request, 'run', spec, collection, 'Android run runner returned an invalid result.', function(result)
    if result.status ~= 'success' then
      current:finish(task_error('run', request.target, result))
      return
    end

    current:start_child(
      function(done) return self.adb:resolve_launch_components(request.device.serial, request.target.application_id, done) end,
      function(resolve_err, components)
        if resolve_err then
          current:finish(resolve_err)
          return
        end
        if type(components) ~= 'table' or not vim.islist(components) then
          current:finish(failure('invalid_adb_result', 'ADB returned an invalid launcher activity list.'))
          return
        end
        local selected = components[1]
        if not selected then
          current:finish(failure('launcher_not_found', ('Installed %s, but it has no enabled MAIN/LAUNCHER activity.'):format(request.target.application_id)))
          return
        end
        if not valid_component(request.target.application_id, selected) then
          current:finish(failure('invalid_adb_result', 'ADB returned an invalid launcher activity.'))
          return
        end

        current:start_child(
          function(done) return self.adb:launch(request.device.serial, request.target.application_id, selected.component, done) end,
          function(launch_err, launch_result)
            if launch_err then
              current:finish(launch_err)
              return
            end
            if type(launch_result) ~= 'table' then
              current:finish(failure('invalid_adb_result', 'ADB returned an invalid launch result.'))
              return
            end
            current:finish(nil, {
              kind = 'run',
              target = request.target,
              device = request.device,
              component = selected,
              task = result,
              launch = launch_result,
            })
          end,
          'launch'
        )
      end,
      'launcher resolution'
    )
  end)
  return current
end

function Execution:stop(request, callback)
  local current = operation(callback)
  current:start_child(function(done) return self.adb:stop(request.device.serial, request.target.application_id, done) end, function(err, result)
    if err then
      current:finish(err)
      return
    end
    if type(result) ~= 'table' then
      current:finish(failure('invalid_adb_result', 'ADB returned an invalid stop result.'))
      return
    end
    current:finish(nil, {
      kind = 'stop',
      target = request.target,
      device = request.device,
      result = result,
    })
  end, 'stop')
  return current
end

return M

-- vim: ts=2 sts=2 sw=2 et
