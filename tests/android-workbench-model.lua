local failures = {}

local function fail(name, message) failures[#failures + 1] = ('%s: %s'):format(name, message) end

local function expect(name, actual, expected)
  if vim.deep_equal(actual, expected) then return end
  fail(name, ('expected %s, got %s'):format(vim.inspect(expected), vim.inspect(actual)))
end

local function expect_true(name, value)
  if value then return end
  fail(name, 'expected a truthy value')
end

local model = require 'android_workbench.gradle.model'
local Task = require 'android_workbench.gradle.task'
local nonce = '0123456789abcdef0123456789abcdef'
local root = '/tmp/android-workbench-model-root'
local included_root = root .. '/build-logic'

local function fixture()
  return {
    {
      type = 'target',
      build_path = ':',
      build_root = root,
      project_path = ':app',
      project_dir = root .. '/app',
      variant = 'debug',
      application_id = 'example.app.debug',
      assemble_task = ':app:assembleDebug',
      install_task = ':app:installDebug',
    },
    {
      type = 'target',
      build_path = ':build-logic',
      build_root = included_root,
      project_path = ':demo',
      project_dir = included_root .. '/demo',
      variant = 'release',
      application_id = 'example.demo',
      assemble_task = ':build-logic:demo:assembleRelease',
      install_task = ':build-logic:demo:installRelease',
    },
    { type = 'project_complete', build_path = ':', project_path = ':app', target_count = 1 },
    { type = 'project_complete', build_path = ':build-logic', project_path = ':demo', target_count = 1 },
    {
      type = 'build_complete',
      build_path = ':',
      build_root = root,
      application_projects = { ':app' },
      included_build_roots = { included_root },
      project_count = 2,
      task_count = 5,
    },
    {
      type = 'build_complete',
      build_path = ':build-logic',
      build_root = included_root,
      application_projects = { ':demo' },
      included_build_roots = {},
      project_count = 2,
      task_count = 3,
    },
    {
      type = 'task_chunk',
      build_path = ':',
      project_path = ':',
      chunk_index = 1,
      names = { '__androidWorkbenchEmitProjectV1', 'help' },
    },
    { type = 'task_project_complete', build_path = ':', project_path = ':', chunk_count = 1, task_count = 2 },
    {
      type = 'task_chunk',
      build_path = ':',
      project_path = ':app',
      chunk_index = 1,
      names = { '__androidWorkbenchDiscoverV1', 'assembleDebug', 'installDebug' },
    },
    { type = 'task_project_complete', build_path = ':', project_path = ':app', chunk_count = 1, task_count = 3 },
    { type = 'task_chunk', build_path = ':build-logic', project_path = ':', chunk_index = 1, names = { 'help' } },
    { type = 'task_project_complete', build_path = ':build-logic', project_path = ':', chunk_count = 1, task_count = 1 },
    {
      type = 'task_chunk',
      build_path = ':build-logic',
      project_path = ':demo',
      chunk_index = 1,
      names = { 'assembleRelease', 'installRelease' },
    },
    { type = 'task_project_complete', build_path = ':build-logic', project_path = ':demo', chunk_count = 1, task_count = 2 },
    { type = 'tree_complete', build_path = ':' },
  }
end

local function jsonl(records)
  local lines = {}
  for _, source in ipairs(records) do
    local record = vim.deepcopy(source)
    if record.schema == nil then record.schema = 1 end
    if record.nonce == nil then record.nonce = nonce end
    lines[#lines + 1] = model.marker .. vim.json.encode(record)
  end
  return table.concat(lines, '\n') .. '\n'
end

local function changed(change)
  local records = fixture()
  change(records)
  return records
end

local function expect_error(name, records, code, message)
  local snapshot, err = model.decode(jsonl(records), nonce, root)
  expect(name .. ' returns no snapshot', snapshot, nil)
  expect(name .. ' error code', err and err.code, code)
  if message then expect_true(name .. ' error is specific', err and type(err.message) == 'string' and err.message:find(message, 1, true)) end
end

local function expect_output_error(name, output, code)
  local snapshot, err = model.decode(output, nonce, root)
  expect(name .. ' returns no snapshot', snapshot, nil)
  expect(name .. ' error code', err and err.code, code)
end

local ok, unexpected = xpcall(function()
  local snapshot, err = model.decode(jsonl(fixture()), nonce, root)
  expect('complete composite model has no error', err, nil)
  expect('complete composite model keeps requested root', snapshot and snapshot.root, root)
  expect('builds are sorted by qualified identity', vim.tbl_map(function(build) return build.id end, snapshot.builds), { ':', ':build-logic' })
  expect('targets are sorted by qualified identity', vim.tbl_map(function(target) return target.id end, snapshot.targets), {
    ':app#debug',
    ':build-logic:demo#release',
  })
  expect('root target retains its qualified assemble task', snapshot.targets[1].assemble_task, ':app:assembleDebug')
  expect('included target retains its qualified install task', snapshot.targets[2].install_task, ':build-logic:demo:installRelease')
  expect('tasks are sorted by exact qualified identity', vim.tbl_map(function(task) return task.id end, snapshot.tasks), {
    ':__androidWorkbenchEmitProjectV1',
    ':app:__androidWorkbenchDiscoverV1',
    ':app:assembleDebug',
    ':app:installDebug',
    ':build-logic:demo:assembleRelease',
    ':build-logic:demo:installRelease',
    ':build-logic:help',
    ':help',
  })
  expect('task DTO contains only neutral identity fields', snapshot.tasks[3], {
    id = ':app:assembleDebug',
    build_path = ':',
    project_path = ':app',
    name = 'assembleDebug',
  })

  expect('task identity qualifies the root build root project', Task.identity(':', ':', 'help'), ':help')
  expect('task identity qualifies an included subproject', Task.identity(':build-logic', ':demo', 'assembleRelease'), ':build-logic:demo:assembleRelease')
  expect('task identity rejects a Gradle-invalid name', Task.identity(':', ':app', 'bad:name'), nil)
  expect('task identity rejects an oversized derived id', Task.identity(':', ':' .. string.rep('p', 4094), 'task'), nil)
  expect('task identity measures a prefixed multibyte id in UTF-8 bytes', Task.identity(':', ':' .. string.rep('界', 1364), '界'), nil)
  expect_true('task identity accepts a prefixed multibyte id within the byte bound', Task.identity(':', ':' .. string.rep('界', 1363), '界') ~= nil)
  expect(
    'task normalize rejects forged ids',
    Task.normalize {
      id = ':app:other',
      build_path = ':',
      project_path = ':app',
      name = 'assembleDebug',
    },
    nil
  )
  expect(
    'task normalize rejects extra DTO fields',
    Task.normalize {
      id = ':app:assembleDebug',
      build_path = ':',
      project_path = ':app',
      name = 'assembleDebug',
      description = 'not part of the domain DTO',
    },
    nil
  )
  local offered = Task.sorted(snapshot)
  expect('task picker resolution returns the canonical offered DTO', Task.resolve(offered, { id = ':app:assembleDebug' }), offered[3])
  expect('task picker resolution rejects an unknown id', Task.resolve(offered, { id = ':app:notOffered' }), nil)
  expect('task lookup resolves the current snapshot identity', Task.find(snapshot, ':app:assembleDebug'), snapshot.tasks[3])

  local provider_snapshot, provider_err = model.decode(
    jsonl {
      {
        type = 'error',
        code = 'untransportable_task_name',
        message = 'task identity exceeds its UTF-8 byte limit',
      },
    },
    nonce,
    root
  )
  expect('untransportable provider task returns no partial snapshot', provider_snapshot, nil)
  expect('untransportable provider task keeps its explicit error', provider_err and provider_err.code, 'untransportable_task_name')

  expect_error('mismatched assemble task', changed(function(records) records[1].assemble_task = ':app:assembleRelease' end), 'invalid_target')
  expect_error('unqualified included install task', changed(function(records) records[2].install_task = ':demo:installRelease' end), 'invalid_target')

  expect_error('empty task chunk', changed(function(records) records[7].names = {} end), 'invalid_task')
  expect_error('zero task chunk index', changed(function(records) records[7].chunk_index = 0 end), 'invalid_task')
  expect_error('invalid Gradle task name', changed(function(records) records[7].names[1] = 'bad:name' end), 'invalid_task')
  expect_error('duplicate task name', changed(function(records) records[7].names[2] = records[7].names[1] end), 'identity_collision')
  expect_error('duplicate task chunk', changed(function(records) records[#records + 1] = vim.deepcopy(records[7]) end), 'identity_collision')
  expect_error('missing task chunk', changed(function(records) table.remove(records, 7) end), 'incomplete_tree')
  expect_error('noncontiguous task chunks', changed(function(records) records[7].chunk_index = 2 end), 'incomplete_tree')
  expect_error('task project chunk count mismatch', changed(function(records) records[8].chunk_count = 2 end), 'incomplete_tree')
  expect_error('task project task count mismatch', changed(function(records) records[8].task_count = 3 end), 'incomplete_tree')
  expect_error('build task project count mismatch', changed(function(records) records[5].project_count = 3 end), 'incomplete_tree')
  expect_error('build task count mismatch', changed(function(records) records[5].task_count = 6 end), 'incomplete_tree')
  expect_error('missing root task project completion', changed(function(records) table.remove(records, 8) end), 'incomplete_tree')
  expect_error(
    'substituted task project cannot satisfy a build count',
    changed(function(records)
      records[7].project_path = ':substitute'
      records[8].project_path = ':substitute'
    end),
    'incomplete_tree',
    'root project task completion record is missing'
  )
  expect_error(
    'task project count exceeds the bounded model',
    changed(function(records) records[8].task_count = Task.limits.max_tasks + 1 end),
    'invalid_task_project'
  )
  expect_error('build task count exceeds the bounded model', changed(function(records) records[5].task_count = Task.limits.max_tasks + 1 end), 'invalid_build')
  expect_error(
    'root discovery task is provider-internal',
    changed(function(records)
      records[7].names[#records[7].names + 1] = '__androidWorkbenchDiscoverV1'
      records[8].task_count = 3
      records[5].task_count = 6
    end),
    'invalid_task'
  )
  expect_error(
    'application project emitter is provider-internal',
    changed(function(records)
      records[9].names[#records[9].names + 1] = '__androidWorkbenchEmitProjectV1'
      records[10].task_count = 4
      records[5].task_count = 6
    end),
    'invalid_task'
  )
  expect_error(
    'task chunk references an unknown build',
    changed(function(records)
      records[#records + 1] = { type = 'task_chunk', build_path = ':unknown', project_path = ':', chunk_index = 1, names = { 'help' } }
      records[#records + 1] = {
        type = 'task_project_complete',
        build_path = ':unknown',
        project_path = ':',
        chunk_count = 1,
        task_count = 1,
      }
    end),
    'incomplete_tree'
  )

  expect_error('duplicate target identity', changed(function(records) records[#records + 1] = vim.deepcopy(records[1]) end), 'identity_collision')
  expect_error('duplicate project identity', changed(function(records) records[#records + 1] = vim.deepcopy(records[3]) end), 'identity_collision')
  expect_error(
    'duplicate build path',
    changed(
      function(records)
        records[#records + 1] = {
          type = 'build_complete',
          build_path = ':',
          build_root = root .. '/duplicate',
          application_projects = {},
          included_build_roots = {},
          project_count = 0,
          task_count = 0,
        }
      end
    ),
    'identity_collision'
  )
  expect_error(
    'duplicate canonical build root',
    changed(
      function(records)
        records[#records + 1] = {
          type = 'build_complete',
          build_path = ':shadow',
          build_root = included_root,
          application_projects = {},
          included_build_roots = {},
          project_count = 0,
          task_count = 0,
        }
      end
    ),
    'identity_collision'
  )

  local mismatched_snapshot, mismatched_err = model.decode(jsonl(fixture()), nonce, root .. '/other')
  expect('requested-root mismatch returns no snapshot', mismatched_snapshot, nil)
  expect('requested-root mismatch is classified', mismatched_err and mismatched_err.code, 'root_mismatch')

  expect_error('target count mismatch', changed(function(records) records[3].target_count = 2 end), 'incomplete_tree')
  expect_error('missing declared project completion', changed(function(records) table.remove(records, 3) end), 'incomplete_tree')
  expect_error('undeclared project completion', changed(function(records) records[5].application_projects = {} end), 'incomplete_tree')
  expect_error(
    'target without project completion',
    changed(function(records)
      table.remove(records, 4)
      records[5].application_projects = {}
    end),
    'incomplete_tree'
  )
  expect_error(
    'missing included build completion',
    changed(function(records)
      table.remove(records, 6)
      table.remove(records, 4)
      table.remove(records, 2)
    end),
    'incomplete_tree'
  )
  expect_error('target build-root mismatch', changed(function(records) records[1].build_root = root .. '/other' end), 'incomplete_tree')
  expect_error('missing tree completion', changed(function(records) table.remove(records) end), 'incomplete_tree')
  expect_error(
    'duplicate tree completion',
    changed(function(records) records[#records + 1] = { type = 'tree_complete', build_path = ':' } end),
    'incomplete_tree'
  )
  expect_error(
    'unreachable build',
    changed(function(records)
      records[#records + 1] = {
        type = 'build_complete',
        build_path = ':orphan',
        build_root = root .. '/orphan',
        application_projects = {},
        included_build_roots = {},
        project_count = 1,
        task_count = 0,
      }
      records[#records + 1] = { type = 'task_project_complete', build_path = ':orphan', project_path = ':', chunk_count = 0, task_count = 0 }
    end),
    'incomplete_tree',
    'unreachable build record'
  )

  expect_error('unknown record type', changed(function(records) records[#records + 1] = { type = 'mystery' } end), 'unknown_record')
  expect_error('unsupported record schema', changed(function(records) records[1].schema = 2 end), 'invalid_record')
  expect_error('record nonce mismatch', changed(function(records) records[1].nonce = 'wrong-nonce' end), 'invalid_record')
  expect_error('record missing its type', changed(function(records) records[#records + 1] = { detail = 'missing type' } end), 'invalid_record')

  expect_output_error('missing protocol', 'ordinary Gradle output\n', 'missing_protocol')
  expect_output_error('malformed JSON record', model.marker .. '{not-json\n', 'invalid_json')
  expect_output_error('non-object JSON record', model.marker .. '[]\n', 'invalid_json')
  expect_output_error('oversized protocol record', model.marker .. string.rep('x', 65537) .. '\n', 'record_too_large')
end, debug.traceback)

if not ok then fail('unexpected test error', unexpected) end

if #failures > 0 then
  vim.api.nvim_err_writeln('Android Workbench model validation failed:\n- ' .. table.concat(failures, '\n- '))
  vim.cmd 'cquit 1'
end

print 'Android Workbench model validation passed'
vim.cmd 'qa!'

-- vim: ts=2 sts=2 sw=2 et
