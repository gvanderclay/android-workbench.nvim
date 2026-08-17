local TaskOperation = require 'android_workbench.task_operation'
local TaskOutput = require 'android_workbench.task_output'

local M = {}

local DEFAULT_KILL_GRACE_MS = 1000
local native_instances = setmetatable({}, { __mode = 'k' })

---@class AndroidWorkbenchRunnerOutputEvent
---@field stream 'stdout'|'stderr'
---@field data string
---@field truncated? boolean

---@class AndroidWorkbenchRunnerRequest
---@field argv string[]
---@field cwd string
---@field env? table<string, string>
---@field name string
---@field metadata table
---@field on_output fun(event: AndroidWorkbenchRunnerOutputEvent)

---@class AndroidWorkbenchRunnerResult
---@field status 'success'|'failure'|'cancelled'
---@field code? integer
---@field signal? integer
---@field stdout? string
---@field stderr? string
---@field stdout_truncated? boolean
---@field stderr_truncated? boolean
---@field output_truncated? boolean
---@field error? string
---@field problems? AndroidWorkbenchProblem[]
---@field problems_truncated? boolean

---@class AndroidWorkbenchRunner
---@field start fun(request: AndroidWorkbenchRunnerRequest, callback: fun(error: AndroidWorkbenchError?, result: AndroidWorkbenchRunnerResult?)): AndroidWorkbenchOperationHandle?
---@field has_output? fun(root: string): boolean
---@field show_output? fun(root: string): boolean

local function close_timer(timer)
  if not timer then return end
  pcall(timer.stop, timer)
  local ok, closing = pcall(timer.is_closing, timer)
  if not ok or not closing then pcall(timer.close, timer) end
end

---@param opts? { system?: function, schedule?: fun(callback: function), defer_fn?: function, max_capture_bytes?: integer, max_output_bytes?: integer, max_output_lines?: integer, height?: integer, kill_grace_ms?: integer }
---@return AndroidWorkbenchRunner
function M.new(opts)
  opts = opts or {}
  if type(opts) ~= 'table' then error('android_workbench.runner.new: options must be a table', 2) end
  local system = opts.system or vim.system
  local operation_opts = {
    schedule = opts.schedule,
    max_capture_bytes = opts.max_capture_bytes,
  }
  local defer_fn = opts.defer_fn or vim.defer_fn
  local kill_grace_ms = opts.kill_grace_ms or DEFAULT_KILL_GRACE_MS
  if operation_opts.max_capture_bytes ~= nil and not TaskOperation.valid_limit(operation_opts.max_capture_bytes) then
    error('android_workbench.runner.new: max_capture_bytes must be a positive integer', 2)
  end
  if opts.max_output_bytes ~= nil and not TaskOperation.valid_limit(opts.max_output_bytes) then
    error('android_workbench.runner.new: max_output_bytes must be a positive integer', 2)
  end
  if opts.max_output_lines ~= nil and not TaskOperation.valid_limit(opts.max_output_lines) then
    error('android_workbench.runner.new: max_output_lines must be a positive integer', 2)
  end
  if opts.height ~= nil and not TaskOperation.valid_limit(opts.height) then error('android_workbench.runner.new: height must be a positive integer', 2) end
  if not TaskOperation.valid_limit(kill_grace_ms) then error('android_workbench.runner.new: kill_grace_ms must be a positive integer', 2) end
  local output = TaskOutput.new {
    max_bytes = opts.max_output_bytes,
    max_lines = opts.max_output_lines,
    height = opts.height,
  }

  local runner = {
    start = function(request, callback)
      assert(type(callback) == 'function', 'android_workbench.runner: callback is required')
      local view
      local operation = TaskOperation.new(request, function(err, result)
        if view then pcall(view.finish, err, result) end
        callback(err, result)
      end, operation_opts)
      local process
      local terminal_error
      local cancel_requested = false
      local exited = false
      local completed_fields
      local term_sent = false
      local kill_timer

      local function send_term()
        if term_sent or exited then return true end
        if not process then return true end
        local called, sent = pcall(process.kill, process, 15)
        if not called or sent == false then return false end
        term_sent = true
        return true
      end

      local function begin_termination()
        if not send_term() then return false end
        if exited or kill_timer then return true end
        kill_timer = defer_fn(function()
          kill_timer = nil
          if not exited and process then pcall(process.kill, process, 9) end
        end, kill_grace_ms)
        return true
      end

      local handle = {}
      function handle.cancel()
        if cancel_requested then return false end
        if operation:is_done() then
          if not completed_fields or completed_fields.status ~= 'success' then return false end
          return operation:replace_pending_terminal(nil, {
            status = 'cancelled',
            code = completed_fields.code,
            signal = completed_fields.signal,
          })
        end
        cancel_requested = true
        local accepted = begin_termination()
        if operation:is_done() then return true end
        if not accepted then
          cancel_requested = false
          return false
        end
        return true
      end

      if operation:is_done() then return handle end

      local presented, created = pcall(output.start, operation.request)
      if presented then view = created end
      if view then
        local downstream_output = operation.request.on_output
        operation.request.on_output = function(event)
          pcall(view.append, event)
          if downstream_output then pcall(downstream_output, event) end
        end
      end

      local function consume(stream, err, data)
        if operation:is_done() or cancel_requested or terminal_error then return end
        if err then
          terminal_error = TaskOperation.failure('stream_error', ('Failed reading task %s.'):format(stream), { error = tostring(err) })
          begin_termination()
          return
        end
        if data ~= nil and type(data) ~= 'string' then
          terminal_error = TaskOperation.failure('invalid_process_output', ('Task %s returned invalid output.'):format(stream))
          begin_termination()
          return
        end
        operation:output(stream, data)
      end

      local ok, spawned = pcall(system, operation.request.argv, {
        cwd = operation.request.cwd,
        env = operation.request.env,
        text = true,
        stdout = function(err, data) consume('stdout', err, data) end,
        stderr = function(err, data) consume('stderr', err, data) end,
      }, function(completed)
        exited = true
        close_timer(kill_timer)
        kill_timer = nil
        if operation:is_done() then return end
        if type(completed) ~= 'table' or type(completed.code) ~= 'number' or (completed.signal ~= nil and type(completed.signal) ~= 'number') then
          operation:complete(TaskOperation.failure('invalid_process_result', 'Task process returned an invalid completion result.'))
          return
        end
        if terminal_error then
          operation:complete(terminal_error)
          return
        end
        local code = completed.code
        local signal = completed.signal
        if cancel_requested then
          operation:complete(nil, {
            status = 'cancelled',
            code = code,
            signal = signal,
          })
          return
        end
        local succeeded = code == 0 and (signal == nil or signal == 0)
        completed_fields = {
          status = succeeded and 'success' or 'failure',
          code = code,
          signal = signal,
        }
        operation:complete(nil, completed_fields)
      end)

      if not ok or type(spawned) ~= 'table' or type(spawned.kill) ~= 'function' then
        close_timer(kill_timer)
        kill_timer = nil
        operation:complete(terminal_error or TaskOperation.failure('spawn_failed', 'Could not start task process.', { error = tostring(spawned) }))
        return handle
      end
      process = spawned
      if terminal_error or cancel_requested then begin_termination() end
      return handle
    end,
  }
  function runner.show_output(root) return output.show(root) end
  function runner.has_output(root) return output.has_output(root) end
  function runner._close_output() return output.close() end
  native_instances[runner] = true
  return runner
end

function M._is_native(runner) return native_instances[runner] == true end

return M

-- vim: ts=2 sts=2 sw=2 et
