local M = {}

local SUBCOMMANDS = { 'build', 'cancel', 'emulator', 'gradle', 'logcat', 'output', 'refresh', 'run', 'status', 'stop', 'target' }
local EMULATOR_ACTIONS = { 'start', 'stop' }
local LOGCAT_ACTIONS = { 'stop' }
local TARGETS = { 'app', 'device', 'variant' }
local USAGE =
  'Usage: :Android [build | run | gradle | output | stop | cancel | emulator start | emulator stop | logcat [stop] | status | refresh | target app | target variant | target device]'

local function matches(candidates, lead)
  local result = {}
  for _, candidate in ipairs(candidates) do
    if candidate:sub(1, #lead) == lead then result[#result + 1] = candidate end
  end
  return result
end

---@param arg_lead string
---@param command_line string
---@param cursor_position integer
---@return string[]
function M.complete(arg_lead, command_line, cursor_position)
  local before_cursor = command_line:sub(1, cursor_position)
  local words = vim.split(before_cursor, '%s+', { trimempty = true })
  local position = #words + (before_cursor:match '%s$' and 1 or 0)

  if position == 2 then return matches(SUBCOMMANDS, arg_lead) end
  if position == 3 and words[2] == 'target' then return matches(TARGETS, arg_lead) end
  if position == 3 and words[2] == 'emulator' then return matches(EMULATOR_ACTIONS, arg_lead) end
  if position == 3 and words[2] == 'logcat' then return matches(LOGCAT_ACTIONS, arg_lead) end
  return {}
end

local function invalid(message)
  require('android_workbench.notify').emit {
    level = 'error',
    code = 'invalid_command',
    message = message .. '\n' .. USAGE,
  }
  return false
end

---@param args string[]
---@param context? table
---@return boolean
function M.execute(args, context)
  local subcommand = args[1]
  local android = require 'android_workbench'

  if subcommand == nil then
    android.open_actions(context)
    return true
  end

  if subcommand == 'status' and #args == 1 then
    android.show_status(context)
    return true
  end

  if subcommand == 'refresh' and #args == 1 then
    android.refresh(context)
    return true
  end

  if subcommand == 'build' and #args == 1 then
    android.build(context)
    return true
  end

  if subcommand == 'run' and #args == 1 then
    android.run(context)
    return true
  end

  if subcommand == 'gradle' then
    if #args == 1 then
      android.gradle_task(context)
      return true
    end
    return invalid 'The gradle command does not accept arguments.'
  end

  if subcommand == 'output' and #args == 1 then
    android.show_task_output(context)
    return true
  end

  if subcommand == 'stop' and #args == 1 then
    android.stop(context)
    return true
  end

  if subcommand == 'cancel' and #args == 1 then
    android.cancel(context)
    return true
  end

  if subcommand == 'emulator' then
    if #args == 2 and args[2] == 'start' then
      android.start_emulator(context)
      return true
    end
    if #args == 2 and args[2] == 'stop' then
      android.stop_emulator(context)
      return true
    end
    return invalid 'The emulator command requires start or stop.'
  end

  if subcommand == 'logcat' then
    if #args == 1 then
      android.logcat(context)
      return true
    end
    if #args == 2 and args[2] == 'stop' then
      android.stop_logcat(context)
      return true
    end
    return invalid 'The logcat command accepts only stop.'
  end

  if subcommand == 'target' then
    if #args ~= 2 then return invalid 'The target command requires app, variant, or device.' end
    if args[2] ~= 'app' and args[2] ~= 'variant' and args[2] ~= 'device' then return invalid(('Unknown Android target: %s'):format(args[2])) end
    android.select_target(args[2], context)
    return true
  end

  return invalid(('Unknown Android subcommand: %s'):format(subcommand))
end

return M

-- vim: ts=2 sts=2 sw=2 et
