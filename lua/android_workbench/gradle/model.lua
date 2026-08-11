local Task = require 'android_workbench.gradle.task'

local M = {}

local MARKER = '__ANDROID_WORKBENCH_DISCOVERY_V1__'
local SCHEMA_VERSION = 1
local MAX_RECORDS = 20000
local MAX_RECORD_BYTES = 65536
local MAX_TASKS = Task.limits.max_tasks
local MAX_BUILDS = MAX_RECORDS
local MAX_TARGETS = MAX_RECORDS
local DISCOVERY_TASK = '__androidWorkbenchDiscoverV1'
local PROJECT_TASK = '__androidWorkbenchEmitProjectV1'
local FINGERPRINT_FIELD = '_android_workbench_gradle'

M.limits = {
  max_builds = MAX_BUILDS,
  max_targets = MAX_TARGETS,
  max_tasks = MAX_TASKS,
}

local function failure(code, message, details, source) return { code = code, message = message, details = details, source = source or 'protocol' } end

local function text(value, name, max_length)
  if type(value) ~= 'string' or value == '' or #value > max_length or value:find '[%z\1-\31]' then return nil, name .. ' must be a non-empty bounded string' end
  return value
end

local function path(value, name)
  local valid, err = text(value, name, 4096)
  if not valid then return nil, err end
  if valid:sub(1, 1) ~= ':' or valid:find('::', 1, true) or (#valid > 1 and valid:sub(-1) == ':') then return nil, name .. ' is not a canonical Gradle path' end
  return valid
end

local function list(value, name, maximum)
  if type(value) ~= 'table' or getmetatable(value) ~= nil or not vim.islist(value) then return nil, name .. ' must be a plain array' end
  if #value > (maximum or MAX_RECORDS) then return nil, name .. ' exceeds the discovery limit' end
  return value
end

local function integer(value, name, maximum)
  if type(value) ~= 'number' or value < 0 or value % 1 ~= 0 or value > (maximum or MAX_RECORDS) then
    return nil, name .. ' must be a bounded non-negative integer'
  end
  return value
end

local function project_key(build_path, project_path) return build_path .. '\0' .. project_path end

local function project_identity(build_path, project_path)
  local segments = {}
  if build_path ~= ':' then segments[#segments + 1] = build_path:sub(2) end
  if project_path ~= ':' then segments[#segments + 1] = project_path:sub(2) end
  return ':' .. table.concat(segments, ':')
end

local function qualify(build_path, project_path, task_name)
  local identity = project_identity(build_path, project_path)
  return (identity == ':' and ':' or identity .. ':') .. task_name
end

local function task_suffix(variant) return variant:sub(1, 1):upper() .. variant:sub(2) end

local function plain_object(value, allowed, required, name)
  if type(value) ~= 'table' or getmetatable(value) ~= nil or vim.islist(value) then return nil, name .. ' must be a plain object' end
  for key, _ in next, value do
    if type(key) ~= 'string' or not allowed[key] then return nil, name .. ' contains unsupported fields' end
  end
  for key, _ in pairs(required) do
    if rawget(value, key) == nil then return nil, name .. ' is missing ' .. key end
  end
  return value
end

local function record_lines(stdout)
  local records = {}
  for line in (stdout .. '\n'):gmatch '(.-)\r?\n' do
    if line:sub(1, #MARKER) == MARKER then
      local payload = line:sub(#MARKER + 1)
      if #payload > MAX_RECORD_BYTES then return nil, failure('record_too_large', 'Gradle discovery produced an oversized record') end
      if #records == MAX_RECORDS then return nil, failure('record_limit', 'Gradle discovery produced too many records') end
      local ok, decoded = pcall(vim.json.decode, payload)
      if not ok or type(decoded) ~= 'table' or vim.islist(decoded) then return nil, failure('invalid_json', 'Gradle discovery produced malformed JSONL') end
      records[#records + 1] = decoded
    end
  end
  if #records == 0 then return nil, failure('missing_protocol', 'Gradle emitted no Android Workbench records') end
  return records
end

local function validate_envelope(record, nonce)
  if record.schema ~= SCHEMA_VERSION then return 'unsupported discovery schema' end
  if record.nonce ~= nonce then return 'discovery nonce mismatch' end
  if type(record.type) ~= 'string' then return 'record type is missing' end
end

local function decode_target(record)
  local build_path, err = path(record.build_path, 'build_path')
  if not build_path then return nil, err end
  local project_path
  project_path, err = path(record.project_path, 'project_path')
  if not project_path then return nil, err end
  local build_root
  build_root, err = text(record.build_root, 'build_root', 16384)
  if not build_root then return nil, err end
  build_root = vim.fs.normalize(build_root)
  local project_dir
  project_dir, err = text(record.project_dir, 'project_dir', 16384)
  if not project_dir then return nil, err end
  project_dir = vim.fs.normalize(project_dir)
  local variant
  variant, err = text(record.variant, 'variant', 512)
  if not variant then return nil, err end
  local application_id
  application_id, err = text(record.application_id, 'application_id', 2048)
  if not application_id then return nil, err end
  local assemble_task
  assemble_task, err = path(record.assemble_task, 'assemble_task')
  if not assemble_task then return nil, err end

  local suffix = task_suffix(variant)
  if assemble_task ~= qualify(build_path, project_path, 'assemble' .. suffix) then return nil, 'assemble_task does not match its variant identity' end

  local install_task
  if record.install_task ~= nil and record.install_task ~= vim.NIL then
    install_task, err = path(record.install_task, 'install_task')
    if not install_task then return nil, err end
    if install_task ~= qualify(build_path, project_path, 'install' .. suffix) then return nil, 'install_task does not match its variant identity' end
  end

  local identity = project_identity(build_path, project_path)
  return {
    id = identity .. '#' .. variant,
    project_id = identity,
    build_path = build_path,
    build_root = build_root,
    project_path = project_path,
    project_dir = project_dir,
    variant = variant,
    application_id = application_id,
    assemble_task = assemble_task,
    install_task = install_task,
  }
end

local function decode_build(record)
  local build_path, err = path(record.build_path, 'build_path')
  if not build_path then return nil, err end
  local build_root
  build_root, err = text(record.build_root, 'build_root', 16384)
  if not build_root then return nil, err end
  build_root = vim.fs.normalize(build_root)
  local applications
  applications, err = list(record.application_projects, 'application_projects')
  if not applications then return nil, err end
  local includes
  includes, err = list(record.included_build_roots, 'included_build_roots')
  if not includes then return nil, err end
  local project_count
  project_count, err = integer(record.project_count, 'project_count')
  if not project_count then return nil, err end
  local task_count
  task_count, err = integer(record.task_count, 'task_count', MAX_TASKS)
  if not task_count then return nil, err end

  local seen_projects, seen_roots = {}, {}
  local project_paths, included_roots = {}, {}
  for _, value in ipairs(applications) do
    local project_path
    project_path, err = path(value, 'application project path')
    if not project_path then return nil, err end
    if seen_projects[project_path] then return nil, 'duplicate application project path' end
    seen_projects[project_path] = true
    project_paths[#project_paths + 1] = project_path
  end
  for _, value in ipairs(includes) do
    local included_root
    included_root, err = text(value, 'included build root', 16384)
    if not included_root then return nil, err end
    included_root = vim.fs.normalize(included_root)
    if seen_roots[included_root] then return nil, 'duplicate included build root' end
    seen_roots[included_root] = true
    included_roots[#included_roots + 1] = included_root
  end
  table.sort(project_paths)
  table.sort(included_roots)
  return {
    id = build_path,
    build_path = build_path,
    build_root = build_root,
    application_projects = project_paths,
    included_build_roots = included_roots,
    project_count = project_count,
    task_count = task_count,
  }
end

local function decode_task_chunk(record)
  local build_path, err = path(record.build_path, 'build_path')
  if not build_path then return nil, err end
  local project_path
  project_path, err = path(record.project_path, 'project_path')
  if not project_path then return nil, err end
  local chunk_index
  chunk_index, err = integer(record.chunk_index, 'chunk_index')
  if not chunk_index or chunk_index == 0 then return nil, err or 'chunk_index must be positive' end
  local names
  names, err = list(record.names, 'task names')
  if not names then return nil, err end
  if #names == 0 then return nil, 'task chunk must not be empty' end

  local tasks = {}
  for _, name in ipairs(names) do
    local id = Task.identity(build_path, project_path, name)
    if not id then return nil, 'task name is not executable or transportable' end
    tasks[#tasks + 1] = {
      id = id,
      build_path = build_path,
      project_path = project_path,
      name = name,
    }
  end
  return {
    build_path = build_path,
    project_path = project_path,
    chunk_index = chunk_index,
    tasks = tasks,
  }
end

local function decode_task_project(record)
  local build_path, err = path(record.build_path, 'build_path')
  if not build_path then return nil, err end
  local project_path
  project_path, err = path(record.project_path, 'project_path')
  if not project_path then return nil, err end
  local chunk_count
  chunk_count, err = integer(record.chunk_count, 'chunk_count')
  if not chunk_count then return nil, err end
  local task_count
  task_count, err = integer(record.task_count, 'task_count', MAX_TASKS)
  if not task_count then return nil, err end
  return {
    build_path = build_path,
    project_path = project_path,
    chunk_count = chunk_count,
    task_count = task_count,
  }
end

local SNAPSHOT_FIELDS = {
  [FINGERPRINT_FIELD] = true,
  builds = true,
  root = true,
  schema_version = true,
  targets = true,
  tasks = true,
}
local SNAPSHOT_REQUIRED = { builds = true, root = true, schema_version = true, targets = true, tasks = true }
local BUILD_FIELDS = {
  application_projects = true,
  build_path = true,
  build_root = true,
  id = true,
  included_build_roots = true,
  project_count = true,
  task_count = true,
}
local BUILD_REQUIRED = BUILD_FIELDS
local TARGET_FIELDS = {
  application_id = true,
  assemble_task = true,
  build_path = true,
  build_root = true,
  id = true,
  install_task = true,
  project_dir = true,
  project_id = true,
  project_path = true,
  variant = true,
}
local TARGET_REQUIRED = {
  application_id = true,
  assemble_task = true,
  build_path = true,
  build_root = true,
  id = true,
  project_dir = true,
  project_id = true,
  project_path = true,
  variant = true,
}
local FINGERPRINT_FIELDS = { fingerprint = true, reason = true, status = true, version = true }
local FINGERPRINT_REQUIRED = { status = true, version = true }

local function normalize_string_list(value, name)
  local values, err = list(value, name)
  if not values then return nil, err end
  local result, seen = {}, {}
  for _, candidate in ipairs(values) do
    local normalized
    normalized, err = path(candidate, name .. ' entry')
    if not normalized then return nil, err end
    if seen[normalized] then return nil, name .. ' entries must be unique' end
    seen[normalized] = true
    result[#result + 1] = normalized
  end
  table.sort(result)
  return result
end

local function normalize_root_list(value, name)
  local values, err = list(value, name)
  if not values then return nil, err end
  local result, seen = {}, {}
  for _, candidate in ipairs(values) do
    local normalized
    normalized, err = text(candidate, name .. ' entry', 16384)
    if not normalized then return nil, err end
    normalized = vim.fs.normalize(normalized)
    if seen[normalized] then return nil, name .. ' entries must be unique' end
    seen[normalized] = true
    result[#result + 1] = normalized
  end
  table.sort(result)
  return result
end

local function normalize_build(value)
  local _, err = plain_object(value, BUILD_FIELDS, BUILD_REQUIRED, 'build')
  if err then return nil, err end

  local build_path
  build_path, err = path(rawget(value, 'build_path'), 'build_path')
  if not build_path then return nil, err end
  if rawget(value, 'id') ~= build_path then return nil, 'build id does not match build_path' end

  local build_root
  build_root, err = text(rawget(value, 'build_root'), 'build_root', 16384)
  if not build_root then return nil, err end
  build_root = vim.fs.normalize(build_root)

  local application_projects
  application_projects, err = normalize_string_list(rawget(value, 'application_projects'), 'application_projects')
  if not application_projects then return nil, err end
  local included_build_roots
  included_build_roots, err = normalize_root_list(rawget(value, 'included_build_roots'), 'included_build_roots')
  if not included_build_roots then return nil, err end

  local project_count
  project_count, err = integer(rawget(value, 'project_count'), 'project_count')
  if not project_count or project_count == 0 then return nil, err or 'project_count must be positive' end
  local task_count
  task_count, err = integer(rawget(value, 'task_count'), 'task_count', MAX_TASKS)
  if not task_count then return nil, err end

  return {
    id = build_path,
    build_path = build_path,
    build_root = build_root,
    application_projects = application_projects,
    included_build_roots = included_build_roots,
    project_count = project_count,
    task_count = task_count,
  }
end

local function normalize_target(value)
  local _, err = plain_object(value, TARGET_FIELDS, TARGET_REQUIRED, 'target')
  if err then return nil, err end

  local build_path
  build_path, err = path(rawget(value, 'build_path'), 'build_path')
  if not build_path then return nil, err end
  local project_path
  project_path, err = path(rawget(value, 'project_path'), 'project_path')
  if not project_path then return nil, err end
  local build_root
  build_root, err = text(rawget(value, 'build_root'), 'build_root', 16384)
  if not build_root then return nil, err end
  build_root = vim.fs.normalize(build_root)
  local project_dir
  project_dir, err = text(rawget(value, 'project_dir'), 'project_dir', 16384)
  if not project_dir then return nil, err end
  project_dir = vim.fs.normalize(project_dir)
  local variant
  variant, err = text(rawget(value, 'variant'), 'variant', 512)
  if not variant then return nil, err end
  local application_id
  application_id, err = text(rawget(value, 'application_id'), 'application_id', 2048)
  if not application_id then return nil, err end

  local identity = project_identity(build_path, project_path)
  if rawget(value, 'project_id') ~= identity then return nil, 'project_id does not match its Gradle identity' end
  if rawget(value, 'id') ~= identity .. '#' .. variant then return nil, 'target id does not match its Gradle identity' end

  local suffix = task_suffix(variant)
  local assemble_task
  assemble_task, err = path(rawget(value, 'assemble_task'), 'assemble_task')
  if not assemble_task then return nil, err end
  if assemble_task ~= qualify(build_path, project_path, 'assemble' .. suffix) then return nil, 'assemble_task does not match its variant identity' end

  local install_task
  if rawget(value, 'install_task') ~= nil then
    install_task, err = path(rawget(value, 'install_task'), 'install_task')
    if not install_task then return nil, err end
    if install_task ~= qualify(build_path, project_path, 'install' .. suffix) then return nil, 'install_task does not match its variant identity' end
  end

  return {
    id = identity .. '#' .. variant,
    project_id = identity,
    build_path = build_path,
    build_root = build_root,
    project_path = project_path,
    project_dir = project_dir,
    variant = variant,
    application_id = application_id,
    assemble_task = assemble_task,
    install_task = install_task,
  }
end

local function normalize_fingerprint(value)
  local _, err = plain_object(value, FINGERPRINT_FIELDS, FINGERPRINT_REQUIRED, FINGERPRINT_FIELD)
  if err then return nil, err end
  if rawget(value, 'version') ~= 1 then return nil, FINGERPRINT_FIELD .. ' has an unsupported version' end

  local status = rawget(value, 'status')
  if status == 'fingerprinted' then
    local fingerprint = rawget(value, 'fingerprint')
    if type(fingerprint) ~= 'string' or #fingerprint ~= 64 or not fingerprint:match '^[0-9a-f]+$' or rawget(value, 'reason') ~= nil then
      return nil, FINGERPRINT_FIELD .. ' has an invalid fingerprint'
    end
    return { version = 1, status = status, fingerprint = fingerprint }
  end
  if status == 'unverifiable' then
    local reason = rawget(value, 'reason')
    if (reason ~= 'capture_unavailable' and reason ~= 'capture_failed') or rawget(value, 'fingerprint') ~= nil then
      return nil, FINGERPRINT_FIELD .. ' has an invalid unverifiable reason'
    end
    return { version = 1, status = status, reason = reason }
  end
  return nil, FINGERPRINT_FIELD .. ' has an invalid status'
end

function M.normalize(snapshot, requested_root)
  local _, err = plain_object(snapshot, SNAPSHOT_FIELDS, SNAPSHOT_REQUIRED, 'snapshot')
  if err then return nil, failure('invalid_snapshot', err, nil, 'normalizer') end
  if rawget(snapshot, 'schema_version') ~= SCHEMA_VERSION then
    return nil, failure('invalid_snapshot', 'snapshot has an unsupported schema version', nil, 'normalizer')
  end

  local root
  root, err = text(rawget(snapshot, 'root'), 'root', 16384)
  if not root then return nil, failure('invalid_snapshot', err, nil, 'normalizer') end
  root = vim.fs.normalize(root)
  if requested_root ~= nil and root ~= requested_root then
    return nil, failure('root_mismatch', 'discovery snapshot root does not match the requested project root', nil, 'normalizer')
  end

  local build_values
  build_values, err = list(rawget(snapshot, 'builds'), 'builds', MAX_BUILDS)
  if not build_values then return nil, failure('invalid_snapshot', err, nil, 'normalizer') end
  local target_values
  target_values, err = list(rawget(snapshot, 'targets'), 'targets', MAX_TARGETS)
  if not target_values then return nil, failure('invalid_snapshot', err, nil, 'normalizer') end
  local task_values
  task_values, err = list(rawget(snapshot, 'tasks'), 'tasks', MAX_TASKS)
  if not task_values then return nil, failure('invalid_snapshot', err, nil, 'normalizer') end

  local builds, builds_by_path, builds_by_root, projects_by_build = {}, {}, {}, {}
  for _, candidate in ipairs(build_values) do
    local build
    build, err = normalize_build(candidate)
    if not build then return nil, failure('invalid_build', err, nil, 'normalizer') end
    if builds_by_path[build.build_path] or builds_by_root[build.build_root] then
      return nil, failure('identity_collision', 'build paths and roots must be unique', nil, 'normalizer')
    end
    builds[#builds + 1] = build
    builds_by_path[build.build_path] = build
    builds_by_root[build.build_root] = build
    local projects = { [':'] = true }
    for _, project_path in ipairs(build.application_projects) do
      projects[project_path] = true
    end
    projects_by_build[build.build_path] = projects
  end
  table.sort(builds, function(left, right) return left.build_path < right.build_path end)

  local root_build = builds_by_path[':']
  if not root_build then return nil, failure('incomplete_snapshot', 'root build is missing', nil, 'normalizer') end
  if root_build.build_root ~= root then return nil, failure('root_mismatch', 'root build does not match the snapshot root', nil, 'normalizer') end

  for _, build in ipairs(builds) do
    for _, included_root in ipairs(build.included_build_roots) do
      if not builds_by_root[included_root] then
        return nil, failure('incomplete_snapshot', 'included build root does not identify a build', { build_root = included_root }, 'normalizer')
      end
    end
  end
  local reached = {}
  local function visit(build)
    if reached[build.build_path] then return end
    reached[build.build_path] = true
    for _, included_root in ipairs(build.included_build_roots) do
      visit(builds_by_root[included_root])
    end
  end
  visit(root_build)
  for build_path, _ in pairs(builds_by_path) do
    if not reached[build_path] then
      return nil, failure('incomplete_snapshot', 'build is unreachable from the root build', { build_path = build_path }, 'normalizer')
    end
  end

  local tasks, task_err = Task.normalize_catalog(task_values)
  if not tasks then return nil, failure('invalid_task', task_err, nil, 'normalizer') end
  local tasks_by_id, task_counts = {}, {}
  for _, task in ipairs(tasks) do
    local build = builds_by_path[task.build_path]
    if not build then return nil, failure('incomplete_snapshot', 'task references an unknown build', { task = task.id }, 'normalizer') end
    if task.project_path == ':' and task.name == DISCOVERY_TASK then
      return nil, failure('invalid_task', 'root discovery task is provider-internal', { task = task.id }, 'normalizer')
    end
    if task.name == PROJECT_TASK and vim.tbl_contains(build.application_projects, task.project_path) then
      return nil, failure('invalid_task', 'application project emitter is provider-internal', { task = task.id }, 'normalizer')
    end
    tasks_by_id[task.id] = task
    task_counts[task.build_path] = (task_counts[task.build_path] or 0) + 1
    projects_by_build[task.build_path][task.project_path] = true
  end
  for _, build in ipairs(builds) do
    if (task_counts[build.build_path] or 0) ~= build.task_count then
      return nil, failure('incomplete_snapshot', 'build task count does not match the task catalog', { build_path = build.build_path }, 'normalizer')
    end
    local known_projects = 0
    for _ in pairs(projects_by_build[build.build_path]) do
      known_projects = known_projects + 1
    end
    if known_projects > build.project_count then
      return nil, failure('incomplete_snapshot', 'build project count is smaller than its known projects', { build_path = build.build_path }, 'normalizer')
    end
  end

  local targets, targets_by_id = {}, {}
  for _, candidate in ipairs(target_values) do
    local target
    target, err = normalize_target(candidate)
    if not target then return nil, failure('invalid_target', err, nil, 'normalizer') end
    if targets_by_id[target.id] then return nil, failure('identity_collision', 'target ids must be unique', { target = target.id }, 'normalizer') end
    local build = builds_by_path[target.build_path]
    if not build or target.build_root ~= build.build_root then
      return nil, failure('incomplete_snapshot', 'target does not match a known build', { target = target.id }, 'normalizer')
    end
    if not projects_by_build[target.build_path][target.project_path] or not vim.tbl_contains(build.application_projects, target.project_path) then
      return nil, failure('incomplete_snapshot', 'target project is not declared by its build', { target = target.id }, 'normalizer')
    end
    if not tasks_by_id[target.assemble_task] or (target.install_task and not tasks_by_id[target.install_task]) then
      return nil, failure('incomplete_snapshot', 'target execution tasks are missing from the task catalog', { target = target.id }, 'normalizer')
    end
    targets[#targets + 1] = target
    targets_by_id[target.id] = true
  end
  table.sort(targets, function(left, right) return left.id < right.id end)

  local normalized = {
    schema_version = SCHEMA_VERSION,
    root = root,
    builds = builds,
    targets = targets,
    tasks = tasks,
  }
  if rawget(snapshot, FINGERPRINT_FIELD) ~= nil then
    local fingerprint
    fingerprint, err = normalize_fingerprint(rawget(snapshot, FINGERPRINT_FIELD))
    if not fingerprint then return nil, failure('invalid_snapshot', err, nil, 'normalizer') end
    normalized[FINGERPRINT_FIELD] = fingerprint
  end
  return normalized
end

function M.decode(stdout, nonce, requested_root)
  local records, records_err = record_lines(stdout)
  if not records then return nil, records_err end

  for _, record in ipairs(records) do
    local envelope_err = validate_envelope(record, nonce)
    if envelope_err then return nil, failure('invalid_record', envelope_err) end
    if record.type == 'error' then
      local code = type(record.code) == 'string' and record.code or 'provider_error'
      local message = type(record.message) == 'string' and record.message or 'Gradle discovery failed'
      return nil, failure(code, message, record.details, 'provider')
    end
  end

  local builds_by_path, builds_by_root = {}, {}
  local projects, targets, targets_by_project = {}, {}, {}
  local task_chunks, task_projects, tasks = {}, {}, {}
  local tree_count = 0

  for _, record in ipairs(records) do
    if record.type == 'target' then
      local target, err = decode_target(record)
      if not target then return nil, failure('invalid_target', err) end
      if targets[target.id] then return nil, failure('identity_collision', 'duplicate target identity: ' .. target.id) end
      targets[target.id] = target
      local key = project_key(target.build_path, target.project_path)
      targets_by_project[key] = (targets_by_project[key] or 0) + 1
    elseif record.type == 'project_complete' then
      local build_path, err = path(record.build_path, 'build_path')
      if not build_path then return nil, failure('invalid_project', err) end
      local project_path
      project_path, err = path(record.project_path, 'project_path')
      if not project_path then return nil, failure('invalid_project', err) end
      local count
      count, err = integer(record.target_count, 'target_count')
      if not count then return nil, failure('invalid_project', err) end
      local key = project_key(build_path, project_path)
      if projects[key] then return nil, failure('identity_collision', 'duplicate project completion record') end
      projects[key] = { build_path = build_path, project_path = project_path, target_count = count }
    elseif record.type == 'task_chunk' then
      local chunk, err = decode_task_chunk(record)
      if not chunk then return nil, failure('invalid_task', err) end
      local key = project_key(chunk.build_path, chunk.project_path)
      task_chunks[key] = task_chunks[key] or {}
      if task_chunks[key][chunk.chunk_index] then return nil, failure('identity_collision', 'duplicate task chunk index') end
      task_chunks[key][chunk.chunk_index] = chunk
      for _, task in ipairs(chunk.tasks) do
        if tasks[task.id] then return nil, failure('identity_collision', 'duplicate task identity: ' .. task.id) end
        tasks[task.id] = task
      end
    elseif record.type == 'task_project_complete' then
      local project, err = decode_task_project(record)
      if not project then return nil, failure('invalid_task_project', err) end
      local key = project_key(project.build_path, project.project_path)
      if task_projects[key] then return nil, failure('identity_collision', 'duplicate task project completion record') end
      task_projects[key] = project
    elseif record.type == 'build_complete' then
      local build, err = decode_build(record)
      if not build then return nil, failure('invalid_build', err) end
      if builds_by_path[build.build_path] or builds_by_root[build.build_root] then
        return nil, failure('identity_collision', 'duplicate build identity or canonical root')
      end
      builds_by_path[build.build_path] = build
      builds_by_root[build.build_root] = build
    elseif record.type == 'tree_complete' then
      tree_count = tree_count + 1
      if record.build_path ~= ':' then return nil, failure('invalid_tree', 'tree completion did not come from the root build') end
    elseif record.type ~= 'error' then
      return nil, failure('unknown_record', 'unknown Gradle discovery record: ' .. tostring(record.type))
    end
  end

  if tree_count ~= 1 then return nil, failure('incomplete_tree', 'expected exactly one tree completion record') end
  local root_build = builds_by_path[':']
  if not root_build then return nil, failure('incomplete_tree', 'root build completion record is missing') end
  if requested_root and root_build.build_root ~= requested_root then
    return nil, failure('root_mismatch', 'Gradle model root does not match the requested project root')
  end

  for key, chunks in pairs(task_chunks) do
    local project = task_projects[key]
    if not project then return nil, failure('incomplete_tree', 'task chunk has no project completion record') end
    local chunk_count, task_count = 0, 0
    for _, chunk in pairs(chunks) do
      chunk_count = chunk_count + 1
      task_count = task_count + #chunk.tasks
    end
    if chunk_count ~= project.chunk_count then return nil, failure('incomplete_tree', 'task chunk count does not match project completion record') end
    if task_count ~= project.task_count then return nil, failure('incomplete_tree', 'task count does not match project completion record') end
    for index = 1, project.chunk_count do
      if not chunks[index] then return nil, failure('incomplete_tree', 'task chunks are not contiguous') end
    end
  end
  for key, project in pairs(task_projects) do
    if not builds_by_path[project.build_path] then return nil, failure('incomplete_tree', 'task project references an unknown build') end
    local chunks = task_chunks[key]
    if project.chunk_count == 0 then
      if project.task_count ~= 0 then return nil, failure('incomplete_tree', 'zero-chunk task project has a nonzero task count') end
    elseif not chunks then
      return nil, failure('incomplete_tree', 'task project chunks are missing')
    end
  end

  for _, task in pairs(tasks) do
    if task.project_path == ':' and task.name == DISCOVERY_TASK then
      return nil, failure('invalid_task', 'root discovery task was not filtered from the task model')
    end
    local build = builds_by_path[task.build_path]
    if not build then return nil, failure('incomplete_tree', 'task references an unknown build') end
    if task.name == PROJECT_TASK and vim.tbl_contains(build.application_projects, task.project_path) then
      return nil, failure('invalid_task', 'application project emitter was not filtered from the task model')
    end
  end

  for key, project in pairs(projects) do
    local build = builds_by_path[project.build_path]
    if not build then return nil, failure('incomplete_tree', 'application project references an unknown build') end
    if not vim.tbl_contains(build.application_projects, project.project_path) then
      return nil, failure('incomplete_tree', 'undeclared application project completion record')
    end
    if (targets_by_project[key] or 0) ~= project.target_count then
      return nil, failure('incomplete_tree', 'target count does not match project completion record')
    end
  end
  for _, build in pairs(builds_by_path) do
    local project_count, task_count = 0, 0
    for _, project in pairs(task_projects) do
      if project.build_path == build.build_path then
        project_count = project_count + 1
        task_count = task_count + project.task_count
      end
    end
    if project_count ~= build.project_count then return nil, failure('incomplete_tree', 'task project count does not match build completion record') end
    if task_count ~= build.task_count then return nil, failure('incomplete_tree', 'task count does not match build completion record') end
    if not task_projects[project_key(build.build_path, ':')] then return nil, failure('incomplete_tree', 'root project task completion record is missing') end
    for _, project_path in ipairs(build.application_projects) do
      if not projects[project_key(build.build_path, project_path)] then
        return nil, failure('incomplete_tree', 'application project completion record is missing')
      end
      if not task_projects[project_key(build.build_path, project_path)] then
        return nil, failure('incomplete_tree', 'application project task completion record is missing')
      end
    end
    for _, included_root in ipairs(build.included_build_roots) do
      if not builds_by_root[included_root] then return nil, failure('incomplete_tree', 'included build completion record is missing') end
    end
  end
  for key, _ in pairs(targets_by_project) do
    if not projects[key] then return nil, failure('incomplete_tree', 'target has no project completion record') end
  end
  for _, target in pairs(targets) do
    local build = builds_by_path[target.build_path]
    if not build or target.build_root ~= build.build_root then
      return nil, failure('incomplete_tree', 'target build identity does not match its build completion record')
    end
  end

  local reached = {}
  local function visit(build)
    if reached[build.build_path] then return end
    reached[build.build_path] = true
    for _, included_root in ipairs(build.included_build_roots) do
      visit(builds_by_root[included_root])
    end
  end
  visit(root_build)
  for build_path, _ in pairs(builds_by_path) do
    if not reached[build_path] then return nil, failure('incomplete_tree', 'unreachable build record: ' .. build_path) end
  end

  local build_list, target_list, task_list = {}, {}, {}
  for _, build in pairs(builds_by_path) do
    build_list[#build_list + 1] = build
  end
  for _, target in pairs(targets) do
    target_list[#target_list + 1] = target
  end
  for _, task in pairs(tasks) do
    task_list[#task_list + 1] = task
  end
  table.sort(build_list, function(left, right) return left.build_path < right.build_path end)
  table.sort(target_list, function(left, right) return left.id < right.id end)
  table.sort(task_list, function(left, right) return left.id < right.id end)

  return M.normalize(
    { schema_version = SCHEMA_VERSION, root = root_build.build_root, builds = build_list, targets = target_list, tasks = task_list },
    requested_root
  )
end

M.marker = MARKER

return M
