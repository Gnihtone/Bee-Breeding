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

-- Find first empty slot in a device.
local function find_free_slot(dev)
  local nodes = device_nodes(dev)
  if #nodes == 0 then return nil, nil, "no nodes" end
  
  local node = nodes[1]
  local tp = component.proxy(node.tp)
  
  local ok, stacks = pcall(tp.getAllStacks, node.side)
  if not ok or not stacks then
    return nil, nil, "getAllStacks failed"
  end
  
  local slot = 0
  for stack in stacks do
    slot = slot + 1
    if not stack or not stack.name then
      stacks = nil  -- Help GC
      return node, slot
    end
  end
  
  stacks = nil  -- Help GC
  return nil, nil, "no free slot"
end

-- Find slot containing item with given label.
local function find_slot_with(dev, label)
  local nodes = device_nodes(dev)
  if #nodes == 0 then return nil end
  
  local node = nodes[1]
  local tp = component.proxy(node.tp)
  
  local ok, stacks = pcall(tp.getAllStacks, node.side)
  if not ok or not stacks then return nil end
  
  local slot = 0
  for stack in stacks do
    slot = slot + 1
    if stack and stack.label == label then
      local result_stack = {label = stack.label, size = stack.size, name = stack.name}
      stacks = nil  -- Help GC
      return node, slot, result_stack
    end
  end
  
  stacks = nil  -- Help GC
  return nil
end

-- Build a unique key for stack identity using name + label + tag
local function stack_key(stack)
  local key = (stack.name or "") .. "|" .. (stack.label or "")
  if stack.hasTag and stack.tag then
    key = key .. "|" .. tostring(stack.tag)
  end
  return key
end

-- Consolidate identical items in a buffer (combine into stacks).
-- Uses name + label + tag to identify identical items.
local function consolidate_buffer(dev)
  local nodes = device_nodes(dev)
  if #nodes == 0 then return end
  
  -- Use only first node (all nodes point to same inventory)
  local node = nodes[1]
    local tp = component.proxy(node.tp)
  
  -- Get all stacks in one call
  local ok, stacks = pcall(tp.getAllStacks, node.side)
  if not ok or not stacks then return end
    
  -- Build items list from getAllStacks
  local items = {}
  local slot = 0
  for stack in stacks do
    slot = slot + 1
    if stack and stack.name then
      table.insert(items, {
        slot = slot,
        key = stack_key(stack),
        size = stack.size or 1,
        maxSize = stack.maxSize or 64
      })
    end
  end
  
  if #items < 2 then return end  -- Nothing to consolidate
  
  -- Group by key
  local by_key = {}  -- key -> list of items
  for _, item in ipairs(items) do
    by_key[item.key] = by_key[item.key] or {}
    table.insert(by_key[item.key], item)
  end
  
  -- For each group, merge into first slot
  for _, group in pairs(by_key) do
    if #group < 2 then goto continue_group end
    
    local target = group[1]
    for i = 2, #group do
      local source = group[i]
      if source.size == 0 then goto continue_source end
      
      -- Calculate how much we can move
      local space = target.maxSize - target.size
      if space <= 0 then
        -- Target full, make source the new target
        target = source
        goto continue_source
      end
      
      local to_move = math.min(space, source.size)
      local ok_move, moved = pcall(tp.transferItem, node.side, node.side, to_move, source.slot, target.slot)
      if ok_move and moved and moved > 0 then
        target.size = target.size + moved
        source.size = source.size - moved
      end
      
      ::continue_source::
    end
    
    ::continue_group::
  end
  
  -- Help GC by clearing references
  items = nil
  by_key = nil
end

return {
  device_nodes = device_nodes,
  find_free_slot = find_free_slot,
  find_slot_with = find_slot_with,
  consolidate_buffer = consolidate_buffer,
}
