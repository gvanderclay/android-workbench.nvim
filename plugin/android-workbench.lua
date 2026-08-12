if vim.g.loaded_android_workbench then return end
vim.g.loaded_android_workbench = true

if vim.fn.exists ':Android' == 2 then
  vim.notify('Android Workbench: :Android already exists; command registration skipped.', vim.log.levels.WARN)
  return
end

vim.api.nvim_create_user_command('Android', function(command)
  local ok, err = pcall(function() require('android_workbench.command').execute(command.fargs) end)
  if not ok then require('android_workbench.notify').emit {
    level = 'error',
    code = 'command_failed',
    message = tostring(err),
  } end
end, {
  nargs = '*',
  complete = function(...) return require('android_workbench.command').complete(...) end,
  desc = 'Android Workbench',
  force = false,
})

-- vim: ts=2 sts=2 sw=2 et
