local Model = require 'android_workbench.logcat.model'
local Runner = require 'android_workbench.runner'
local Spool = require 'android_workbench.logcat.spool'

local M = {}

local DEFAULT_HEIGHT = 15
local DEFAULT_MAX_LINE_BYTES = 64 * 1024
local DEFAULT_MAX_RECORDS = 10000
local DEFAULT_MAX_RETAINED_BYTES = 4 * 1024 * 1024
local DEFAULT_UID_REFRESH_INTERVAL_MS = 1000
local DEFAULT_UID_TIMEOUT_MS = 30000
local MAX_SOURCE_ENTRIES = 50000

local HIGHLIGHTS = {
  V = 'Comment',
  D = 'DiagnosticHint',
  I = 'DiagnosticInfo',
  W = 'DiagnosticWarn',
  E = 'DiagnosticError',
  F = 'DiagnosticError',
  A = 'DiagnosticError',
}

local SKIP_DIRECTORIES = {
  ['.cxx'] = true,
  ['.git'] = true,
  ['.gradle'] = true,
  ['.idea'] = true,
  build = true,
  node_modules = true,
  out = true,
}

local function failure(code, message, details)
  return {
    code = code,
    message = message,
    details = details,
  }
end

local function positive_integer(value) return type(value) == 'number' and value == value and value > 0 and value <= 2147483647 and value % 1 == 0 end

local function valid_serial(value) return type(value) == 'string' and value ~= '' and #value <= 1024 and not value:find '%c' end

local function valid_application_id(value)
  if type(value) ~= 'string' or value == '' or #value > 512 or not value:find('.', 1, true) then return false end
  if value:sub(1, 1) == '.' or value:sub(-1) == '.' or value:find('..', 1, true) then return false end
  for segment in value:gmatch '[^.]+' do
    if not segment:match '^[A-Za-z][A-Za-z0-9_]*$' then return false end
  end
  return true
end

local function default_picker()
  return {
    select = function(request, callback)
      vim.ui.select(request.items, {
        prompt = request.prompt,
        format_item = request.format_item,
      }, function(item) callback(nil, item) end)
    end,
  }
end

local function default_notifications()
  return {
    emit = function(event)
      local levels = {
        error = vim.log.levels.ERROR,
        warn = vim.log.levels.WARN,
        info = vim.log.levels.INFO,
      }
      vim.notify(event.message, levels[event.level] or vim.log.levels.INFO, { title = event.title or 'Android Logcat' })
    end,
  }
end

local function notify(notifications, level, message)
  pcall(notifications.emit, {
    level = level,
    title = 'Android Logcat',
    message = message,
  })
end

local function parse_uid(stdout, application_id)
  local found
  local count = 0
  local exact_prefix = '^package:' .. vim.pesc(application_id) .. '%s+'
  stdout = (stdout or ''):gsub('\r\n', '\n'):gsub('\r', '\n')
  for line in (stdout .. '\n'):gmatch '(.-)\n' do
    local entry = vim.trim(line)
    if entry ~= '' then
      local package_name, uid = entry:match '^package:(.-)%s+uid:(%d+)$'
      if package_name == application_id and uid then
        count = count + 1
        found = tonumber(uid)
      elseif entry:match(exact_prefix) then
        return nil, failure('invalid_uid_output', ('ADB returned an invalid UID for %s.'):format(application_id), { output = entry })
      end
    end
  end
  if count ~= 1 or not found then
    return nil,
      failure(
        'package_not_installed',
        ('Could not resolve the installed UID for %s. Run the application first.'):format(application_id),
        { output = vim.trim(stdout or '') }
      )
  end
  return found
end

local function close_timer(timer)
  if not timer then return end
  pcall(timer.stop, timer)
  local ok, closing = pcall(timer.is_closing, timer)
  if not ok or not closing then pcall(timer.close, timer) end
end

local function cancel_handle(handle)
  if not handle or type(handle.cancel) ~= 'function' then return end
  pcall(handle.cancel, handle)
end

local function relative_label(root, path)
  local ok, relative = pcall(vim.fs.relpath, root, path)
  if ok and relative then return relative end
  return path
end

local function buffer_windows(bufnr)
  local result = {}
  for _, winid in ipairs(vim.fn.win_findbuf(bufnr)) do
    if vim.api.nvim_win_is_valid(winid) then result[#result + 1] = winid end
  end
  return result
end

---@param opts? table
---@return table
function M.new(opts)
  opts = opts or {}
  if type(opts) ~= 'table' then error('android_workbench.logcat.native.new: options must be a table', 2) end
  if opts.max_records ~= nil and not positive_integer(opts.max_records) then
    error('android_workbench.logcat.native.new: max_records must be a positive integer', 2)
  end
  if opts.max_line_bytes ~= nil and not positive_integer(opts.max_line_bytes) then
    error('android_workbench.logcat.native.new: max_line_bytes must be a positive integer', 2)
  end
  if opts.max_retained_bytes ~= nil and not positive_integer(opts.max_retained_bytes) then
    error('android_workbench.logcat.native.new: max_retained_bytes must be a positive integer', 2)
  end
  if opts.initial_lines ~= nil and not positive_integer(opts.initial_lines) then
    error('android_workbench.logcat.native.new: initial_lines must be a positive integer', 2)
  end
  if opts.height ~= nil and not positive_integer(opts.height) then error('android_workbench.logcat.native.new: height must be a positive integer', 2) end
  if opts.uid_timeout_ms ~= nil and not positive_integer(opts.uid_timeout_ms) then
    error('android_workbench.logcat.native.new: uid_timeout_ms must be a positive integer', 2)
  end
  if opts.input ~= nil and type(opts.input) ~= 'function' then error('android_workbench.logcat.native.new: input must be a function', 2) end
  if opts.spool_tempname ~= nil and type(opts.spool_tempname) ~= 'function' then
    error('android_workbench.logcat.native.new: spool_tempname must be a function', 2)
  end

  local max_records = opts.max_records or DEFAULT_MAX_RECORDS
  local max_line_bytes = opts.max_line_bytes or DEFAULT_MAX_LINE_BYTES
  local max_retained_bytes = opts.max_retained_bytes or DEFAULT_MAX_RETAINED_BYTES
  local initial_lines = opts.initial_lines
  local height = opts.height or DEFAULT_HEIGHT
  local uid_timeout_ms = opts.uid_timeout_ms or DEFAULT_UID_TIMEOUT_MS
  local runner = opts.runner or Runner.new { max_capture_bytes = 64 * 1024 }
  local picker = opts.picker or default_picker()
  local notifications = opts.notifications or default_notifications()
  local input = opts.input or vim.ui.input
  local schedule = opts.schedule or vim.schedule
  local defer_fn = opts.defer_fn or vim.defer_fn
  local spool_tempname = opts.spool_tempname or vim.fn.tempname
  local dock = { win = nil, source_win = nil }
  local session_buffers = {}

  local function usable_source_window(winid)
    if not winid or not vim.api.nvim_win_is_valid(winid) then return false end
    if vim.api.nvim_win_get_config(winid).relative ~= '' then return false end
    return vim.bo[vim.api.nvim_win_get_buf(winid)].buftype == ''
  end

  local function owned_dock_window()
    local winid = dock.win
    if
      not winid
      or not vim.api.nvim_win_is_valid(winid)
      or vim.api.nvim_win_get_config(winid).relative ~= ''
      or not session_buffers[vim.api.nvim_win_get_buf(winid)]
    then
      dock.win = nil
      return nil
    end
    return winid
  end

  return {
    start = function(request)
      if type(request) ~= 'table' then error('Android Logcat request must be a table', 2) end
      if type(request.root) ~= 'string' or request.root == '' then error('Android Logcat request requires a project root', 2) end
      if type(request.project_dir) ~= 'string' or request.project_dir == '' then
        error('Android Logcat request requires an application project directory', 2)
      end
      if type(request.resolve_adb) ~= 'function' then error('Android Logcat request requires an adb resolver', 2) end
      if not valid_serial(request.device_serial) then error('Android Logcat request has an invalid device serial', 2) end
      if not valid_application_id(request.application_id) then error('Android Logcat request has an invalid applicationId', 2) end
      if request.variant ~= nil and (type(request.variant) ~= 'string' or request.variant == '') then
        error('Android Logcat request has an invalid variant', 2)
      end
      if type(request.select_logcat_session) ~= 'function' then error('Android Logcat request requires a session selector', 2) end
      if type(request.on_exit) ~= 'function' then error('Android Logcat request requires on_exit', 2) end

      local resolved, adb, adb_err = pcall(request.resolve_adb)
      if not resolved then
        local message = type(adb) == 'table' and (adb.message or adb.code or vim.inspect(adb)) or adb
        error(('Android Logcat could not resolve adb: %s'):format(tostring(message)), 2)
      end
      if type(adb) ~= 'string' or adb == '' or adb:find('\0', 1, true) then
        local message = type(adb_err) == 'table' and (adb_err.message or adb_err.code) or adb_err
        error(('Android Logcat could not resolve adb: %s'):format(tostring(message or 'no executable was returned')), 2)
      end

      local state = {
        bufnr = nil,
        child = nil,
        done = false,
        stop_requested = false,
        phase = 'starting',
        uid = nil,
        partial = '',
        previous = nil,
        discarding_gap = false,
        discarding_cr = false,
        records = {},
        record_bytes = 0,
        pending_records = {},
        pending_record_bytes = 0,
        rendered_records = 0,
        filters = { level = 'verbose', tag = nil, text = nil },
        paused = false,
        follow = true,
        source_index = nil,
        source_win = nil,
        timer = nil,
        uid_child = nil,
        uid_query_generation = 0,
        uid_query_timeout_timer = nil,
        uid_refresh_timer = nil,
        picker_handle = nil,
        session_picker_handle = nil,
        session_picker_generation = 0,
        session_picker_active = false,
        child_generation = 0,
        pending_error = nil,
        help_bufnr = nil,
        help_win = nil,
        hidden = false,
        restoring = false,
        spool = nil,
        spool_failed = false,
        storage_generation = 0,
        discard_history = false,
      }
      local namespace = vim.api.nvim_create_namespace(
        'android-workbench-logcat-' .. vim.fn.sha256(request.root .. '\0' .. request.device_serial .. '\0' .. request.application_id)
      )
      local handle = {}

      local function set_modifiable(value)
        if not state.bufnr or not vim.api.nvim_buf_is_valid(state.bufnr) then return false end
        vim.bo[state.bufnr].readonly = not value
        vim.bo[state.bufnr].modifiable = value
        return true
      end

      local function status_label()
        local status = state.phase:upper()
        if state.paused then status = status .. ' · PAUSED' end
        return status
      end

      local function winbar()
        local filters = state.filters
        local identity = ('%s · %s%s'):format(request.application_id, request.device_serial, state.uid and (' · uid ' .. state.uid) or '')
        identity = identity:gsub('%%', '%%%%')
        return (' [S] sessions  [?] shortcuts  [p] pause  [f] follow  [c] clear %%=%%< Android Logcat · %s · %s · level≥%s · filters=%s · follow=%s '):format(
          identity,
          status_label(),
          filters.level:upper(),
          (filters.tag or filters.text) and 'on' or 'off',
          state.follow and 'on' or 'off'
        )
      end

      local function highlight_line(row, record)
        if not state.bufnr or not vim.api.nvim_buf_is_valid(state.bufnr) then return end
        local highlight = record.priority and HIGHLIGHTS[record.priority]
        if highlight then pcall(vim.api.nvim_buf_set_extmark, state.bufnr, namespace, row, 0, { line_hl_group = highlight, priority = 10 }) end
        if Model.parse_frame(record) then
          local start_col, end_col = record.raw:find '%([^():]+:%d+%)'
          if start_col then
            pcall(vim.api.nvim_buf_set_extmark, state.bufnr, namespace, row, start_col - 1, {
              end_col = end_col,
              hl_group = 'Underlined',
              hl_mode = 'combine',
              priority = 20,
            })
          end
        end
      end

      local function update_winbars()
        local value = winbar()
        for _, winid in ipairs(buffer_windows(state.bufnr)) do
          pcall(vim.api.nvim_set_option_value, 'winbar', value, { scope = 'local', win = winid })
        end
      end

      local function close_help()
        local winid = state.help_win
        local bufnr = state.help_bufnr
        state.help_win = nil
        state.help_bufnr = nil
        if winid and vim.api.nvim_win_is_valid(winid) then pcall(vim.api.nvim_win_close, winid, true) end
        if bufnr and vim.api.nvim_buf_is_valid(bufnr) then pcall(vim.api.nvim_buf_delete, bufnr, { force = true }) end
      end

      local function cancel_session_picker()
        state.session_picker_generation = state.session_picker_generation + 1
        state.session_picker_active = false
        local picker_handle = state.session_picker_handle
        state.session_picker_handle = nil
        cancel_handle(picker_handle)
      end

      local function follow_tail()
        if not state.follow or state.paused or not state.bufnr or not vim.api.nvim_buf_is_valid(state.bufnr) then return end
        local last = math.max(1, vim.api.nvim_buf_line_count(state.bufnr))
        for _, winid in ipairs(buffer_windows(state.bufnr)) do
          pcall(vim.api.nvim_win_set_cursor, winid, { last, 0 })
        end
      end

      local function render()
        if state.hidden then
          update_winbars()
          return
        end
        if state.paused or not set_modifiable(true) then
          update_winbars()
          return
        end
        vim.api.nvim_buf_clear_namespace(state.bufnr, namespace, 0, -1)
        local output = {}
        local visible = {}
        for _, record in ipairs(state.records) do
          if Model.matches(record, state.filters) then
            output[#output + 1] = record.raw
            visible[#visible + 1] = record
          end
        end
        vim.api.nvim_buf_set_lines(state.bufnr, 0, -1, false, output)
        state.rendered_records = #visible
        set_modifiable(false)
        for index, record in ipairs(visible) do
          highlight_line(index - 1, record)
        end
        update_winbars()
        follow_tail()
      end

      local function trim_records()
        local count = #state.records
        local trim = 0
        if count > max_records then trim = math.max(count - max_records, math.max(1, math.floor(max_records / 10))) end
        local retained_bytes = state.record_bytes
        for index = 1, trim do
          retained_bytes = retained_bytes - #state.records[index].raw
        end
        while trim < count and retained_bytes > max_retained_bytes do
          trim = trim + 1
          retained_bytes = retained_bytes - #state.records[trim].raw
        end
        if trim == 0 then return false end
        local retained = {}
        for index = trim + 1, count do
          retained[#retained + 1] = state.records[index]
        end
        state.records = retained
        state.record_bytes = retained_bytes
        return true
      end

      local function compact_context(record)
        if not record then return nil end
        return {
          timestamp = record.timestamp,
          uid = record.uid,
          application_id = record.application_id,
          pid = record.pid,
          tid = record.tid,
          priority = record.priority,
          level = record.level,
          rank = record.rank,
          tag = record.tag,
        }
      end

      local function release_buffer_history()
        state.rendered_records = 0
        state.source_index = nil
        if not set_modifiable(true) then return end
        vim.api.nvim_buf_clear_namespace(state.bufnr, namespace, 0, -1)
        vim.api.nvim_buf_set_lines(state.bufnr, 0, -1, false, {})
        set_modifiable(false)
      end

      local function ensure_spool()
        if state.spool or state.spool_failed or state.discard_history then return state.spool end
        state.spool = Spool.new {
          max_records = max_records,
          max_bytes = max_retained_bytes,
          tempname = spool_tempname,
        }
        return state.spool
      end

      local function encode_records(records)
        local entries = {}
        for _, record in ipairs(records) do
          local encoded, value = pcall(vim.json.encode, record)
          if not encoded then return nil, tostring(value) end
          entries[#entries + 1] = { data = value, raw_bytes = #record.raw }
        end
        return entries
      end

      local function notify_spool_failure(err)
        if state.spool_failed then return end
        state.spool_failed = true
        notify(notifications, 'warn', ('Could not use private Logcat history storage; retaining bounded history in memory: %s'):format(err))
      end

      local function append_to_spool(records)
        if state.spool_failed then return records end
        local spool = ensure_spool()
        if not spool then return records end
        local entries, encode_err = encode_records(records)
        if not entries then
          notify_spool_failure(encode_err)
          return records
        end
        local accepted, append_err = spool:append(entries)
        if append_err then notify_spool_failure(append_err) end
        if accepted >= #records then return {} end
        local remaining = {}
        for index = accepted + 1, #records do
          remaining[#remaining + 1] = records[index]
        end
        return remaining
      end

      local function reset_record_bytes()
        state.record_bytes = 0
        for _, record in ipairs(state.records) do
          state.record_bytes = state.record_bytes + #record.raw
        end
      end

      local function append_memory(records)
        local visible = {}
        for _, record in ipairs(records) do
          state.records[#state.records + 1] = record
          state.record_bytes = state.record_bytes + #record.raw
          if Model.matches(record, state.filters) then visible[#visible + 1] = record end
        end
        local trimmed = trim_records()
        if state.hidden or state.paused then
          update_winbars()
          return
        end
        if trimmed then
          render()
          return
        end
        if #visible == 0 or not set_modifiable(true) then return end
        local start_row = state.rendered_records
        local lines = {}
        for _, record in ipairs(visible) do
          lines[#lines + 1] = record.raw
        end
        if state.rendered_records == 0 then
          vim.api.nvim_buf_set_lines(state.bufnr, 0, -1, false, lines)
        else
          vim.api.nvim_buf_set_lines(state.bufnr, -1, -1, false, lines)
        end
        state.rendered_records = state.rendered_records + #visible
        set_modifiable(false)
        for index, record in ipairs(visible) do
          highlight_line(start_row + index - 1, record)
        end
        follow_tail()
      end

      local function move_memory_to_spool()
        if state.discard_history then
          state.records = {}
          state.record_bytes = 0
          release_buffer_history()
          return
        end
        local remaining = append_to_spool(state.records)
        state.records = remaining
        reset_record_bytes()
        release_buffer_history()
      end

      local function append_records(records)
        if #records == 0 or state.done or state.discard_history then return end
        if state.hidden and not state.restoring then
          records = append_to_spool(records)
          if #records == 0 then
            update_winbars()
            return
          end
        end
        append_memory(records)
      end

      local function append_pending(record)
        if record.uid == nil or state.done or state.discard_history then return end
        state.pending_records[#state.pending_records + 1] = record
        state.pending_record_bytes = state.pending_record_bytes + #record.raw
        local count = #state.pending_records
        local trim = count > max_records and math.max(count - max_records, math.max(1, math.floor(max_records / 10))) or 0
        local retained_bytes = state.pending_record_bytes
        for index = 1, trim do
          retained_bytes = retained_bytes - #state.pending_records[index].raw
        end
        while trim < count and retained_bytes > max_retained_bytes do
          trim = trim + 1
          retained_bytes = retained_bytes - #state.pending_records[trim].raw
        end
        if trim > 0 then
          local retained = {}
          for index = trim + 1, count do
            retained[#retained + 1] = state.pending_records[index]
          end
          state.pending_records = retained
          state.pending_record_bytes = retained_bytes
        end
      end

      local function adopt_uid(uid)
        state.uid = uid
        if not uid or #state.pending_records == 0 then return end
        local accepted = {}
        for _, record in ipairs(state.pending_records) do
          if record.uid == uid then
            record.application_id = request.application_id
            accepted[#accepted + 1] = record
          end
        end
        state.pending_records = {}
        state.pending_record_bytes = 0
        append_records(accepted)
      end

      local function consume(data)
        if state.done or type(data) ~= 'string' or data == '' then return end
        local value = state.partial == '' and data or state.partial .. data
        local start = 1
        local records = {}
        while true do
          local newline = value:find('[\r\n]', start)
          if not newline then break end
          if value:sub(newline, newline) == '\r' and newline == #value then break end
          if newline - start <= max_line_bytes then
            local line = value:sub(start, newline - 1)
            local record = Model.parse_line(line, state.previous)
            if record.uid ~= nil and record.uid == state.uid then record.application_id = request.application_id end
            state.previous = compact_context(record)
            if record.application_id == request.application_id then
              records[#records + 1] = record
            else
              append_pending(record)
            end
          else
            state.previous = nil
          end
          if value:sub(newline, newline + 1) == '\r\n' then
            start = newline + 2
          else
            start = newline + 1
          end
        end
        local partial_bytes = #value - start + 1
        local trailing_cr = partial_bytes > 0 and value:sub(-1) == '\r'
        if trailing_cr then partial_bytes = partial_bytes - 1 end
        if partial_bytes > max_line_bytes then
          state.partial = ''
          state.previous = nil
          state.discarding_gap = true
          state.discarding_cr = trailing_cr
        else
          state.partial = value:sub(start)
        end
        append_records(records)
      end

      local function consume_after_gap(data)
        state.partial = ''
        state.previous = nil
        state.discarding_gap = true
        if type(data) ~= 'string' or data == '' then return end
        if state.discarding_cr then
          state.discarding_cr = false
          state.discarding_gap = false
          if data:sub(1, 1) == '\n' then data = data:sub(2) end
          consume(data)
          return
        end
        local newline = data:find '[\r\n]'
        if not newline then return end
        if data:sub(newline, newline) == '\r' and newline == #data then
          state.discarding_cr = true
          return
        end
        local start = newline + 1
        if data:sub(newline, newline + 1) == '\r\n' then start = newline + 2 end
        state.discarding_gap = false
        consume(data:sub(start))
      end

      local function close_private_history(discard)
        state.storage_generation = state.storage_generation + 1
        state.restoring = false
        if state.spool then state.spool:close() end
        state.spool = nil
        state.spool_failed = false
        if discard then
          state.records = {}
          state.record_bytes = 0
          state.pending_records = {}
          state.pending_record_bytes = 0
          state.source_index = nil
          release_buffer_history()
        end
      end

      local function decode_history(entries)
        local records = {}
        for _, entry in ipairs(entries or {}) do
          local decoded, record = pcall(vim.json.decode, entry)
          if not decoded or type(record) ~= 'table' or type(record.raw) ~= 'string' or #record.raw > max_line_bytes then
            return nil, 'temporary history contained an invalid record'
          end
          records[#records + 1] = record
        end
        return records
      end

      local function enter_hidden()
        if state.hidden then return end
        state.hidden = true
        close_help()
        if state.restoring then
          release_buffer_history()
          return
        end
        move_memory_to_spool()
      end

      local function enter_visible()
        state.hidden = false
        if state.done or state.discard_history or state.restoring or not state.spool then
          render()
          return
        end
        local spool = state.spool
        state.restoring = true
        state.storage_generation = state.storage_generation + 1
        local generation = state.storage_generation
        local started = spool:read_all(function(err, entries)
          if state.done or state.discard_history or state.storage_generation ~= generation or state.spool ~= spool then return end
          state.spool = nil
          state.restoring = false
          state.spool_failed = false
          if err then
            notify_spool_failure(err)
          else
            local restored, decode_err = decode_history(entries)
            if not restored then
              notify_spool_failure(decode_err)
            else
              local current = state.records
              state.records = restored
              for _, record in ipairs(current) do
                state.records[#state.records + 1] = record
              end
              reset_record_bytes()
              trim_records()
            end
          end
          if state.hidden then
            state.spool_failed = false
            move_memory_to_spool()
          else
            render()
          end
        end)
        if not started then
          state.restoring = false
          state.spool = nil
          notify_spool_failure 'temporary history could not begin restoration'
          render()
        end
      end

      local function finish(result)
        if state.done then return false end
        state.done = true
        state.child_generation = state.child_generation + 1
        state.uid_query_generation = state.uid_query_generation + 1
        close_timer(state.timer)
        state.timer = nil
        close_timer(state.uid_query_timeout_timer)
        state.uid_query_timeout_timer = nil
        close_timer(state.uid_refresh_timer)
        state.uid_refresh_timer = nil
        cancel_handle(state.uid_child)
        state.uid_child = nil
        cancel_handle(state.picker_handle)
        state.picker_handle = nil
        cancel_session_picker()
        state.child = nil
        close_help()
        local discard_history = state.hidden or state.discard_history
        close_private_history(false)
        if not discard_history and not state.discarding_gap and state.partial ~= '' then
          local line = state.partial
          if line:sub(-1) == '\r' then line = line:sub(1, -2) end
          local record = Model.parse_line(line, state.previous)
          state.partial = ''
          if record.uid ~= nil and record.uid == state.uid then record.application_id = request.application_id end
          if record.application_id == request.application_id then
            state.records[#state.records + 1] = record
            state.record_bytes = state.record_bytes + #record.raw
            trim_records()
          end
        end
        state.partial = ''
        state.previous = nil
        state.pending_records = {}
        state.pending_record_bytes = 0
        if discard_history then
          state.records = {}
          state.record_bytes = 0
          release_buffer_history()
        end
        state.phase = result.status == 'failure' and 'failed' or 'stopped'
        render()
        schedule(function() pcall(request.on_exit, result) end)
        return true
      end

      local function start_runner(task, on_terminal)
        if state.done then return false end
        state.child_generation = state.child_generation + 1
        local token = state.child_generation
        state.child = nil

        local function terminal(err, result)
          if state.done or state.child_generation ~= token then return end
          state.child_generation = state.child_generation + 1
          state.child = nil
          if state.pending_error then
            finish { status = 'failure', error = state.pending_error }
            return
          end
          if state.stop_requested then
            finish { status = 'stopped' }
            return
          end
          on_terminal(err, result)
        end

        local started, child = pcall(runner.start, task, terminal)
        if not started then
          if not state.done and state.child_generation == token then
            state.child_generation = state.child_generation + 1
            finish { status = 'failure', error = failure('runner_start_failed', 'Could not start Android Logcat.', { error = tostring(child) }) }
          end
          return false
        end
        if state.done or state.child_generation ~= token then
          cancel_handle(child)
          return true
        end
        if type(child) ~= 'table' or type(child.cancel) ~= 'function' then
          state.child_generation = state.child_generation + 1
          finish { status = 'failure', error = failure('invalid_operation_handle', 'Android Logcat runner returned an invalid operation handle.') }
          return false
        end
        state.child = child
        return true
      end

      local refresh_uid

      local function schedule_uid_refresh()
        if state.done or state.stop_requested or state.phase ~= 'running' or state.uid_refresh_timer then return end
        state.uid_refresh_timer = defer_fn(function()
          local timer = state.uid_refresh_timer
          state.uid_refresh_timer = nil
          close_timer(timer)
          refresh_uid()
        end, DEFAULT_UID_REFRESH_INTERVAL_MS)
      end

      refresh_uid = function()
        if state.done or state.stop_requested or state.phase ~= 'running' or state.uid_child then return end
        state.uid_query_generation = state.uid_query_generation + 1
        local token = state.uid_query_generation
        local timed_out = false

        local function terminal(err, result)
          if state.done or state.uid_query_generation ~= token then return end
          state.uid_query_generation = state.uid_query_generation + 1
          state.uid_child = nil
          close_timer(state.uid_query_timeout_timer)
          state.uid_query_timeout_timer = nil
          if timed_out or err or not result or result.status ~= 'success' then
            state.uid = nil
          else
            adopt_uid(parse_uid(result.stdout, request.application_id))
          end
          update_winbars()
          schedule_uid_refresh()
        end

        local started, child = pcall(runner.start, {
          argv = {
            adb,
            '-s',
            request.device_serial,
            'shell',
            'cmd',
            'package',
            'list',
            'packages',
            '-U',
            '--user',
            'current',
            request.application_id,
          },
          cwd = request.root,
          name = ('Refresh Logcat package identity for %s'):format(request.application_id),
          metadata = { kind = 'android-logcat-uid', root = request.root, device_serial = request.device_serial },
        }, terminal)
        if not started then
          if not state.done and state.uid_query_generation == token then
            state.uid_query_generation = state.uid_query_generation + 1
            state.uid = nil
            update_winbars()
            schedule_uid_refresh()
          end
          return
        end
        if state.done or state.uid_query_generation ~= token then
          cancel_handle(child)
          return
        end
        if type(child) ~= 'table' or type(child.cancel) ~= 'function' then
          state.uid_query_generation = state.uid_query_generation + 1
          state.uid = nil
          update_winbars()
          schedule_uid_refresh()
          return
        end
        state.uid_child = child
        state.uid_query_timeout_timer = defer_fn(function()
          state.uid_query_timeout_timer = nil
          if state.done or state.uid_query_generation ~= token then return end
          timed_out = true
          state.uid = nil
          update_winbars()
          cancel_handle(state.uid_child)
        end, uid_timeout_ms)
      end

      local function stop_uid_monitor()
        state.uid_query_generation = state.uid_query_generation + 1
        close_timer(state.uid_query_timeout_timer)
        state.uid_query_timeout_timer = nil
        close_timer(state.uid_refresh_timer)
        state.uid_refresh_timer = nil
        cancel_handle(state.uid_child)
        state.uid_child = nil
      end

      local function create_source_index()
        if state.source_index then return state.source_index end
        local index = {}
        local ok, iterator = pcall(vim.fs.dir, request.root, {
          depth = 64,
          follow = false,
          skip = function(relative)
            local name = vim.fs.basename(relative)
            return not SKIP_DIRECTORIES[name]
          end,
        })
        if not ok then
          notify(notifications, 'error', ('Could not index Android sources: %s'):format(iterator))
          state.source_index = index
          return index
        end
        local entries = 0
        for relative, entry_type in iterator do
          entries = entries + 1
          if entries > MAX_SOURCE_ENTRIES then
            notify(notifications, 'warn', 'Android source index is too large; source-frame navigation is disabled for this Logcat session.')
            state.source_index = {}
            return state.source_index
          end
          if entry_type == 'file' and (relative:match '^src/' or relative:find('/src/', 1, true)) then
            local name = vim.fs.basename(relative)
            if name:match '%.kt$' or name:match '%.java$' then
              index[name] = index[name] or {}
              index[name][#index[name] + 1] = vim.fs.joinpath(request.root, relative)
            end
          end
        end
        state.source_index = index
        return index
      end

      local function open_source(path, line)
        local target_win = state.source_win
        if not usable_source_window(target_win) then
          vim.cmd 'aboveleft new'
          target_win = vim.api.nvim_get_current_win()
        else
          vim.api.nvim_set_current_win(target_win)
        end
        state.source_win = target_win
        pcall(vim.cmd, "normal! m'")
        vim.cmd(('edit +%d %s'):format(line, vim.fn.fnameescape(path)))
      end

      local function jump_frame()
        if not state.bufnr or not vim.api.nvim_buf_is_valid(state.bufnr) then return end
        local row = vim.api.nvim_win_get_cursor(0)[1]
        local line = vim.api.nvim_buf_get_lines(state.bufnr, row - 1, row, false)[1]
        local frame = Model.parse_frame(line)
        if not frame then
          notify(notifications, 'warn', 'No source stack frame under the cursor.')
          return
        end
        local index = create_source_index()
        local candidates = Model.best_sources(index[frame.file_name] or {}, frame, {
          project_dir = request.project_dir,
          variant = request.variant,
        })
        if #candidates == 0 then
          notify(notifications, 'warn', ('Could not resolve %s inside %s.'):format(frame.file_name, request.root))
          return
        end
        if #candidates == 1 then
          open_source(candidates[1], frame.line)
          return
        end

        local started, picker_handle = pcall(picker.select, {
          prompt = ('Source for %s'):format(frame.file_name),
          items = candidates,
          current = nil,
          format_item = function(path) return relative_label(request.root, path) end,
        }, function(err, path)
          state.picker_handle = nil
          if state.done then return end
          if err then
            notify(notifications, 'error', tostring(type(err) == 'table' and (err.message or err.code) or err))
          elseif path then
            open_source(path, frame.line)
          end
        end)
        if not started then
          notify(notifications, 'error', ('Could not open source picker: %s'):format(picker_handle))
        else
          state.picker_handle = picker_handle
        end
      end

      local function move_frame(direction)
        if not state.bufnr or not vim.api.nvim_buf_is_valid(state.bufnr) then return end
        local current = vim.api.nvim_win_get_cursor(0)[1]
        local count = vim.api.nvim_buf_line_count(state.bufnr)
        local row = current + direction
        while row >= 1 and row <= count do
          local line = vim.api.nvim_buf_get_lines(state.bufnr, row - 1, row, false)[1]
          if Model.parse_frame(line) then
            vim.api.nvim_win_set_cursor(0, { row, 0 })
            return
          end
          row = row + direction
        end
        notify(notifications, 'info', direction > 0 and 'No later source frame.' or 'No earlier source frame.')
      end

      local function choose_level()
        local levels = Model.levels()
        local started, picker_handle = pcall(picker.select, {
          prompt = 'Minimum Logcat level',
          items = levels,
          current = state.filters.level,
          format_item = function(level) return level:upper() end,
        }, function(err, level)
          state.picker_handle = nil
          if state.done then return end
          if err then
            notify(notifications, 'error', tostring(type(err) == 'table' and (err.message or err.code) or err))
          elseif level then
            state.filters.level = level
            render()
          end
        end)
        if not started then
          notify(notifications, 'error', ('Could not open Logcat level picker: %s'):format(picker_handle))
        else
          state.picker_handle = picker_handle
        end
      end

      local function choose_text(kind)
        local current = state.filters[kind]
        local prompt = kind == 'tag' and 'Logcat tag contains: ' or 'Logcat message contains: '
        local ok, err = pcall(input, { prompt = prompt, default = current or '' }, function(value)
          if state.done or value == nil then return end
          value = vim.trim(value)
          state.filters[kind] = value ~= '' and value or nil
          render()
        end)
        if not ok then notify(notifications, 'error', ('Could not open Logcat filter input: %s'):format(err)) end
      end

      local function choose_session()
        if state.done or state.stop_requested or state.session_picker_active then return end
        state.session_picker_generation = state.session_picker_generation + 1
        local token = state.session_picker_generation
        state.session_picker_active = true
        local completed = false
        local started, picker_handle = pcall(request.select_logcat_session, function()
          if state.done or state.session_picker_generation ~= token then return end
          completed = true
          state.session_picker_active = false
          state.session_picker_handle = nil
        end)
        if not started then
          if state.session_picker_generation == token then
            state.session_picker_generation = state.session_picker_generation + 1
            state.session_picker_active = false
          end
          notify(notifications, 'error', ('Could not open Logcat session picker: %s'):format(picker_handle))
        elseif completed then
          cancel_handle(picker_handle)
          return
        elseif state.done or state.session_picker_generation ~= token then
          cancel_handle(picker_handle)
        elseif type(picker_handle) ~= 'table' or type(picker_handle.cancel) ~= 'function' then
          state.session_picker_generation = state.session_picker_generation + 1
          state.session_picker_active = false
          notify(notifications, 'error', 'Could not open Logcat session picker: selector returned an invalid handle')
        else
          state.session_picker_handle = picker_handle
        end
      end

      local function hide()
        local winid = vim.api.nvim_get_current_win()
        if vim.api.nvim_win_get_buf(winid) == state.bufnr and #vim.api.nvim_list_wins() > 1 then pcall(vim.api.nvim_win_close, winid, false) end
      end

      local function shortcut_lines()
        local filters = state.filters
        return {
          (' app     %s'):format(request.application_id),
          (' device  %s'):format(request.device_serial),
          (' uid     %s'):format(state.uid or 'resolving'),
          (' state   %s'):format(status_label()),
          '',
          ' ?       Show this shortcut help',
          ' p       Pause or resume rendering',
          ' f       Toggle following the newest line',
          ' c       Clear the local view',
          ' S       Select another Logcat session',
          ' l       Choose the minimum level',
          ' t       Filter by tag text',
          ' /       Filter by message text',
          ' x       Reset all filters',
          ' <CR>/gf Open the source frame under the cursor',
          ' [f/]f   Move to the previous or next source frame',
          ' s       Stop this Logcat stream',
          ' q       Hide the Logcat window',
          '',
          (' level≥%s · tag=%s · text=%s · follow=%s'):format(
            filters.level:upper(),
            filters.tag or '*',
            filters.text or '*',
            state.follow and 'on' or 'off'
          ),
        }
      end

      local function show_shortcuts()
        if state.done then return end
        if state.help_win and vim.api.nvim_win_is_valid(state.help_win) then
          vim.api.nvim_set_current_win(state.help_win)
          return
        end
        close_help()

        local lines = shortcut_lines()
        local width = 1
        for _, line in ipairs(lines) do
          width = math.max(width, vim.fn.strdisplaywidth(line))
        end
        width = math.min(width, math.max(1, vim.o.columns - 4))
        local height = math.min(#lines, math.max(1, vim.o.lines - vim.o.cmdheight - 4))
        local bufnr = vim.api.nvim_create_buf(false, true)
        state.help_bufnr = bufnr
        pcall(vim.api.nvim_buf_set_name, bufnr, ('android-logcat-help://%d'):format(bufnr))
        vim.bo[bufnr].buftype = 'nofile'
        vim.bo[bufnr].bufhidden = 'wipe'
        vim.bo[bufnr].swapfile = false
        vim.bo[bufnr].undofile = false
        vim.bo[bufnr].modeline = false
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
        vim.bo[bufnr].modifiable = false
        vim.bo[bufnr].readonly = true

        local close_opts = { buffer = bufnr, silent = true, desc = 'Close Logcat shortcuts' }
        for _, lhs in ipairs { 'q', '<Esc>', '?' } do
          vim.keymap.set('n', lhs, close_help, close_opts)
        end
        vim.api.nvim_create_autocmd('BufWipeout', {
          buffer = bufnr,
          once = true,
          callback = function(args)
            if state.help_bufnr == args.buf then
              state.help_bufnr = nil
              state.help_win = nil
            end
          end,
        })

        local opened, winid = pcall(vim.api.nvim_open_win, bufnr, true, {
          relative = 'editor',
          row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
          col = math.max(0, math.floor((vim.o.columns - width) / 2)),
          width = width,
          height = height,
          style = 'minimal',
          border = 'rounded',
          title = ' Android Logcat shortcuts ',
          title_pos = 'center',
        })
        if not opened then
          close_help()
          notify(notifications, 'error', ('Could not open Logcat shortcuts: %s'):format(winid))
          return
        end
        state.help_win = winid
        vim.wo[winid].cursorline = true
        vim.wo[winid].wrap = false
        vim.bo[bufnr].filetype = 'androidlogcathelp'
      end

      local function install_buffer()
        local bufnr = vim.api.nvim_create_buf(false, true)
        state.bufnr = bufnr
        session_buffers[bufnr] = true
        local name = vim.fn.sha256(request.root .. '\0' .. request.device_serial .. '\0' .. request.application_id)
        vim.api.nvim_buf_set_name(bufnr, ('android-logcat://%s/%d'):format(name, bufnr))
        vim.bo[bufnr].buftype = 'nofile'
        vim.bo[bufnr].bufhidden = 'hide'
        vim.bo[bufnr].swapfile = false
        vim.bo[bufnr].undofile = false
        vim.bo[bufnr].undolevels = -1
        vim.bo[bufnr].modeline = false
        vim.bo[bufnr].modifiable = false
        vim.bo[bufnr].readonly = true

        local map_opts = { buffer = bufnr, silent = true }
        vim.keymap.set('n', 'p', function()
          state.paused = not state.paused
          render()
        end, vim.tbl_extend('force', map_opts, { desc = 'Pause/resume Logcat rendering' }))
        vim.keymap.set('n', 'f', function()
          state.follow = not state.follow
          update_winbars()
          follow_tail()
        end, vim.tbl_extend('force', map_opts, { desc = 'Toggle Logcat follow' }))
        vim.keymap.set('n', 'c', function()
          close_private_history(true)
          state.discarding_gap = state.discarding_gap or state.partial ~= ''
          state.discarding_cr = false
          state.partial = ''
          state.previous = nil
          render()
        end, vim.tbl_extend('force', map_opts, { desc = 'Clear local Logcat view' }))
        vim.keymap.set('n', 'S', choose_session, vim.tbl_extend('force', map_opts, { desc = 'Select Logcat session' }))
        vim.keymap.set('n', 'l', choose_level, vim.tbl_extend('force', map_opts, { desc = 'Set minimum Logcat level' }))
        vim.keymap.set('n', 't', function() choose_text 'tag' end, vim.tbl_extend('force', map_opts, { desc = 'Filter Logcat tags' }))
        vim.keymap.set('n', '/', function() choose_text 'text' end, vim.tbl_extend('force', map_opts, { desc = 'Filter Logcat messages' }))
        vim.keymap.set('n', 'x', function()
          state.filters = { level = 'verbose', tag = nil, text = nil }
          render()
        end, vim.tbl_extend('force', map_opts, { desc = 'Reset Logcat filters' }))
        vim.keymap.set('n', '<CR>', jump_frame, vim.tbl_extend('force', map_opts, { desc = 'Open Logcat source frame' }))
        vim.keymap.set('n', 'gf', jump_frame, vim.tbl_extend('force', map_opts, { desc = 'Open Logcat source frame' }))
        vim.keymap.set('n', ']f', function() move_frame(1) end, vim.tbl_extend('force', map_opts, { desc = 'Next Logcat source frame' }))
        vim.keymap.set('n', '[f', function() move_frame(-1) end, vim.tbl_extend('force', map_opts, { desc = 'Previous Logcat source frame' }))
        vim.keymap.set('n', 's', function() handle:stop() end, vim.tbl_extend('force', map_opts, { desc = 'Stop Logcat' }))
        vim.keymap.set('n', 'q', hide, vim.tbl_extend('force', map_opts, { desc = 'Hide Logcat' }))
        vim.keymap.set('n', '?', show_shortcuts, vim.tbl_extend('force', map_opts, { desc = 'Show Logcat shortcuts' }))

        vim.api.nvim_create_autocmd('BufWinEnter', {
          buffer = bufnr,
          callback = function()
            enter_visible()
            update_winbars()
          end,
        })
        vim.api.nvim_create_autocmd('BufHidden', { buffer = bufnr, callback = enter_hidden })
        vim.api.nvim_create_autocmd('BufWipeout', {
          buffer = bufnr,
          once = true,
          callback = function(args)
            session_buffers[args.buf] = nil
            if dock.win and vim.api.nvim_win_is_valid(dock.win) then
              local ok, dock_bufnr = pcall(vim.api.nvim_win_get_buf, dock.win)
              if ok and dock_bufnr == args.buf then dock.win = nil end
            end
            close_help()
            handle:_abandon()
            handle:stop()
          end,
        })
        vim.bo[bufnr].filetype = 'androidlogcat'
        render()
      end

      function handle:show(show_opts)
        show_opts = show_opts or {}
        if not state.bufnr or not vim.api.nvim_buf_is_valid(state.bufnr) then return false end
        local windows = buffer_windows(state.bufnr)
        if #windows > 0 then
          enter_visible()
          update_winbars()
          if show_opts.focus ~= false then vim.api.nvim_set_current_win(windows[1]) end
          return true
        end

        local origin = vim.api.nvim_get_current_win()
        if usable_source_window(origin) then dock.source_win = origin end
        if usable_source_window(dock.source_win) then state.source_win = dock.source_win end
        local log_win = owned_dock_window()
        if log_win then
          vim.api.nvim_win_set_buf(log_win, state.bufnr)
        else
          vim.cmd(('botright %dsplit'):format(height))
          log_win = vim.api.nvim_get_current_win()
          dock.win = log_win
          vim.api.nvim_win_set_buf(log_win, state.bufnr)
        end
        enter_visible()
        vim.wo[log_win].winfixheight = true
        if show_opts.focus ~= false then vim.api.nvim_set_current_win(log_win) end
        update_winbars()
        if show_opts.focus == false and vim.api.nvim_win_is_valid(origin) then vim.api.nvim_set_current_win(origin) end
        follow_tail()
        return true
      end

      function handle:stop()
        if state.done or state.stop_requested then return false end
        local previous_phase = state.phase
        state.stop_requested = true
        state.phase = 'stopping'
        update_winbars()
        if state.child then
          local cancelled, result = pcall(state.child.cancel, state.child)
          if not cancelled or result == false then
            state.stop_requested = false
            state.phase = previous_phase
            update_winbars()
            return false
          end
          stop_uid_monitor()
          if state.hidden then close_private_history(true) end
          close_help()
          cancel_session_picker()
        else
          stop_uid_monitor()
          finish { status = 'stopped' }
        end
        return true
      end

      function handle:_abandon()
        if state.discard_history then return false end
        state.discard_history = true
        close_help()
        cancel_session_picker()
        close_private_history(true)
        return true
      end

      function handle:status()
        local spool_status = state.spool and state.spool:status()
          or { records = 0, raw_bytes = 0, storage_bytes = 0, pending_bytes = 0, files = 0, pathnames = 0, mode = nil }
        return {
          phase = state.phase,
          paused = state.paused,
          follow = state.follow,
          records = #state.records + spool_status.records,
          retained_bytes = state.record_bytes + spool_status.raw_bytes,
          pending_records = #state.pending_records,
          pending_bytes = state.pending_record_bytes,
          in_memory_records = #state.records,
          storage = state.restoring and 'restoring' or (state.hidden and not state.spool_failed and 'disk' or 'memory'),
          spool_files = spool_status.files,
          spool_pathnames = spool_status.pathnames,
          spool_pending_bytes = spool_status.pending_bytes,
          spool_storage_bytes = spool_status.storage_bytes,
          spool_mode = spool_status.mode,
          source_indexed = state.source_index ~= nil,
          filters = vim.deepcopy(state.filters),
          bufnr = state.bufnr,
          uid = state.uid,
        }
      end

      install_buffer()
      handle:show { focus = request.focus ~= false }

      state.phase = 'resolving-app'
      update_winbars()
      state.timer = defer_fn(function()
        state.timer = nil
        if state.done or state.phase ~= 'resolving-app' then return end
        state.pending_error =
          failure('uid_query_timeout', ('Resolving %s on %s timed out after %d ms.'):format(request.application_id, request.device_serial, uid_timeout_ms))
        state.phase = 'stopping'
        update_winbars()
        if state.child then
          local cancelled, result = pcall(state.child.cancel, state.child)
          if not cancelled or result == false then
            notify(notifications, 'error', 'Could not cancel the timed-out Logcat UID query; waiting for it to exit.')
          end
        else
          finish { status = 'failure', error = state.pending_error }
        end
      end, uid_timeout_ms)
      start_runner({
        argv = {
          adb,
          '-s',
          request.device_serial,
          'shell',
          'cmd',
          'package',
          'list',
          'packages',
          '-U',
          '--user',
          'current',
          request.application_id,
        },
        cwd = request.root,
        name = ('Resolve Logcat UID for %s'):format(request.application_id),
        metadata = { kind = 'android-logcat-uid', root = request.root, device_serial = request.device_serial },
      }, function(err, result)
        close_timer(state.timer)
        state.timer = nil
        if state.done then return end
        if err or not result or result.status ~= 'success' then
          finish {
            status = 'failure',
            error = err or failure('uid_query_failed', ('Could not resolve the installed UID for %s.'):format(request.application_id), result),
          }
          return
        end
        local uid, uid_err = parse_uid(result.stdout, request.application_id)
        if not uid then
          finish { status = 'failure', error = uid_err }
          return
        end

        state.uid = uid
        state.phase = 'running'
        render()
        local stream_argv = {
          adb,
          '-s',
          request.device_serial,
          'logcat',
          '-b',
          'main,system,crash',
          '-v',
          'threadtime,year,uid,printable',
        }
        if initial_lines then
          stream_argv[#stream_argv + 1] = '-T'
          stream_argv[#stream_argv + 1] = tostring(initial_lines)
        end
        stream_argv[#stream_argv + 1] = '*:V'
        local stream_started = start_runner({
          argv = stream_argv,
          cwd = request.root,
          name = ('Logcat %s on %s'):format(request.application_id, request.device_serial),
          metadata = {
            kind = 'android-logcat',
            root = request.root,
            application_id = request.application_id,
            device_serial = request.device_serial,
          },
          on_output = function(event)
            if event.stream ~= 'stdout' then return end
            if event.truncated then
              state.discarding_cr = false
              consume_after_gap(event.data)
            elseif state.discarding_gap then
              consume_after_gap(event.data)
            else
              consume(event.data)
            end
          end,
        }, function(stream_err, stream_result)
          if state.done then return end
          if stream_result and stream_result.status == 'cancelled' then
            finish { status = 'stopped' }
            return
          end
          local details = stream_err or stream_result
          finish {
            status = 'failure',
            error = stream_err or failure('logcat_stopped', 'Android Logcat stopped unexpectedly.', details),
          }
        end)
        if stream_started and not state.done then schedule_uid_refresh() end
      end)

      return handle
    end,
  }
end

return M

-- vim: ts=2 sts=2 sw=2 et
