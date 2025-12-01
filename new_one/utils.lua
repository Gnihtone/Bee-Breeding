-- utils.lua
-- Common utility functions shared across modules.

local component = require("component")

-- Normalize device to a list of nodes.
-- Handles: single node, array of nodes, or table with .nodes field.
local function device_nodes(dev)
  if not dev then return {} end
  if dev.nodes then return dev.nodes end
  if dev.side and dev.tp then return {dev} end
  if type(dev[1]) == "table" and dev[1].side and dev[1].tp then
    return dev
  end
  return {}
end

-- Find first empty slot across all nodes of a device.
local function find_free_slot(dev)
  for _, node in ipairs(device_nodes(dev)) do
    local tp = component.proxy(node.tp)
    local ok_size, size_or_err = pcall(tp.getInventorySize, node.side)
    if ok_size and type(size_or_err) == "number" then
      for slot = 1, size_or_err do
        local ok_stack, stack = pcall(tp.getStackInSlot, node.side, slot)
        if ok_stack and not stack then
          return node, slot
        end
      end
    end
  end
  return nil, nil, "no free slot"
end

-- Find slot containing item with given label.
local function find_slot_with(dev, label)
  for _, node in ipairs(device_nodes(dev)) do
    local tp = component.proxy(node.tp)
    local ok_size, size_or_err = pcall(tp.getInventorySize, node.side)
    if ok_size and type(size_or_err) == "number" then
      for slot = 1, size_or_err do
        local ok_stack, stack = pcall(tp.getStackInSlot, node.side, slot)
        if ok_stack and stack and stack.label == label then
          return node, slot, stack
        end
      end
    end
  end
  return nil
end

return {
  device_nodes = device_nodes,
  find_free_slot = find_free_slot,
  find_slot_with = find_slot_with,
}

