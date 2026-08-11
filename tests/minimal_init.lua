local root = vim.env.ANDROID_WORKBENCH_TEST_ROOT
if type(root) ~= 'string' or root == '' then error 'ANDROID_WORKBENCH_TEST_ROOT is required' end

local runtimepath = { root, vim.env.VIMRUNTIME }
local nvim_lib = vim.fs.normalize(vim.fs.joinpath(vim.env.VIMRUNTIME, '..', '..', '..', 'lib', 'nvim'))
if vim.uv.fs_stat(nvim_lib) then runtimepath[#runtimepath + 1] = nvim_lib end

vim.opt.runtimepath = runtimepath
vim.opt.packpath = { root, vim.env.VIMRUNTIME }
vim.opt.loadplugins = true

-- vim: ts=2 sts=2 sw=2 et
