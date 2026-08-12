local M = {}

---@param root string
---@return string? wrapper
---@return string? error
function M.resolve(root)
  local path = vim.fs.joinpath(root, 'gradlew')
  local stat = vim.uv.fs_stat(path)
  if not stat then return nil, 'No Gradle wrapper found under ' .. root end
  if stat.type ~= 'file' then return nil, 'Gradle wrapper is not a file: ' .. path end
  if vim.fn.executable(path) ~= 1 then return nil, 'Gradle wrapper is not executable: ' .. path end
  return path
end

return M

-- vim: ts=2 sts=2 sw=2 et
