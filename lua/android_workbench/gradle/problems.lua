local Problem = require 'android_workbench.problem'

local M = {}

local LIMITS = {
  items = 1000,
  line_bytes = 16384,
  message_bytes = Problem.limits.message_bytes,
}

local severity_types = {
  error = 'E',
  warning = 'W',
  info = 'I',
}

local overseer_severities = {
  E = 'error',
  W = 'warning',
  I = 'info',
  N = 'info',
  error = 'error',
  warning = 'warning',
  info = 'info',
  hint = 'info',
}

---@param diagnostics? table[]
---@param truncated? boolean
---@return table[]?, boolean|string
function M.from_overseer(diagnostics, truncated)
  diagnostics = diagnostics or {}
  if type(diagnostics) ~= 'table' or not vim.islist(diagnostics) then return nil, 'Overseer diagnostics must be an array' end
  if truncated ~= nil and type(truncated) ~= 'boolean' then return nil, 'Overseer problems_truncated must be a boolean' end

  local items = {}
  local was_truncated = truncated == true or #diagnostics > LIMITS.items
  for index = 1, math.min(#diagnostics, LIMITS.items) do
    local diagnostic = diagnostics[index]
    if type(diagnostic) ~= 'table' then return nil, ('Overseer diagnostic %d must be a table'):format(index) end
    local severity = overseer_severities[diagnostic.type or diagnostic.severity]
    if not severity then return nil, ('Overseer diagnostic %d has an invalid severity'):format(index) end
    items[#items + 1] = {
      path = diagnostic.filename,
      line = diagnostic.lnum,
      column = diagnostic.col,
      end_line = diagnostic.end_lnum,
      end_column = diagnostic.end_col,
      message = diagnostic.text,
      severity = severity,
    }
  end
  return Problem.normalize(items, was_truncated)
end

local function decode_file_uri(uri)
  local decoded, value = pcall(vim.uri_to_fname, uri)
  if not decoded or type(value) ~= 'string' then return nil end
  return value
end

local function point(path, line, column, message)
  return {
    path = path,
    line = tonumber(line),
    column = column and tonumber(column) or nil,
    message = message,
    severity = 'error',
  }
end

local function ranged(path, line, column, end_line, end_column, message)
  local item = point(path, line, column, message)
  item.end_line = tonumber(end_line)
  item.end_column = tonumber(end_column)
  return item
end

local function parse_line(line)
  local uri, line_number, column, message = line:match '^e:%s+(file:///.+):(%d+):(%d+)%s+(.+)$'
  if uri then
    local path = decode_file_uri(uri)
    if path then return point(path, line_number, column, message) end
    return nil
  end

  local path, end_line, end_column
  path, line_number, column, end_line, end_column, message = line:match '^ERROR:%s+(/.+):(%d+):(%d+)%-(%d+):(%d+):%s*(.+)$'
  if path then return ranged(path, line_number, column, end_line, end_column, message) end

  path, line_number, column, end_column, message = line:match '^ERROR:%s+(/.+):(%d+):(%d+)%-(%d+):%s*(.+)$'
  if path then return ranged(path, line_number, column, line_number, end_column, message) end

  path, line_number, column, message = line:match '^ERROR:%s+(/.+):(%d+):(%d+):%s*(.+)$'
  if path then return point(path, line_number, column, message) end

  path, line_number, message = line:match '^ERROR:%s+(/.+):(%d+):%s*(.+)$'
  if path then return point(path, line_number, nil, message) end

  path, line_number, column, end_line, end_column, message = line:match '^(/.+):(%d+):(%d+)%-(%d+):(%d+):%s*[Ee]rror:%s*(.+)$'
  if path then return ranged(path, line_number, column, end_line, end_column, message) end

  path, line_number, column, end_column, message = line:match '^(/.+):(%d+):(%d+)%-(%d+):%s*[Ee]rror:%s*(.+)$'
  if path then return ranged(path, line_number, column, line_number, end_column, message) end

  path, line_number, column, message = line:match '^(/.+):(%d+):(%d+):%s*[Ee]rror:%s*(.+)$'
  if path then return point(path, line_number, column, message) end

  path, line_number, message = line:match '^(/.+):(%d+):%s*[Ee]rror:%s*(.+)$'
  if path then return point(path, line_number, nil, message) end
end

local Collector = {}
Collector.__index = Collector

function Collector:_mark_truncated()
  if self.truncated then return end
  self.truncated = true
  self.result_version = self.result_version + 1
end

function Collector:_add(item)
  local normalized_items, item_truncated = Problem.normalize({ item }, false)
  if not normalized_items then return end
  local normalized = normalized_items[1]
  if #normalized.message > self.max_message_bytes then
    normalized.message = normalized.message:sub(1, self.max_message_bytes)
    item_truncated = true
  end
  local key = table.concat({
    normalized.path,
    tostring(normalized.line),
    tostring(normalized.column or ''),
    tostring(normalized.end_line or ''),
    tostring(normalized.end_column or ''),
    normalized.severity,
    normalized.message,
  }, '\0')
  if self.seen[key] then return end
  if #self.items >= self.max_items then
    self:_mark_truncated()
    return
  end
  self.seen[key] = true
  self.items[#self.items + 1] = normalized
  self.result_version = self.result_version + 1
  if item_truncated then self:_mark_truncated() end
end

function Collector:parse(line)
  if self.finished then return nil, 'problem collector is already finished' end
  if type(line) ~= 'string' then return nil, 'problem line must be a string' end
  if #line > self.max_line_bytes then
    self:_mark_truncated()
    return true
  end
  if line:sub(-1) == '\r' then line = line:sub(1, -2) end
  local item = parse_line(line)
  if item then self:_add(item) end
  return true
end

function Collector:_consume(stream, data)
  local partial = self.partials[stream]
  local dropping = self.dropping[stream]
  local position = 1
  while position <= #data do
    local newline = data:find('\n', position, true)
    local stop = newline and newline - 1 or #data
    local piece = data:sub(position, stop)
    if not dropping then
      if #partial + #piece > self.max_line_bytes then
        partial = ''
        dropping = true
        self:_mark_truncated()
      else
        partial = partial .. piece
      end
    end
    if newline then
      if not dropping then self:parse(partial) end
      partial = ''
      dropping = false
      position = newline + 1
    else
      position = #data + 1
    end
  end
  self.partials[stream] = partial
  self.dropping[stream] = dropping
end

function Collector:on_output(event)
  if self.finished then return nil, 'problem collector is already finished' end
  if type(event) ~= 'table' or (event.stream ~= 'stdout' and event.stream ~= 'stderr') or type(event.data) ~= 'string' then
    return nil, 'problem output event is invalid'
  end
  if event.truncated ~= nil and type(event.truncated) ~= 'boolean' then return nil, 'problem output truncation flag is invalid' end
  if event.truncated then
    self.partials[event.stream] = ''
    self.dropping[event.stream] = true
    self:_mark_truncated()
  end
  self:_consume(event.stream, event.data)
  return true
end

local function diagnostic(item)
  local value = {
    filename = item.path,
    lnum = item.line,
    text = item.message,
    type = severity_types[item.severity],
  }
  if item.column then value.col = item.column end
  if item.end_line then value.end_lnum = item.end_line end
  if item.end_column then value.end_col = item.end_column end
  return value
end

function Collector:get_result()
  local diagnostics = {}
  for index, item in ipairs(self.items) do
    diagnostics[index] = diagnostic(item)
  end
  return { diagnostics = diagnostics, problems_truncated = self.truncated }
end

function Collector:finish()
  if not self.finished then
    for _, stream in ipairs { 'stdout', 'stderr' } do
      if self.dropping[stream] then
        self:_mark_truncated()
      elseif self.partials[stream] ~= '' then
        self:parse(self.partials[stream])
      end
      self.partials[stream] = ''
      self.dropping[stream] = false
    end
    self.finished = true
  end
  local problems = {}
  for index, item in ipairs(self.items) do
    problems[index] = vim.deepcopy(item)
  end
  return { problems = problems, problems_truncated = self.truncated }
end

function Collector:reset()
  self.items = {}
  self.seen = {}
  self.partials = { stdout = '', stderr = '' }
  self.dropping = { stdout = false, stderr = false }
  self.truncated = false
  self.finished = false
  self.result_version = 0
end

local function bounded_option(name, value, default, maximum)
  if value == nil then return default end
  if type(value) ~= 'number' or value % 1 ~= 0 or value < 1 or value > maximum then
    error(('android_workbench.gradle.problems.new: %s must be an integer between 1 and %d'):format(name, maximum), 3)
  end
  return value
end

---@param opts? { max_items?: integer, max_line_bytes?: integer, max_message_bytes?: integer }
---@return table
function M.new(opts)
  opts = opts or {}
  if type(opts) ~= 'table' then error('android_workbench.gradle.problems.new: opts must be a table', 2) end
  local collector = setmetatable({
    max_items = bounded_option('max_items', opts.max_items, LIMITS.items, LIMITS.items),
    max_line_bytes = bounded_option('max_line_bytes', opts.max_line_bytes, LIMITS.line_bytes, LIMITS.line_bytes),
    max_message_bytes = bounded_option('max_message_bytes', opts.max_message_bytes, LIMITS.message_bytes, LIMITS.message_bytes),
  }, Collector)
  collector:reset()
  return collector
end

return M

-- vim: ts=2 sts=2 sw=2 et
