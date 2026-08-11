local M = {}

local Root = {}
Root.__index = Root

local wrapper_name = 'gradlew'
local wrapper_markers = { wrapper_name }

local function error_result(code, message, details)
  return {
    code = code,
    message = message,
    details = details,
  }
end

---@param opts? table
---@return table
function M.new(opts)
  opts = opts or {}
  return setmetatable({
    fs = opts.fs or vim.fs,
    uv = opts.uv or vim.uv,
  }, Root)
end

---@param path string
---@return string
function Root:canonicalize(path) return self.uv.fs_realpath(path) or self.fs.normalize(path) end

---@param context? { bufnr?: integer, path?: string, root?: string }|integer|string
---@return { root: string, wrapper: string }? result
---@return table? error
function Root:resolve(context)
  local source
  if type(context) == 'table' then
    source = context.root or context.path or context.bufnr
  else
    source = context
  end
  if source == nil then source = 0 end

  local ok, found = pcall(self.fs.root, source, wrapper_markers)
  if not ok then return nil, error_result('invalid_root_source', 'Could not inspect the requested Android project path.', tostring(found)) end
  if not found then return nil, error_result('gradle_wrapper_not_found', 'No Gradle wrapper was found for the current buffer or path.') end

  local root = self:canonicalize(found)
  local wrapper = self.fs.joinpath(root, wrapper_name)
  if self.uv.fs_stat(wrapper) then return {
    root = root,
    wrapper = wrapper,
  } end

  return nil, error_result('gradle_wrapper_not_found', ('The Gradle wrapper under %s is no longer available.'):format(root))
end

return M

-- vim: ts=2 sts=2 sw=2 et
