local M = {}

local Spool = {}
Spool.__index = Spool

local function close_fd(uv, fd)
  if fd then pcall(uv.fs_close, fd) end
end

local function set_values(values)
  local result = {}
  for value in pairs(values) do
    result[#result + 1] = value
  end
  return result
end

function Spool:_close_segment(segment)
  if not segment or not segment.fd then return end
  close_fd(self.uv, segment.fd)
  segment.fd = nil
  self.open_files = math.max(0, self.open_files - 1)
  self.all_segments[segment] = nil
end

function Spool:_open_segment()
  local path = self.tempname()
  if type(path) ~= 'string' or path == '' then return nil, 'temporary path provider returned no path' end
  local fd, open_err = self.uv.fs_open(path, 'wx+', 384)
  if not fd then return nil, tostring(open_err or 'could not open temporary history') end
  local unlinked, unlink_err = self.uv.fs_unlink(path)
  if not unlinked then
    close_fd(self.uv, fd)
    return nil, tostring(unlink_err or 'could not unlink temporary history')
  end
  local stat, stat_err = self.uv.fs_fstat(fd)
  if not stat then
    close_fd(self.uv, fd)
    return nil, tostring(stat_err or 'could not inspect temporary history')
  end
  local segment = {
    fd = fd,
    count = 0,
    raw_bytes = 0,
    payload_bytes = 0,
    written_bytes = 0,
    pending = {},
    pending_bytes = 0,
    queued = false,
    writing = false,
    reading = false,
    retired = false,
    mode = stat.mode % 512,
  }
  self.open_files = self.open_files + 1
  self.all_segments[segment] = true
  return segment
end

function Spool:_drop_pending(segment)
  self.pending_bytes = math.max(0, self.pending_bytes - segment.pending_bytes)
  segment.pending = {}
  segment.pending_bytes = 0
  segment.queued = false
end

function Spool:_retire(segment)
  if not segment then return end
  if not segment.retired then
    segment.retired = true
    self:_drop_pending(segment)
  end
  if not segment.writing and not segment.reading then self:_close_segment(segment) end
end

function Spool:_evict_oldest()
  local segment = table.remove(self.segments, 1)
  if not segment then return false end
  self.records = math.max(0, self.records - segment.count)
  self.raw_bytes = math.max(0, self.raw_bytes - segment.raw_bytes)
  self.payload_bytes = math.max(0, self.payload_bytes - segment.payload_bytes)
  self:_retire(segment)
  return true
end

function Spool:_queue_segment(segment)
  if self.closed or segment.retired or segment.queued or segment.writing or segment.pending_bytes == 0 then return end
  segment.queued = true
  self.write_queue[#self.write_queue + 1] = segment
end

function Spool:_deliver(callback, err, entries)
  self.schedule(function() callback(err, entries) end)
end

function Spool:_finish_read(err, entries)
  if self.read_finished then return end
  self.read_finished = true
  local callback = self.read_callback
  self.read_callback = nil
  self.closed = true
  self.records = 0
  self.raw_bytes = 0
  self.payload_bytes = 0
  self.pending_bytes = 0
  self.write_queue = {}
  self.segments = {}
  for _, segment in ipairs(set_values(self.all_segments)) do
    if not segment.writing and not segment.reading then self:_close_segment(segment) end
  end
  if callback then self:_deliver(callback, err, entries) end
end

function Spool:_read_segment(segments, index, entries, segment, offset, chunks)
  if self.closed or self.read_finished then return end
  local remaining = segment.written_bytes - offset
  if remaining == 0 then
    segment.reading = false
    local data = table.concat(chunks)
    local consumed = 0
    for value in data:gmatch '(.-)\n' do
      consumed = consumed + #value + 1
      entries[#entries + 1] = value
    end
    self:_close_segment(segment)
    if consumed ~= #data then
      self:_finish_read('temporary history ended with an incomplete record', nil)
      return
    end
    self:_read_next(segments, index + 1, entries)
    return
  end
  self.uv.fs_read(segment.fd, remaining, offset, function(err, data)
    if self.closed or self.read_finished then
      segment.reading = false
      self:_close_segment(segment)
      return
    end
    if err or type(data) ~= 'string' or data == '' then
      segment.reading = false
      self:_close_segment(segment)
      self:_finish_read(tostring(err or 'could not read temporary history'), nil)
      return
    end
    chunks[#chunks + 1] = data
    self:_read_segment(segments, index, entries, segment, offset + #data, chunks)
  end)
end

function Spool:_read_next(segments, index, entries)
  if self.closed or self.read_finished then return end
  local segment = segments[index]
  if not segment then
    self:_finish_read(nil, entries)
    return
  end
  segment.reading = true
  self:_read_segment(segments, index, entries, segment, 0, {})
end

function Spool:_begin_read()
  if self.closed or self.read_started or self.writing then return end
  for _, segment in ipairs(self.segments) do
    if segment.pending_bytes > 0 or segment.queued or segment.writing then return end
  end
  self.read_started = true
  if self.error then
    self:_finish_read(self.error, nil)
    return
  end
  local segments = {}
  for _, segment in ipairs(self.segments) do
    segments[#segments + 1] = segment
  end
  self:_read_next(segments, 1, {})
end

function Spool:_pump()
  if self.writing then return end
  if self.closed then
    for _, segment in ipairs(self.write_queue) do
      segment.queued = false
      self:_retire(segment)
    end
    self.write_queue = {}
    return
  end
  while #self.write_queue > 0 do
    local segment = table.remove(self.write_queue, 1)
    segment.queued = false
    if not segment.retired and segment.fd and segment.pending_bytes > 0 then
      local data = table.concat(segment.pending)
      local data_bytes = #data
      segment.pending = {}
      segment.pending_bytes = 0
      self.pending_bytes = math.max(0, self.pending_bytes - data_bytes)
      segment.writing = true
      self.writing = segment
      self.inflight_bytes = data_bytes
      local offset = segment.written_bytes
      self.uv.fs_write(segment.fd, data, offset, function(err, written)
        segment.writing = false
        self.writing = nil
        self.inflight_bytes = 0
        if not err and type(written) == 'number' and written > 0 then segment.written_bytes = segment.written_bytes + written end
        if err or type(written) ~= 'number' or written <= 0 then
          self.error = tostring(err or 'could not write temporary history')
        elseif written < data_bytes and not segment.retired and not self.closed then
          local remaining = data:sub(written + 1)
          table.insert(segment.pending, 1, remaining)
          segment.pending_bytes = segment.pending_bytes + #remaining
          self.pending_bytes = self.pending_bytes + #remaining
        end
        if segment.retired or self.closed or self.error then
          self:_retire(segment)
        else
          self:_queue_segment(segment)
        end
        self:_pump()
        if self.reading then self:_begin_read() end
      end)
      return
    end
    if segment.retired then self:_close_segment(segment) end
  end
  if self.reading then self:_begin_read() end
end

function Spool:append(entries)
  if self.closed or self.reading then return 0, 'temporary history is not writable' end
  local accepted = 0
  for _, entry in ipairs(entries) do
    if type(entry) ~= 'table' or type(entry.data) ~= 'string' or type(entry.raw_bytes) ~= 'number' then
      return accepted, 'temporary history received an invalid record'
    end
    local payload_bytes = #entry.data + 1
    if entry.raw_bytes <= self.max_bytes and payload_bytes <= self.max_payload_bytes then
      local segment = self.segments[#self.segments]
      if
        not segment
        or (segment.count > 0 and (segment.count + 1 > self.segment_records or segment.raw_bytes + entry.raw_bytes > self.segment_bytes))
        or (segment.count > 0 and segment.payload_bytes + payload_bytes > self.segment_payload_bytes)
      then
        local opened, open_err = self:_open_segment()
        if not opened then return accepted, open_err end
        segment = opened
        self.segments[#self.segments + 1] = segment
      end
      segment.count = segment.count + 1
      segment.raw_bytes = segment.raw_bytes + entry.raw_bytes
      segment.payload_bytes = segment.payload_bytes + payload_bytes
      segment.pending[#segment.pending + 1] = entry.data .. '\n'
      segment.pending_bytes = segment.pending_bytes + payload_bytes
      self.records = self.records + 1
      self.raw_bytes = self.raw_bytes + entry.raw_bytes
      self.payload_bytes = self.payload_bytes + payload_bytes
      self.pending_bytes = self.pending_bytes + payload_bytes
      self:_queue_segment(segment)
      while #self.segments > 2 or self.records > self.max_records or self.raw_bytes > self.max_bytes or self.payload_bytes > self.max_payload_bytes do
        if not self:_evict_oldest() then break end
      end
      self:_pump()
    else
      while self:_evict_oldest() do
      end
    end
    accepted = accepted + 1
  end
  return accepted
end

function Spool:read_all(callback)
  if type(callback) ~= 'function' or self.closed or self.reading then return false end
  self.reading = true
  self.read_callback = callback
  self:_pump()
  self:_begin_read()
  return true
end

function Spool:close()
  if self.closed then return false end
  self.closed = true
  self.read_callback = nil
  self.write_queue = {}
  self.records = 0
  self.raw_bytes = 0
  self.payload_bytes = 0
  self.pending_bytes = 0
  for _, segment in ipairs(set_values(self.all_segments)) do
    self:_drop_pending(segment)
    segment.retired = true
    if not segment.writing and not segment.reading then self:_close_segment(segment) end
  end
  return true
end

function Spool:status()
  local mode
  for segment in pairs(self.all_segments) do
    mode = segment.mode
    break
  end
  return {
    records = self.records,
    raw_bytes = self.raw_bytes,
    storage_bytes = self.payload_bytes,
    pending_bytes = self.pending_bytes + self.inflight_bytes,
    files = self.open_files,
    pathnames = 0,
    mode = mode,
  }
end

function M.new(opts)
  opts = opts or {}
  local max_records = assert(tonumber(opts.max_records), 'temporary history requires max_records')
  local max_bytes = assert(tonumber(opts.max_bytes), 'temporary history requires max_bytes')
  local max_payload_bytes = tonumber(opts.max_payload_bytes) or max_bytes * 6 + max_records * 256
  return setmetatable({
    uv = opts.uv or vim.uv,
    tempname = opts.tempname or vim.fn.tempname,
    schedule = opts.schedule or vim.schedule,
    max_records = max_records,
    max_bytes = max_bytes,
    max_payload_bytes = max_payload_bytes,
    segment_records = math.max(1, math.floor(max_records / 2)),
    segment_bytes = math.max(1, math.floor(max_bytes / 2)),
    segment_payload_bytes = math.max(1, math.floor(max_payload_bytes / 2)),
    segments = {},
    all_segments = {},
    write_queue = {},
    records = 0,
    raw_bytes = 0,
    payload_bytes = 0,
    pending_bytes = 0,
    inflight_bytes = 0,
    open_files = 0,
    writing = nil,
    reading = false,
    read_started = false,
    read_finished = false,
    read_callback = nil,
    error = nil,
    closed = false,
  }, Spool)
end

return M

-- vim: ts=2 sts=2 sw=2 et
