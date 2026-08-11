local M = {}

local function trust_error(code, message, root, details)
  return {
    code = code,
    message = message,
    root = root,
    details = details,
  }
end

---@param opts? { read?: fun(path: string): boolean|string? }
---@return table
function M.new(opts)
  opts = opts or {}
  local read = opts.read or vim.secure.read

  return {
    authorize = function(root)
      local checked, trusted = pcall(read, root)
      if not checked then return nil, trust_error('trust_check_failed', ('Could not check trust for %s.'):format(root), root, tostring(trusted)) end
      if trusted == true then return true end

      return nil,
        trust_error(
          'project_not_trusted',
          ('Android project discovery was not authorized for %s. Review the project, then use :trust to change this choice.'):format(root),
          root
        )
    end,
  }
end

return M

-- vim: ts=2 sts=2 sw=2 et
