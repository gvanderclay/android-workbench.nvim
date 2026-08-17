for _, path in ipairs {
  assert(vim.env.AWB_PLENARY_PATH),
  assert(vim.env.AWB_SNACKS_PATH),
  assert(vim.env.AWB_TELESCOPE_PATH),
  assert(vim.env.AWB_OVERSEER_PATH),
} do
  vim.opt.runtimepath:prepend(path)
end

local function await(label, start)
  local terminal
  local handle = start(function(err, value) terminal = { err = err, value = value } end)
  assert(vim.wait(30000, function() return terminal ~= nil end, 10), label .. ' timed out')
  assert(terminal.err == nil, label .. ' failed: ' .. vim.inspect(terminal.err))
  return terminal.value, handle
end

local ok, err = xpcall(function()
  require('telescope').setup {}
  local telescope = require('android_workbench.integrations.telescope').new()
  local telescope_result = await('Telescope selection', function(done)
    local handle = telescope.select({
      prompt = 'Android Workbench adapter smoke',
      items = { { id = 'first' }, { id = 'second' } },
      current = { id = 'second' },
      format_item = function(item) return item.id end,
    }, done)
    vim.schedule(function()
      local action_state = require 'telescope.actions.state'
      assert(vim.wait(5000, function() return action_state.get_selected_entry() ~= nil end, 10), 'Telescope finder did not populate')
      require('telescope.actions').select_default(vim.api.nvim_get_current_buf())
    end)
    return handle
  end)
  assert(telescope_result.id == 'second', 'Telescope did not honor the current selection')

  local snacks = require 'snacks'
  snacks.setup { picker = {} }
  local snacks_items = { { id = 'first' }, { id = 'second' } }
  local snacks_adapter = require('android_workbench.integrations.snacks').new()
  local snacks_result, snacks_handle = await('Snacks selection', function(done)
    local handle = snacks_adapter.select({
      prompt = 'Android Workbench Snacks adapter smoke',
      items = snacks_items,
      current = { id = 'second' },
      format_item = function(item) return item.id end,
    }, done)
    vim.schedule(function()
      local active
      assert(
        vim.wait(5000, function()
          local pickers = snacks.picker.get()
          active = pickers[#pickers]
          return active ~= nil and active:current() ~= nil
        end, 10),
        'Snacks picker did not populate'
      )
      assert(active.title == 'Android Workbench Snacks adapter smoke', 'Snacks did not receive the prompt')
      assert(active:current().text:find('● second', 1, true), 'Snacks did not format or select the current item')
      active:action 'confirm'
    end)
    return handle
  end)
  assert(rawequal(snacks_result, snacks_items[2]), 'Snacks did not return the original current item')
  assert(snacks_handle:cancel() == false, 'completed Snacks picker remained cancellable')

  local overseer = require 'overseer'
  overseer.setup { dap = false }
  local output = {}
  local runner = require('android_workbench.integrations.overseer').new { max_capture_bytes = 64 * 1024 }
  local task_result, handle = await('Overseer execution', function(done)
    return runner.start({
      argv = { vim.v.progpath, '--version' },
      cwd = assert(vim.uv.cwd()),
      name = 'Android Workbench adapter smoke',
      metadata = {
        kind = 'gradle_task',
        root = assert(vim.uv.cwd()),
        task_id = ':adapterSmoke',
        build_path = ':',
        project_path = ':',
        task_name = 'adapterSmoke',
      },
      on_output = function(event) output[#output + 1] = event.data end,
    }, done)
  end)
  assert(task_result.status == 'success', 'Overseer task did not succeed')
  assert(handle:cancel() == false, 'completed Overseer task remained cancellable')
  assert(table.concat(output, '\n'):find('NVIM v0.12.4', 1, true), 'Overseer did not stream Neovim output')
  assert(runner.has_output(assert(vim.uv.cwd())), 'Overseer did not retain the Workbench task output')
  local window_count = #vim.api.nvim_tabpage_list_wins(0)
  assert(runner.show_output(assert(vim.uv.cwd())), 'Overseer did not reopen the Workbench task output')
  assert(#vim.api.nvim_tabpage_list_wins(0) == window_count, 'Overseer duplicated an already-visible output window')
end, debug.traceback)

if not ok then
  vim.api.nvim_err_writeln('Optional-adapter integration failed:\n' .. tostring(err))
  vim.cmd 'cquit 1'
end

print 'Optional-adapter integration passed'
vim.cmd 'qa!'
