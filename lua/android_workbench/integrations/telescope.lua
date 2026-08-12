local M = {}

---@class AndroidWorkbenchPickerRequest
---@field prompt string
---@field items any[]
---@field format_item fun(item: any): string
---@field current any|nil

---@class AndroidWorkbenchPicker
---@field select fun(request: AndroidWorkbenchPickerRequest, callback: fun(error: AndroidWorkbenchError?, item: any|nil)): AndroidWorkbenchOperationHandle?

---@return AndroidWorkbenchPicker
function M.new()
  return {
    select = function(request, callback)
      local actions = require 'telescope.actions'
      local action_state = require 'telescope.actions.state'
      local config = require('telescope.config').values
      local finders = require 'telescope.finders'
      local pickers = require 'telescope.pickers'

      local current_index
      for index, item in ipairs(request.items) do
        if item == request.current or vim.deep_equal(item, request.current) then
          current_index = index
          break
        end
      end

      local finished = false
      local prompt_buffer
      local function finish(err, item)
        if finished then return end
        finished = true
        callback(err, item)
      end

      local picker = pickers.new({}, {
        prompt_title = request.prompt,
        default_selection_index = current_index,
        finder = finders.new_table {
          results = request.items,
          entry_maker = function(item)
            local label = request.format_item(item)
            local selected = item == request.current or vim.deep_equal(item, request.current)
            return {
              display = (selected and '● ' or '  ') .. label,
              ordinal = label,
              value = item,
            }
          end,
        },
        sorter = config.generic_sorter {},
        attach_mappings = function(prompt_bufnr)
          prompt_buffer = prompt_bufnr
          vim.api.nvim_create_autocmd('BufWipeout', {
            buffer = prompt_bufnr,
            once = true,
            callback = function()
              vim.schedule(function() finish(nil, nil) end)
            end,
          })

          actions.select_default:replace(function()
            local entry = action_state.get_selected_entry()
            finished = true
            actions.close(prompt_bufnr)
            callback(nil, entry and entry.value or nil)
          end)
          return true
        end,
      })
      picker:find()

      return {
        cancel = function()
          if not prompt_buffer or not vim.api.nvim_buf_is_valid(prompt_buffer) then return false end
          actions.close(prompt_buffer)
          return true
        end,
      }
    end,
  }
end

return M

-- vim: ts=2 sts=2 sw=2 et
