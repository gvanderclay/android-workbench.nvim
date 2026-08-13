local M = {}

---@class AndroidWorkbenchPickerRequest
---@field prompt string
---@field items any[]
---@field format_item fun(item: any): string
---@field current any|nil

---@class AndroidWorkbenchPicker
---@field select fun(request: AndroidWorkbenchPickerRequest, callback: fun(error: AndroidWorkbenchError?, item: any|nil)): AndroidWorkbenchOperationHandle?

local function same_item(left, right) return left == right or vim.deep_equal(left, right) end

---@return AndroidWorkbenchPicker
function M.new()
  return {
    select = function(request, callback)
      local snacks = require 'snacks'
      local current_index
      for index, item in ipairs(request.items) do
        if same_item(item, request.current) then
          current_index = index
          break
        end
      end

      local finished = false
      local function finish(item)
        if finished then return end
        finished = true
        callback(nil, item)
      end

      local snacks_picker = snacks.picker.select(request.items, {
        prompt = request.prompt,
        format_item = function(item)
          local selected = same_item(item, request.current)
          return (selected and '● ' or '  ') .. request.format_item(item)
        end,
        snacks = current_index and {
          on_show = function(picker)
            for index, item in ipairs(picker:items()) do
              if item.idx == current_index then
                picker.list:view(index)
                break
              end
            end
          end,
        } or nil,
      }, function(item, index)
        if item == nil then
          finish(nil)
          return
        end
        if type(index) == 'number' and index % 1 == 0 and request.items[index] ~= nil then
          finish(request.items[index])
          return
        end
        for _, candidate in ipairs(request.items) do
          if same_item(candidate, item) then
            finish(candidate)
            return
          end
        end
        finish(nil)
      end)

      return {
        cancel = function()
          if finished or type(snacks_picker) ~= 'table' or type(snacks_picker.close) ~= 'function' then return false end
          local closed = pcall(snacks_picker.close, snacks_picker)
          if not closed then return false end
          finish(nil)
          return true
        end,
      }
    end,
  }
end

return M

-- vim: ts=2 sts=2 sw=2 et
