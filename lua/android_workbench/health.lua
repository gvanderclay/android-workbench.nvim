local M = {}

function M.check()
  vim.health.start 'Android Workbench'
  local ports = require('android_workbench.config').get().ports

  if vim.fn.has 'nvim-0.12' == 1 then
    local version = vim.version()
    vim.health.ok(('Neovim %d.%d.%d'):format(version.major, version.minor, version.patch))
  else
    vim.health.error 'Neovim 0.12 or newer is required'
  end

  if type(vim.system) == 'function' then
    vim.health.ok 'vim.system is available'
  else
    vim.health.error 'vim.system is unavailable'
  end

  if ports.trust then
    vim.health.ok 'Custom project-trust adapter is configured'
  elseif vim.secure and type(vim.secure.read) == 'function' then
    vim.health.ok 'project trust is available'
  else
    vim.health.error 'vim.secure.read is unavailable'
  end

  if ports.adb then
    if type(ports.adb.resolve_executable) ~= 'function' then
      vim.health.ok 'Custom ADB adapter is configured'
    else
      local ok, adb, err = pcall(ports.adb.resolve_executable, ports.adb)
      if ok and type(adb) == 'string' and adb ~= '' then
        vim.health.ok(('Custom ADB adapter: %s'):format(adb))
      elseif ok then
        local message = type(err) == 'table' and (err.message or err.code) or err
        vim.health.warn(tostring(message or 'The custom ADB adapter could not resolve adb'))
      else
        local message = type(adb) == 'table' and (adb.message or adb.code or vim.inspect(adb)) or adb
        vim.health.error(('Custom ADB adapter failed: %s'):format(tostring(message)))
      end
    end
  else
    local adb = vim.fn.exepath 'adb'
    if adb ~= '' then
      vim.health.ok(('ADB: %s'):format(adb))
    else
      vim.health.warn 'adb is unavailable; device selection, Run, Stop, and Logcat require the Android SDK platform tools'
    end
  end

  if ports.emulator then
    vim.health.ok 'Custom emulator adapter is configured'
  else
    local emulator = vim.fn.exepath 'emulator'
    if emulator ~= '' then
      vim.health.ok(('Android Emulator: %s'):format(emulator))
    else
      vim.health.warn 'Android Emulator is unavailable; AVD discovery and lifecycle actions require the Android SDK emulator'
      vim.health.info 'Build and physical-device workflows remain available'
    end
  end

  if package.config:sub(1, 1) == '\\' then
    vim.health.warn 'The current implementation supports the Unix Gradle wrapper; Windows gradlew.bat execution is not implemented'
    return
  end

  local resolved, err = require('android_workbench.root').new():resolve { path = vim.uv.cwd() }
  if resolved then
    vim.health.ok(('Gradle wrapper: %s'):format(resolved.wrapper))
    vim.health.info(('Project root: %s'):format(resolved.root))
  elseif err and err.code == 'gradle_wrapper_not_found' then
    vim.health.info 'The current directory is not inside a Gradle wrapper project'
  else
    vim.health.warn(err and err.message or 'Could not inspect the current project')
  end
end

return M

-- vim: ts=2 sts=2 sw=2 et
