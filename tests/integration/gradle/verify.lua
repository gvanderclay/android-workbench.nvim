local root = assert(vim.uv.fs_realpath(assert(vim.env.AWB_FIXTURE_ROOT)))
local gradle_version = assert(vim.env.AWB_FIXTURE_GRADLE)
local agp_version = assert(vim.env.AWB_FIXTURE_AGP)
local exact_task_id = ':included:includedProbe'

local function await(label, start)
  local terminal
  start(function(err, value) terminal = { err = err, value = value } end)
  assert(vim.wait(300000, function() return terminal ~= nil end, 20), label .. ' timed out')
  assert(terminal.err == nil, label .. ' failed: ' .. vim.inspect(terminal.err))
  return terminal.value
end

local picker = {
  select = function(request, done)
    local selected
    for _, item in ipairs(request.items) do
      if item.id == exact_task_id or item.variant == 'debug' then
        selected = item
        break
      end
    end
    vim.schedule(function()
      if selected then
        done(nil, selected)
      else
        done { code = 'fixture_selection_missing', message = 'The expected fixture selection was not offered.' }
      end
    end)
    return { cancel = function() return true end }
  end,
}

local trust = {
  authorize = function(candidate)
    if vim.uv.fs_realpath(candidate) == root then return true end
    return nil, { code = 'project_not_trusted', message = 'Fixture trust is restricted to its disposable root.' }
  end,
}

local ok, err = xpcall(function()
  local android = require 'android_workbench'
  android.setup {
    ports = {
      discovery = require('android_workbench.gradle.discovery').new {
        configuration_cache = true,
        timeout_ms = 300000,
      },
      picker = picker,
      trust = trust,
    },
  }

  local first = await('first configuration-cache discovery', function(done) android.refresh({ root = root }, done) end)
  assert(first.targets == 2, ('expected two Android targets, got %s'):format(first.targets))

  local second = await('second configuration-cache discovery', function(done) android.refresh({ root = root }, done) end)
  assert(second.targets == first.targets, 'second discovery changed the Android target count')
  assert(vim.uv.fs_stat(vim.fs.joinpath(root, '.gradle', 'configuration-cache')), 'Gradle did not create configuration-cache state')

  local task = await('included-build exact task', function(done) android.gradle_task({ root = root }, done) end)
  assert(task.kind == 'gradle_task', 'exact task returned the wrong result kind')
  assert(task.gradle_task.id == exact_task_id, 'composite task identity changed before execution')
  assert(task.task.status == 'success', 'included-build task did not succeed')
  local marker = vim.fs.joinpath(root, 'included', 'included-probe.txt')
  assert(vim.uv.fs_stat(marker), 'included-build task marker was not created')
  assert(vim.trim(table.concat(vim.fn.readfile(marker), '\n')) == ':includedProbe', 'included-build task marker had the wrong task path')

  local build = await('Android debug build', function(done) android.build({ root = root }, done) end)
  assert(build.kind == 'build', 'Android build returned the wrong result kind')
  assert(build.target.variant == 'debug', 'Android build selected the wrong variant')
  assert(build.target.application_id == 'com.example.workbenchfixture', 'Android application ID changed during discovery')
  assert(build.task.status == 'success', 'Android debug build did not succeed')
  assert(vim.uv.fs_stat(vim.fs.joinpath(root, 'app', 'build', 'outputs', 'apk', 'debug', 'app-debug.apk')), 'Android debug APK was not produced')

  android.shutdown()
end, debug.traceback)

if not ok then
  vim.api.nvim_err_writeln(('Gradle %s / AGP %s integration failed:\n%s'):format(gradle_version, agp_version, tostring(err)))
  vim.cmd 'cquit 1'
end

print(('Gradle %s / AGP %s integration passed'):format(gradle_version, agp_version))
vim.cmd 'qa!'
