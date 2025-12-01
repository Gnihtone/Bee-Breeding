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

local function discover()
  local transposers = {}
  for addr in component.list("transposer") do
    table.insert(transposers, addr)
  end
  if #transposers == 0 then
    return nil, "No transposers found"
  end

  local devices = {
    transposers = transposers, -- list of addresses
    storages = {}, -- role -> {nodes...}
    apiary = {},
    accl = {},
    analyzer = {},
    me_interfaces = {} -- role -> {address=?, nodes={...}}
  }

  -- Scan all transposers and their six sides.
  for _, addr in ipairs(transposers) do
    local tp = component.proxy(addr)
    for _, side in ipairs({sides.bottom, sides.top, sides.north, sides.south, sides.west, sides.east}) do
      local ok, invName = pcall(tp.getInventoryName, side)
      if not ok or not invName then
        goto continue_side
      end

      local marker = read_marker_transposer(tp, side)
      local role = classify_role(marker)
      local lowerName = string.lower(invName)
      local node = {tp = addr, side = side, marker = marker, name = invName}

      -- Device detection by inventory name.
      if lowerName:find("tile.for.apiculture") or lowerName:find("alveary") then
        table.insert(devices.apiary, node)
      elseif lowerName:find("tile.labMachine") then
        table.insert(devices.accl, node)
      elseif lowerName:find("tile.for.core") then
        table.insert(devices.analyzer, node)
      elseif lowerName:find("interface") then
        if role then
          devices.me_interfaces[role] = devices.me_interfaces[role] or {nodes = {}}
          table.insert(devices.me_interfaces[role].nodes, node)
        end
      end

      if role and role ~= "ROLE:ME-MAIN" and role ~= "ROLE:ME-BEES" then
        devices.storages[role] = devices.storages[role] or {}
        table.insert(devices.storages[role], node)
      end

      ::continue_side::
    end
  end

  -- Map me_interface component addresses to roles via slot-1 marker in interface config.
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
        devices.me_interfaces[role] = devices.me_interfaces[role] or {nodes = {}}
        devices.me_interfaces[role].address = devices.me_interfaces[role].address or addr
      end
    end
  end

  return devices
end

return {
  discover = discover,
}
