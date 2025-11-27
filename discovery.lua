-- discovery.lua
-- Detect devices and storage roles via transposer and slot-1 markers.

local component = require("component")
local sides = require("sides")

local ROLE_PREFIX = "ROLE:"

local function marker_from_stack(stack)
  if not stack then return nil end
  return stack.label or stack.name
end

local function read_marker_transposer(transposer, side)
  local ok, stack = pcall(transposer.getStackInSlot, side, 1)
  if not ok or not stack then
    return nil
  end
  return marker_from_stack(stack)
end

local function classify_role(marker)
  if not marker or marker:sub(1, #ROLE_PREFIX) ~= ROLE_PREFIX then
    return nil
  end
  return marker
end

local function find_transposer()
  local addr = component.list("transposer")()
  if not addr then
    return nil, "No transposer found"
  end
  return component.proxy(addr)
end

local function discover()
  local tp, err = find_transposer()
  if not tp then
    return nil, err
  end

  local devices = {
    transposer = tp,
    apiary = nil,
    accl = nil,
    analyzer = nil,
    storages = {}, -- role -> side
    me_interfaces = {} -- role -> {address=..., side=...}
  }

  local side_roles = {}

  -- Scan all six sides reachable by the selected transposer.
  for _, side in ipairs({sides.bottom, sides.top, sides.north, sides.south, sides.west, sides.east}) do
    local ok, invName = pcall(tp.getInventoryName, side)
    if not ok or not invName then
      goto continue_side
    end

    local lowerName = string.lower(invName)
    local marker = read_marker_transposer(tp, side)
    local role = classify_role(marker)

    -- Device detection by inventory name.
    if lowerName:find("tile.for.apiculture") or lowerName:find("alveary") then
      devices.apiary = side
    elseif lowerName:find("tile.labMachine") then
      devices.accl = side
    elseif lowerName:find("tile.for.core") then
      devices.analyzer = side
    elseif lowerName:find("interface") then
      if role then
        side_roles[role] = side
      end
    end

    if role and not devices.storages[role] then
      -- Only store if role is not a ME marker to avoid mixing.
      if role ~= "ROLE:ME-MAIN" and role ~= "ROLE:ME-BEES" then
        devices.storages[role] = side
      end
    end

    ::continue_side::
  end

  -- Map me_interface addresses to roles via slot-1 marker in interface config.
  for addr in component.list("me_interface") do
    local iface = component.proxy(addr)
    local ok, cfg = pcall(function()
      if iface.getInterfaceConfiguration then
        return iface.getInterfaceConfiguration(1)
      end
    end)
    if ok then
      local marker = cfg and marker_from_stack(cfg)
      local role = classify_role(marker)
      if role then
        devices.me_interfaces[role] = devices.me_interfaces[role] or {}
        devices.me_interfaces[role].address = addr
        devices.me_interfaces[role].side = devices.me_interfaces[role].side or side_roles[role]
      end
    end
  end

  return devices
end

return {
  discover = discover,
}
