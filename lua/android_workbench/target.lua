local M = {}

local function key(app)
  if not app then return nil end
  return ('%d:%s%d:%s'):format(#app.build_path, app.build_path, #app.project_path, app.project_path)
end

function M.same_app(left, right)
  if type(left) ~= 'table' or type(right) ~= 'table' then return false end
  local left_build = rawget(left, 'build_path')
  local left_project = rawget(left, 'project_path')
  return type(left_build) == 'string'
    and type(left_project) == 'string'
    and left_build == rawget(right, 'build_path')
    and left_project == rawget(right, 'project_path')
end

function M.app_label(app)
  if app.build_path == ':' then return app.project_path end
  if app.project_path == ':' then return app.build_path end
  return app.build_path .. app.project_path
end

function M.target_label(target) return ('%s · %s'):format(M.app_label(target), target.variant) end

function M.applications(snapshot)
  local result = {}
  local seen = {}
  for _, target in ipairs(snapshot.targets) do
    local identity = key(target)
    if not seen[identity] then
      seen[identity] = true
      result[#result + 1] = {
        build_path = target.build_path,
        build_root = target.build_root,
        project_path = target.project_path,
        project_dir = target.project_dir,
      }
    end
  end
  table.sort(result, function(left, right) return M.app_label(left) < M.app_label(right) end)
  return result
end

function M.variants(snapshot, app)
  local result = {}
  local seen = {}
  for _, target in ipairs(snapshot.targets) do
    if M.same_app(target, app) and not seen[target.variant] then
      seen[target.variant] = true
      result[#result + 1] = target.variant
    end
  end
  table.sort(result)
  return result
end

function M.contains_variant(items, variant)
  for _, item in ipairs(items) do
    if item == variant then return true end
  end
  return false
end

function M.find(snapshot, selection)
  if not selection or not selection.app or not selection.variant then return nil end
  for _, target in ipairs(snapshot.targets) do
    if M.same_app(target, selection.app) and target.variant == selection.variant then return target end
  end
end

function M.sorted(snapshot)
  local result = vim.deepcopy(snapshot.targets)
  table.sort(result, function(left, right) return M.target_label(left) < M.target_label(right) end)
  return result
end

return M

-- vim: ts=2 sts=2 sw=2 et
