local TaskOperation = require 'android_workbench.task_operation'
local Problems = require 'android_workbench.gradle.problems'
local Problem = require 'android_workbench.problem'

local M = {}

local function default_components(parser)
  return {
    'on_exit_set_status',
    { 'on_output_parse', parser = parser },
    { 'open_output', direction = 'dock', focus = false, on_start = 'always' },
    { 'on_complete_dispose', require_view = { 'FAILURE' } },
  }
end

local function status_name(overseer, status)
  local statuses = type(overseer) == 'table' and type(overseer.STATUS) == 'table' and overseer.STATUS or {}
  if status == statuses.SUCCESS or status == 'SUCCESS' then return 'success' end
  if status == statuses.CANCELED or status == 'CANCELED' then return 'cancelled' end
  return 'failure'
end

---@param opts? { overseer?: table, schedule?: fun(callback: function), max_capture_bytes?: integer, components?: table[] }
---@return { start: fun(request: table, callback: function): table }
function M.new(opts)
  opts = opts or {}
  if opts.components ~= nil and (type(opts.components) ~= 'table' or not vim.islist(opts.components)) then
    error('android_workbench.integrations.overseer.new: components must be an array', 2)
  end
  local injected = opts.overseer
  local components = opts.components
  local schedule = opts.schedule or vim.schedule
  local operation_opts = {
    schedule = schedule,
    max_capture_bytes = opts.max_capture_bytes,
  }

  return {
    start = function(request, callback)
      local operation = TaskOperation.new(request, callback, operation_opts)
      local parser = components == nil and Problems.new() or nil
      local task_components = components or default_components(parser)
      local task
      local task_completion
      local process_completion
      local cancel_requested = false
      local stop_in_progress = false
      local stop_scheduled = false
      local terminal_error

      local function complete_when_released()
        if operation:is_done() or stop_in_progress or not task_completion or not process_completion then return end
        if terminal_error then
          operation:complete(terminal_error)
          return
        end
        operation:complete(nil, {
          status = task_completion.status,
          code = task_completion.code ~= nil and task_completion.code or process_completion.code,
          signal = process_completion.signal,
          error = task_completion.error,
          problems = task_completion.problems,
          problems_truncated = task_completion.problems_truncated,
        })
      end

      local handle = {}
      function handle.cancel()
        if cancel_requested or stop_in_progress or not task then return false end
        if operation:is_done() then
          if terminal_error or not task_completion or task_completion.status ~= 'success' or not process_completion then return false end
          return operation:replace_pending_terminal(nil, {
            status = 'cancelled',
            code = task_completion.code ~= nil and task_completion.code or process_completion.code,
            signal = process_completion.signal,
          })
        end
        stop_in_progress = true
        local called, stopped = pcall(task.stop, task)
        stop_in_progress = false
        if called and stopped == true then cancel_requested = true end
        complete_when_released()
        if operation:is_done() then return true end
        return called and stopped == true
      end

      if operation:is_done() then return handle end

      local overseer = injected
      if not overseer then
        local loaded, value = pcall(require, 'overseer')
        if not loaded then
          operation:complete(TaskOperation.failure('runner_unavailable', 'Overseer is not available.', { error = tostring(value) }))
          return handle
        end
        overseer = value
      end
      if type(overseer) ~= 'table' or type(overseer.new_task) ~= 'function' then
        operation:complete(TaskOperation.failure('runner_unavailable', 'Overseer returned an invalid integration module.'))
        return handle
      end

      local function consume(stream, err, data)
        if operation:is_done() then return end
        if err then
          if terminal_error then return end
          terminal_error = TaskOperation.failure('stream_error', ('Failed reading Overseer task %s.'):format(stream), { error = tostring(err) })
          if task and not stop_scheduled then
            stop_scheduled = true
            schedule(function()
              stop_scheduled = false
              if operation:is_done() then return end
              stop_in_progress = true
              pcall(task.stop, task)
              stop_in_progress = false
              complete_when_released()
            end)
          end
          return
        end
        operation:output(stream, data)
      end

      local function consume_job_output(stream, data)
        if type(data) ~= 'table' or not vim.islist(data) then
          consume(stream, 'Overseer job output was not a list of lines.')
          return
        end
        for _, line in ipairs(data) do
          if type(line) ~= 'string' then
            consume(stream, 'Overseer job output contained a non-string line.')
            return
          end
        end
        consume(stream, nil, table.concat(data, '\n'))
      end

      local created, value = pcall(overseer.new_task, {
        cmd = operation.request.argv,
        cwd = operation.request.cwd,
        env = operation.request.env,
        name = operation.request.name,
        metadata = operation.request.metadata,
        strategy = {
          'jobstart',
          use_terminal = false,
          wrap_opts = {
            on_stdout = function(_, data) consume_job_output('stdout', data) end,
            on_stderr = function(_, data) consume_job_output('stderr', data) end,
            on_exit = function(_, code)
              if process_completion then return end
              if type(code) ~= 'number' then
                terminal_error = terminal_error or TaskOperation.failure('invalid_process_result', 'Overseer returned an invalid process completion result.')
                process_completion = {}
              else
                process_completion = { code = code }
              end
              complete_when_released()
            end,
          },
        },
        components = task_components,
      })
      if not created or type(value) ~= 'table' then
        operation:complete(TaskOperation.failure('task_create_failed', 'Could not create Overseer task.', { error = tostring(value) }))
        return handle
      end
      task = value
      if type(task.subscribe) ~= 'function' or type(task.start) ~= 'function' or type(task.stop) ~= 'function' then
        operation:complete(TaskOperation.failure('task_create_failed', 'Overseer returned an invalid task.'))
        if type(task.dispose) == 'function' then pcall(task.dispose, task, true) end
        return handle
      end

      local subscribed, subscribe_result = pcall(task.subscribe, task, 'on_complete', function(completed_task, status, task_result)
        if task_completion then return end
        local exit_code = type(completed_task) == 'table' and rawget(completed_task, 'exit_code') or nil
        if exit_code ~= nil and type(exit_code) ~= 'number' then
          terminal_error = terminal_error or TaskOperation.failure('invalid_task_result', 'Overseer returned an invalid task completion result.')
          exit_code = nil
        end
        local normalized_status = status_name(overseer, status)
        local problems
        local problems_truncated
        local problems_err
        local problems_present = false
        if normalized_status ~= 'cancelled' then
          if parser and type(task_result) == 'table' and task_result.diagnostics ~= nil then
            problems_present = true
            problems, problems_truncated = Problems.from_overseer(task_result.diagnostics, task_result.problems_truncated)
            if not problems then problems_err = problems_truncated end
          elseif type(task_result) == 'table' and task_result.problems ~= nil then
            problems_present = true
            problems, problems_truncated = Problem.normalize(task_result.problems, task_result.problems_truncated)
            if not problems then problems_err = problems_truncated end
          elseif parser then
            problems_present = true
            local parsed_ok, parsed = pcall(parser.finish, parser)
            if parsed_ok and type(parsed) == 'table' then
              problems, problems_truncated = Problem.normalize(parsed.problems or {}, parsed.problems_truncated)
              if not problems then problems_err = problems_truncated end
            else
              problems_err = parsed_ok and 'Gradle problem parser returned an invalid result.' or tostring(parsed)
            end
          end
          if problems_present and not problems and not problems_err then problems_err = 'Overseer returned invalid problem data.' end
        end
        if problems_err then
          terminal_error = terminal_error
            or TaskOperation.failure('invalid_task_result', 'Overseer returned invalid task problem data.', { error = problems_err })
        end
        task_completion = {
          status = normalized_status,
          code = exit_code,
          error = type(task_result) == 'table' and task_result.error or nil,
          problems = problems,
          problems_truncated = problems_truncated,
        }
        complete_when_released()
      end)
      if not subscribed or subscribe_result == false then
        operation:complete(TaskOperation.failure('task_subscribe_failed', 'Could not observe Overseer task completion.', {
          error = subscribed and 'subscription rejected' or tostring(subscribe_result),
        }))
        pcall(task.dispose, task, true)
        return handle
      end

      if task_completion then
        process_completion = process_completion or { code = task_completion.code, signal = 0 }
        complete_when_released()
        return handle
      end

      local started, start_result = pcall(task.start, task)
      if not started or start_result ~= true then
        operation:complete(TaskOperation.failure('task_start_failed', 'Could not start Overseer task.', { error = started and nil or tostring(start_result) }))
        pcall(task.dispose, task, true)
      end
      return handle
    end,
  }
end

return M

-- vim: ts=2 sts=2 sw=2 et
