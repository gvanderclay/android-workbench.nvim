local M = {}

local FINGERPRINT_FIELD = '_android_workbench_gradle'
local FINGERPRINT_VERSION = 1
local MAX_ENTRIES = 100000
local MAX_FILES = 20000
local MAX_FILE_BYTES = 4 * 1024 * 1024
local MAX_TOTAL_BYTES = 32 * 1024 * 1024

local ignored_directories = {
  build = true,
  node_modules = true,
  out = true,
  target = true,
}

local exact_metadata_files = {
  ['gradle.properties'] = true,
  ['gradle.lockfile'] = true,
  ['gradlew'] = true,
  ['local.properties'] = true,
}

local function under(path, directory) return path == directory or path:sub(1, #directory + 1) == directory .. '/' end

local function has_segment(path, segment)
  return path == segment or path:sub(1, #segment + 1) == segment .. '/' or path:find('/' .. segment .. '/', 1, true) ~= nil
end

local function relevant(relative_path, track_sources)
  local name = vim.fs.basename(relative_path)
  if exact_metadata_files[name] then return true end
  if name == 'AndroidManifest.xml' then return true end
  if relative_path:sub(-7) == '.gradle' or relative_path:sub(-11) == '.gradle.kts' then return true end
  if relative_path:sub(-5) == '.toml' then return true end
  if under(relative_path, 'gradle') or has_segment(relative_path, 'buildSrc') then return true end
  return track_sources and has_segment(relative_path, 'src')
end

local function canonical_directory(path)
  if type(path) ~= 'string' or path == '' then return nil end
  local resolved = vim.uv.fs_realpath(path)
  local stat = resolved and vim.uv.fs_stat(resolved)
  if not stat or stat.type ~= 'directory' then return nil end
  return vim.fs.normalize(resolved)
end

local function roots_for(snapshot)
  if type(snapshot) ~= 'table' then return nil end

  local roots = {}
  local root = canonical_directory(snapshot.root)
  if not root then return nil end
  roots[root] = false

  if type(snapshot.builds) ~= 'table' or not vim.islist(snapshot.builds) then return nil end
  for _, build in ipairs(snapshot.builds) do
    if type(build) ~= 'table' then return nil end
    local build_root = canonical_directory(build.build_root)
    if not build_root then return nil end
    roots[build_root] = roots[build_root] or build.build_path ~= ':'
  end

  local result = {}
  for path, track_sources in pairs(roots) do
    result[#result + 1] = { path = path, track_sources = track_sources }
  end
  table.sort(result, function(left, right) return left.path < right.path end)
  return result
end

local function read_digest(path, budget)
  local descriptor = vim.uv.fs_open(path, 'r', tonumber('400', 8))
  if not descriptor then return nil end

  local stat = vim.uv.fs_fstat(descriptor)
  if not stat or stat.type ~= 'file' or stat.size > MAX_FILE_BYTES or budget.bytes + stat.size > MAX_TOTAL_BYTES then
    vim.uv.fs_close(descriptor)
    return nil
  end

  local content = vim.uv.fs_read(descriptor, stat.size, 0)
  vim.uv.fs_close(descriptor)
  if type(content) ~= 'string' or #content ~= stat.size then return nil end

  budget.bytes = budget.bytes + stat.size
  return vim.fn.sha256(content)
end

local function add_file(files, path, budget)
  path = vim.fs.normalize(path)
  if files[path] then return true end
  budget.files = budget.files + 1
  if budget.files > MAX_FILES then return false end

  local digest = read_digest(path, budget)
  if not digest then return false end
  files[path] = digest
  return true
end

local function scan_root(root, files, budget)
  local iterator = vim.fs.dir(root.path, {
    depth = math.huge,
    skip = function(relative)
      local name = vim.fs.basename(relative)
      return name:sub(1, 1) ~= '.' and not ignored_directories[name]
    end,
  })

  for relative, kind in iterator do
    budget.entries = budget.entries + 1
    if budget.entries > MAX_ENTRIES then return false end

    local path = vim.fs.joinpath(root.path, relative)
    if kind == 'link' then
      local stat = vim.uv.fs_stat(path)
      kind = stat and stat.type or nil
    end
    if kind == 'file' and relevant(relative, root.track_sources) and not add_file(files, path, budget) then return false end
  end
  return true
end

local function capture(snapshot, provider_path)
  local roots = roots_for(snapshot)
  if not roots or type(provider_path) ~= 'string' then return nil end

  local provider = vim.uv.fs_realpath(provider_path)
  if not provider then return nil end

  local files = {}
  local budget = { entries = 0, files = 0, bytes = 0 }
  if not add_file(files, provider, budget) then return nil end
  for _, root in ipairs(roots) do
    if not scan_root(root, files, budget) then return nil end
  end

  local records = { 'android-workbench-gradle-metadata-v' .. FINGERPRINT_VERSION }
  for path, digest in pairs(files) do
    records[#records + 1] = path .. '\0' .. digest
  end
  table.sort(records)
  return vim.fn.sha256(table.concat(records, '\n'))
end

function M.stamp(snapshot, provider_path)
  if type(snapshot) ~= 'table' then return snapshot end
  local ok, fingerprint = pcall(capture, snapshot, provider_path)
  local usable = ok and type(fingerprint) == 'string'
  local stamp = {
    version = FINGERPRINT_VERSION,
    status = usable and 'fingerprinted' or 'unverifiable',
  }
  if usable then
    stamp.fingerprint = fingerprint
  else
    stamp.reason = ok and 'capture_unavailable' or 'capture_failed'
  end
  snapshot[FINGERPRINT_FIELD] = stamp
  return snapshot
end

function M.freshness(snapshot, provider_path)
  if type(snapshot) ~= 'table' then return 'untracked' end
  local metadata = snapshot[FINGERPRINT_FIELD]
  if type(metadata) ~= 'table' or metadata.version ~= FINGERPRINT_VERSION then return 'untracked' end
  if metadata.status == 'unverifiable' then return 'unverifiable' end
  if metadata.status ~= 'fingerprinted' or type(metadata.fingerprint) ~= 'string' then return 'untracked' end
  local ok, current = pcall(capture, snapshot, provider_path)
  if not ok or type(current) ~= 'string' then return 'unverifiable' end
  return current == metadata.fingerprint and 'fresh' or 'changed'
end

function M.is_stale(snapshot, provider_path)
  local value = M.freshness(snapshot, provider_path)
  if value == 'unverifiable' then
    local stamped = type(snapshot) == 'table' and snapshot[FINGERPRINT_FIELD] or nil
    if type(stamped) == 'table' and stamped.version == FINGERPRINT_VERSION and stamped.status == 'unverifiable' then return false end
  end
  return value ~= 'fresh'
end

return M
