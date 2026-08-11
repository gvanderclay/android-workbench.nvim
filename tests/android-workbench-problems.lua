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

local function expect_error(name, callback, pattern)
  local ok, err = pcall(callback)
  if ok then
    fail(name, 'expected an error')
  elseif pattern and not tostring(err):find(pattern, 1, true) then
    fail(name, ('expected error containing %q, got %s'):format(pattern, tostring(err)))
  end
end

local Problem = require 'android_workbench.problem'
local GradleProblems = require 'android_workbench.gradle.problems'
local Diagnostics = require 'android_workbench.integrations.diagnostics'
local Quickfix = require 'android_workbench.integrations.quickfix'

local function item(path, line, message, extra)
  local value = {
    path = path,
    line = line,
    message = message,
    severity = 'error',
  }
  return vim.tbl_extend('force', value, extra or {})
end

local function qf_list(id) return vim.fn.getqflist { id = id, nr = 0, context = 0, items = 0, title = 0, winid = 0 } end

local function batch(root, status, items, extra)
  return vim.tbl_extend('force', {
    root = root,
    kind = 'build',
    name = 'Build app debug',
    status = status,
    items = items or {},
    truncated = false,
  }, extra or {})
end

local function namespace_name(root) return 'android_workbench.problems.' .. vim.fn.sha256(vim.fs.normalize(root)) end

local function augroup_name(root) return 'android_workbench.problems.edits.' .. vim.fn.sha256(vim.fs.normalize(root)) end

local function namespace_id(root) return vim.api.nvim_get_namespaces()[namespace_name(root)] end

local function diagnostic_view(root, buffer)
  local namespace = namespace_id(root)
  if not namespace then return {} end
  local values = {}
  for _, diagnostic in ipairs(vim.diagnostic.get(buffer, { namespace = namespace })) do
    values[#values + 1] = {
      lnum = diagnostic.lnum,
      col = diagnostic.col,
      end_lnum = diagnostic.end_lnum,
      end_col = diagnostic.end_col,
      message = diagnostic.message,
      severity = diagnostic.severity,
      source = diagnostic.source,
      user_data = diagnostic.user_data,
    }
  end
  table.sort(values, function(left, right) return left.message < right.message end)
  return values
end

local ok, unexpected = xpcall(function()
  local parsed = GradleProblems.new()
  parsed:parse 'e: file:///tmp/My%20Feature.kt:12:7 Unresolved reference: missingThing'
  parsed:parse '/tmp/Main.java:19: error: cannot find symbol'
  parsed:parse '/tmp/res/layout/main.xml:4:17: error: resource string/missing not found'
  parsed:parse 'ERROR: /tmp/res/values/strings.xml:6:2-7:9: Resource entry is malformed'
  parsed:parse '/tmp/Bluetooth.kt:138: Error: Missing permission [MissingPermission]'
  parsed:parse 'w: file:///tmp/My%20Feature.kt:14:2 This warning is intentionally ignored'
  parsed:parse '/tmp/Main.java:20: warning: unchecked conversion'
  parsed:parse '/tmp/Bluetooth.kt:139: Warning: This lint warning is intentionally ignored [Example]'
  parsed:parse 'FAILURE: Build failed with an exception.'
  parsed:parse '> Task :app:compileDebugKotlin FAILED'
  local parsed_result = parsed:finish()
  expect('supported Gradle error fixtures', parsed_result, {
    problems = {
      item('/tmp/My Feature.kt', 12, 'Unresolved reference: missingThing', { column = 7 }),
      item('/tmp/Main.java', 19, 'cannot find symbol'),
      item('/tmp/res/layout/main.xml', 4, 'resource string/missing not found', { column = 17 }),
      item('/tmp/res/values/strings.xml', 6, 'Resource entry is malformed', {
        column = 2,
        end_line = 7,
        end_column = 9,
      }),
      item('/tmp/Bluetooth.kt', 138, 'Missing permission [MissingPermission]'),
    },
    problems_truncated = false,
  })

  local overseer_parser = GradleProblems.new()
  overseer_parser:parse '/tmp/Foo.java:3:11: error: broken'
  expect('Overseer parser result shape', overseer_parser:get_result(), {
    diagnostics = {
      {
        filename = '/tmp/Foo.java',
        lnum = 3,
        col = 11,
        text = 'broken',
        type = 'E',
      },
    },
    problems_truncated = false,
  })
  expect('Overseer parser version changes for a problem', overseer_parser.result_version, 1)
  overseer_parser:reset()
  expect('Overseer parser reset', overseer_parser:get_result(), { diagnostics = {}, problems_truncated = false })
  expect('Overseer parser version resets', overseer_parser.result_version, 0)

  local streamed = GradleProblems.new()
  streamed:on_output { stream = 'stdout', data = 'e: file:///tmp/Spl' }
  streamed:on_output { stream = 'stderr', data = '/tmp/Other.java:4: er' }
  streamed:on_output { stream = 'stdout', data = 'it.kt:8:2 split Kotlin\n' }
  streamed:on_output { stream = 'stderr', data = 'ror: split Java\n' }
  streamed:on_output { stream = 'stdout', data = '/tmp/Tail.java:9: error: final partial' }
  expect('stream framing retains independent partials', streamed:finish(), {
    problems = {
      item('/tmp/Split.kt', 8, 'split Kotlin', { column = 2 }),
      item('/tmp/Other.java', 4, 'split Java'),
      item('/tmp/Tail.java', 9, 'final partial'),
    },
    problems_truncated = false,
  })

  local gap = GradleProblems.new()
  gap:on_output { stream = 'stderr', data = '/tmp/Fabricated.java:4: er' }
  gap:on_output {
    stream = 'stderr',
    data = 'ror: must not stitch across the gap\n/tmp/Real.java:7: error: retained after gap\n',
    truncated = true,
  }
  expect('truncated output discards through the next newline', gap:finish(), {
    problems = { item('/tmp/Real.java', 7, 'retained after gap') },
    problems_truncated = true,
  })

  local bounded_line = GradleProblems.new { max_line_bytes = 96 }
  bounded_line:on_output {
    stream = 'stdout',
    data = string.rep('x', 97) .. '\n/tmp/After.java:1: error: bounded recovery\n',
  }
  expect('oversized line is dropped without losing later lines', bounded_line:finish(), {
    problems = { item('/tmp/After.java', 1, 'bounded recovery') },
    problems_truncated = true,
  })

  local bounded_items = GradleProblems.new { max_items = 2, max_message_bytes = 8 }
  bounded_items:parse '/tmp/One.java:1: error: 123456789'
  bounded_items:parse '/tmp/One.java:1: error: 123456789'
  bounded_items:parse '/tmp/Two.java:2: error: second'
  bounded_items:parse '/tmp/Three.java:3: error: third'
  expect('collector bounds messages, deduplicates, and caps count', bounded_items:finish(), {
    problems = {
      item('/tmp/One.java', 1, '12345678'),
      item('/tmp/Two.java', 2, 'second'),
    },
    problems_truncated = true,
  })

  local oversized_message = string.rep('m', Problem.limits.message_bytes + 1)
  local neutral_input = {
    item('/tmp/../tmp/One.java', 1, 'same'),
    item('/tmp/One.java', 1, 'same'),
    item('/tmp/Info.java', 2, oversized_message, { severity = 'info' }),
  }
  local normalized, normalized_truncated = Problem.normalize(neutral_input, false)
  expect('neutral normalization copies, normalizes, and deduplicates', normalized, {
    item('/tmp/One.java', 1, 'same'),
    item('/tmp/Info.java', 2, string.rep('m', Problem.limits.message_bytes), { severity = 'info' }),
  })
  expect('neutral message bound reports truncation', normalized_truncated, true)
  expect('neutral input is not mutated', neutral_input[3].message, oversized_message)

  local invalid, invalid_err = Problem.normalize({ item('relative/Foo.java', 1, 'bad') }, false)
  expect('relative neutral path is rejected', invalid, nil)
  expect_true('relative path rejection explains path', type(invalid_err) == 'string' and invalid_err:find('absolute path', 1, true))
  invalid, invalid_err = Problem.normalize({ item('/tmp/Foo.java', 0, 'bad') }, false)
  expect('zero neutral line is rejected', invalid, nil)
  expect_true('zero line rejection explains line', type(invalid_err) == 'string' and invalid_err:find('line', 1, true))
  invalid, invalid_err = Problem.normalize({ item('/tmp/Foo.java', 1, 'bad', { severity = 'hint' }) }, false)
  expect('unsupported neutral severity is rejected', invalid, nil)
  expect_true('severity rejection names exact contract', type(invalid_err) == 'string' and invalid_err:find('error, warning, or info', 1, true))

  local many = {}
  for index = 1, Problem.limits.items + 1 do
    many[index] = item('/tmp/Many.java', index, ('problem %d'):format(index))
  end
  local capped, capped_truncated = Problem.normalize(many, false)
  expect('neutral item count is capped', #capped, Problem.limits.items)
  expect('neutral item cap reports truncation', capped_truncated, true)

  local from_overseer, from_overseer_truncated = GradleProblems.from_overseer({
    { filename = '/tmp/Hint.java', lnum = 3, col = 2, text = 'provider hint', type = 'N' },
    { filename = '/tmp/Warning.java', lnum = 4, text = 'provider warning', type = 'W' },
  }, false)
  expect('Overseer diagnostics normalize to neutral problems', from_overseer, {
    item('/tmp/Hint.java', 3, 'provider hint', { column = 2, severity = 'info' }),
    item('/tmp/Warning.java', 4, 'provider warning', { severity = 'warning' }),
  })
  expect('Overseer diagnostics preserve truncation', from_overseer_truncated, false)
  local malformed_overseer, malformed_overseer_err = GradleProblems.from_overseer({ true }, false)
  expect('malformed Overseer diagnostics are rejected', malformed_overseer, nil)
  expect_true('malformed Overseer diagnostic is explained', type(malformed_overseer_err) == 'string')
  malformed_overseer, malformed_overseer_err = GradleProblems.from_overseer({}, 'yes')
  expect('malformed Overseer truncation is rejected', malformed_overseer, nil)
  expect_true('malformed Overseer truncation is explained', type(malformed_overseer_err) == 'string')

  expect_error('collector constructor validates bounds', function() GradleProblems.new { max_items = 1001 } end, 'max_items')
  expect_error('quickfix constructor validates open policy', function() Quickfix.new { open_on_failure = 'yes' } end, 'open_on_failure')
  expect_error('quickfix constructor validates close policy', function() Quickfix.new { close_on_success = 'yes' } end, 'close_on_success')
  expect_error('diagnostic constructor requires options', function() Diagnostics.new() end, 'opts')
  expect_error('diagnostic constructor requires a sink', function() Diagnostics.new {} end, 'sink.publish')

  local normalized_batch, normalized_batch_err = Problem.normalize_batch(batch('/project/shared/../shared', 'failure', {
    item('/tmp/../tmp/Shared.java', 4, 'shared validation'),
  }))
  expect('shared batch validation succeeds', normalized_batch_err, nil)
  expect(
    'shared batch validation normalizes root and items',
    normalized_batch,
    batch('/project/shared', 'failure', {
      item('/tmp/Shared.java', 4, 'shared validation'),
    })
  )

  local normalized_task_batch, normalized_task_batch_err = Problem.normalize_batch(batch('/project/shared', 'failure', {
    item('/tmp/Task.java', 8, 'task validation'),
  }, { kind = 'gradle_task', name = 'Gradle task :app:lintDebug' }))
  expect('Gradle task problem batch validation succeeds', normalized_task_batch_err, nil)
  expect('Gradle task problem batch preserves its neutral kind', normalized_task_batch.kind, 'gradle_task')

  local unknown_batch, unknown_batch_err = Problem.normalize_batch(batch('/project/shared', 'failure', {}, { kind = 'unknown' }))
  expect('unknown problem batch kind remains rejected', unknown_batch, nil)
  expect('unknown problem batch kind has a structured error', unknown_batch_err.code, 'invalid_problem_batch')

  local diagnostic_config_before = vim.deepcopy(vim.diagnostic.config())
  local trouble_before = package.loaded.trouble
  local tracked_buffers = {}
  local tracked_namespaces = {}

  local function track_buffer(buffer)
    tracked_buffers[buffer] = true
    return buffer
  end

  local function add_buffer(path)
    local buffer = vim.fn.bufadd(vim.fs.normalize(path))
    return track_buffer(buffer)
  end

  local function loaded_buffer(path)
    local buffer = track_buffer(vim.api.nvim_create_buf(false, false))
    vim.api.nvim_buf_set_name(buffer, path)
    vim.api.nvim_buf_set_lines(buffer, 0, -1, false, { 'one', 'two', 'three' })
    vim.bo[buffer].modified = false
    return buffer
  end

  local function track_namespace(root)
    local namespace = namespace_id(root)
    if namespace then tracked_namespaces[namespace] = true end
    return namespace
  end

  local function unique_autocmds(root, buffer)
    local unique = {}
    for _, autocmd in ipairs(vim.api.nvim_get_autocmds { group = augroup_name(root), buffer = buffer }) do
      unique[autocmd.id] = true
    end
    return vim.tbl_count(unique)
  end

  local mutation_root = '/project/diagnostic-mutation/../diagnostic-mutation'
  local mutation_path = '/tmp/android-workbench-problems/Mutation[1]*.kt'
  local downstream_calls = 0
  local downstream_extra
  local downstream_root
  local mutation_sink = Diagnostics.new {
    sink = {
      publish = function(received, extra)
        downstream_calls = downstream_calls + 1
        downstream_extra = extra
        downstream_root = received.root
        received.root = '/mutated'
        received.items[1].line = 99
        return true
      end,
    },
  }
  local diagnostic_published, diagnostic_publish_err = mutation_sink.publish(batch(mutation_root, 'failure', {
    item(mutation_path, 7, 'defensive copy', { column = 3 }),
  }))
  expect('diagnostic decorator publishes', diagnostic_published, true)
  expect('diagnostic decorator has no error', diagnostic_publish_err, nil)
  expect('decorated sink is called exactly once', downstream_calls, 1)
  expect('decorated sink is called as a plain function', downstream_extra, nil)
  expect('decorated sink receives a normalized root', downstream_root, '/project/diagnostic-mutation')
  local mutation_buffer = add_buffer(mutation_path)
  track_namespace(mutation_root)
  expect('decorated sink mutation cannot change diagnostic projection', diagnostic_view(mutation_root, mutation_buffer)[1].lnum, 6)
  expect('literal special-character path resolves exactly', vim.api.nvim_buf_get_name(mutation_buffer), mutation_path)
  expect('diagnostic publication does not load an unopened buffer', vim.api.nvim_buf_is_loaded(mutation_buffer), false)

  local invalid_decorated, invalid_decorated_err = mutation_sink.publish(batch('relative/root', 'failure', {}))
  expect('diagnostic decorator rejects invalid batch', invalid_decorated, nil)
  expect('diagnostic invalid batch remains structured', invalid_decorated_err.code, 'invalid_problem_batch')
  expect('invalid batch never reaches decorated sink', downstream_calls, 1)

  local conversion_root = '/project/diagnostic-conversion'
  local conversion_path = '/tmp/android-workbench-problems/Conversion.kt'
  local conversion_buffer = add_buffer(conversion_path)
  local lsp_namespace = vim.api.nvim_create_namespace 'android-workbench-problems-test-lsp'
  tracked_namespaces[lsp_namespace] = true
  vim.diagnostic.set(lsp_namespace, conversion_buffer, {
    { lnum = 0, col = 0, message = 'language server', severity = vim.diagnostic.severity.ERROR, source = 'kotlin_lsp' },
  })
  local conversion_sink = Diagnostics.new { sink = { publish = function() return true end } }
  diagnostic_published = conversion_sink.publish(batch(conversion_root, 'failure', {
    item(conversion_path, 12, 'range error', { column = 7, end_line = 13, end_column = 9 }),
    item(conversion_path, 4, 'warning item', { severity = 'warning' }),
    item(conversion_path, 6, 'info item', { column = 2, severity = 'info' }),
  }, { kind = 'run', name = 'Run app debug', truncated = true }))
  expect('ranged diagnostic batch publishes', diagnostic_published, true)
  local conversion_namespace = track_namespace(conversion_root)
  local metadata = {
    android_workbench = {
      root = conversion_root,
      kind = 'run',
      name = 'Run app debug',
      status = 'failure',
      truncated = true,
    },
  }
  expect('diagnostic conversion preserves severity, source, ranges, and metadata', diagnostic_view(conversion_root, conversion_buffer), {
    {
      lnum = 5,
      col = 1,
      end_lnum = 5,
      end_col = 1,
      message = 'info item',
      severity = vim.diagnostic.severity.INFO,
      source = 'Android Workbench',
      user_data = metadata,
    },
    {
      lnum = 11,
      col = 6,
      end_lnum = 12,
      end_col = 8,
      message = 'range error',
      severity = vim.diagnostic.severity.ERROR,
      source = 'Android Workbench',
      user_data = metadata,
    },
    {
      lnum = 3,
      col = 0,
      end_lnum = 3,
      end_col = 0,
      message = 'warning item',
      severity = vim.diagnostic.severity.WARN,
      source = 'Android Workbench',
      user_data = metadata,
    },
  })
  local from_qf = vim.diagnostic.fromqflist {
    {
      bufnr = conversion_buffer,
      lnum = 12,
      col = 7,
      end_lnum = 13,
      end_col = 9,
      text = 'range error',
      type = 'E',
      nr = 0,
      valid = 1,
    },
  }
  local projected_range = diagnostic_view(conversion_root, conversion_buffer)[2]
  expect('neutral range conversion matches Neovim quickfix conversion', {
    projected_range.lnum,
    projected_range.col,
    projected_range.end_lnum,
    projected_range.end_col,
  }, {
    from_qf[1].lnum,
    from_qf[1].col,
    from_qf[1].end_lnum,
    from_qf[1].end_col,
  })
  expect('diagnostic namespace is named by the canonical root hash', conversion_namespace, vim.api.nvim_get_namespaces()[namespace_name(conversion_root)])
  expect('diagnostic namespace does not expose the raw root', vim.api.nvim_get_namespaces()['android_workbench.problems:' .. conversion_root], nil)
  expect('Workbench projection leaves LSP namespace untouched', #vim.diagnostic.get(conversion_buffer, { namespace = lsp_namespace }), 1)

  local isolated_root = '/project/diagnostic-isolated'
  local isolated_sink = Diagnostics.new { sink = { publish = function() return true end } }
  diagnostic_published = isolated_sink.publish(batch(isolated_root, 'failure', {
    item(conversion_path, 2, 'other root'),
  }))
  expect('second diagnostic root publishes', diagnostic_published, true)
  track_namespace(isolated_root)
  diagnostic_published = conversion_sink.publish(batch(conversion_root, 'success', {
    item(conversion_path, 20, 'success items are not diagnostics'),
  }))
  expect('successful batch publishes downstream', diagnostic_published, true)
  expect('success clears the matching root diagnostics', #diagnostic_view(conversion_root, conversion_buffer), 0)
  expect('success leaves a second root untouched', #diagnostic_view(isolated_root, conversion_buffer), 1)
  expect('success leaves LSP diagnostics untouched', #vim.diagnostic.get(conversion_buffer, { namespace = lsp_namespace }), 1)
  diagnostic_published = isolated_sink.publish(batch(isolated_root, 'failure', {}))
  expect('locationless failure publishes downstream', diagnostic_published, true)
  expect('locationless failure clears prior root diagnostics', #diagnostic_view(isolated_root, conversion_buffer), 0)

  local replacement_root = '/project/diagnostic-replacement'
  local retained_path = '/tmp/android-workbench-problems/Retained.kt'
  local vanished_path = '/tmp/android-workbench-problems/Vanished.kt'
  local replacement_sink = Diagnostics.new { sink = { publish = function() return true end } }
  diagnostic_published = replacement_sink.publish(batch(replacement_root, 'failure', {
    item(retained_path, 1, 'old retained'),
    item(vanished_path, 2, 'vanished'),
  }))
  local retained_buffer = add_buffer(retained_path)
  local vanished_buffer = add_buffer(vanished_path)
  track_namespace(replacement_root)
  expect('initial replacement batch spans buffers', #diagnostic_view(replacement_root, vanished_buffer), 1)
  diagnostic_published = replacement_sink.publish(batch('/project/diagnostic-replacement/../diagnostic-replacement', 'failure', {
    item(retained_path, 3, 'new retained'),
  }))
  expect('same canonical root replacement publishes', diagnostic_published, true)
  expect('replacement updates retained buffer', diagnostic_view(replacement_root, retained_buffer)[1].message, 'new retained')
  expect('replacement removes vanished buffer', #diagnostic_view(replacement_root, vanished_buffer), 0)

  local edit_root = '/project/diagnostic-edit'
  local edit_path = '/tmp/android-workbench-problems/Edit.kt'
  local edit_buffer = loaded_buffer(edit_path)
  vim.diagnostic.set(lsp_namespace, edit_buffer, {
    { lnum = 0, col = 0, message = 'edit lsp', severity = vim.diagnostic.severity.WARN },
  })
  local first_edit_sink = Diagnostics.new { sink = { publish = function() return true end } }
  diagnostic_published = first_edit_sink.publish(batch(edit_root, 'failure', { item(edit_path, 2, 'first edit batch') }))
  track_namespace(edit_root)
  expect('first adapter installs one edit invalidator', unique_autocmds(edit_root, edit_buffer), 1)
  local reconstructed_edit_sink = Diagnostics.new { sink = { publish = function() return true end } }
  diagnostic_published = reconstructed_edit_sink.publish(batch(edit_root, 'failure', { item(edit_path, 3, 'reconstructed batch') }))
  expect('reconstruction replaces stale edit invalidator', unique_autocmds(edit_root, edit_buffer), 1)
  vim.api.nvim_exec_autocmds('TextChanged', { buffer = edit_buffer })
  expect('first edit clears only Workbench diagnostics', #diagnostic_view(edit_root, edit_buffer), 0)
  expect('first edit leaves LSP namespace untouched', #vim.diagnostic.get(edit_buffer, { namespace = lsp_namespace }), 1)
  expect('edit invalidation is one shot', unique_autocmds(edit_root, edit_buffer), 0)
  vim.diagnostic.set(namespace_id(edit_root), edit_buffer, {
    { lnum = 0, message = 'manual same-namespace diagnostic' },
  })
  vim.api.nvim_exec_autocmds('TextChangedI', { buffer = edit_buffer })
  expect('spent edit invalidator does not clear again', #diagnostic_view(edit_root, edit_buffer), 1)
  diagnostic_published = reconstructed_edit_sink.publish(batch(edit_root, 'failure', { item(edit_path, 1, 'rearmed batch') }))
  vim.api.nvim_exec_autocmds('TextChangedP', { buffer = edit_buffer })
  expect('next batch rearms edit invalidation', #diagnostic_view(edit_root, edit_buffer), 0)

  vim.fn.setqflist({}, 'f')
  local modified_root = '/project/diagnostic-modified'
  local modified_path = '/tmp/android-workbench-problems/Modified.kt'
  local modified_buffer = loaded_buffer(modified_path)
  vim.api.nvim_buf_set_lines(modified_buffer, 0, 1, false, { 'changed' })
  expect('modified fixture is dirty', vim.bo[modified_buffer].modified, true)
  local modified_sink = Diagnostics.new { sink = Quickfix.new() }
  diagnostic_published = modified_sink.publish(batch(modified_root, 'failure', { item(modified_path, 1, 'dirty source') }))
  expect('modified-buffer batch still publishes quickfix', diagnostic_published, true)
  track_namespace(modified_root)
  expect('modified buffer skips diagnostic projection', #diagnostic_view(modified_root, modified_buffer), 0)
  expect('modified buffer remains in canonical quickfix', #vim.fn.getqflist({ items = 0 }).items, 1)
  vim.bo[modified_buffer].modified = false

  local projection_root = '/project/diagnostic-projection-failure'
  local projection_path = '/tmp/android-workbench-problems/Projection.kt'
  local projection_buffer = add_buffer(projection_path)
  local projection_sink = Diagnostics.new { sink = Quickfix.new() }
  local original_diagnostic_set = vim.diagnostic.set
  vim.diagnostic.set = function() error 'injected diagnostic failure' end
  local projection_ok, projection_result, projection_err = pcall(
    function() return projection_sink.publish(batch(projection_root, 'failure', { item(projection_path, 4, 'quickfix survives') })) end
  )
  vim.diagnostic.set = original_diagnostic_set
  expect('diagnostic API failure is contained', projection_ok, true)
  expect('diagnostic API failure rejects projection', projection_result, nil)
  expect('diagnostic API failure is structured', projection_err.code, 'diagnostic_publish_failed')
  track_namespace(projection_root)
  expect('diagnostic failure leaves projection empty', #diagnostic_view(projection_root, projection_buffer), 0)
  expect('diagnostic failure still publishes canonical quickfix', vim.fn.getqflist({ items = 0 }).items[1].text, 'quickfix survives')

  local prior_projection = diagnostic_view(replacement_root, retained_buffer)
  local throwing_sink = Diagnostics.new { sink = { publish = function() error 'downstream throw' end } }
  local rejected, rejected_err = throwing_sink.publish(batch(replacement_root, 'failure', { item(retained_path, 9, 'must not replace') }))
  expect('throwing downstream is contained', rejected, nil)
  expect('throwing downstream error is structured', rejected_err.code, 'problem_sink_failed')
  expect('throwing downstream leaves prior diagnostics', diagnostic_view(replacement_root, retained_buffer), prior_projection)
  local false_sink = Diagnostics.new { sink = { publish = function() return false end } }
  rejected, rejected_err = false_sink.publish(batch('/project/diagnostic-false', 'failure', {}))
  expect('false downstream is rejected', rejected, nil)
  expect('false downstream error is structured', rejected_err.code, 'problem_sink_failed')
  local malformed_sink = Diagnostics.new { sink = { publish = function() return nil, 'bad result' end } }
  rejected, rejected_err = malformed_sink.publish(batch('/project/diagnostic-malformed', 'failure', {}))
  expect('malformed downstream is rejected', rejected, nil)
  expect('malformed downstream error is structured', rejected_err.code, 'problem_sink_failed')

  expect('diagnostic adapter does not configure global diagnostics', vim.diagnostic.config(), diagnostic_config_before)
  expect('diagnostic adapter does not load or call Trouble', package.loaded.trouble, trouble_before)

  vim.fn.setqflist({}, 'f')
  for namespace in pairs(tracked_namespaces) do
    pcall(vim.diagnostic.reset, namespace)
  end
  for buffer in pairs(tracked_buffers) do
    if vim.api.nvim_buf_is_valid(buffer) then
      vim.bo[buffer].modified = false
      pcall(vim.api.nvim_buf_delete, buffer, { force = true })
    end
  end

  vim.fn.setqflist({}, 'f')
  vim.fn.setqflist({}, ' ', { title = 'User older', context = { owner = 'user', key = 1 }, items = {} })
  local user_older = vim.fn.getqflist { id = 0, nr = 0 }
  vim.fn.setqflist({}, ' ', { title = 'User newer', context = { owner = 'user', key = 2 }, items = {} })
  local user_newer = vim.fn.getqflist { id = 0, nr = 0 }
  vim.cmd 'silent 1chistory'

  local sink = Quickfix.new()
  local published, publish_err = sink.publish {
    root = '/project/a',
    kind = 'build',
    name = 'Build app debug',
    status = 'failure',
    items = { item('/project/a/app/src/Main.java', 12, 'cannot find symbol', { column = 7 }) },
    truncated = false,
  }
  expect('quickfix failure publishes', published, true)
  expect('quickfix publish has no error', publish_err, nil)
  expect('default quickfix sink is populate-only', vim.fn.getqflist({ winid = 0 }).winid, 0)
  local root_a = vim.fn.getqflist { id = 0, nr = 0, context = 0, items = 0, title = 0 }
  expect('quickfix appends at stack end', root_a.nr, 3)
  expect('quickfix preserves older user list', qf_list(user_older.id).title, 'User older')
  expect('quickfix preserves newer user list', qf_list(user_newer.id).title, 'User newer')
  expect('quickfix owns exact root context', root_a.context, {
    owner = 'android_workbench',
    root = '/project/a',
    kind = 'build',
    name = 'Build app debug',
    status = 'failure',
    truncated = false,
  })
  expect('quickfix title describes task', root_a.title, 'Android: Build app debug')
  expect('quickfix item location', {
    path = vim.api.nvim_buf_get_name(root_a.items[1].bufnr),
    line = root_a.items[1].lnum,
    column = root_a.items[1].col,
    message = root_a.items[1].text,
    type = root_a.items[1].type,
  }, {
    path = '/project/a/app/src/Main.java',
    line = 12,
    column = 7,
    message = 'cannot find symbol',
    type = 'E',
  })

  published = sink.publish {
    root = '/project/a/../a',
    kind = 'run',
    name = 'Run app debug',
    status = 'failure',
    items = { item('/project/a/app/src/Run.java', 21, 'install compile failure') },
    truncated = true,
  }
  expect('same normalized root replaces owned list', published, true)
  expect('same root retains one quickfix id', vim.fn.getqflist({ nr = '$' }).nr, 3)
  local replaced_a = qf_list(root_a.id)
  expect('same root updates context without changing ownership', replaced_a.context, {
    owner = 'android_workbench',
    root = '/project/a',
    kind = 'run',
    name = 'Run app debug',
    status = 'failure',
    truncated = true,
  })
  expect('truncated quickfix title is visible', replaced_a.title, 'Android: Run app debug [truncated]')

  local reconstructed = Quickfix.new()
  published = reconstructed.publish {
    root = '/project/a',
    kind = 'build',
    name = 'Build reconstructed debug',
    status = 'failure',
    items = { item('/project/a/app/src/Reconstructed.java', 18, 'reused after shutdown') },
    truncated = false,
  }
  expect('reconstructed sink reuses root-owned history', published, true)
  expect('reconstructed sink does not duplicate root list', vim.fn.getqflist({ nr = '$' }).nr, 3)
  expect('reconstructed sink retains root quickfix id', qf_list(root_a.id).context.name, 'Build reconstructed debug')

  published = sink.publish {
    root = '/project/b',
    kind = 'build',
    name = 'Build other debug',
    status = 'failure',
    items = { item('/project/b/Other.java', 2, 'other root') },
    truncated = false,
  }
  expect('second root publishes independently', published, true)
  local root_b = vim.fn.getqflist { id = 0, nr = 0, context = 0, items = 0 }
  expect('second root gets a distinct list', root_b.id ~= root_a.id, true)

  published = sink.publish {
    root = '/project/a',
    kind = 'build',
    name = 'Build app debug',
    status = 'success',
    items = {},
    truncated = false,
  }
  expect('success clears same root', published, true)
  expect('success empties same-root owned items', #qf_list(root_a.id).items, 0)
  expect('success does not clear another root', #qf_list(root_b.id).items, 1)
  expect('clearing a non-current root preserves the current list', vim.fn.getqflist({ id = 0 }).id, root_b.id)

  vim.fn.setqflist({}, 'r', {
    id = root_a.id,
    title = 'User reclaimed',
    context = { owner = 'user', root = '/project/a' },
    items = { { filename = '/tmp/User.java', lnum = 1, text = 'keep me' } },
  })
  published = sink.publish {
    root = '/project/a',
    kind = 'build',
    name = 'Build app debug',
    status = 'failure',
    items = { item('/project/a/New.java', 5, 'new failure') },
    truncated = false,
  }
  expect('context mismatch creates a new owned list', published, true)
  local replacement_a = vim.fn.getqflist { id = 0, nr = 0, context = 0 }
  expect('context mismatch does not reuse reclaimed id', replacement_a.id ~= root_a.id, true)
  expect('context mismatch does not replace reclaimed list', qf_list(root_a.id).title, 'User reclaimed')
  expect('new list restores exact ownership', replacement_a.context.owner, 'android_workbench')

  local before_invalid = vim.fn.getqflist({ nr = '$' }).nr
  local invalid_publish, invalid_publish_err = sink.publish {
    root = '/project/a',
    kind = 'build',
    name = 'Build app debug',
    status = 'failure',
    items = { item('relative.java', 1, 'bad') },
    truncated = false,
  }
  expect('malformed batch is rejected', invalid_publish, nil)
  expect('malformed batch error is structured', invalid_publish_err.code, 'invalid_problem_batch')
  expect_true('malformed batch has a safe message', type(invalid_publish_err.message) == 'string' and invalid_publish_err.message ~= '')
  expect('malformed batch does not mutate history', vim.fn.getqflist({ nr = '$' }).nr, before_invalid)

  pcall(vim.cmd, 'cclose')
  local focused = vim.api.nvim_get_current_win()
  local opening_sink = Quickfix.new { open_on_failure = true }
  published = opening_sink.publish {
    root = '/project/open',
    kind = 'build',
    name = 'Build open debug',
    status = 'failure',
    items = { item('/project/open/Open.java', 3, 'visible failure') },
    truncated = false,
  }
  expect('open-on-failure publishes', published, true)
  expect('open-on-failure preserves focus', vim.api.nvim_get_current_win(), focused)
  expect_true('open-on-failure reveals quickfix', vim.fn.getqflist({ winid = 0 }).winid > 0)

  local opening_id = vim.fn.getqflist({ id = 0 }).id
  published = opening_sink.publish {
    root = '/project/open',
    kind = 'build',
    name = 'Build open debug',
    status = 'success',
    items = {},
    truncated = false,
  }
  expect('default reveal adapter accepts success', published, true)
  expect_true('close-on-success defaults off', vim.fn.getqflist({ winid = 0 }).winid > 0)
  expect('default success still clears owned history', #qf_list(opening_id).items, 0)

  vim.cmd 'cclose'
  published = opening_sink.publish {
    root = '/project/success',
    kind = 'build',
    name = 'Build successful debug',
    status = 'success',
    items = { item('/project/success/Info.java', 4, 'informational', { severity = 'info' }) },
    truncated = false,
  }
  expect('successful nonempty batch publishes', published, true)
  expect('successful batch does not open quickfix', vim.fn.getqflist({ winid = 0 }).winid, 0)

  published = opening_sink.publish {
    root = '/project/empty',
    kind = 'run',
    name = 'Run empty debug',
    status = 'failure',
    items = {},
    truncated = false,
  }
  expect('empty failure without an owned list is a no-op', published, true)
  expect('empty failure does not open quickfix', vim.fn.getqflist({ winid = 0 }).winid, 0)

  local closing_sink = Quickfix.new { open_on_failure = true, close_on_success = true }
  published = closing_sink.publish {
    root = '/project/close',
    kind = 'build',
    name = 'Build close debug',
    status = 'failure',
    items = { item('/project/close/Close.java', 8, 'close after success') },
    truncated = false,
  }
  expect('close-policy failure publishes', published, true)
  local closing_list = vim.fn.getqflist { id = 0, nr = 0, winid = 0 }
  expect_true('close-policy failure opens quickfix', closing_list.winid > 0)
  local history_before_close = vim.fn.getqflist({ nr = '$' }).nr
  published = closing_sink.publish {
    root = '/project/close',
    kind = 'build',
    name = 'Build close debug',
    status = 'success',
    items = {},
    truncated = false,
  }
  expect('matching success closes the owned list', published, true)
  expect('matching success closes its visible quickfix window', vim.fn.getqflist({ winid = 0 }).winid, 0)
  expect('matching success preserves quickfix history', vim.fn.getqflist({ nr = '$' }).nr, history_before_close)
  expect('matching success retains the cleared owned list', #qf_list(closing_list.id).items, 0)

  published = closing_sink.publish {
    root = '/project/guarded-close',
    kind = 'run',
    name = 'Run guarded debug',
    status = 'failure',
    items = { item('/project/guarded-close/Guarded.java', 9, 'guarded close') },
    truncated = false,
  }
  expect('guarded close failure publishes', published, true)
  local guarded = vim.fn.getqflist { id = 0, nr = 0, winid = 0 }
  expect_true('guarded close failure opens quickfix', guarded.winid > 0)
  vim.fn.setqflist({}, ' ', {
    title = 'Visible user list',
    context = { owner = 'user', root = '/project/guarded-close' },
    items = { { filename = '/tmp/UserVisible.java', lnum = 1, text = 'keep visible' } },
  })
  local visible_user = vim.fn.getqflist { id = 0, nr = 0, winid = 0, title = 0 }
  expect_true('user list remains visible before guarded success', visible_user.winid > 0)
  expect('user list is current before guarded success', visible_user.title, 'Visible user list')
  local guarded_history = vim.fn.getqflist({ nr = '$' }).nr
  published = closing_sink.publish {
    root = '/project/guarded-close',
    kind = 'run',
    name = 'Run guarded debug',
    status = 'success',
    items = {},
    truncated = false,
  }
  expect('noncurrent owned success publishes', published, true)
  expect('noncurrent owned success never selects another history entry', vim.fn.getqflist({ id = 0 }).id, visible_user.id)
  expect('noncurrent owned success leaves the user quickfix visible', vim.fn.getqflist({ winid = 0 }).winid, visible_user.winid)
  expect('noncurrent owned success preserves user contents', qf_list(visible_user.id).title, 'Visible user list')
  expect('noncurrent owned success clears only its historical list', #qf_list(guarded.id).items, 0)
  expect('noncurrent owned success preserves stack history', vim.fn.getqflist({ nr = '$' }).nr, guarded_history)
  vim.cmd 'cclose'
  vim.fn.setqflist({}, 'f')
end, debug.traceback)

if not ok then fail('unexpected test error', unexpected) end

if #failures > 0 then
  vim.api.nvim_err_writeln('Android Workbench problem validation failed:\n- ' .. table.concat(failures, '\n- '))
  vim.cmd 'cquit 1'
end

print 'Android Workbench problem validation passed'
vim.cmd 'qa!'
