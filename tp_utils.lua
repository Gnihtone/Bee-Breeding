-- tp_utils.lua
-- Helpers for working with multiple transposers and inventory nodes.
-- A node is represented as {tp = "<address>", side = <number>, marker = "...", name = "..."}.

local component = require("component")

-- Build a map addr -> proxy for quick reuse.
local function build_proxy_map(addrs)
  local map = {}
  for _, addr in ipairs(addrs or {}) do
    if addr and not map[addr] then
      map[addr] = component.proxy(addr)
    end
  end
  return map
end

-- Pick the first usable node and its proxy.
local function pick_node(tp_map, nodes)
  if not nodes then return nil end
  for _, node in ipairs(nodes) do
    if node.tp and tp_map[node.tp] then
      return node, tp_map[node.tp]
    end
  end
  return nil
end

-- Find a common transposer between two node lists.
-- Returns {tp = proxy, tp_addr = addr, a = nodeA, b = nodeB} or nil+err.
local function find_common(tp_map, nodesA, nodesB)
  if not nodesA or not nodesB then
    return nil, "missing nodes"
  end
  for _, a in ipairs(nodesA) do
    for _, b in ipairs(nodesB) do
      if a.tp and b.tp and a.tp == b.tp then
        local tp = tp_map[a.tp]
        if tp then
          return {tp = tp, tp_addr = a.tp, a = a, b = b}
        end
      end
    end
  end
  return nil, "no common transposer"
end

return {
  build_proxy_map = build_proxy_map,
  pick_node = pick_node,
  find_common = find_common,
}
