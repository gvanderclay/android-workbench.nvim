dofile(vim.fs.joinpath(vim.env.ANDROID_WORKBENCH_TEST_ROOT, 'tests', 'minimal_init.lua'))

_G.android_workbench_collision = {
  calls = 0,
  notifications = {},
}

vim.notify = function(message, level)
  table.insert(_G.android_workbench_collision.notifications, {
    message = message,
    level = level,
  })
end

vim.api.nvim_create_user_command('Android', function() _G.android_workbench_collision.calls = _G.android_workbench_collision.calls + 1 end, {})

-- vim: ts=2 sts=2 sw=2 et
