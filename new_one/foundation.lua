-- foundation.lua
-- Ensures the required foundation block is placed into a designated buffer for manual installation under the apiary.
-- Assumes the block already exists in the ME network (no crafting).

local component = require("component")
local mover = require("mover")
local me_interface = require("me_interface")
local utils = require("utils")

local foundation_mt = {}
foundation_mt.__index = foundation_mt

local function first_database()
  for addr in component.list("database") do
    return addr
  end
  return nil
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

-- Configure ME interface slot 9 for the required block and move it to foundation buffer.
function foundation_mt:ensure(label)
  if label == "none" then
    return true
  end

  local ok_cfg, err = self.me:configure_output_slot({label = label}, {slot_idx = 9})
  if not ok_cfg then
    error("failed to configure ME interface: " .. tostring(err), 2)
  end

  local _, dst_slot, ferr = utils.find_free_slot(self.foundation_dev)
  if not dst_slot then
    error(ferr or "no destination slot", 2)
  end

  local moved, merr = mover.move_between_devices(self.me_dev, self.foundation_dev, 1, 9, dst_slot)
  if not moved then
    error("move failed: " .. tostring(merr), 2)
  end
  return true
end

local function new(me_dev, foundation_dev, db_addr)
  local me_addr = (me_dev and me_dev.address) or addr_of(me_dev)
  if not me_addr then
    error("ME interface address required", 2)
  end
  local db = db_addr or first_database()
  if not db then
    error("database component not found", 2)
  end
  local me_obj = me_interface.new(me_addr, db)
  local obj = {
    me = me_obj,
    me_dev = me_dev,
    foundation_dev = foundation_dev,
  }
  return setmetatable(obj, foundation_mt)
end

return {
  new = new,
}
