-- me.lua
-- Interact with main ME interface to ensure required blocks.

local component = require("component")
local tp_utils = require("tp_utils")

local DEFAULT_SLOT = 9
local DEFAULT_DB_SLOT = 1

local function find_stack_by_label(iface, label)
  local items = iface.getItemsInNetwork()
  if not items then return nil end
  for _, entry in ipairs(items) do
    if entry.label == label or entry.name == label then
      return entry
    end
  end
  return nil
end

-- nodes: list of {tp, side} for the ME interface inventory
-- tp_map: addr -> proxy
-- db_addr: optional database address to use; if nil, first database is used.
local function new(addr, nodes, tp_map, db_addr)
  if not addr then
    return nil, "main ME interface address missing"
  end
  if not nodes or #nodes == 0 then
    return nil, "main ME interface node missing"
  end
  if not tp_map then
    return nil, "transposer map required"
  end
  if not db_addr then
    db_addr = component.list("database")()
  end
  if not db_addr then
    return nil, "database component required for ME (setInterfaceConfiguration)"
  end

  local db = component.proxy(db_addr)
  if not db then
    return nil, "invalid database component"
  end

  local iface = component.proxy(addr)
  if not iface or not iface.setInterfaceConfiguration then
    return nil, "invalid main ME interface"
  end

  local self = {}

  -- Configure interface to provide a target stack (by descriptor).
  local function configure(stack, slot)
    slot = slot or DEFAULT_SLOT
    local okdb, errdb = pcall(iface.store, stack, db_addr, DEFAULT_DB_SLOT)
    if not okdb then
      return nil, "database store failed: " .. tostring(errdb)
    end
    local stored = db.get(DEFAULT_DB_SLOT)
    if not stored then
      if db.set then
        local okset, errset = pcall(db.set, DEFAULT_DB_SLOT, stack)
        if not okset then
          return nil, "database slot empty after store; fallback set failed: " .. tostring(errset)
        end
        stored = db.get(DEFAULT_DB_SLOT)
      end
      if not stored then
        return nil, "database slot empty after store"
      end
    end
    local ok, err = pcall(iface.setInterfaceConfiguration, slot, db_addr, DEFAULT_DB_SLOT, stack.size or stack.count or 1)
    if not ok then
      return nil, "setInterfaceConfiguration failed: " .. tostring(err)
    end
    return slot
  end

  -- Ensure block is present in storage by pulling from ME.
  -- targetNodes: list of nodes for destination inventory.
  function self:ensure_block_by_label(label, targetNodes, targetSlot)
    local stack = find_stack_by_label(iface, label)
    if not stack then
      return nil, "block not found in ME: " .. tostring(label)
    end
    local slot, err = configure(stack, DEFAULT_SLOT)
    if not slot then
      return nil, err
    end
    local route, rerr = tp_utils.find_common(tp_map, nodes, targetNodes)
    if not route then
      return nil, "no common transposer for ME->target: " .. tostring(rerr)
    end
    local moved = route.tp.transferItem(route.a.side, route.b.side, 64, slot, targetSlot)
    return moved
  end

  return self
end

return {
  new = new,
}
