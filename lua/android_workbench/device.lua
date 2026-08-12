local M = {}

local MAX_DEVICES = 1024

local Device = {}
Device.__index = Device

local function workbench_error(code, message, root, details)
  return {
    code = code,
    message = message,
    root = root,
    details = details,
  }
end

local function raw_string(value, field)
  if type(value) ~= 'table' then return nil end
  local result = rawget(value, field)
  return type(result) == 'string' and result or nil
end

local function valid_identity(value) return type(value) == 'string' and value ~= '' and #value <= 1024 and not value:find '[%s%c]' end
local function valid_serial(value) return type(value) == 'string' and value ~= '' and #value <= 1024 and not value:find '%c' end

local function normalize_error(err, root, code, message)
  if type(err) == 'table' and type(rawget(err, 'code')) == 'string' and type(rawget(err, 'message')) == 'string' then return err end
  return workbench_error(code or 'device_operation_failed', message or 'Android device operation failed.', root, err == nil and nil or tostring(err))
end

local function cancel_handle(handle)
  if type(handle) ~= 'table' or type(handle.cancel) ~= 'function' then return false end
  local called, accepted = pcall(handle.cancel, handle)
  return called and accepted ~= false
end

local function new_operation(root, callback)
  local operation = {
    child = nil,
    done = false,
    cancelling = false,
    generation = 0,
  }

  function operation:finish(err, value)
    if self.done then return false end
    self.done = true
    self.generation = self.generation + 1
    self.child = nil
    if err ~= nil then err = normalize_error(err, root) end
    callback(err, value)
    return true
  end

  function operation:start_child(starter, on_terminal, start_error)
    if self.done or self.cancelling then return false end
    self.generation = self.generation + 1
    local token = self.generation
    self.child = nil

    local function terminal(err, value)
      if self.done or self.generation ~= token then return end
      self.generation = self.generation + 1
      self.child = nil

      if self.cancelling then
        if err ~= nil and not (type(err) == 'table' and rawget(err, 'code') == 'cancelled') then
          self:finish(err)
        else
          self:finish(workbench_error('cancelled', 'Android device operation was cancelled.', root))
        end
        return
      end

      local completed, thrown = xpcall(function() on_terminal(err, value) end, debug.traceback)
      if not completed and not self.done then
        self:finish(workbench_error('device_operation_failed', 'Android device operation failed.', root, tostring(thrown)))
      end
    end

    local started, handle = pcall(starter, terminal)
    if not started then
      if self.done or self.generation ~= token then return false end
      self.generation = self.generation + 1
      self:finish(
        start_error and start_error(handle) or workbench_error('adapter_failed', 'Could not start an Android device operation.', root, tostring(handle))
      )
      return false
    end

    if self.done or self.generation ~= token then
      cancel_handle(handle)
      return true
    end
    if handle ~= nil and (type(handle) ~= 'table' or type(handle.cancel) ~= 'function') then
      self.generation = self.generation + 1
      self:finish(workbench_error('invalid_operation_handle', 'An Android device adapter returned an invalid operation handle.', root))
      return false
    end
    self.child = handle
    return true
  end

  function operation:cancel()
    if self.done or self.cancelling then return false end
    self.cancelling = true
    local child = self.child
    if child == nil then
      self.cancelling = false
      return false
    end
    local accepted = cancel_handle(child)
    if self.done then return true end
    if not accepted then
      self.cancelling = false
      return false
    end
    return true
  end

  return operation
end

local function sequence(value)
  if type(value) ~= 'table' then return nil end
  local count, maximum = 0, 0
  for key in next, value do
    if type(key) ~= 'number' or key < 1 or key % 1 ~= 0 then return nil end
    count = count + 1
    maximum = math.max(maximum, key)
  end
  if count ~= maximum then return nil end
  local result = {}
  for index = 1, maximum do
    result[index] = rawget(value, index)
  end
  return result
end

local function stored_device(device)
  if type(device) ~= 'table' then return nil end
  local serial = raw_string(device, 'serial')
  local avd_name = raw_string(device, 'avd_name')
  if avd_name ~= nil then
    if not valid_identity(avd_name) or (serial ~= nil and not valid_serial(serial)) then return nil end
    return {
      avd_name = avd_name,
      serial = serial,
    }
  end
  if not valid_serial(serial) then return nil end
  return { serial = serial }
end

local function same_stored_device(left, right)
  if left == nil or right == nil then return left == right end
  local stored_left = stored_device(left)
  local stored_right = stored_device(right)
  if not stored_left or not stored_right then return false end
  return stored_left.serial == stored_right.serial and stored_left.avd_name == stored_right.avd_name
end

local function runtime_device(value, expected_serial, expected_avd, root)
  if type(value) ~= 'table' then return nil, workbench_error('invalid_device_result', 'Android device validation returned an invalid device.', root) end
  local serial = raw_string(value, 'serial')
  local state = raw_string(value, 'state')
  local avd_name = raw_string(value, 'avd_name')
  if not valid_serial(serial) or state ~= 'online' or (avd_name ~= nil and not valid_identity(avd_name)) then
    return nil,
      workbench_error('invalid_device_result', 'Android device validation did not return an online device.', root, {
        serial = serial,
        state = state,
      })
  end
  if expected_serial ~= nil and serial ~= expected_serial then
    return nil,
      workbench_error('device_changed', ('Android device validation returned a different device for %s.'):format(expected_serial), root, {
        requested_serial = expected_serial,
        returned_serial = serial,
      })
  end
  if expected_avd ~= nil and avd_name ~= expected_avd then
    return nil,
      workbench_error('device_changed', ('Android emulator %s changed identity during validation.'):format(expected_avd), root, {
        remembered_avd = expected_avd,
        current_avd = avd_name,
      })
  end
  if expected_avd == nil and avd_name ~= nil then
    return nil, workbench_error('device_changed', ('Android device %s is now an emulator. Select the Android device again.'):format(serial), root)
  end

  return {
    serial = serial,
    avd_name = avd_name,
    state = 'online',
    raw_state = raw_string(value, 'raw_state'),
    label = raw_string(value, 'label') or avd_name or serial,
    details = raw_string(value, 'details'),
  }
end

local function stopped_avd(avd_name, label)
  return {
    avd_name = avd_name,
    state = 'stopped',
    label = label or avd_name,
  }
end

local function stopped_resource(avd_name, label)
  local resource = stopped_avd(avd_name, label)
  resource.id = 'avd:' .. avd_name
  return resource
end

local function resource_label(resource)
  if resource.avd_name then
    if resource.serial then return ('%s (running: %s)'):format(resource.label or resource.avd_name, resource.serial) end
    return ('%s (stopped)'):format(resource.label or resource.avd_name)
  end
  if resource.label and resource.label ~= resource.serial then return ('%s (%s)'):format(resource.label, resource.serial) end
  return resource.serial
end

local function selected_resource(resources, selected)
  if not selected then return nil end
  for _, resource in ipairs(resources) do
    if selected.avd_name ~= nil then
      if resource.avd_name == selected.avd_name then return resource end
    elseif resource.avd_name == nil and resource.serial == selected.serial then
      return resource
    end
  end
end

local function read_selection(session)
  local called, selection = pcall(session.selection, session)
  if not called or type(selection) ~= 'table' then
    return nil, workbench_error('state_read_failed', 'Could not read the selected Android device.', session.root, called and nil or tostring(selection))
  end
  local device = rawget(selection, 'device')
  if device == nil then return nil end
  local stored = stored_device(device)
  if not stored then return nil, workbench_error('state_invalid', 'The selected Android device has an invalid stable identity.', session.root) end
  return stored
end

local function write_selection(session, expected, requested)
  local current, read_err = read_selection(session)
  if read_err then return nil, read_err end
  if not same_stored_device(current, expected) then
    return nil, workbench_error('device_changed', 'The selected Android device changed during the operation. Retry the action.', session.root)
  end
  if same_stored_device(current, requested) then return true end

  local called, saved, save_err = pcall(session.set_device_selection, session, requested)
  if not called then return nil, workbench_error('state_write_failed', 'Could not save the selected Android device.', session.root, tostring(saved)) end
  if not saved then return nil, normalize_error(save_err, session.root, 'state_write_failed', 'Could not save the selected Android device.') end
  return true
end

local function validate_device_rows(value, root)
  local rows = sequence(value)
  if not rows or #rows > MAX_DEVICES then return nil, workbench_error('invalid_devices_result', 'ADB returned an invalid device list.', root) end
  local result, serials = {}, {}
  for _, row in ipairs(rows) do
    local serial = raw_string(row, 'serial')
    local state = raw_string(row, 'state')
    if not valid_serial(serial) or state == nil or state == '' then
      return nil, workbench_error('invalid_devices_result', 'ADB returned an invalid device entry.', root)
    end
    if serials[serial] then
      return nil, workbench_error('invalid_devices_result', 'ADB returned the same device serial more than once.', root, { serial = serial })
    end
    serials[serial] = true
    result[#result + 1] = {
      serial = serial,
      state = state,
      raw_state = raw_string(row, 'raw_state'),
      label = raw_string(row, 'label') or serial,
      details = raw_string(row, 'details'),
    }
  end
  return result
end

local function validate_avd_rows(value, root)
  local rows = sequence(value)
  if not rows then return nil, workbench_error('invalid_avds_result', 'The emulator service returned an invalid AVD list.', root) end
  local result, names = {}, {}
  for _, row in ipairs(rows) do
    local avd_name = raw_string(row, 'avd_name')
    local label = raw_string(row, 'label')
    if not valid_identity(avd_name) or (label ~= nil and label == '') then
      return nil, workbench_error('invalid_avds_result', 'The emulator service returned an invalid AVD entry.', root)
    end
    if names[avd_name] then
      return nil, workbench_error('invalid_avds_result', 'The emulator service returned the same AVD more than once.', root, { avd_name = avd_name })
    end
    names[avd_name] = true
    result[#result + 1] = { avd_name = avd_name, label = label or avd_name }
  end
  return result
end

---@param opts { adb: table, emulator: table, picker: table }
---@return table
function M.new(opts)
  assert(type(opts) == 'table', 'android_workbench.device.new requires options')
  assert(
    type(opts.adb) == 'table' and type(opts.adb.list_devices) == 'function' and type(opts.adb.validate_serial) == 'function',
    'android_workbench.device.new requires adb.list_devices/validate_serial'
  )
  assert(
    type(opts.emulator) == 'table'
      and type(opts.emulator.list_avds) == 'function'
      and type(opts.emulator.start) == 'function'
      and type(opts.emulator.stop) == 'function',
    'android_workbench.device.new requires emulator.list_avds/start/stop'
  )
  assert(type(opts.picker) == 'table' and type(opts.picker.select) == 'function', 'android_workbench.device.new requires picker.select')

  return setmetatable({
    adb = opts.adb,
    emulator = opts.emulator,
    picker = opts.picker,
  }, Device)
end

function Device:_inventory(session, operation, callback)
  operation:start_child(function(done) return self.adb:list_devices(done) end, function(adb_err, value)
    if adb_err then
      callback(adb_err)
      return
    end
    local devices, devices_err = validate_device_rows(value, session.root)
    if not devices then
      callback(devices_err)
      return
    end

    local resources, emulator_serials = {}, {}
    for _, device in ipairs(devices) do
      if device.state == 'online' then
        if device.serial:match '^emulator%-%d+$' then
          emulator_serials[#emulator_serials + 1] = device.serial
        else
          device.id = 'serial:' .. device.serial
          resources[#resources + 1] = device
        end
      end
    end

    local running = {}
    local index = 1
    local function list_avds()
      operation:start_child(function(done) return self.emulator:list_avds(done) end, function(avd_err, avd_value)
        if avd_err and (type(avd_err) ~= 'table' or avd_err.code ~= 'emulator_not_found') then
          callback(avd_err)
          return
        end
        local avds, validation_err = validate_avd_rows(avd_err and {} or avd_value, session.root)
        if not avds then
          callback(validation_err)
          return
        end

        local listed = {}
        for _, avd in ipairs(avds) do
          listed[avd.avd_name] = true
          local online = running[avd.avd_name]
          if online then
            online.id = 'avd:' .. avd.avd_name
            online.label = avd.label
            resources[#resources + 1] = online
          else
            resources[#resources + 1] = stopped_resource(avd.avd_name, avd.label)
          end
        end
        for avd_name, online in pairs(running) do
          if not listed[avd_name] then
            online.id = 'avd:' .. avd_name
            resources[#resources + 1] = online
          end
        end
        table.sort(resources, function(left, right)
          local left_label, right_label = resource_label(left):lower(), resource_label(right):lower()
          if left_label ~= right_label then return left_label < right_label end
          return left.id < right.id
        end)
        callback(nil, resources)
      end, function(err) return workbench_error('emulator_list_failed', 'Could not list Android virtual devices.', session.root, tostring(err)) end)
    end

    local function resolve_emulator()
      local serial = emulator_serials[index]
      index = index + 1
      if serial == nil then
        list_avds()
        return
      end
      operation:start_child(function(done) return self.adb:validate_serial(serial, done) end, function(validate_err, device)
        if validate_err then
          callback(validate_err)
          return
        end
        local validated, identity_err = runtime_device(device, serial, raw_string(device, 'avd_name'), session.root)
        if not validated or validated.avd_name == nil then
          callback(identity_err or workbench_error('device_reselection_required', 'A running emulator has no stable AVD identity.', session.root))
          return
        end
        if running[validated.avd_name] then
          callback(
            workbench_error(
              'emulator_ambiguous',
              ('More than one running emulator uses AVD %s. Stop the duplicate instance and retry.'):format(validated.avd_name),
              session.root,
              { avd_name = validated.avd_name }
            )
          )
          return
        end
        running[validated.avd_name] = validated
        resolve_emulator()
      end, function(err) return workbench_error('adb_start_failed', 'Could not resolve a running emulator identity.', session.root, tostring(err)) end)
    end
    resolve_emulator()
  end, function(err) return workbench_error('adb_start_failed', 'Could not list Android devices.', session.root, tostring(err)) end)
end

function Device:_choose(session, operation, prompt, resources, selected, opts, callback)
  opts = opts or {}
  if #resources == 0 then
    callback(workbench_error('device_not_found', 'No matching Android device is available.', session.root))
    return
  end

  local function accept(item)
    local id = raw_string(item, 'id')
    for _, candidate in ipairs(resources) do
      if id ~= nil and candidate.id == id then
        callback(nil, candidate)
        return
      end
    end
    callback(workbench_error('invalid_selection', 'The picker returned an unknown Android device.', session.root))
  end

  if #resources == 1 and not opts.always_pick then
    accept(resources[1])
    return
  end

  operation:start_child(
    function(done)
      return self.picker.select({
        prompt = prompt,
        items = vim.deepcopy(resources),
        current = vim.deepcopy(selected_resource(resources, selected)),
        format_item = resource_label,
      }, done)
    end,
    function(picker_err, item)
      if picker_err then
        callback(picker_err)
      elseif item == nil then
        callback(workbench_error('cancelled', 'Android device selection was cancelled.', session.root))
      else
        accept(item)
      end
    end,
    function(err) return workbench_error('picker_failed', 'Could not open the Android device picker.', session.root, tostring(err)) end
  )
end

function Device:_validate(session, operation, requested, callback)
  operation:start_child(function(done) return self.adb:validate_serial(requested.serial, done) end, function(err, value)
    if err then
      callback(err)
      return
    end
    local device, validation_err = runtime_device(value, requested.serial, requested.avd_name, session.root)
    callback(validation_err, device)
  end, function(err) return workbench_error('adb_start_failed', 'Could not validate the selected Android device.', session.root, tostring(err)) end)
end

function Device:_start_avd(session, operation, expected, avd_name, callback)
  operation:start_child(
    function(done) return self.emulator:start(avd_name, done) end,
    function(err, value)
      if err then
        callback(err)
        return
      end
      local device, validation_err = runtime_device(value, nil, avd_name, session.root)
      if not device then
        callback(validation_err)
        return
      end
      local saved, save_err = write_selection(session, expected, { avd_name = avd_name, serial = device.serial })
      if not saved then
        callback(save_err)
        return
      end
      callback(nil, device)
    end,
    function(err) return workbench_error('emulator_start_failed', ('Could not start Android emulator %s.'):format(avd_name), session.root, tostring(err)) end
  )
end

function Device:_stop_avd(session, operation, expected, device, remember_avd, callback)
  operation:start_child(
    function(done) return self.emulator:stop({ avd_name = device.avd_name, serial = device.serial }, done) end,
    function(err, value)
      if err then
        callback(err)
        return
      end
      if type(value) ~= 'table' or raw_string(value, 'avd_name') ~= device.avd_name or raw_string(value, 'serial') ~= device.serial then
        callback(workbench_error('invalid_emulator_result', 'The emulator service stopped a different Android emulator.', session.root))
        return
      end
      local requested = remember_avd and { avd_name = device.avd_name } or expected
      local saved, save_err = write_selection(session, expected, requested)
      if not saved then
        callback(save_err)
        return
      end
      callback(nil, stopped_avd(device.avd_name, device.label))
    end,
    function(err) return workbench_error('emulator_stop_failed', ('Could not stop Android emulator %s.'):format(device.avd_name), session.root, tostring(err)) end
  )
end

---@param session table
---@param callback fun(err: table?, device: table?)
---@return table
function Device:select(session, callback)
  callback = callback or function() end
  local operation = new_operation(session.root, callback)
  local baseline, selection_err = read_selection(session)
  if selection_err then
    operation:finish(selection_err)
    return operation
  end

  self:_inventory(session, operation, function(err, resources)
    if err then
      operation:finish(err)
      return
    end
    self:_choose(session, operation, 'Android device', resources, baseline, {}, function(choose_err, resource)
      if choose_err then
        operation:finish(choose_err)
        return
      end

      local requested = stored_device(resource)
      if resource.state == 'stopped' then
        local saved, save_err = write_selection(session, baseline, requested)
        operation:finish(save_err, saved and stopped_avd(resource.avd_name, resource.label) or nil)
        return
      end

      self:_validate(session, operation, resource, function(validate_err, device)
        if validate_err then
          operation:finish(validate_err)
          return
        end
        local saved, save_err = write_selection(session, baseline, stored_device(device))
        operation:finish(save_err, saved and device or nil)
      end)
    end)
  end)
  return operation
end

function Device:_resolve_selected(session, operation, selected, opts, callback)
  if selected.serial ~= nil then
    self:_validate(session, operation, selected, function(err, device)
      if err then
        local can_rebind = selected.avd_name ~= nil and type(err) == 'table' and (err.code == 'device_not_found' or err.code == 'device_not_ready')
        if not can_rebind then
          callback(err)
          return
        end

        self:_inventory(session, operation, function(inventory_err, resources)
          if inventory_err then
            callback(inventory_err)
            return
          end
          local resource = selected_resource(resources, selected)
          if resource and resource.state == 'online' then
            local rebound, validation_err = runtime_device(resource, resource.serial, selected.avd_name, session.root)
            if not rebound then
              callback(validation_err)
              return
            end
            local saved, save_err = write_selection(session, selected, {
              avd_name = selected.avd_name,
              serial = rebound.serial,
            })
            if not saved then
              callback(save_err)
              return
            end
            callback(nil, rebound)
            return
          end
          if not opts.start_stopped_avd then
            callback(err)
            return
          end
          local current, current_err = read_selection(session)
          if current_err then
            callback(current_err)
          elseif not same_stored_device(current, selected) then
            callback(workbench_error('device_changed', 'The selected Android device changed during the operation. Retry the action.', session.root))
          else
            self:_start_avd(session, operation, selected, selected.avd_name, callback)
          end
        end)
        return
      end
      local current, current_err = read_selection(session)
      if current_err then
        callback(current_err)
      elseif not same_stored_device(current, selected) then
        callback(workbench_error('device_changed', 'The selected Android device changed during the operation. Retry the action.', session.root))
      else
        callback(nil, device)
      end
    end)
    return
  end

  -- A physical selection always has a serial; schema validation guarantees
  -- that a serial-less selection is a stable AVD identity.
  if opts.start_stopped_avd then
    self:_start_avd(session, operation, selected, selected.avd_name, callback)
    return
  end

  self:_inventory(session, operation, function(err, resources)
    if err then
      callback(err)
      return
    end
    local resource = selected_resource(resources, selected)
    if not resource or resource.state ~= 'online' then
      callback(
        workbench_error(
          'device_not_ready',
          ('Android virtual device %s is not running. Start it and retry.'):format(selected.avd_name),
          session.root,
          { avd_name = selected.avd_name }
        )
      )
      return
    end
    local saved, save_err = write_selection(session, selected, { avd_name = selected.avd_name, serial = resource.serial })
    if not saved then
      callback(save_err)
      return
    end
    local device, validation_err = runtime_device(resource, resource.serial, selected.avd_name, session.root)
    callback(validation_err, device)
  end)
end

---@param session table
---@param opts? { start_stopped_avd?: boolean }
---@param callback fun(err: table?, device: table?)
---@return table
function Device:resolve(session, opts, callback)
  opts = opts or {}
  callback = callback or function() end
  local operation = new_operation(session.root, callback)
  local selected, selection_err = read_selection(session)
  if selection_err then
    operation:finish(selection_err)
    return operation
  end

  local function resolve_current(current)
    self:_resolve_selected(session, operation, current, opts, function(err, device) operation:finish(err, device) end)
  end
  if selected then
    resolve_current(selected)
    return operation
  end

  operation:start_child(function(done) return self:select(session, done) end, function(err)
    if err then
      operation:finish(err)
      return
    end
    local current, current_err = read_selection(session)
    if current_err then
      operation:finish(current_err)
    elseif not current then
      operation:finish(workbench_error('device_not_found', 'No Android device is selected.', session.root))
    else
      resolve_current(current)
    end
  end, function(err) return workbench_error('device_operation_failed', 'Could not select an Android device.', session.root, tostring(err)) end)
  return operation
end

---@param session table
---@param callback fun(err: table?, device: table?)
---@return table
function Device:start(session, callback)
  callback = callback or function() end
  local operation = new_operation(session.root, callback)
  local baseline, selection_err = read_selection(session)
  if selection_err then
    operation:finish(selection_err)
    return operation
  end
  if baseline and baseline.avd_name then
    self:_start_avd(session, operation, baseline, baseline.avd_name, function(err, device) operation:finish(err, device) end)
    return operation
  end

  self:_inventory(session, operation, function(err, resources)
    if err then
      operation:finish(err)
      return
    end
    local avds = vim.tbl_filter(function(resource) return resource.avd_name ~= nil end, resources)
    self:_choose(session, operation, 'Android virtual device to start', avds, nil, { always_pick = true }, function(choose_err, resource)
      if choose_err then
        operation:finish(choose_err)
        return
      end
      local requested = stored_device(resource)
      local saved, save_err = write_selection(session, baseline, requested)
      if not saved then
        operation:finish(save_err)
        return
      end
      self:_start_avd(session, operation, requested, resource.avd_name, function(start_err, device) operation:finish(start_err, device) end)
    end)
  end)
  return operation
end

---@param session table
---@param callback fun(err: table?, device: table?)
---@return table
function Device:stop(session, callback)
  callback = callback or function() end
  local operation = new_operation(session.root, callback)
  local baseline, selection_err = read_selection(session)
  if selection_err then
    operation:finish(selection_err)
    return operation
  end

  if baseline and baseline.avd_name and baseline.serial then
    self:_stop_avd(session, operation, baseline, baseline, true, function(stop_err, device) operation:finish(stop_err, device) end)
    return operation
  end

  self:_inventory(session, operation, function(err, resources)
    if err then
      operation:finish(err)
      return
    end
    local running = vim.tbl_filter(function(resource) return resource.avd_name ~= nil and resource.state == 'online' end, resources)
    local selected = baseline and baseline.avd_name and selected_resource(running, baseline) or nil

    local function stop(resource, expected, remember_avd)
      self:_stop_avd(session, operation, expected, resource, remember_avd, function(stop_err, device) operation:finish(stop_err, device) end)
    end

    if baseline and baseline.avd_name then
      if not selected then
        operation:finish(workbench_error('emulator_not_running', ('Android virtual device %s is not running.'):format(baseline.avd_name), session.root, {
          avd_name = baseline.avd_name,
        }))
        return
      end
      stop(selected, baseline, true)
      return
    end

    self:_choose(session, operation, 'Android virtual device to stop', running, nil, { always_pick = true }, function(choose_err, resource)
      if choose_err then
        operation:finish(choose_err)
        return
      end
      stop(resource, baseline, false)
    end)
  end)
  return operation
end

return M

-- vim: ts=2 sts=2 sw=2 et
