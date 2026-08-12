local M = {}

local config = require 'android_workbench.config'

local function error_message(err)
  if type(err) == 'table' then
    local message = rawget(err, 'message')
    if type(message) == 'string' then return message end
    local code = rawget(err, 'code')
    if type(code) == 'string' then return code end
    return vim.inspect(err)
  end
  return tostring(err)
end

---@param event { level?: 'info'|'warn'|'error', title?: string, message: string, code?: string }
function M.emit(event)
  event = {
    level = event.level or 'info',
    title = event.title or 'Android Workbench',
    message = event.message,
    code = event.code,
  }

  local notifications = config.get().ports.notifications
  if notifications ~= nil then
    local ok, err = pcall(notifications.emit, event)
    if ok then return end
    event = {
      level = 'error',
      title = 'Android Workbench',
      message = ('Notification adapter failed: %s'):format(error_message(err)),
    }
  end

  local levels = {
    info = vim.log.levels.INFO,
    warn = vim.log.levels.WARN,
    error = vim.log.levels.ERROR,
  }
  vim.notify(event.message, levels[event.level] or vim.log.levels.INFO, { title = event.title })
end

return M

-- vim: ts=2 sts=2 sw=2 et
