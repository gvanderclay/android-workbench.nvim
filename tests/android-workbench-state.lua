local failures = {}

local function fail(name, message) failures[#failures + 1] = ('%s: %s'):format(name, message) end

local function expect(name, actual, expected)
  if vim.deep_equal(actual, expected) then return end
  fail(name, ('expected %s, got %s'):format(vim.inspect(expected), vim.inspect(actual)))
end

local function expect_true(name, value)
  if value then return end
  fail(name, 'expected a truthy value')
end

local State = require 'android_workbench.state'
local bit = require 'bit'
local temporary_directories = {}

local function temporary_directory()
  local directory = vim.fn.tempname()
  temporary_directories[#temporary_directories + 1] = directory
  return directory
end

local function path_for(directory, root) return vim.fs.joinpath(directory, vim.fn.sha256(root) .. '.json') end

local function write_payload(directory, root, payload)
  assert(vim.fn.mkdir(directory, 'p') == 1)
  assert(vim.fn.writefile({ payload }, path_for(directory, root), 's') == 0)
end

local function write_value(directory, root, value) write_payload(directory, root, vim.json.encode(value)) end

local function permissions(path)
  local stat = assert(vim.uv.fs_stat(path))
  return bit.band(stat.mode, tonumber('777', 8))
end

local ok, unexpected = xpcall(function()
  local directory = temporary_directory()
  local state = State.new { directory = directory }
  local root_one = '/tmp/android-workbench-state-one'
  local root_two = '/tmp/android-workbench-state-two'
  local selection_one = {
    app = { build_path = ':', project_path = ':app' },
    variant = 'debug',
    device = { serial = 'emulator-5554', avd_name = 'Pixel_8_API_35' },
  }
  local selection_two = {
    app = { build_path = ':included', project_path = ':demo' },
    variant = 'release',
    device = { serial = 'R58M321' },
  }

  expect('first root saves', state.save(root_one, selection_one), true)
  expect('second root saves', state.save(root_two, selection_two), true)
  expect('first root round trips independently', state.load(root_one), selection_one)
  expect('second root round trips independently', state.load(root_two), selection_two)

  local stopped_avd = {
    app = { build_path = ':', project_path = ':app' },
    variant = 'debug',
    device = { avd_name = 'Pixel_8_API_35' },
  }
  expect('stopped AVD selection saves without an ephemeral serial', state.save(root_one, stopped_avd), true)
  expect('stopped AVD selection round trips in schema version one', state.load(root_one), stopped_avd)
  expect_true('root identities use different state files', path_for(directory, root_one) ~= path_for(directory, root_two))
  expect('state directory is owner-private', permissions(directory), tonumber('700', 8))
  expect('first state file is owner-private', permissions(path_for(directory, root_one)), tonumber('600', 8))
  expect('second state file is owner-private', permissions(path_for(directory, root_two)), tonumber('600', 8))

  local invalid_json_root = '/tmp/android-workbench-invalid-json'
  write_payload(directory, invalid_json_root, '{not-json')
  local loaded, err = state.load(invalid_json_root)
  expect('invalid JSON returns no selection', loaded, nil)
  expect('invalid JSON is classified', err and err.code, 'state_invalid')

  local unsupported_schema_root = '/tmp/android-workbench-unsupported-schema'
  write_value(directory, unsupported_schema_root, {
    schema_version = 2,
    root = unsupported_schema_root,
    selection = vim.empty_dict(),
  })
  loaded, err = state.load(unsupported_schema_root)
  expect('unsupported schema returns no selection', loaded, nil)
  expect('unsupported schema is classified', err and err.code, 'state_schema_unsupported')

  local mismatched_root = '/tmp/android-workbench-root-mismatch'
  write_value(directory, mismatched_root, {
    schema_version = 1,
    root = '/tmp/a-different-android-root',
    selection = vim.empty_dict(),
  })
  loaded, err = state.load(mismatched_root)
  expect('mismatched root returns no selection', loaded, nil)
  expect('mismatched root is classified', err and err.code, 'state_root_mismatch')

  local invalid_selection_root = '/tmp/android-workbench-invalid-selection'
  write_value(directory, invalid_selection_root, {
    schema_version = 1,
    root = invalid_selection_root,
    selection = { variant = 'debug' },
  })
  loaded, err = state.load(invalid_selection_root)
  expect('invalid selection returns no value', loaded, nil)
  expect('invalid selection is classified', err and err.code, 'state_invalid')

  local invalid_saved, invalid_save_err = state.save(root_one, { variant = 'release' })
  expect('invalid selection is not saved', invalid_saved, nil)
  expect('invalid save is classified', invalid_save_err and invalid_save_err.code, 'state_invalid')
  expect('invalid save preserves the prior state', state.load(root_one), stopped_avd)

  invalid_saved, invalid_save_err = state.save(root_one, { device = vim.empty_dict() })
  expect('device without a stable identity is not saved', invalid_saved, nil)
  expect('missing device identity is classified', invalid_save_err and invalid_save_err.code, 'state_invalid')
  expect('missing device identity preserves the prior state', state.load(root_one), stopped_avd)

  local atomic_directory = temporary_directory()
  local fail_rename = false
  local injected_uv = setmetatable({
    fs_rename = function(from, to)
      if fail_rename then return nil, 'injected rename failure' end
      return vim.uv.fs_rename(from, to)
    end,
  }, { __index = vim.uv })
  local atomic_state = State.new { directory = atomic_directory, uv = injected_uv }
  local atomic_root = '/tmp/android-workbench-atomic-state'
  expect('atomic fixture saves', atomic_state.save(atomic_root, selection_one), true)

  fail_rename = true
  local saved, save_err = atomic_state.save(atomic_root, selection_two)
  expect('injected rename failure rejects replacement', saved, nil)
  expect('injected rename failure is classified', save_err and save_err.code, 'state_write_failed')
  expect('failed atomic replacement preserves the old state', State.new({ directory = atomic_directory }).load(atomic_root), selection_one)

  local temporary_files = {}
  for name in vim.fs.dir(atomic_directory) do
    if name:find('.tmp.', 1, true) then temporary_files[#temporary_files + 1] = name end
  end
  expect('failed atomic replacement cleans its temporary file', temporary_files, {})
end, debug.traceback)

for _, directory in ipairs(temporary_directories) do
  vim.fn.delete(directory, 'rf')
end
if not ok then fail('unexpected test error', unexpected) end

if #failures > 0 then
  vim.api.nvim_err_writeln('Android Workbench state validation failed:\n- ' .. table.concat(failures, '\n- '))
  vim.cmd 'cquit 1'
end

print 'Android Workbench state validation passed'
vim.cmd 'qa!'

-- vim: ts=2 sts=2 sw=2 et
