-- mover.lua
-- Helpers to shuttle items between devices discovered by discovery.lua.
-- A device may be a single node or a table with field `nodes` (as in discovery.lua for ME interfaces).

local component = require("component")
local utils = require("utils")

local device_nodes = utils.device_nodes

local function assert_node(node, name)
  if not (node and node.tp and node.side) then
    error(string.format("invalid %s node", name or "inventory"), 2)
  end
end

local function get_transposer(addr)
  local tp = component.proxy(addr)
  if not tp then
    error("transposer not found: " .. tostring(addr), 2)
  end
  return tp
end

-- Move up to count items between two nodes on the same transposer.
local function move_between_nodes(src_node, dst_node, count, src_slot, dst_slot)
  assert_node(src_node, "source")
  assert_node(dst_node, "dest")

  if src_node.tp ~= dst_node.tp then
    return nil, "nodes are on different transposers"
  end

  local tp = get_transposer(src_node.tp)
  local ok, moved_or_err = pcall(tp.transferItem, src_node.side, dst_node.side, count or 64, src_slot or 1, dst_slot or 1)
  if not ok then
    return nil, "transfer failed: " .. tostring(moved_or_err)
  end
  return moved_or_err or 0
end

-- Move all items from one slot to another side; useful when you do not care how many move.
local function move_slot_nodes(src_node, dst_node, src_slot, dst_slot)
  return move_between_nodes(src_node, dst_node, nil, src_slot, dst_slot)
end

-- Move between two devices (each may have multiple nodes); picks the first compatible node pair on same transposer.
local function move_between_devices(src_dev, dst_dev, count, src_slot, dst_slot)
  local src_list = device_nodes(src_dev)
  local dst_list = device_nodes(dst_dev)
  for _, s in ipairs(src_list) do
    for _, d in ipairs(dst_list) do
      if s.tp == d.tp then
        return move_between_nodes(s, d, count, src_slot, dst_slot)
      end
    end
  end
  return nil, "no shared transposer between devices"
end

return {
  move_between_devices = move_between_devices,
  move_between_nodes = move_between_nodes,
  move_slot_nodes = move_slot_nodes,
}
