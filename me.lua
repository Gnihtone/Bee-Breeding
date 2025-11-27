-- me.lua
-- Interact with main ME interface to ensure required blocks.

local component = require("component")

local DEFAULT_SLOT = 9

local function find_stack_by_label(iface, label)
  local items = iface.getAvailableItems()
  if not items then return nil end
  for _, entry in ipairs(items) do
    if entry.label == label or entry.name == label then
      return entry
    end
  end
  return nil
end

local function new(addr, side, transposer)
  if not addr then
    return nil, "main ME interface address missing"
  end
  if not side then
    return nil, "main ME interface side missing"
  end
  if not transposer then
    return nil, "transposer required"
  end

  local iface = component.proxy(addr)
  if not iface or not iface.setInterfaceConfiguration then
    return nil, "invalid main ME interface"
  end

  local self = {}

  -- Configure interface to provide a target stack (by descriptor).
  local function configure(stack, slot)
    slot = slot or DEFAULT_SLOT
    local ok, err = pcall(iface.setInterfaceConfiguration, slot, stack)
    if not ok then
      return nil, "setInterfaceConfiguration failed: " .. tostring(err)
    end
    return slot
  end

  -- Attempt to pull one stack of the requested item into target side/slot.
  local function pull_to(targetSide, targetSlot, slot)
    slot = slot or DEFAULT_SLOT
    local moved = transposer.transferItem(side, targetSide, 64, slot, targetSlot)
    return moved
  end

  -- Ensure block is present in storage by pulling from ME.
  function self:ensure_block_by_label(label, targetSide, targetSlot)
    local stack = find_stack_by_label(iface, label)
    if not stack then
      return nil, "block not found in ME: " .. tostring(label)
    end
    local slot, err = configure(stack, DEFAULT_SLOT)
    if not slot then
      return nil, err
    end
    local moved = pull_to(targetSide, targetSlot, slot)
    return moved
  end

  return self
end

return {
  new = new,
}
