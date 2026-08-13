local M = {}

local function idle(status) return status.operation == nil end

local function selected(status, field)
  local selection = status.selection or {}
  return selection[field] ~= nil
end

local function selected_device(status)
  local selection = status.selection or {}
  if type(selection.device) ~= 'table' then return nil end
  return selection.device
end

local function can_stop_application(status)
  local device = selected_device(status)
  return idle(status) and selected(status, 'app') and selected(status, 'variant') and device ~= nil and device.serial ~= nil
end

local function can_stop_emulator(status)
  local device = selected_device(status)
  return idle(status) and device ~= nil and device.avd_name ~= nil and device.serial ~= nil
end

local function logcat_stopped(status) return status.logcat == nil or status.logcat == 'stopped' end

local function logcat_running(status) return status.logcat == 'running' end

local function logcat_active(status) return status.logcat == 'starting' or logcat_running(status) end

local function task_output_available(status) return status.task_output == true end

local registry = {
  { id = 'build', label = 'Build', argv = { 'build' }, predicate = idle },
  { id = 'run', label = 'Run', argv = { 'run' }, predicate = idle },
  { id = 'gradle_task', label = 'Run Gradle task', argv = { 'gradle' }, predicate = idle },
  { id = 'stop', label = 'Stop application', argv = { 'stop' }, predicate = can_stop_application },
  { id = 'manage_emulators', label = 'Manage emulators', argv = { 'emulator' }, predicate = idle },
  { id = 'start_emulator', label = 'Start emulator', argv = { 'emulator', 'start' }, predicate = idle },
  { id = 'stop_emulator', label = 'Stop emulator', argv = { 'emulator', 'stop' }, predicate = can_stop_emulator },
  { id = 'cancel_build', label = 'Cancel build', argv = { 'cancel' }, predicate = function(status) return status.operation == 'build' end },
  { id = 'cancel_run', label = 'Cancel run', argv = { 'cancel' }, predicate = function(status) return status.operation == 'run' end },
  {
    id = 'cancel_gradle_task',
    label = 'Cancel Gradle task',
    argv = { 'cancel' },
    predicate = function(status) return status.operation == 'gradle_task' end,
  },
  { id = 'cancel_stop', label = 'Cancel stop', argv = { 'cancel' }, predicate = function(status) return status.operation == 'stop' end },
  { id = 'show_task_output', label = 'Show task output', argv = { 'output' }, predicate = task_output_available },
  {
    id = 'cancel_emulator_start',
    label = 'Cancel emulator start',
    argv = { 'cancel' },
    predicate = function(status) return status.operation == 'emulator_start' end,
  },
  {
    id = 'cancel_emulator_cold_boot',
    label = 'Cancel emulator Cold Boot',
    argv = { 'cancel' },
    predicate = function(status) return status.operation == 'emulator_cold_boot' end,
  },
  {
    id = 'cancel_emulator_manage',
    label = 'Cancel emulator manager',
    argv = { 'cancel' },
    predicate = function(status) return status.operation == 'emulator_manage' end,
  },
  {
    id = 'cancel_emulator_stop',
    label = 'Cancel emulator stop',
    argv = { 'cancel' },
    predicate = function(status) return status.operation == 'emulator_stop' end,
  },
  { id = 'open_logcat', label = 'Open Logcat', argv = { 'logcat' }, predicate = logcat_stopped },
  { id = 'show_logcat', label = 'Show Logcat', argv = { 'logcat' }, predicate = logcat_running },
  { id = 'select_logcat_session', label = 'Select Logcat session', argv = { 'logcat', 'sessions' }, predicate = logcat_running },
  { id = 'stop_logcat', label = 'Stop current Logcat session', argv = { 'logcat', 'stop' }, predicate = logcat_active },
  { id = 'stop_all_logcats', label = 'Stop all Logcat sessions', argv = { 'logcat', 'stop', 'all' }, predicate = logcat_running },
  { id = 'select_app', label = 'Select application', argv = { 'target', 'app' }, predicate = idle },
  {
    id = 'select_variant',
    label = 'Select variant',
    argv = { 'target', 'variant' },
    predicate = function(status) return idle(status) and selected(status, 'app') end,
  },
  { id = 'select_device', label = 'Select device', argv = { 'target', 'device' }, predicate = idle },
  { id = 'refresh', label = 'Refresh project', argv = { 'refresh' }, predicate = idle },
  { id = 'status', label = 'Show status', argv = { 'status' }, predicate = function() return true end },
}

---@param status table
---@return table[]
function M.available(status)
  local result = {}
  for _, action in ipairs(registry) do
    if action.predicate(status) then
      local argv = {}
      for index, argument in ipairs(action.argv) do
        argv[index] = argument
      end
      result[#result + 1] = {
        id = action.id,
        label = action.label,
        argv = argv,
      }
    end
  end
  return result
end

return M

-- vim: ts=2 sts=2 sw=2 et
