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

local state = {}

package.preload['telescope.actions'] = function()
  return {
    close = function(bufnr)
      state.closes = state.closes + 1
      if vim.api.nvim_buf_is_valid(bufnr) then vim.api.nvim_buf_delete(bufnr, { force = true }) end
    end,
    select_default = {
      replace = function(_, callback) state.select = callback end,
    },
  }
end

package.preload['telescope.actions.state'] = function()
  return {
    get_selected_entry = function() return state.selected end,
  }
end

package.preload['telescope.config'] = function()
  return {
    values = {
      generic_sorter = function() return state.sorter end,
    },
  }
end

package.preload['telescope.finders'] = function()
  return {
    new_table = function(spec)
      state.finder = spec
      return spec
    end,
  }
end

package.preload['telescope.pickers'] = function()
  return {
    new = function(_, spec)
      state.spec = spec
      return {
        find = function()
          state.prompt_buffer = vim.api.nvim_create_buf(false, true)
          spec.attach_mappings(state.prompt_buffer)
        end,
      }
    end,
  }
end

local picker = require('android_workbench.integrations.telescope').new()

local function open(request, callback)
  state.closes = 0
  state.finder = nil
  state.prompt_buffer = nil
  state.select = nil
  state.selected = nil
  state.sorter = {}
  state.spec = nil
  local handle = picker.select(request, callback)
  return handle, state.prompt_buffer
end

local items = {
  { id = 'one', label = 'One' },
  { id = 'two', label = 'Two' },
}
local request = {
  prompt = 'Choose target',
  items = items,
  current = { id = 'one', label = 'One' },
  format_item = function(item) return item.label end,
}

local ok, unexpected = xpcall(function()
  local selected_calls = {}
  local selected_handle = open(request, function(err, item) selected_calls[#selected_calls + 1] = { err = err, item = item } end)
  expect('picker prompt is forwarded', state.spec.prompt_title, 'Choose target')
  expect('deep-equal current item sets default selection', state.spec.default_selection_index, 1)
  expect('picker sorter is configured', state.spec.sorter, state.sorter)
  expect('picker results are forwarded', state.finder.results, items)
  expect('current entry is marked', state.finder.entry_maker(items[1]).display, '● One')
  expect('other entry is unmarked', state.finder.entry_maker(items[2]).display, '  Two')

  state.selected = { value = items[2] }
  state.select()
  expect('selection closes the picker', state.closes, 1)
  expect('selection callback runs once', #selected_calls, 1)
  expect('selection returns the chosen item', selected_calls[1], { err = nil, item = items[2] })
  expect('selection makes cancellation terminal', selected_handle.cancel(), false)
  state.select()
  expect('duplicate selection remains terminal', #selected_calls, 1)

  local cancelled_calls = {}
  local cancelled_handle = open(request, function(err, item) cancelled_calls[#cancelled_calls + 1] = { err = err, item = item } end)
  expect('cancellation closes a live picker', cancelled_handle.cancel(), true)
  expect_true('cancellation completes after wipeout', vim.wait(1000, function() return #cancelled_calls == 1 end, 10))
  expect('cancellation is a quiet dismissal', cancelled_calls[1], {})
  expect('repeated cancellation is rejected', cancelled_handle.cancel(), false)
  expect('cancellation callback stays exactly once', #cancelled_calls, 1)

  local wiped_calls = {}
  local _, wiped_buffer = open(request, function(err, item) wiped_calls[#wiped_calls + 1] = { err = err, item = item } end)
  vim.api.nvim_buf_delete(wiped_buffer, { force = true })
  expect_true('picker wipeout completes as dismissal', vim.wait(1000, function() return #wiped_calls == 1 end, 10))
  expect('picker wipeout is quiet', wiped_calls[1], {})
  state.selected = { value = items[1] }
  state.select()
  expect('late selection after wipeout stays terminal', #wiped_calls, 1)
end, debug.traceback)

if not ok then fail('unexpected test error', unexpected) end

if #failures > 0 then
  vim.api.nvim_err_writeln('Android Workbench Telescope validation failed:\n- ' .. table.concat(failures, '\n- '))
  vim.cmd 'cquit 1'
end

print 'Android Workbench Telescope validation passed'
vim.cmd 'qa!'

-- vim: ts=2 sts=2 sw=2 et
