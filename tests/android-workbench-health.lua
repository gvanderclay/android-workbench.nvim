local failures = {}

local function fail(name, message) failures[#failures + 1] = ('%s: %s'):format(name, message) end

local function expect(name, actual, expected)
  if vim.deep_equal(actual, expected) then return end
  fail(name, ('expected %s, got %s'):format(vim.inspect(expected), vim.inspect(actual)))
end

local function find_report(reports, level, pattern)
  for _, report in ipairs(reports) do
    if report.level == level and report.message:find(pattern, 1, true) then return report end
  end
end

local health = require 'android_workbench.health'
local original_cwd = assert(vim.uv.cwd())
local original_health = vim.health
local temporary_root = vim.fn.tempname()

local ok, unexpected = xpcall(function()
  assert(vim.fn.mkdir(temporary_root, 'p') == 1)
  temporary_root = assert(vim.uv.fs_realpath(temporary_root))
  vim.cmd.cd(vim.fn.fnameescape(temporary_root))

  local function check()
    local reports = {}
    vim.health = {}
    for _, level in ipairs { 'start', 'ok', 'info', 'warn', 'error' } do
      vim.health[level] = function(message)
        reports[#reports + 1] = {
          level = level,
          message = message,
        }
      end
    end
    health.check()
    return reports
  end

  local wrapper = vim.fs.joinpath(temporary_root, 'gradlew')
  assert(vim.fn.mkdir(wrapper, 'p') == 1)
  local directory_reports = check()
  expect('wrapper directory is rejected', find_report(directory_reports, 'error', 'Gradle wrapper is not a file:'), {
    level = 'error',
    message = 'Gradle wrapper is not a file: ' .. wrapper,
  })
  vim.fn.delete(wrapper, 'rf')

  assert(vim.fn.writefile({ '#!/bin/sh' }, wrapper) == 0)
  assert(vim.uv.fs_chmod(wrapper, tonumber('600', 8)))
  local non_executable_reports = check()
  expect('non-executable wrapper is rejected', find_report(non_executable_reports, 'error', 'Gradle wrapper is not executable:'), {
    level = 'error',
    message = 'Gradle wrapper is not executable: ' .. wrapper,
  })

  assert(vim.uv.fs_chmod(wrapper, tonumber('700', 8)))
  local executable_reports = check()
  expect('executable wrapper is accepted', find_report(executable_reports, 'ok', 'Gradle wrapper:'), {
    level = 'ok',
    message = 'Gradle wrapper: ' .. wrapper,
  })
end, debug.traceback)

vim.health = original_health
vim.cmd.cd(vim.fn.fnameescape(original_cwd))
vim.fn.delete(temporary_root, 'rf')

if not ok then fail('unexpected test error', unexpected) end

if #failures > 0 then
  vim.api.nvim_err_writeln('Android Workbench health validation failed:\n- ' .. table.concat(failures, '\n- '))
  vim.cmd 'cquit 1'
end

print 'Android Workbench health validation passed'
vim.cmd 'qa!'

-- vim: ts=2 sts=2 sw=2 et
