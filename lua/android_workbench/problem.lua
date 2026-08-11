local M = {}

local LIMITS = {
  items = 1000,
  message_bytes = 4096,
  name_bytes = 512,
  path_bytes = 8192,
  integer = 2147483647,
}

M.limits = vim.deepcopy(LIMITS)

local severities = {
  error = true,
  warning = true,
  info = true,
}

local function failure(code, message, details)
  local value = { code = code, message = message }
  if details then value.details = details end
  return value
end

local function valid_integer(value) return type(value) == 'number' and value % 1 == 0 and value >= 1 and value <= LIMITS.integer end

local function normalize_path(path)
  if type(path) ~= 'string' or path == '' or #path > LIMITS.path_bytes then return nil, 'problem path must be a bounded absolute path' end
  if path:sub(1, 1) ~= '/' or path:find('\0', 1, true) or path:find('\r', 1, true) or path:find('\n', 1, true) then
    return nil, 'problem path must be a bounded absolute path'
  end
  local normalized = vim.fs.normalize(path)
  if type(normalized) ~= 'string' or normalized:sub(1, 1) ~= '/' then return nil, 'problem path must be a bounded absolute path' end
  return normalized
end

local function normalize_root(root)
  local normalized, err = normalize_path(root)
  if not normalized then return nil, err end
  return normalized
end

local function normalize_message(message)
  if type(message) ~= 'string' or message == '' or message:find('\0', 1, true) then return nil, false, 'problem message must be a non-empty string' end
  message = message:gsub('[\r\n]+', ' ')
  if message == '' then return nil, false, 'problem message must be a non-empty string' end
  if #message <= LIMITS.message_bytes then return message, false end
  return message:sub(1, LIMITS.message_bytes), true
end

local function normalize_item(item)
  if type(item) ~= 'table' then return nil, false, 'problem item must be a table' end

  local path, path_err = normalize_path(item.path)
  if not path then return nil, false, path_err end
  if not valid_integer(item.line) then return nil, false, 'problem line must be a positive integer' end
  if item.column ~= nil and not valid_integer(item.column) then return nil, false, 'problem column must be a positive integer' end
  if item.end_line ~= nil and not valid_integer(item.end_line) then return nil, false, 'problem end_line must be a positive integer' end
  if item.end_column ~= nil and not valid_integer(item.end_column) then return nil, false, 'problem end_column must be a positive integer' end
  if item.end_line and item.end_line < item.line then return nil, false, 'problem range must not end before it starts' end
  if item.end_line == item.line and item.column and item.end_column and item.end_column < item.column then
    return nil, false, 'problem range must not end before it starts'
  end
  if not severities[item.severity] then return nil, false, 'problem severity must be error, warning, or info' end

  local message, message_truncated, message_err = normalize_message(item.message)
  if not message then return nil, false, message_err end

  local normalized = {
    path = path,
    line = item.line,
    message = message,
    severity = item.severity,
  }
  if item.column then normalized.column = item.column end
  if item.end_line then normalized.end_line = item.end_line end
  if item.end_column then normalized.end_column = item.end_column end
  return normalized, message_truncated
end

local function item_key(item)
  return table.concat({
    item.path,
    tostring(item.line),
    tostring(item.column or ''),
    tostring(item.end_line or ''),
    tostring(item.end_column or ''),
    item.severity,
    item.message,
  }, '\0')
end

---@param items table[]
---@param truncated? boolean
---@return table[]?, boolean|string
function M.normalize(items, truncated)
  if type(items) ~= 'table' or not vim.islist(items) then return nil, 'problems must be an array' end
  if truncated ~= nil and type(truncated) ~= 'boolean' then return nil, 'problems_truncated must be a boolean' end

  local normalized = {}
  local seen = {}
  local was_truncated = truncated == true or #items > LIMITS.items
  for index = 1, math.min(#items, LIMITS.items) do
    local item, item_truncated, item_err = normalize_item(items[index])
    if not item then return nil, ('problem %d: %s'):format(index, item_err) end
    local key = item_key(item)
    if not seen[key] then
      seen[key] = true
      normalized[#normalized + 1] = item
    end
    was_truncated = was_truncated or item_truncated
  end
  return normalized, was_truncated
end

---@param batch table
---@return table?, table?
function M.normalize_batch(batch)
  if type(batch) ~= 'table' then return nil, failure('invalid_problem_batch', 'Android problem batch must be a table.') end

  local root = normalize_root(batch.root)
  if not root then return nil, failure('invalid_problem_batch', 'Android problem batch root must be a bounded absolute path.') end
  if batch.kind ~= 'build' and batch.kind ~= 'run' and batch.kind ~= 'gradle_task' then
    return nil, failure('invalid_problem_batch', 'Android problem batch kind must be build, run, or gradle_task.')
  end
  if
    type(batch.name) ~= 'string'
    or batch.name == ''
    or #batch.name > LIMITS.name_bytes
    or batch.name:find('\0', 1, true)
    or batch.name:find('\r', 1, true)
    or batch.name:find('\n', 1, true)
  then
    return nil, failure('invalid_problem_batch', 'Android problem batch name must be a bounded single-line string.')
  end
  if batch.status ~= 'success' and batch.status ~= 'failure' then
    return nil, failure('invalid_problem_batch', 'Android problem batch status must be success or failure.')
  end
  if type(batch.truncated) ~= 'boolean' then return nil, failure('invalid_problem_batch', 'Android problem batch truncated flag must be a boolean.') end

  local items, truncated_or_error = M.normalize(batch.items, batch.truncated)
  if not items then return nil, failure('invalid_problem_batch', 'Android problem batch contains invalid items.', { error = truncated_or_error }) end
  return {
    root = root,
    kind = batch.kind,
    name = batch.name,
    status = batch.status,
    items = items,
    truncated = truncated_or_error,
  }
end

return M

-- vim: ts=2 sts=2 sw=2 et
