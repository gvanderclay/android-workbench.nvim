local Problem = require 'android_workbench.problem'

local M = {}

local OWNER = 'android_workbench'

local severity_types = {
  error = 'E',
  warning = 'W',
  info = 'I',
}

local function failure(code, message, details)
  local value = { code = code, message = message }
  if details then value.details = details end
  return value
end

local function qf_item(item)
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

local function list_payload(batch)
  local items = {}
  for index, item in ipairs(batch.items) do
    items[index] = qf_item(item)
  end
  local suffix = batch.truncated and ' [truncated]' or ''
  return {
    title = ('Android: %s%s'):format(batch.name, suffix),
    context = {
      owner = OWNER,
      root = batch.root,
      kind = batch.kind,
      name = batch.name,
      status = batch.status,
      truncated = batch.truncated,
    },
    items = items,
  }
end

local function query_list(id)
  local ok, value = pcall(vim.fn.getqflist, { id = id, nr = 0, context = 0 })
  if not ok or type(value) ~= 'table' then
    return nil, failure('quickfix_unavailable', 'Could not inspect the Android problem list.', { error = tostring(value) })
  end
  return value
end

local function owned_list(id, root)
  if type(id) ~= 'number' then return nil end
  local value, query_err = query_list(id)
  if not value then return nil, query_err end
  if value.id ~= id then return nil end
  local context = value.context
  if type(context) ~= 'table' or context.owner ~= OWNER or context.root ~= root then return nil end
  return value
end

local function find_owned_list(root)
  local ok, newest = pcall(vim.fn.getqflist, { nr = '$' })
  if not ok or type(newest) ~= 'table' or type(newest.nr) ~= 'number' then
    return nil, failure('quickfix_unavailable', 'Could not inspect Android problem-list history.', { error = tostring(newest) })
  end
  for number = newest.nr, 1, -1 do
    local queried, value = pcall(vim.fn.getqflist, { nr = number, id = 0, context = 0 })
    if not queried or type(value) ~= 'table' then
      return nil, failure('quickfix_unavailable', 'Could not inspect Android problem-list history.', { error = tostring(value) })
    end
    local context = value.context
    if type(context) == 'table' and context.owner == OWNER and context.root == root then return value end
  end
end

local function replace_list(id, batch)
  local ok, result = pcall(vim.fn.setqflist, {}, 'r', vim.tbl_extend('force', { id = id }, list_payload(batch)))
  if not ok or result ~= 0 then
    return nil, failure('quickfix_publish_failed', 'Could not update the Android problem list.', { error = ok and tostring(result) or tostring(result) })
  end
  return true
end

local function create_list(batch)
  local payload = list_payload(batch)
  payload.nr = '$'
  local ok, result = pcall(vim.fn.setqflist, {}, ' ', payload)
  if not ok or result ~= 0 then return nil, failure('quickfix_publish_failed', 'Could not create the Android problem list.', { error = tostring(result) }) end
  local created, query_err = query_list(0)
  if not created then return nil, query_err end
  local context = created.context
  if type(created.id) ~= 'number' or created.id <= 0 or type(context) ~= 'table' or context.owner ~= OWNER or context.root ~= batch.root then
    return nil, failure('quickfix_publish_failed', 'Neovim did not retain the Android problem list.')
  end
  return created
end

local function select_list(id)
  local value, query_err = query_list(id)
  if not value then return nil, query_err end
  if value.id ~= id or type(value.nr) ~= 'number' or value.nr < 1 then
    return nil, failure('quickfix_publish_failed', 'The Android problem list is no longer available.')
  end
  local selected, select_err = pcall(vim.cmd, ('silent %dchistory'):format(value.nr))
  if not selected then return nil, failure('quickfix_publish_failed', 'Could not select the Android problem list.', { error = tostring(select_err) }) end
  local current, current_err = query_list(0)
  if not current then return nil, current_err end
  if current.id ~= id then return nil, failure('quickfix_publish_failed', 'Neovim selected a different problem list.') end
  return true
end

local function open_without_focus(id)
  local selected, select_err = select_list(id)
  if not selected then return nil, select_err end
  local previous = vim.api.nvim_get_current_win()
  local opened, open_err = pcall(vim.cmd, 'botright copen')
  if not opened then return nil, failure('quickfix_open_failed', 'Could not open the Android problem list.', { error = tostring(open_err) }) end
  if vim.api.nvim_win_is_valid(previous) then
    local restored, restore_err = pcall(vim.api.nvim_set_current_win, previous)
    if not restored then
      return nil, failure('quickfix_open_failed', 'Could not restore focus after opening Android problems.', { error = tostring(restore_err) })
    end
  end
  return true
end

local function close_visible_owned_list(id, root)
  local ok, current = pcall(vim.fn.getqflist, { id = 0, context = 0, winid = 0 })
  if not ok or type(current) ~= 'table' then
    return nil, failure('quickfix_unavailable', 'Could not inspect the visible quickfix list.', { error = tostring(current) })
  end
  local context = current.context
  if current.id ~= id or type(context) ~= 'table' or context.owner ~= OWNER or context.root ~= root then return true end
  if type(current.winid) ~= 'number' or current.winid <= 0 then return true end
  if not vim.api.nvim_win_is_valid(current.winid) then return true end

  local closed, close_err = pcall(vim.api.nvim_win_close, current.winid, false)
  if not closed then return nil, failure('quickfix_close_failed', 'Could not close the resolved Android problem list.', { error = tostring(close_err) }) end
  return true
end

---@param opts? { open_on_failure?: boolean, close_on_success?: boolean }
---@return { publish: fun(batch: table): true|nil, table? }
function M.new(opts)
  opts = opts or {}
  if type(opts) ~= 'table' then error('android_workbench.integrations.quickfix.new: opts must be a table', 2) end
  if opts.open_on_failure ~= nil and type(opts.open_on_failure) ~= 'boolean' then
    error('android_workbench.integrations.quickfix.new: open_on_failure must be a boolean', 2)
  end
  if opts.close_on_success ~= nil and type(opts.close_on_success) ~= 'boolean' then
    error('android_workbench.integrations.quickfix.new: close_on_success must be a boolean', 2)
  end
  local open_on_failure = opts.open_on_failure == true
  local close_on_success = opts.close_on_success == true
  local lists = {}

  return {
    publish = function(batch)
      local normalized, batch_err = Problem.normalize_batch(batch)
      if not normalized then return nil, batch_err end

      local existing, list_err = owned_list(lists[normalized.root], normalized.root)
      if list_err then return nil, list_err end
      if not existing then
        lists[normalized.root] = nil
        existing, list_err = find_owned_list(normalized.root)
        if list_err then return nil, list_err end
        if existing then lists[normalized.root] = existing.id end
      end

      if #normalized.items == 0 then
        if not existing then return true end
        local replaced, replace_err = replace_list(existing.id, normalized)
        if not replaced then return nil, replace_err end
        if close_on_success and normalized.status == 'success' then return close_visible_owned_list(existing.id, normalized.root) end
        return true
      end

      local id
      if existing then
        local replaced, replace_err = replace_list(existing.id, normalized)
        if not replaced then return nil, replace_err end
        id = existing.id
      else
        local created, create_err = create_list(normalized)
        if not created then return nil, create_err end
        id = created.id
        lists[normalized.root] = id
      end

      if open_on_failure and normalized.status == 'failure' then return open_without_focus(id) end
      return true
    end,
  }
end

return M

-- vim: ts=2 sts=2 sw=2 et
