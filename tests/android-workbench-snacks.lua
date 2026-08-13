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

package.preload.snacks = function()
  return {
    picker = {
      select = function(items, opts, on_choice)
        state.items = items
        state.opts = opts
        state.on_choice = on_choice
        state.picker = {
          close = function(self)
            if self.closed then return end
            self.closed = true
            state.closes = state.closes + 1
            on_choice()
          end,
          items = function() return state.picker_items end,
          list = {
            view = function(_, index) state.view_index = index end,
          },
        }
        if state.complete_in_select then on_choice(state.complete_in_select.item, state.complete_in_select.index) end
        if opts.snacks and opts.snacks.on_show then opts.snacks.on_show(state.picker) end
        return state.picker
      end,
    },
  }
end

local Snacks = require 'android_workbench.integrations.snacks'
expect('Snacks stays unloaded when the adapter module loads', package.loaded.snacks, nil)

local picker = Snacks.new()
expect('Snacks stays unloaded when the adapter is constructed', package.loaded.snacks, nil)

local function open(request, callback, opts)
  opts = opts or {}
  state.closes = 0
  state.complete_in_select = opts.complete_in_select
  state.items = nil
  state.on_choice = nil
  state.opts = nil
  state.picker = nil
  state.picker_items = opts.picker_items or {
    { idx = 2 },
    { idx = 1 },
  }
  state.view_index = nil
  local handle = picker.select(request, callback)
  return handle
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
  expect('picker prompt is forwarded', state.opts.prompt, 'Choose target')
  expect('picker items are forwarded', state.items, items)
  expect('deep-equal current item is marked', state.opts.format_item(items[1]), '● One')
  expect('other item is unmarked', state.opts.format_item(items[2]), '  Two')
  expect('deep-equal current item is selected after sorting', state.view_index, 2)

  state.on_choice({ id = 'two', label = 'Two' }, 2)
  expect('selection callback runs once', #selected_calls, 1)
  expect('selection has no adapter error', selected_calls[1].err, nil)
  expect_true('selection returns the original chosen item', rawequal(selected_calls[1].item, items[2]))
  expect('selection makes cancellation terminal', selected_handle:cancel(), false)
  state.on_choice(items[1], 1)
  expect('duplicate selection remains terminal', #selected_calls, 1)

  local cancelled_calls = {}
  local cancelled_handle = open(request, function(err, item) cancelled_calls[#cancelled_calls + 1] = { err = err, item = item } end)
  expect('cancellation closes a live picker', cancelled_handle:cancel(), true)
  expect('cancellation closes Snacks once', state.closes, 1)
  expect('cancellation is a quiet dismissal', cancelled_calls, { {} })
  expect('repeated cancellation is rejected', cancelled_handle:cancel(), false)
  state.on_choice(items[1], 1)
  expect('late selection after cancellation stays terminal', #cancelled_calls, 1)

  local dismissed_calls = {}
  local dismissed_handle = open(request, function(err, item) dismissed_calls[#dismissed_calls + 1] = { err = err, item = item } end)
  state.on_choice()
  expect('external dismissal is quiet', dismissed_calls, { {} })
  expect('dismissal makes cancellation terminal', dismissed_handle:cancel(), false)

  local synchronous_calls = {}
  local synchronous_handle = open(request, function(err, item) synchronous_calls[#synchronous_calls + 1] = { err = err, item = item } end, {
    complete_in_select = { item = { id = 'one', label = 'One' }, index = 1 },
  })
  expect('synchronous selection completes once', #synchronous_calls, 1)
  expect_true('synchronous selection returns the original item', rawequal(synchronous_calls[1].item, items[1]))
  expect('synchronous completion is not cancellable', synchronous_handle:cancel(), false)
end, debug.traceback)

if not ok then fail('unexpected test error', unexpected) end

if #failures > 0 then
  vim.api.nvim_err_writeln('Android Workbench Snacks validation failed:\n- ' .. table.concat(failures, '\n- '))
  vim.cmd 'cquit 1'
end

print 'Android Workbench Snacks validation passed'
vim.cmd 'qa!'

-- vim: ts=2 sts=2 sw=2 et
