-- inventory.lua
-- Movement and lookup helpers across transposer-connected inventories.

local analyzer = require("analyzer")
local tp_utils = require("tp_utils")

-- tp_map: addr -> transposer proxy
-- roles: role -> {nodes}
local function new(tp_map, roles)
  roles = roles or {}
  if not tp_map then
    return nil, "transposer map required"
  end

  local self = {}

  local function first_node(nodes)
    return tp_utils.pick_node(tp_map, nodes)
  end

  local function first_free_slot(nodes)
    local node, tp = first_node(nodes)
    if not node or not tp then return nil end
    local size = tp.getInventorySize(node.side)
    if not size then return nil end
    for slot = 1, size do
      if not tp.getStackInSlot(node.side, slot) then
        return slot
      end
    end
    return nil
  end

  local function first_stack(nodes, predicate)
    local node, tp = first_node(nodes)
    if not node or not tp then
      return nil
    end
    local size = tp.getInventorySize(node.side)
    if not size then
      return nil
    end
    for slot = 1, size do
      local stack = tp.getStackInSlot(node.side, slot)
      if stack and (not predicate or predicate(stack)) then
        return slot, stack, node
      end
    end
    return nil
  end

  function self:first_stack(nodes, predicate)
    return first_stack(nodes, predicate)
  end

  function self:first_free_slot(nodes)
    return first_free_slot(nodes)
  end

  local function is_drone(stack)
    return stack and stack.name == "Forestry:beeDroneGE"
  end

  local function is_princess(stack)
    return stack and stack.name == "Forestry:beePrincessGE"
  end

  function self:count_pure_drones(nodes, species)
    local node, tp = first_node(nodes)
    if not node or not tp then return 0 end
    local size = tp.getInventorySize(node.side)
    local count = 0
    if not size then
      return 0
    end
    for slot = 1, size do
      local stack = tp.getStackInSlot(node.side, slot)
      if is_drone(stack) then
        local pure, s = analyzer.is_pure(stack)
        if pure and s == species then
          count = count + (stack.size or 1)
        end
      end
    end
    return count
  end

  function self:find_drone(nodes, species, preferPure)
    preferPure = preferPure ~= false
    local node, tp = first_node(nodes)
    if not node or not tp then return nil end
    local size = tp.getInventorySize(node.side)
    if not size then return nil end
    local fallback = nil
    for slot = 1, size do
      local stack = tp.getStackInSlot(node.side, slot)
      if is_drone(stack) then
        local _, s = analyzer.is_pure(stack)
        if s == species then
          local pure = select(1, analyzer.is_pure(stack))
          if pure then
            if preferPure then
              return slot, stack, node
            else
              fallback = fallback or {slot, stack, node}
            end
          else
            fallback = fallback or {slot, stack, node}
          end
        end
      end
    end
    if fallback then
      return fallback[1], fallback[2], fallback[3]
    end
    return nil
  end

  function self:find_princess(nodes, species, pristineOnly)
    pristineOnly = pristineOnly ~= false
    local node, tp = first_node(nodes)
    if not node or not tp then return nil end
    local size = tp.getInventorySize(node.side)
    if not size then return nil end
    for slot = 1, size do
      local stack = tp.getStackInSlot(node.side, slot)
      if is_princess(stack) then
        local _, s = analyzer.is_pure(stack)
        if s == species or species == nil then
          if pristineOnly then
            if analyzer.is_pristine_princess(stack) then
              return slot, stack, node
            end
          else
            return slot, stack, node
          end
        end
      end
    end
    return nil
  end

  function self:dump_dirty_drones(fromNodes, toTrashNodes)
    toTrashNodes = toTrashNodes or roles.trash
    if not toTrashNodes then
      return 0
    end
    local route, rerr = tp_utils.find_common(tp_map, fromNodes, toTrashNodes)
    if not route then
      return 0, rerr
    end
    local moved = 0
    local tp = route.tp
    local size = tp.getInventorySize(route.a.side)
    if not size then
      return 0
    end
    for slot = 1, size do
      local stack = tp.getStackInSlot(route.a.side, slot)
      if is_drone(stack) then
        local pure = select(1, analyzer.is_pure(stack))
        if not pure then
          moved = moved + (tp.transferItem(route.a.side, route.b.side, stack.size or 1, slot) or 0)
        end
      end
    end
    return moved
  end

  -- Move between two node sets that share a transposer.
  function self:move(fromNodes, toNodes, count, fromSlot, toSlot)
    local route, err = tp_utils.find_common(tp_map, fromNodes, toNodes)
    if not route then
      return nil, err
    end
    local moved = route.tp.transferItem(route.a.side, route.b.side, count or 64, fromSlot, toSlot)
    return moved
  end

  self.roles = roles

  return self
end

return {
  new = new,
}
