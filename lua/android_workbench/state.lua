local M = {}

local SCHEMA_VERSION = 1
local DIRECTORY_MODE = tonumber('700', 8)
local FILE_MODE = tonumber('600', 8)
local temporary_sequence = 0

local function state_error(code, message, path, details)
  return {
    code = code,
    message = message,
    path = path,
    details = details,
  }
end

local function copy_selection(selection)
  local app = selection and selection.app
  local device = selection and selection.device
  return {
    app = app and {
      build_path = app.build_path,
      project_path = app.project_path,
    } or nil,
    variant = selection and selection.variant or nil,
    device = device and {
      serial = device.serial,
      avd_name = device.avd_name,
    } or nil,
  }
end

local function validate_selection(selection)
  if type(selection) ~= 'table' then return nil, 'selection must be an object' end

  if selection.app ~= nil then
    if type(selection.app) ~= 'table' then return nil, 'selection.app must be an object' end
    if type(selection.app.build_path) ~= 'string' or selection.app.build_path == '' then return nil, 'selection.app.build_path must be a non-empty string' end
    if type(selection.app.project_path) ~= 'string' or selection.app.project_path == '' then
      return nil, 'selection.app.project_path must be a non-empty string'
    end
  end

  if selection.variant ~= nil and (type(selection.variant) ~= 'string' or selection.variant == '') then
    return nil, 'selection.variant must be a non-empty string'
  end
  if selection.app == nil and selection.variant ~= nil then return nil, 'selection.variant requires selection.app' end

  if selection.device ~= nil then
    if type(selection.device) ~= 'table' then return nil, 'selection.device must be an object' end
    if selection.device.serial ~= nil and (type(selection.device.serial) ~= 'string' or selection.device.serial == '') then
      return nil, 'selection.device.serial must be a non-empty string'
    end
    if selection.device.avd_name ~= nil and (type(selection.device.avd_name) ~= 'string' or selection.device.avd_name == '') then
      return nil, 'selection.device.avd_name must be a non-empty string'
    end
    if selection.device.serial == nil and selection.device.avd_name == nil then return nil, 'selection.device requires a serial or AVD name' end
  end

  return copy_selection(selection)
end

---@param opts? { directory?: string, uv?: table, fn?: table, json?: table, fs?: table }
---@return table
function M.new(opts)
  opts = opts or {}
  local uv = opts.uv or vim.uv
  local fn = opts.fn or vim.fn
  local json = opts.json or vim.json
  local fs = opts.fs or vim.fs
  local directory = opts.directory or fs.joinpath(fn.stdpath 'state', 'android-workbench')

  local function path_for(root) return fs.joinpath(directory, fn.sha256(root) .. '.json') end

  local function load(root)
    if type(root) ~= 'string' or root == '' then return nil, state_error('state_invalid_root', 'Android Workbench state requires a project root.') end
    local path = path_for(root)
    local stat, stat_error, stat_code = uv.fs_stat(path)
    if not stat then
      if stat_code == 'ENOENT' then return nil end
      return nil, state_error('state_read_failed', ('Could not inspect Android Workbench state at %s.'):format(path), path, tostring(stat_error))
    end

    local read_ok, lines = pcall(fn.readfile, path, 'b')
    if not read_ok then return nil, state_error('state_read_failed', ('Could not read Android Workbench state at %s.'):format(path), path, tostring(lines)) end

    local decoded_ok, value = pcall(json.decode, table.concat(lines, '\n'))
    if not decoded_ok or type(value) ~= 'table' then
      return nil, state_error('state_invalid', ('Android Workbench state at %s is not valid JSON.'):format(path), path, decoded_ok and nil or tostring(value))
    end
    if value.schema_version ~= SCHEMA_VERSION then
      return nil,
        state_error(
          'state_schema_unsupported',
          ('Android Workbench state at %s uses unsupported schema version %s.'):format(path, tostring(value.schema_version)),
          path
        )
    end
    if value.root ~= root then
      return nil, state_error('state_root_mismatch', ('Android Workbench state at %s belongs to a different project root.'):format(path), path)
    end

    local selection, validation_error = validate_selection(value.selection or {})
    if not selection then return nil, state_error('state_invalid', ('Android Workbench state at %s is invalid: %s.'):format(path, validation_error), path) end
    return selection
  end

  local function save(root, requested_selection)
    if type(root) ~= 'string' or root == '' then return nil, state_error('state_invalid_root', 'Android Workbench state requires a project root.') end
    local selection, validation_error = validate_selection(requested_selection)
    if not selection then return nil, state_error('state_invalid', ('Could not save Android Workbench state: %s.'):format(validation_error)) end

    local mkdir_ok, mkdir_result = pcall(fn.mkdir, directory, 'p', DIRECTORY_MODE)
    if not mkdir_ok or mkdir_result == 0 then
      return nil,
        state_error('state_directory_failed', ('Could not create Android Workbench state directory %s.'):format(directory), directory, tostring(mkdir_result))
    end

    local chmod_ok, chmod_error = uv.fs_chmod(directory, DIRECTORY_MODE)
    if not chmod_ok then
      return nil,
        state_error('state_permissions_failed', ('Could not protect Android Workbench state directory %s.'):format(directory), directory, tostring(chmod_error))
    end

    local persisted_selection = vim.empty_dict()
    if selection.app then persisted_selection.app = {
      build_path = selection.app.build_path,
      project_path = selection.app.project_path,
    } end
    if selection.variant then persisted_selection.variant = selection.variant end
    if selection.device then
      persisted_selection.device = vim.empty_dict()
      if selection.device.serial then persisted_selection.device.serial = selection.device.serial end
      if selection.device.avd_name then persisted_selection.device.avd_name = selection.device.avd_name end
    end

    local encoded_ok, encoded = pcall(json.encode, {
      schema_version = SCHEMA_VERSION,
      root = root,
      selection = persisted_selection,
    })
    if not encoded_ok then return nil, state_error('state_encode_failed', 'Could not encode Android Workbench state.', nil, tostring(encoded)) end

    temporary_sequence = temporary_sequence + 1
    local path = path_for(root)
    local temporary_path = ('%s.tmp.%s.%d'):format(path, tostring(uv.os_getpid()), temporary_sequence)
    local write_ok, write_result = pcall(fn.writefile, { encoded }, temporary_path, 's')
    if not write_ok or write_result ~= 0 then
      pcall(uv.fs_unlink, temporary_path)
      return nil, state_error('state_write_failed', ('Could not write Android Workbench state at %s.'):format(path), path, tostring(write_result))
    end

    local file_chmod_ok, file_chmod_error = uv.fs_chmod(temporary_path, FILE_MODE)
    if not file_chmod_ok then
      pcall(uv.fs_unlink, temporary_path)
      return nil, state_error('state_permissions_failed', ('Could not protect Android Workbench state at %s.'):format(path), path, tostring(file_chmod_error))
    end

    local renamed, rename_error = uv.fs_rename(temporary_path, path)
    if not renamed then
      pcall(uv.fs_unlink, temporary_path)
      return nil, state_error('state_write_failed', ('Could not replace Android Workbench state at %s.'):format(path), path, tostring(rename_error))
    end

    return true
  end

  return {
    load = load,
    save = save,
  }
end

return M

-- vim: ts=2 sts=2 sw=2 et
