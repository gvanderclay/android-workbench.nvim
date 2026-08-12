local M = {}

local LEVELS = {
  verbose = { priority = 'V', rank = 1 },
  debug = { priority = 'D', rank = 2 },
  info = { priority = 'I', rank = 3 },
  warn = { priority = 'W', rank = 4 },
  error = { priority = 'E', rank = 5 },
  assert = { priority = 'A', rank = 6 },
}

local NAMES_BY_PRIORITY = {
  V = 'verbose',
  D = 'debug',
  I = 'info',
  W = 'warn',
  E = 'error',
  F = 'assert',
  A = 'assert',
}

local function contains(haystack, needle) return haystack:lower():find(needle:lower(), 1, true) ~= nil end

---@return string[]
function M.levels() return { 'verbose', 'debug', 'info', 'warn', 'error', 'assert' } end

---@param value any
---@return string? level
function M.normalize_level(value)
  if type(value) ~= 'string' then return nil end
  local normalized = value:lower()
  if normalized == 'warning' then normalized = 'warn' end
  if normalized == 'fatal' then normalized = 'assert' end
  return LEVELS[normalized] and normalized or nil
end

---@param line string
---@param previous? table
---@return table
function M.parse_line(line, previous)
  local date, time, uid, remainder = line:match '^(%d%d%d%d%-%d%d%-%d%d)%s+(%d%d:%d%d:%d%d%.%d+)%s+(%S+)%s+(.+)$'
  local pid, tid, priority, tag, message
  if remainder then
    pid, tid, priority, tag, message = remainder:match '^(%d+)%s+(%d+)%s+([VDIWEFA])%s+([^:]-)%s*:%s?(.*)$'
  end
  if priority then
    local level = NAMES_BY_PRIORITY[priority]
    return {
      raw = date .. ' ' .. time .. ' ' .. remainder,
      timestamp = date .. ' ' .. time,
      uid = tonumber(uid),
      pid = tonumber(pid),
      tid = tonumber(tid),
      priority = priority,
      level = level,
      rank = LEVELS[level].rank,
      tag = vim.trim(tag),
      message = message,
    }
  end

  date, time, pid, tid, priority, tag, message =
    line:match '^(%d%d%d%d%-%d%d%-%d%d)%s+(%d%d:%d%d:%d%d%.%d+)%s+(%d+)%s+(%d+)%s+([VDIWEFA])%s+([^:]-)%s*:%s?(.*)$'
  if priority then
    local level = NAMES_BY_PRIORITY[priority]
    return {
      raw = line,
      timestamp = date .. ' ' .. time,
      pid = tonumber(pid),
      tid = tonumber(tid),
      priority = priority,
      level = level,
      rank = LEVELS[level].rank,
      tag = vim.trim(tag),
      message = message,
    }
  end

  local divider = line:match '^%-%-%-%-%-%-%-%-%- beginning of '
  if previous and not divider then
    return {
      raw = line,
      timestamp = previous.timestamp,
      uid = previous.uid,
      application_id = previous.application_id,
      pid = previous.pid,
      tid = previous.tid,
      priority = previous.priority,
      level = previous.level,
      rank = previous.rank,
      tag = previous.tag,
      message = line,
      continuation = true,
    }
  end

  return {
    raw = line,
    message = line,
    divider = divider ~= nil,
  }
end

---@param record table
---@param filters? { level?: string, tag?: string, text?: string }
---@return boolean
function M.matches(record, filters)
  filters = filters or {}
  local level = M.normalize_level(filters.level or 'verbose') or 'verbose'
  if record.rank and record.rank < LEVELS[level].rank then return false end
  if filters.tag and filters.tag ~= '' then
    if not record.tag or not contains(record.tag, filters.tag) then return false end
  end
  if filters.text and filters.text ~= '' then
    if not contains(record.raw or record.message or '', filters.text) then return false end
  end
  return true
end

---@param value string|table
---@return table? frame
function M.parse_frame(value)
  local line = type(value) == 'table' and (value.message or value.raw) or value
  if type(line) ~= 'string' then return nil end

  local class_name, method_name, file_name, line_number = line:match 'at%s+([%w_.$]+)%.([%w_$<>%-]+)%(([^():]+):(%d+)%)'
  if not class_name then return nil end
  return {
    raw = line,
    class_name = class_name,
    method_name = method_name,
    file_name = file_name,
    line = tonumber(line_number),
  }
end

local function path_prefix(path, prefix) return path == prefix or path:sub(1, #prefix + 1) == prefix .. '/' end

---@param path string
---@param frame table
---@param context { project_dir?: string, variant?: string }
---@return integer
function M.source_rank(path, frame, context)
  path = vim.fs.normalize(path)
  context = context or {}
  local project_dir = context.project_dir and vim.fs.normalize(context.project_dir) or nil
  local package_name = frame.class_name:match '^(.*)%.[^.]+$'
  local expected_suffix = package_name and (package_name:gsub('%.', '/') .. '/' .. frame.file_name) or frame.file_name
  local exact_package = path:sub(-#expected_suffix) == expected_suffix
  local in_project = project_dir and path_prefix(path, project_dir) or false
  local in_variant = in_project and context.variant and path:find('/src/' .. context.variant .. '/', 1, true) ~= nil

  if exact_package and in_variant then return 1 end
  if exact_package and in_project then return 2 end
  if exact_package then return 3 end
  if in_project then return 4 end
  return 5
end

---@param paths string[]
---@param frame table
---@param context { project_dir?: string, variant?: string }
---@return string[]
function M.best_sources(paths, frame, context)
  local best_rank
  local best = {}
  for _, path in ipairs(paths) do
    if vim.fs.basename(path) == frame.file_name then
      local rank = M.source_rank(path, frame, context)
      if best_rank == nil or rank < best_rank then
        best_rank = rank
        best = { path }
      elseif rank == best_rank then
        best[#best + 1] = path
      end
    end
  end
  table.sort(best)
  return best
end

return M

-- vim: ts=2 sts=2 sw=2 et
