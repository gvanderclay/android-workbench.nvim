local M = {}

local DEFAULT_MAX_BYTES = 4 * 1024 * 1024
local DEFAULT_MAX_LINES = 10000
local DEFAULT_HEIGHT = 12
local TASK_KINDS = {
  ['android-build'] = true,
  ['android-run'] = true,
  gradle_task = true,
}

local function positive_integer(value) return type(value) == 'number' and value > 0 and value <= 2147483647 and value % 1 == 0 end

local function buffer_windows(bufnr)
  local result = {}
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then return result end
  for _, winid in ipairs(vim.fn.win_findbuf(bufnr)) do
    if vim.api.nvim_win_is_valid(winid) then result[#result + 1] = winid end
  end
  return result
end

local function line_count(state) return state.last - state.first + 1 end

local function remove_first_line(state)
  if state.first >= state.last then return false end
  local line = state.lines[state.first]
  state.lines[state.first] = nil
  state.first = state.first + 1
  state.bytes = state.bytes - #line - 1
  return true
end

local function trim(state, max_bytes, max_lines)
  local trimmed = false
  while line_count(state) > max_lines do
    remove_first_line(state)
    trimmed = true
  end

  local overflow = state.bytes - max_bytes
  while overflow > 0 do
    local line = state.lines[state.first]
    if state.first < state.last and #line + 1 <= overflow then
      overflow = overflow - #line - 1
      remove_first_line(state)
    else
      local removed = math.min(#line, overflow)
      state.lines[state.first] = line:sub(removed + 1)
      state.bytes = state.bytes - removed
      overflow = overflow - removed
    end
    trimmed = true
  end
  if trimmed then state.truncated = true end
end

local function append(state, data, max_bytes, max_lines)
  if data == '' then return end
  data = data:gsub('%z', '�')
  local parts = vim.split(data, '\n', { plain = true })
  state.lines[state.last] = state.lines[state.last] .. parts[1]
  for index = 2, #parts do
    state.last = state.last + 1
    state.lines[state.last] = parts[index]
  end
  state.bytes = state.bytes + #data
  trim(state, max_bytes, max_lines)
end

local function rendered_lines(state)
  local lines = {}
  if state.truncated then lines[#lines + 1] = '… earlier output truncated …' end
  for index = state.first, state.last do
    lines[#lines + 1] = state.lines[index]
  end
  return lines
end

local function status_text(value) return tostring(value):gsub('%%', '%%%%') end

---@param opts? { max_bytes?: integer, max_lines?: integer, height?: integer }
---@return table
function M.new(opts)
  opts = opts or {}
  if type(opts) ~= 'table' then error('android_workbench.task_output.new: options must be a table', 2) end
  if opts.max_bytes ~= nil and not positive_integer(opts.max_bytes) then error('android_workbench.task_output.new: max_bytes must be a positive integer', 2) end
  if opts.max_lines ~= nil and not positive_integer(opts.max_lines) then error('android_workbench.task_output.new: max_lines must be a positive integer', 2) end
  if opts.height ~= nil and not positive_integer(opts.height) then error('android_workbench.task_output.new: height must be a positive integer', 2) end

  local max_bytes = opts.max_bytes or DEFAULT_MAX_BYTES
  local max_lines = opts.max_lines or DEFAULT_MAX_LINES
  local height = opts.height or DEFAULT_HEIGHT
  local states = {}
  local owner = {}

  local function current(state, generation) return not state.closed and state.generation == generation and states[state.root] == state end

  local function update_winbars(state)
    local truncation = state.truncated and ' · TRUNCATED' or ''
    local value = (' [q] hide  [f] follow:%s %%=%%< Android task · %s · %s%s · %s '):format(
      state.follow and 'on' or 'off',
      status_text(state.name),
      status_text(state.phase:upper()),
      truncation,
      status_text(state.root)
    )
    for _, winid in ipairs(buffer_windows(state.bufnr)) do
      pcall(vim.api.nvim_set_option_value, 'winbar', value, { scope = 'local', win = winid })
    end
  end

  local function follow_tail(state)
    if not state.follow or not state.bufnr or not vim.api.nvim_buf_is_valid(state.bufnr) then return end
    local last = math.max(1, vim.api.nvim_buf_line_count(state.bufnr))
    for _, winid in ipairs(buffer_windows(state.bufnr)) do
      pcall(vim.api.nvim_win_set_cursor, winid, { last, 0 })
    end
  end

  local render
  local function ensure_buffer(state)
    if state.bufnr and vim.api.nvim_buf_is_valid(state.bufnr) then return true end
    local bufnr = vim.api.nvim_create_buf(false, true)
    state.bufnr = bufnr
    vim.api.nvim_buf_set_name(bufnr, ('android-task-output://%s/%d'):format(vim.fn.sha256(state.root), bufnr))
    vim.bo[bufnr].buftype = 'nofile'
    vim.bo[bufnr].bufhidden = 'hide'
    vim.bo[bufnr].swapfile = false
    vim.bo[bufnr].undofile = false
    vim.bo[bufnr].undolevels = -1
    vim.bo[bufnr].modeline = false
    vim.bo[bufnr].modifiable = false
    vim.bo[bufnr].readonly = true

    vim.keymap.set('n', 'q', function()
      local winid = vim.api.nvim_get_current_win()
      if vim.api.nvim_win_get_buf(winid) == state.bufnr and #vim.api.nvim_list_wins() > 1 then pcall(vim.api.nvim_win_close, winid, false) end
    end, { buffer = bufnr, silent = true, desc = 'Hide Android task output' })
    vim.keymap.set('n', 'f', function()
      state.follow = not state.follow
      update_winbars(state)
      follow_tail(state)
    end, { buffer = bufnr, silent = true, desc = 'Toggle Android task output follow' })

    vim.api.nvim_create_autocmd('BufWinEnter', { buffer = bufnr, callback = function() update_winbars(state) end })
    vim.api.nvim_create_autocmd('BufWipeout', {
      buffer = bufnr,
      once = true,
      callback = function(args)
        if state.bufnr == args.buf then state.bufnr = nil end
      end,
    })
    vim.bo[bufnr].filetype = 'androidtaskoutput'
    return true
  end

  render = function(state)
    if state.closed or not ensure_buffer(state) then return false end
    vim.bo[state.bufnr].readonly = false
    vim.bo[state.bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(state.bufnr, 0, -1, false, rendered_lines(state))
    vim.bo[state.bufnr].modifiable = false
    vim.bo[state.bufnr].readonly = true
    update_winbars(state)
    follow_tail(state)
    return true
  end

  function owner.start(request)
    local metadata = request and request.metadata
    if type(request) ~= 'table' or type(request.cwd) ~= 'string' or type(metadata) ~= 'table' then return nil end
    if not TASK_KINDS[metadata.kind] or metadata.root ~= request.cwd then return nil end

    local state = states[request.cwd]
    if not state then
      state = { root = request.cwd, generation = 0 }
      states[request.cwd] = state
    end
    state.generation = state.generation + 1
    state.closed = false
    state.name = request.name
    state.phase = 'running'
    state.lines = { '' }
    state.first = 1
    state.last = 1
    state.bytes = 0
    state.truncated = false
    state.follow = true
    local generation = state.generation
    render(state)
    owner.show(request.cwd, { focus = false })

    return {
      append = function(event)
        if not current(state, generation) or type(event) ~= 'table' or type(event.data) ~= 'string' then return false end
        if event.truncated then
          state.lines = { '' }
          state.first = 1
          state.last = 1
          state.bytes = 0
          state.truncated = true
        end
        append(state, event.data, max_bytes, max_lines)
        render(state)
        return true
      end,
      finish = function(err, result)
        if not current(state, generation) then return false end
        if err then
          state.phase = 'error'
        elseif type(result) == 'table' and type(result.status) == 'string' then
          state.phase = result.status
          if result.output_truncated or result.stdout_truncated or result.stderr_truncated then state.truncated = true end
        else
          state.phase = 'error'
        end
        render(state)
        return true
      end,
    }
  end

  function owner.has_output(root) return states[root] ~= nil end

  function owner.show(root, show_opts)
    local state = states[root]
    if not state or state.closed or not render(state) then return false end
    show_opts = show_opts or {}
    local windows = buffer_windows(state.bufnr)
    if #windows > 0 then
      if show_opts.focus ~= false then vim.api.nvim_set_current_win(windows[1]) end
      return true
    end

    local origin = vim.api.nvim_get_current_win()
    local opened, winid = pcall(vim.api.nvim_open_win, state.bufnr, show_opts.focus ~= false, {
      split = 'below',
      win = origin,
      height = height,
    })
    if not opened then return false end
    vim.wo[winid].winfixheight = true
    update_winbars(state)
    follow_tail(state)
    return true
  end

  function owner.close()
    local closing = states
    states = {}
    for _, state in pairs(closing) do
      state.closed = true
      state.generation = state.generation + 1
      local bufnr = state.bufnr
      state.bufnr = nil
      if bufnr and vim.api.nvim_buf_is_valid(bufnr) then pcall(vim.api.nvim_buf_delete, bufnr, { force = true }) end
    end
    return true
  end

  return owner
end

return M

-- vim: ts=2 sts=2 sw=2 et
