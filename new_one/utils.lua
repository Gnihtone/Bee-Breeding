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

-- Consolidate identical items in a buffer (combine into stacks).
-- Uses fingerprint to identify identical items.
local function consolidate_buffer(dev, mover)
  local nodes = device_nodes(dev)
  if #nodes == 0 then return end
  
  -- For each node, consolidate items
  for _, node in ipairs(nodes) do
    local tp = component.proxy(node.tp)
    local ok_size, size = pcall(tp.getInventorySize, node.side)
    if not ok_size or type(size) ~= "number" then
      goto continue_node
    end
    
    -- Build map of fingerprint -> first slot with space
    local fingerprint_slots = {}  -- fingerprint -> {slot, size, maxSize}
    
    for slot = 1, size do
      local ok_stack, stack = pcall(tp.getStackInSlot, node.side, slot)
      if ok_stack and stack and stack.fingerprint then
        local fp = stack.fingerprint
        local max_size = stack.maxSize or 64
        
        if not fingerprint_slots[fp] then
          fingerprint_slots[fp] = {slot = slot, size = stack.size or 1, maxSize = max_size}
        else
          -- Try to merge this slot into the first one
          local target = fingerprint_slots[fp]
          if target.size < target.maxSize then
            local space = target.maxSize - target.size
            local to_move = math.min(space, stack.size or 1)
            
            if mover and mover.move_between_nodes then
              local moved = mover.move_between_nodes(node, node, to_move, slot, target.slot)
              if moved and moved > 0 then
                target.size = target.size + moved
              end
            else
              -- Fallback: use transposer directly
              local ok_move, moved = pcall(tp.transferItem, node.side, node.side, to_move, slot, target.slot)
              if ok_move and moved and moved > 0 then
                target.size = target.size + moved
              end
            end
          end
        end
      end
    end
    
    ::continue_node::
  end
end

return {
  device_nodes = device_nodes,
  find_free_slot = find_free_slot,
  find_slot_with = find_slot_with,
  consolidate_buffer = consolidate_buffer,
}
