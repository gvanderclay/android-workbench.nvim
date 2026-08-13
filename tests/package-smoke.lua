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

local function unloaded(name) expect(name .. ' stays unloaded', package.loaded[name], nil) end

local root = assert(vim.uv.fs_realpath(vim.env.ANDROID_WORKBENCH_TEST_ROOT))
local nvim_lib = vim.fs.normalize(vim.fs.joinpath(vim.env.VIMRUNTIME, '..', '..', '..', 'lib', 'nvim'))

local ok, unexpected = xpcall(function()
  local runtimepath = vim.opt.runtimepath:get()
  expect('package is first on runtimepath', runtimepath[1], root)
  for _, path in ipairs(runtimepath) do
    expect_true('runtimepath excludes user configuration paths', path == root or path == nvim_lib or vim.startswith(path, vim.env.VIMRUNTIME))
  end
  expect('Android command is registered by normal plugin loading', vim.fn.exists ':Android', 2)
  expect('plugin load guard is set', vim.g.loaded_android_workbench, true)

  unloaded 'android_workbench'
  unloaded 'android_workbench.command'
  unloaded 'android_workbench.notify'
  unloaded 'android_workbench.app'
  unloaded 'android_workbench.android.adb'
  unloaded 'android_workbench.android.emulator'
  unloaded 'android_workbench.gradle.discovery'
  unloaded 'android_workbench.integrations.snacks'
  unloaded 'android_workbench.integrations.telescope'
  unloaded 'android_workbench.integrations.overseer'
  unloaded 'trouble'

  for _, suffix in ipairs { 'm', 'b', 'r', 'g', 'l', 'e', 'M', 'v', 'd', 'E' } do
    expect(('package defines no <leader>i%s mapping'):format(suffix), next(vim.fn.maparg('<leader>i' .. suffix, 'n', false, true)), nil)
  end

  expect_true('static completion exposes target actions', vim.tbl_contains(vim.fn.getcompletion('Android t', 'cmdline'), 'target'))
  expect_true('static completion exposes native task output', vim.tbl_contains(vim.fn.getcompletion('Android o', 'cmdline'), 'output'))
  expect('completion loads only the command layer', type(package.loaded['android_workbench.command']), 'table')
  unloaded 'android_workbench.notify'
  unloaded 'android_workbench.app'
  unloaded 'android_workbench.android.adb'
  unloaded 'android_workbench.gradle.discovery'
  unloaded 'android_workbench.integrations.snacks'
  unloaded 'android_workbench.integrations.telescope'
  unloaded 'android_workbench.integrations.overseer'

  expect('setup exposes no private configuration result', require('android_workbench').setup {}, nil)
  expect('default Run auto-start remains enabled', require('android_workbench.config').get().run.start_stopped_avd, true)
  expect('setup remains configuration-only', package.loaded['android_workbench.app'], nil)

  local provider = vim.fs.joinpath(root, 'lua', 'android_workbench', 'gradle', 'android_workbench.init.gradle')
  local provider_stat = vim.uv.fs_stat(provider)
  expect('bundled Gradle provider is a file', provider_stat and provider_stat.type, 'file')

  local help_ok, help_err = pcall(vim.cmd.help, 'android-workbench')
  expect('Android Workbench help opens', help_ok, true)
  if not help_ok then fail('Android Workbench help error', tostring(help_err)) end
  expect_true('help resolves to the package vimdoc', vim.api.nvim_buf_get_name(0):find '/doc/android%-workbench%.txt$' ~= nil)
  local api_help_ok, api_help_err = pcall(vim.cmd.help, 'android-workbench-api')
  expect('public API help opens', api_help_ok, true)
  if not api_help_ok then fail('Android Workbench API help error', tostring(api_help_err)) end

  local health_ok, health_err = pcall(vim.cmd.checkhealth, 'android_workbench')
  expect('Android Workbench health runs', health_ok, true)
  if not health_ok then fail('Android Workbench health error', tostring(health_err)) end
  expect('health does not construct the application', package.loaded['android_workbench.app'], nil)
  unloaded 'android_workbench.integrations.snacks'
  unloaded 'android_workbench.integrations.telescope'
  unloaded 'android_workbench.integrations.overseer'
  unloaded 'trouble'

  local android = assert(package.loaded.android_workbench)
  local shutdown = android.shutdown
  local shutdown_calls = 0
  android.shutdown = function() shutdown_calls = shutdown_calls + 1 end
  vim.api.nvim_exec_autocmds('VimLeavePre', {})
  vim.api.nvim_exec_autocmds('VimLeavePre', {})
  expect('VimLeavePre shuts Workbench down once', shutdown_calls, 1)
  android.shutdown = shutdown
end, debug.traceback)

if not ok then fail('unexpected test error', unexpected) end

if #failures > 0 then
  vim.api.nvim_err_writeln('Android Workbench package smoke failed:\n- ' .. table.concat(failures, '\n- '))
  vim.cmd 'cquit 1'
end

print 'Android Workbench package smoke passed'
vim.cmd 'qa!'

-- vim: ts=2 sts=2 sw=2 et
