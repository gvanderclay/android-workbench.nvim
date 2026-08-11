local MAX_ID_BYTES = 4096
local MAX_TASKS = 1024 * 1024

local M = {
  limits = {
    max_tasks = MAX_TASKS,
  },
}

local function gradle_path(value)
  return type(value) == 'string'
    and #value <= MAX_ID_BYTES
    and value:sub(1, 1) == ':'
    and not value:find('::', 1, true)
    and (#value == 1 or value:sub(-1) ~= ':')
    and not value:find '[%z\1-\31]'
end

local function task_name(value)
  return type(value) == 'string'
    and value ~= ''
    and not value:find '[%z\1-\31]'
    and not value:find '[/\\:<>"?*|]'
    and value:sub(1, 1) ~= '.'
    and value:sub(-1) ~= '.'
end

---@param build_path string
---@param project_path string
---@param name string
---@return string? id
function M.identity(build_path, project_path, name)
  if not gradle_path(build_path) or not gradle_path(project_path) or not task_name(name) then return nil end
  local segments = {}
  if build_path ~= ':' then segments[#segments + 1] = build_path:sub(2) end
  if project_path ~= ':' then segments[#segments + 1] = project_path:sub(2) end
  segments[#segments + 1] = name
  local id = ':' .. table.concat(segments, ':')
  return #id <= MAX_ID_BYTES and id or nil
end

---@param value table
---@return table? task
---@return string? error
function M.normalize(value)
  if type(value) ~= 'table' or getmetatable(value) ~= nil or vim.islist(value) then return nil, 'task must be a plain object' end
  local fields = { id = true, build_path = true, project_path = true, name = true }
  local count = 0
  for key, _ in next, value do
    if not fields[key] then return nil, 'task contains unsupported fields' end
    count = count + 1
  end
  if count ~= 4 then return nil, 'task is missing required fields' end
  local build_path = rawget(value, 'build_path')
  local project_path = rawget(value, 'project_path')
  local name = rawget(value, 'name')
  local id = M.identity(build_path, project_path, name)
  if not id then return nil, 'task identity is invalid' end
  if rawget(value, 'id') ~= id then return nil, 'task id does not match its Gradle identity' end
  return {
    id = id,
    build_path = build_path,
    project_path = project_path,
    name = name,
  }
end

---@param value table
---@return table[]? tasks
---@return string? error
function M.normalize_catalog(value)
  if type(value) ~= 'table' or getmetatable(value) ~= nil or not vim.islist(value) then return nil, 'tasks must be a plain array' end
  if #value > MAX_TASKS then return nil, 'task catalog exceeds the discovery limit' end
  local result, seen = {}, {}
  for _, candidate in ipairs(value) do
    local task, err = M.normalize(candidate)
    if not task then return nil, err end
    if seen[task.id] then return nil, 'task ids must be unique' end
    seen[task.id] = true
    result[#result + 1] = task
  end
  table.sort(result, function(left, right) return left.id < right.id end)
  return result
end

---@param task table
---@return string
function M.label(task) return task.id end

---@param snapshot table
---@param id string
---@return table? task
function M.find(snapshot, id)
  if type(snapshot) ~= 'table' or type(snapshot.tasks) ~= 'table' or type(id) ~= 'string' then return nil end
  for _, candidate in ipairs(snapshot.tasks) do
    local normalized = M.normalize(candidate)
    if normalized and normalized.id == id then return candidate end
  end
end

---@param items table[]
---@param candidate table
---@return table? task
function M.resolve(items, candidate)
  if type(items) ~= 'table' or not vim.islist(items) or type(candidate) ~= 'table' then return nil end
  local id = rawget(candidate, 'id')
  if type(id) ~= 'string' then return nil end
  for _, item in ipairs(items) do
    local normalized = M.normalize(item)
    if normalized and normalized.id == id then return item end
  end
end

---@param snapshot table
---@return table[] tasks
function M.sorted(snapshot)
  local result = type(snapshot) == 'table' and M.normalize_catalog(snapshot.tasks) or nil
  return result or {}
end

return M

-- vim: ts=2 sts=2 sw=2 et
