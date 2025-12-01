-- me_interface.lua
-- Object wrapper around an AE2 ME Interface: list items and request crafts into a configured output slot.
-- Create via new(iface, db_addr) where iface is address/proxy and db_addr points to a database component.

local component = require("component")

local DB_SLOTS = 81 -- 9x9 database

local function as_iface(iface)
  if type(iface) == "string" then
    return component.proxy(iface)
  end
  return iface
end

local function as_db(db_addr)
  if type(db_addr) == "string" then
    return component.proxy(db_addr)
  end
  return db_addr
end

local function addr_of(proxy_or_addr)
  if type(proxy_or_addr) == "string" then
    return proxy_or_addr
  end
  if type(proxy_or_addr) == "table" and proxy_or_addr.address then
    return proxy_or_addr.address
  end
  return nil
end

local function build_filter(stack)
  local filter = {}
  if stack.name then filter.name = stack.name end
  if stack.label then filter.label = stack.label end
  if stack.fingerprint then filter.fingerprint = stack.fingerprint end
  if stack.size then filter.size = stack.size end
  return filter
end

local iface_mt = {}
iface_mt.__index = iface_mt

function iface_mt:_iface_slot_count()
  local ok, cfg = pcall(self.iface.getInterfaceConfiguration)
  if ok and type(cfg) == "table" and #cfg > 0 then
    return #cfg
  end
  return 9
end

local function find_free_db_slot(db)
  for i = 1, DB_SLOTS do
    local ok, entry = pcall(db.get, i)
    if ok and (entry == nil or entry.size == 0) then
      return i
    end
  end
  return nil, "no free database slot"
end

-- List stored items in the ME network, optionally filtered by stack descriptor.
function iface_mt:list_items(stack_filter)
  local filter = stack_filter and build_filter(stack_filter) or nil
  local ok, items_or_err = pcall(self.iface.getItemsInNetwork, filter)
  if not ok then
    return nil, "getItemsInNetwork failed: " .. tostring(items_or_err)
  end
  return items_or_err
end

-- Find first craftable matching the stack descriptor.
function iface_mt:find_craftable(stack)
  local filter = build_filter(stack)
  local ok, list_or_err = pcall(self.iface.getCraftables, filter)
  if not ok then
    return nil, "getCraftables failed: " .. tostring(list_or_err)
  end
  if not list_or_err or not list_or_err[1] then
    return nil, "no craftable found"
  end
  return list_or_err[1]
end

-- Write a ghost item into database and point interface slot to it.
function iface_mt:configure_output_slot(stack, opts)
  opts = opts or {}
  local db_slot = opts.db_slot
  if not db_slot then
    local slot, serr = find_free_db_slot(self.db)
    if not slot then
      return nil, serr
    end
    db_slot = slot
  end

  local ok_store, store_err = pcall(self.iface.store, build_filter(stack), self.db_addr, db_slot, 1)
  if not ok_store or store_err == false then
    return nil, "store to database failed"
  end

  local target_slot = opts.slot_idx or self:_iface_slot_count()
  local ok_cfg, cfg_err = pcall(self.iface.setInterfaceConfiguration, target_slot, self.db_addr, db_slot, opts.size or stack.size or 64)
  if not ok_cfg or cfg_err == false then
    return nil, "setInterfaceConfiguration failed"
  end

  -- Clear any previous ghost to avoid leaking db slots; if we reused a slot, wiping is harmless.
  pcall(self.db.clear, db_slot)
  os.sleep(0.5)

  return true
end

-- Request crafting of a stack and configure the interface output slot.
function iface_mt:request_to_interface(stack, amount, opts)
  opts = opts or {}
  local craftable, err = self:find_craftable(stack)
  if not craftable then
    return nil, err
  end
  local ok_req, req = pcall(craftable.request, amount or stack.size or 1)
  if not ok_req then
    return nil, "craft request failed"
  end
  local ok_cfg, cfg_err = self:configure_output_slot(stack, {slot_idx = opts.slot_idx, size = amount or stack.size})
  if not ok_cfg then
    return nil, cfg_err
  end
  return req or true
end

local function new(iface, db_addr)
  local db_proxy = as_db(db_addr)
  local obj = {
    iface = as_iface(iface),
    db = db_proxy,
    db_addr = addr_of(db_addr) or (db_proxy and db_proxy.address),
  }
  if not obj.iface then
    error("ME interface proxy not available", 2)
  end
  if not obj.db then
    error("database proxy not available", 2)
  end
  return setmetatable(obj, iface_mt)
end

return {
  new = new,
}
