local Problem = require 'android_workbench.problem'

local M = {}

local DEFAULT_MAX_CAPTURE_BYTES = 4 * 1024 * 1024
local DEFAULT_MAX_PENDING_EVENTS = 1024
local DEFAULT_MAX_DRAIN_BYTES = 64 * 1024
local DEFAULT_MAX_DRAIN_EVENTS = 256

local function failure(code, message, details)
  return {
    code = code,
    message = message,
    details = details,
  }
end

local function positive_integer(value) return type(value) == 'number' and value > 0 and value <= 2147483647 and value % 1 == 0 end

local function normalize_request(request)
  if type(request) ~= 'table' then return nil, failure('invalid_request', 'Runner request must be a table.') end
  if type(request.argv) ~= 'table' or not vim.islist(request.argv) or #request.argv == 0 then
    return nil, failure('invalid_request', 'Runner request argv must be a non-empty array.')
  end

  local argv = {}
  for index, value in ipairs(request.argv) do
    if type(value) ~= 'string' or value == '' or value:find('\0', 1, true) then
      return nil, failure('invalid_request', ('Runner request argv[%d] must be a non-empty string without NUL bytes.'):format(index))
    end
    argv[index] = value
  end

  if type(request.cwd) ~= 'string' or request.cwd == '' then return nil, failure('invalid_request', 'Runner request cwd must be a non-empty path.') end
  if request.name ~= nil and (type(request.name) ~= 'string' or request.name == '') then
    return nil, failure('invalid_request', 'Runner request name must be a non-empty string when provided.')
  end
  if request.metadata ~= nil and type(request.metadata) ~= 'table' then
    return nil, failure('invalid_request', 'Runner request metadata must be a table when provided.')
  end
  if request.on_output ~= nil and type(request.on_output) ~= 'function' then
    return nil, failure('invalid_request', 'Runner request on_output must be a function when provided.')
  end

  local env
  if request.env ~= nil then
    if type(request.env) ~= 'table' then return nil, failure('invalid_request', 'Runner request env must be a string map when provided.') end
    env = {}
    for key, value in pairs(request.env) do
      if type(key) ~= 'string' or key == '' or type(value) ~= 'string' then
        return nil, failure('invalid_request', 'Runner request env must contain only non-empty string keys and string values.')
      end
      env[key] = value
    end
  end

  return {
    argv = argv,
    cwd = request.cwd,
    env = env,
    name = request.name or table.concat(argv, ' '),
    metadata = request.metadata or {},
    on_output = request.on_output,
  }
end

local function new_capture(limit)
  local capture = {
    chunks = {},
    bytes = 0,
    first = 1,
    last = 0,
    limit = limit,
    truncated = false,
  }

  function capture:append(data)
    if data == '' then return end
    local size = #data
    if size >= self.limit then
      local had_data = self.bytes > 0
      self.chunks = { data:sub(size - self.limit + 1) }
      self.bytes = self.limit
      self.first = 1
      self.last = 1
      self.truncated = self.truncated or had_data or size > self.limit
      return
    end

    self.last = self.last + 1
    self.chunks[self.last] = data
    self.bytes = self.bytes + size
    while self.bytes > self.limit do
      local overflow = self.bytes - self.limit
      local first = self.chunks[self.first]
      if #first <= overflow then
        self.chunks[self.first] = nil
        self.first = self.first + 1
        self.bytes = self.bytes - #first
      else
        self.chunks[self.first] = first:sub(overflow + 1)
        self.bytes = self.limit
      end
      self.truncated = true
    end
  end

  function capture:value() return table.concat(self.chunks, '', self.first, self.last) end

  return capture
end

local function pending_count(pending)
  if pending.last < pending.first then return 0 end
  return pending.last - pending.first + 1
end

local function reset_pending(pending)
  pending.items = {}
  pending.bytes = 0
  pending.first = 1
  pending.last = 0
end

local function remove_first(pending)
  local item = pending.items[pending.first]
  if not item then return false end
  pending.bytes = pending.bytes - (#item.data - item.offset + 1)
  pending.items[pending.first] = nil
  pending.first = pending.first + 1
  if pending.first > pending.last then reset_pending(pending) end
  return true
end

local function mark_output_truncated(operation)
  operation.output_truncated = true
  operation.truncation_pending = true
end

local function trim_pending(operation)
  local pending = operation.pending
  local truncated = false

  while pending_count(pending) > operation.max_pending_events do
    remove_first(pending)
    truncated = true
  end

  local overflow = pending.bytes - operation.max_pending_output_bytes
  while overflow > 0 do
    local item = pending.items[pending.first]
    if not item then break end
    local available = #item.data - item.offset + 1
    if available <= overflow then
      overflow = overflow - available
      remove_first(pending)
    else
      item.offset = item.offset + overflow
      pending.bytes = pending.bytes - overflow
      overflow = 0
    end
    truncated = true
  end

  if truncated then mark_output_truncated(operation) end
end

local function append_pending(operation, stream, data)
  local pending = operation.pending
  if #data > operation.max_pending_output_bytes then
    reset_pending(pending)
    data = data:sub(#data - operation.max_pending_output_bytes + 1)
    mark_output_truncated(operation)
  end

  pending.last = pending.last + 1
  pending.items[pending.last] = {
    stream = stream,
    data = data,
    offset = 1,
  }
  pending.bytes = pending.bytes + #data
  trim_pending(operation)
end

local function take_pending(operation, max_bytes)
  local pending = operation.pending
  local item = pending.items[pending.first]
  if not item then return nil end

  local available = #item.data - item.offset + 1
  local size = math.min(available, max_bytes)
  local data
  if item.offset == 1 and size == #item.data then
    data = item.data
  else
    data = item.data:sub(item.offset, item.offset + size - 1)
  end

  item.offset = item.offset + size
  pending.bytes = pending.bytes - size
  if item.offset > #item.data then
    pending.items[pending.first] = nil
    pending.first = pending.first + 1
    if pending.first > pending.last then reset_pending(pending) end
  end
  return item.stream, data
end

---@param request table
---@param callback fun(err: table?, result: table?)
---@param opts? { schedule?: fun(callback: function), max_capture_bytes?: integer, max_pending_output_bytes?: integer, max_pending_events?: integer, max_drain_bytes?: integer, max_drain_events?: integer }
---@return table operation
function M.new(request, callback, opts)
  assert(type(callback) == 'function', 'android_workbench.runner: callback is required')
  opts = opts or {}
  local schedule = opts.schedule or vim.schedule
  local capture_limit = opts.max_capture_bytes or DEFAULT_MAX_CAPTURE_BYTES
  local pending_limit = opts.max_pending_output_bytes or capture_limit
  local max_pending_events = opts.max_pending_events or DEFAULT_MAX_PENDING_EVENTS
  local max_drain_bytes = opts.max_drain_bytes or math.min(pending_limit, DEFAULT_MAX_DRAIN_BYTES)
  local max_drain_events = opts.max_drain_events or DEFAULT_MAX_DRAIN_EVENTS
  assert(positive_integer(capture_limit), 'android_workbench.task_operation: max_capture_bytes must be a positive integer')
  assert(positive_integer(pending_limit), 'android_workbench.task_operation: max_pending_output_bytes must be a positive integer')
  assert(positive_integer(max_pending_events), 'android_workbench.task_operation: max_pending_events must be a positive integer')
  assert(positive_integer(max_drain_bytes), 'android_workbench.task_operation: max_drain_bytes must be a positive integer')
  assert(positive_integer(max_drain_events), 'android_workbench.task_operation: max_drain_events must be a positive integer')

  local normalized, request_err = normalize_request(request)
  local operation = {
    request = normalized,
    done = false,
    stdout = new_capture(capture_limit),
    stderr = new_capture(capture_limit),
    pending = { items = {}, bytes = 0, first = 1, last = 0 },
    max_pending_output_bytes = pending_limit,
    max_pending_events = max_pending_events,
    max_drain_bytes = max_drain_bytes,
    max_drain_events = max_drain_events,
    drain_scheduled = false,
    output_truncated = false,
    truncation_pending = false,
    terminal = nil,
    terminal_scheduled = false,
    terminal_delivered = false,
  }

  local function deliver_terminal()
    if operation.terminal_delivered or not operation.terminal then return end
    operation.terminal_delivered = true
    local terminal = operation.terminal
    callback(terminal.err, terminal.result)
  end

  local function schedule_terminal()
    if operation.terminal_scheduled or operation.terminal_delivered or not operation.terminal then return end
    operation.terminal_scheduled = true
    schedule(deliver_terminal)
  end

  local drain
  drain = function()
    local deliveries = {}
    local remaining_bytes = operation.max_drain_bytes
    local remaining_events = operation.max_drain_events
    while remaining_bytes > 0 and remaining_events > 0 and pending_count(operation.pending) > 0 do
      local stream, data = take_pending(operation, remaining_bytes)
      if not data then break end
      local delivery = deliveries[#deliveries]
      if not delivery or delivery.stream ~= stream then
        delivery = { stream = stream, chunks = {} }
        deliveries[#deliveries + 1] = delivery
      end
      delivery.chunks[#delivery.chunks + 1] = data
      remaining_bytes = remaining_bytes - #data
      remaining_events = remaining_events - 1
    end

    if operation.truncation_pending and deliveries[1] then
      deliveries[1].truncated = true
      operation.truncation_pending = false
    end

    local output_callback = operation.request and operation.request.on_output
    if output_callback then
      for _, delivery in ipairs(deliveries) do
        local event = {
          stream = delivery.stream,
          data = table.concat(delivery.chunks),
        }
        if delivery.truncated then event.truncated = true end
        pcall(output_callback, event)
      end
    end

    if pending_count(operation.pending) > 0 then
      schedule(drain)
      return
    end

    operation.drain_scheduled = false
    if operation.terminal then deliver_terminal() end
  end

  local function schedule_drain()
    if operation.drain_scheduled then return end
    operation.drain_scheduled = true
    schedule(drain)
  end

  function operation:is_done() return self.done end

  function operation:pending_output()
    return {
      bytes = self.pending.bytes,
      events = pending_count(self.pending),
      scheduled = self.drain_scheduled,
      truncated = self.output_truncated,
    }
  end

  function operation:output(stream, data)
    if self.done or data == nil or data == '' then return false end
    local capture = stream == 'stdout' and self.stdout or self.stderr
    capture:append(data)
    if self.request.on_output then
      append_pending(self, stream, data)
      schedule_drain()
    end
    return true
  end

  local function terminal_result(err, fields)
    if err then return nil end
    fields = fields or {}
    local result = {
      status = fields.status,
      code = fields.code,
      signal = fields.signal,
      stdout = operation.stdout:value(),
      stderr = operation.stderr:value(),
      stdout_truncated = operation.stdout.truncated,
      stderr_truncated = operation.stderr.truncated,
      output_truncated = operation.output_truncated,
      name = operation.request.name,
      metadata = operation.request.metadata,
    }
    if fields.error ~= nil then result.error = tostring(fields.error) end
    if fields.problems ~= nil or fields.problems_truncated ~= nil then
      local problems, problems_truncated = Problem.normalize(fields.problems == nil and {} or fields.problems, fields.problems_truncated)
      if not problems then return nil, failure('invalid_task_result', 'Task returned invalid problem data.', { error = problems_truncated }) end
      result.problems = problems
      result.problems_truncated = problems_truncated
    end
    return result
  end

  function operation:complete(err, fields)
    if self.done then return false end
    self.done = true

    local result, result_err = terminal_result(err, fields)
    self.terminal = { err = err or result_err, result = result }
    if not self.drain_scheduled then schedule_terminal() end
    return true
  end

  function operation:replace_pending_terminal(err, fields)
    if not self.done or self.terminal_delivered or not self.terminal then return false end
    local result, result_err = terminal_result(err, fields)
    self.terminal = { err = err or result_err, result = result }
    return true
  end

  if request_err then
    operation.done = true
    operation.terminal = { err = request_err }
    schedule_terminal()
  end

  return operation
end

function M.failure(code, message, details) return failure(code, message, details) end

function M.valid_limit(value) return positive_integer(value) end

return M

-- vim: ts=2 sts=2 sw=2 et
