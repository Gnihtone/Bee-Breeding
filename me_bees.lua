-- me_bees.lua
-- Work with the dedicated bee ME interface via setInterfaceConfiguration.

local component = require("component")

local DEFAULT_SLOT = 9 -- use the last config slot by convention
local DEFAULT_WAIT = 20 -- seconds to wait for ME to populate after config

local function find_stack_by_species(iface, speciesName)
  local items = iface.getAvailableItems()
  if not items then return nil end
  for _, entry in ipairs(items) do
    local stack = entry
    -- entry may be {size=..., name=..., fingerprint=..., label=...}
    if stack.label == speciesName or (stack.displayName and stack.displayName == speciesName) then
      return stack
    end
    if stack.individual and stack.individual.displayName == speciesName then
      return stack
    end
    if stack.label and stack.label:find(speciesName, 1, true) then
      return stack
    end
  end
  return nil
end

local function new(addr, side, transposer)
  if not addr then
    return nil, "bee ME interface address missing"
  end
  if not side then
    return nil, "bee ME interface side missing"
  end
  if not transposer then
    return nil, "transposer required"
  end

  local iface = component.proxy(addr)
  if not iface or not iface.setInterfaceConfiguration then
    return nil, "invalid bee ME interface"
  end

  local self = {}

  -- Find a bee stack by species name (displayName) in ME.
  function self:find_species(speciesName)
    return find_stack_by_species(iface, speciesName)
  end

  -- Configure slot to output the desired bee stack.
  function self:set_config(slot, stack)
    slot = slot or DEFAULT_SLOT
    local ok, err = pcall(iface.setInterfaceConfiguration, slot, stack)
    if not ok then
      return nil, "setInterfaceConfiguration failed: " .. tostring(err)
    end
    return true
  end

  -- Pull one stack of the configured bee from the interface into target side/slot.
  function self:pull_bee(targetSide, targetSlot, slot)
    slot = slot or DEFAULT_SLOT
    local moved = transposer.transferItem(side, targetSide, 64, slot, targetSlot)
    return moved
  end

  -- Return bees back into the interface (they will be absorbed into ME).
  function self:push_bee(fromSide, fromSlot, count, toSlot)
    toSlot = toSlot or DEFAULT_SLOT
    local moved = transposer.transferItem(fromSide, side, count or 64, fromSlot, toSlot)
    return moved
  end

  -- High-level: request a species and pull it to targetSide/targetSlot.
  function self:request_species(speciesName, targetSide, targetSlot, slot, waitSeconds)
    slot = slot or DEFAULT_SLOT
    local stack = self:find_species(speciesName)
    if not stack then
      return nil, "species not found in bee ME: " .. tostring(speciesName)
    end
    local ok, err = self:set_config(slot, stack)
    if not ok then
      return nil, err
    end
    local deadline = os.time() + (waitSeconds or DEFAULT_WAIT)
    local moved = 0
    repeat
      moved = self:pull_bee(targetSide, targetSlot, slot) or 0
      if moved > 0 then break end
      os.sleep(0.5)
    until os.time() >= deadline
    if moved == 0 then
      return nil, "timed out waiting for bee output from ME"
    end
    return moved
  end

  -- Push cleaned bees back into ME (any stack).
  function self:return_bee(fromSide, fromSlot, count, toSlot)
    return self:push_bee(fromSide, fromSlot, count, toSlot)
  end

  return self
end

return {
  new = new,
}
