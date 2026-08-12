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

local ok, unexpected = xpcall(function()
  local collision = _G.android_workbench_collision
  expect_true('collision fixture is installed', type(collision) == 'table')
  expect('incumbent Android command still exists', vim.fn.exists ':Android', 2)
  expect('plugin load guard is set after collision', vim.g.loaded_android_workbench, true)
  expect('command collision emits one warning', #collision.notifications, 1)
  expect('command collision warning level', collision.notifications[1] and collision.notifications[1].level, vim.log.levels.WARN)
  expect_true(
    'command collision warning identifies the preserved command',
    collision.notifications[1] and collision.notifications[1].message:find(':Android already exists', 1, true)
  )
  vim.cmd.runtime 'plugin/android-workbench.lua'
  expect('reloading the plugin emits no duplicate collision warning', #collision.notifications, 1)

  vim.cmd.Android()
  expect('incumbent Android command remains callable', collision.calls, 1)
  expect('incumbent invocation emits no Workbench notification', #collision.notifications, 1)
  expect('collision does not load the command implementation', package.loaded['android_workbench.command'], nil)
  expect('collision does not construct the application', package.loaded['android_workbench.app'], nil)
end, debug.traceback)

if not ok then fail('unexpected test error', unexpected) end

if #failures > 0 then
  vim.api.nvim_err_writeln('Android Workbench command-collision smoke failed:\n- ' .. table.concat(failures, '\n- '))
  vim.cmd 'cquit 1'
end

print 'Android Workbench command-collision smoke passed'
vim.cmd 'qa!'

-- vim: ts=2 sts=2 sw=2 et
