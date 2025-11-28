-- me_bees.lua
-- Work with the dedicated bee ME interface via setInterfaceConfiguration.

local component = require("component")
local tp_utils = require("tp_utils")

local DEFAULT_SLOT = 9 -- use the last config slot by convention
local DEFAULT_WAIT = 20 -- seconds to wait for ME to populate after config
local DEFAULT_DB_SLOT = 1 -- use first db slot for ghost stacks

local function find_stack_by_species(iface, speciesName)
  local items = iface.getItemsInNetwork()
  if not items then return nil end
  for _, entry in ipairs(items) do
    local stack = entry
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

-- nodes: list of {tp, side} pointing at the bee ME interface inventory.
-- tp_map: addr -> proxy
-- db_addr: optional database address to use; if nil, first database is used.
local function new(addr, nodes, tp_map, db_addr)
  if not addr then
    return nil, "bee ME interface address missing"
  end
  if not nodes or #nodes == 0 then
    return nil, "bee ME interface node missing"
  end
  if not tp_map then
    return nil, "transposer map required"
  end
  if not db_addr then
    db_addr = component.list("database")()
  end
  if not db_addr then
    return nil, "database component required for bee ME (setInterfaceConfiguration)"
  end

  local db = component.proxy(db_addr)
  if not db then
    return nil, "invalid database component"
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
    -- Store descriptor via ME interface into database slot.
    local okdb, errdb = pcall(iface.store, stack, db_addr, DEFAULT_DB_SLOT)
    if not okdb then
      return nil, "database store failed: " .. tostring(errdb)
    end
    local ok, err = pcall(iface.setInterfaceConfiguration, slot, db_addr, DEFAULT_DB_SLOT, stack.size or stack.count or 1)
    if not ok then
      return nil, "setInterfaceConfiguration failed: " .. tostring(err)
    end
    return true
  end

  -- Pull one stack of the configured bee from the interface into target inventory nodes/slot.
  local function pull_to(targetNodes, targetSlot, slot)
    slot = slot or DEFAULT_SLOT
    local route, err = tp_utils.find_common(tp_map, nodes, targetNodes)
    if not route then
      return nil, "no common transposer for bee ME -> target: " .. tostring(err)
    end
    local moved = route.tp.transferItem(route.a.side, route.b.side, 64, slot, targetSlot)
    return moved
  end

  -- Return bees back into the interface (they will be absorbed into ME).
  local function push_from(sourceNodes, fromSlot, count, toSlot)
    toSlot = toSlot or DEFAULT_SLOT
    local route, err = tp_utils.find_common(tp_map, sourceNodes, nodes)
    if not route then
      return nil, "no common transposer for return to bee ME: " .. tostring(err)
    end
    local moved = route.tp.transferItem(route.a.side, route.b.side, count or 64, fromSlot, toSlot)
    return moved
  end

  -- High-level: request a species and pull it to target inventory nodes/slot.
  function self:request_species(speciesName, targetNodes, targetSlot, slot, waitSeconds)
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
      moved = pull_to(targetNodes, targetSlot, slot) or 0
      if moved > 0 then break end
      os.sleep(0.5)
    until os.time() >= deadline
    if moved == 0 then
      return nil, "timed out waiting for bee output from ME"
    end
    return moved
  end

  -- Push cleaned bees back into ME (any stack).
  function self:return_bee(fromNodes, fromSlot, count, toSlot)
    return push_from(fromNodes, fromSlot, count, toSlot)
  end

  return self
end

return {
  new = new,
}
