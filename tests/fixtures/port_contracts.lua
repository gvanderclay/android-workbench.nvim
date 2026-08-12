local M = {}

local function contract(required, optional)
  local allowed = {}
  for _, field in ipairs(required) do
    allowed[field] = true
  end
  for _, field in ipairs(optional or {}) do
    allowed[field] = true
  end
  return { required = required, allowed = allowed }
end

M.picker_request = contract({ 'prompt', 'items', 'format_item' }, { 'current' })
M.runner_request = contract({ 'argv', 'cwd', 'name', 'metadata', 'on_output' }, { 'env' })
M.runner_output = contract({ 'stream', 'data' }, { 'truncated' })
M.runner_result = contract({ 'status' }, {
  'code',
  'signal',
  'stdout',
  'stderr',
  'stdout_truncated',
  'stderr_truncated',
  'output_truncated',
  'error',
  'name',
  'metadata',
  'problems',
  'problems_truncated',
})
M.task_terminal = contract({ 'status', 'name', 'metadata', 'problems', 'problems_truncated' }, {
  'code',
  'signal',
  'stdout',
  'stderr',
  'stdout_truncated',
  'stderr_truncated',
  'output_truncated',
  'error',
})
M.problem_batch = contract { 'root', 'kind', 'name', 'status', 'items', 'truncated' }
M.problem_item = contract({ 'path', 'line', 'message', 'severity' }, { 'column', 'end_line', 'end_column' })
M.adb_methods = { 'list_devices', 'validate_serial', 'resolve_launch_components', 'launch', 'stop' }
M.adb_device = contract({ 'serial', 'state' }, { 'raw_state', 'label', 'details', 'avd_name' })
M.adb_component = contract({ 'component', 'package' }, { 'activity' })
M.adb_launch = contract({ 'serial', 'application_id', 'component', 'status' }, {
  'activity',
  'launch_state',
  'total_time_ms',
  'wait_time_ms',
})
M.adb_stop = contract { 'serial', 'application_id' }

function M.check(value, expected)
  if type(value) ~= 'table' then return nil, 'value must be a table' end
  for _, field in ipairs(expected.required) do
    if rawget(value, field) == nil then return nil, ('missing required field %s'):format(field) end
  end
  for field in pairs(value) do
    if not expected.allowed[field] then return nil, ('unsupported field %s'):format(tostring(field)) end
  end
  return true
end

function M.check_methods(value, expected)
  if type(value) ~= 'table' then return nil, 'port must be a table' end
  for _, method in ipairs(expected) do
    if type(rawget(value, method)) ~= 'function' and type(value[method]) ~= 'function' then return nil, ('missing required method %s'):format(method) end
  end
  return true
end

return M

-- vim: ts=2 sts=2 sw=2 et
