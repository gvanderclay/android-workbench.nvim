local Problem = require 'android_workbench.problem'

local M = {}

local SOURCE = 'Android Workbench'
local NAMESPACE_PREFIX = 'android_workbench.problems.'
local AUGROUP_PREFIX = 'android_workbench.problems.edits.'

local severities = {
  error = vim.diagnostic.severity.ERROR,
  warning = vim.diagnostic.severity.WARN,
  info = vim.diagnostic.severity.INFO,
}

local function failure(code, message, details)
  local value = { code = code, message = message }
  if details then value.details = details end
  return value
end

local function error_text(value)
  local ok, rendered = pcall(tostring, value)
  return ok and rendered or 'unknown error'
end

local function structured_error(value)
  return type(value) == 'table' and type(value.code) == 'string' and value.code ~= '' and type(value.message) == 'string' and value.message ~= ''
end

local function diagnostic(item, batch)
  local value = {
    lnum = item.line - 1,
    message = item.message,
    severity = severities[item.severity],
    source = SOURCE,
    user_data = {
      android_workbench = {
        root = batch.root,
        kind = batch.kind,
        name = batch.name,
        status = batch.status,
        truncated = batch.truncated,
      },
    },
  }
  if item.column then value.col = item.column - 1 end
  if item.end_line then value.end_lnum = item.end_line - 1 end
  if item.end_column then value.end_col = item.end_column - 1 end
  return value
end

local function clear_projection(state)
  local ok, err = pcall(vim.diagnostic.reset, state.namespace)
  if not ok then return nil, failure('diagnostic_publish_failed', 'Could not clear Android diagnostics.', { error = error_text(err) }) end
  local grouped, group = pcall(vim.api.nvim_create_augroup, state.group_name, { clear = true })
  if not grouped or type(group) ~= 'number' or group <= 0 then
    return nil,
      failure('diagnostic_publish_failed', 'Could not reset Android diagnostic edit tracking.', {
        error = grouped and 'augroup creation returned an invalid identifier' or error_text(group),
      })
  end
  state.group = group
  return true
end

local function resolve_buffer(path)
  local ok, created = pcall(function() return vim.fn.bufadd(vim.fs.normalize(path)) end)
  if not ok or type(created) ~= 'number' or created <= 0 or not vim.api.nvim_buf_is_valid(created) then
    return nil,
      failure('diagnostic_publish_failed', 'Could not create a buffer for an Android diagnostic.', {
        error = ok and 'bufadd returned an invalid buffer' or error_text(created),
        path = path,
      })
  end
  return created
end

local function is_modified(buffer)
  local ok, modified = pcall(function() return vim.bo[buffer].modified end)
  if not ok or type(modified) ~= 'boolean' then
    return nil,
      failure('diagnostic_publish_failed', 'Could not inspect the Android diagnostic buffer.', {
        buffer = buffer,
        error = ok and 'buffer modified state was not boolean' or error_text(modified),
      })
  end
  return modified
end

local function arm_edit_clear(state, buffer)
  local ok, autocmd = pcall(vim.api.nvim_create_autocmd, { 'TextChanged', 'TextChangedI', 'TextChangedP' }, {
    group = state.group,
    buffer = buffer,
    once = true,
    desc = 'Invalidate edited Android build diagnostics',
    callback = function(event)
      local reset = pcall(vim.diagnostic.reset, state.namespace, event.buf)
      if reset then pcall(vim.api.nvim_clear_autocmds, { group = state.group, buffer = event.buf }) end
    end,
  })
  if not ok or type(autocmd) ~= 'number' or autocmd <= 0 then
    return nil,
      failure('diagnostic_publish_failed', 'Could not watch an Android diagnostic buffer for edits.', {
        buffer = buffer,
        error = ok and 'autocmd creation returned an invalid identifier' or error_text(autocmd),
      })
  end
  return true
end

local function project(state, batch)
  local cleared, clear_err = clear_projection(state)
  if not cleared then return nil, clear_err end
  if batch.status == 'success' or #batch.items == 0 then return true end

  local grouped = {}
  for _, item in ipairs(batch.items) do
    local buffer, buffer_err = resolve_buffer(item.path)
    if not buffer then return nil, buffer_err end
    local modified, modified_err = is_modified(buffer)
    if modified == nil then return nil, modified_err end
    if not modified then
      grouped[buffer] = grouped[buffer] or {}
      grouped[buffer][#grouped[buffer] + 1] = diagnostic(item, batch)
    end
  end

  for buffer, items in pairs(grouped) do
    local ok, err = pcall(vim.diagnostic.set, state.namespace, buffer, items)
    if not ok then
      clear_projection(state)
      return nil,
        failure('diagnostic_publish_failed', 'Could not publish Android diagnostics.', {
          buffer = buffer,
          error = error_text(err),
        })
    end
  end

  for buffer in pairs(grouped) do
    local armed, arm_err = arm_edit_clear(state, buffer)
    if not armed then
      clear_projection(state)
      return nil, arm_err
    end
  end
  return true
end

---@param opts { sink: AndroidWorkbenchProblemSink }
---@return AndroidWorkbenchProblemSink
function M.new(opts)
  if type(opts) ~= 'table' then error('android_workbench.integrations.diagnostics.new: opts must be a table', 2) end
  if type(opts.sink) ~= 'table' or type(opts.sink.publish) ~= 'function' then
    error('android_workbench.integrations.diagnostics.new: sink.publish must be a function', 2)
  end
  local sink = opts.sink
  local roots = {}

  return {
    publish = function(batch)
      local normalized, batch_err = Problem.normalize_batch(batch)
      if not normalized then return nil, batch_err end

      local called, published, publish_err = pcall(sink.publish, vim.deepcopy(normalized))
      if not called then return nil, failure('problem_sink_failed', 'The decorated Android problem sink threw an error.', { error = error_text(published) }) end
      if published ~= true then
        if published == nil and structured_error(publish_err) then return nil, publish_err end
        return nil,
          failure('problem_sink_failed', 'The decorated Android problem sink returned an invalid result.', {
            error = error_text(publish_err or published),
          })
      end

      local state = roots[normalized.root]
      if not state then
        local hashed, root_hash = pcall(vim.fn.sha256, normalized.root)
        if not hashed or type(root_hash) ~= 'string' or #root_hash ~= 64 or not root_hash:match '^%x+$' then
          return nil,
            failure('diagnostic_publish_failed', 'Could not identify the Android diagnostic root.', {
              error = hashed and 'root hash was invalid' or error_text(root_hash),
            })
        end
        local ok, namespace = pcall(vim.api.nvim_create_namespace, NAMESPACE_PREFIX .. root_hash)
        if not ok or type(namespace) ~= 'number' or namespace <= 0 then
          return nil,
            failure('diagnostic_publish_failed', 'Could not create an Android diagnostic namespace.', {
              error = ok and 'namespace creation returned an invalid identifier' or error_text(namespace),
            })
        end
        state = {
          namespace = namespace,
          group_name = AUGROUP_PREFIX .. root_hash,
        }
        roots[normalized.root] = state
      end

      return project(state, normalized)
    end,
  }
end

return M

-- vim: ts=2 sts=2 sw=2 et
