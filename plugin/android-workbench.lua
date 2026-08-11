if vim.g.loaded_android_workbench then return end

vim.api.nvim_create_user_command('Android', function(command)
  local ok, err = pcall(function() require('android_workbench.command').execute(command.fargs) end)
  if not ok then require('android_workbench')._notify {
    level = 'error',
    code = 'command_failed',
    message = tostring(err),
  } end
end, {
  nargs = '*',
  complete = function(...) return require('android_workbench.command').complete(...) end,
  desc = 'Android Workbench',
})
vim.g.loaded_android_workbench = true

-- vim: ts=2 sts=2 sw=2 et
