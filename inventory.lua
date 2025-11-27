-- inventory.lua
-- Movement and lookup helpers across transposer-connected inventories.

local analyzer = require("analyzer")

local function new(tp, roles)
  if not tp then
    return nil, "transposer required"
  end
  roles = roles or {}

  local self = {}

  local function move(fromSide, toSide, count, fromSlot, toSlot)
    return tp.transferItem(fromSide, toSide, count or 64, fromSlot, toSlot)
  end

  local function first_free_slot(side)
    local size = tp.getInventorySize(side)
    if not size then return nil end
    for slot = 1, size do
      if not tp.getStackInSlot(side, slot) then
        return slot
      end
    end
    return nil
  end

  local function first_stack(side, predicate)
    local size = tp.getInventorySize(side)
    if not size then
      return nil
    end
    for slot = 1, size do
      local stack = tp.getStackInSlot(side, slot)
      if stack and (not predicate or predicate(stack)) then
        return slot, stack
      end
    end
    return nil
  end

  function self:first_stack(side, predicate)
    return first_stack(side, predicate)
  end

  function self:first_free_slot(side)
    return first_free_slot(side)
  end

  local function is_drone(stack)
    return stack and stack.name == "Forestry:beeDroneGE"
  end

  local function is_princess(stack)
    return stack and stack.name == "Forestry:beePrincessGE"
  end

  function self:count_pure_drones(side, species)
    local size = tp.getInventorySize(side)
    local count = 0
    if not size then
      return 0
    end
    for slot = 1, size do
      local stack = tp.getStackInSlot(side, slot)
      if is_drone(stack) then
        local pure, s = analyzer.is_pure(stack)
        if pure and s == species then
          count = count + (stack.size or 1)
        end
      end
    end
    return count
  end

  function self:find_drone(side, species, preferPure)
    preferPure = preferPure ~= false
    local size = tp.getInventorySize(side)
    if not size then return nil end
    local fallback = nil
    for slot = 1, size do
      local stack = tp.getStackInSlot(side, slot)
      if is_drone(stack) then
        local _, s = analyzer.is_pure(stack)
        if s == species then
          local pure = select(1, analyzer.is_pure(stack))
          if pure then
            if preferPure then
              return slot, stack
            else
              fallback = fallback or {slot, stack}
            end
          else
            fallback = fallback or {slot, stack}
          end
        end
      end
    end
    if fallback then
      return fallback[1], fallback[2]
    end
    return nil
  end

  function self:find_princess(side, species, pristineOnly)
    pristineOnly = pristineOnly ~= false
    local size = tp.getInventorySize(side)
    if not size then return nil end
    for slot = 1, size do
      local stack = tp.getStackInSlot(side, slot)
      if is_princess(stack) then
        local _, s = analyzer.is_pure(stack)
        if s == species or species == nil then
          if pristineOnly then
            if analyzer.is_pristine_princess(stack) then
              return slot, stack
            end
          else
            return slot, stack
          end
        end
      end
    end
    return nil
  end

  function self:dump_dirty_drones(fromSide, toTrashSide)
    toTrashSide = toTrashSide or roles.trash
    if not toTrashSide then
      return 0
    end
    local moved = 0
    local size = tp.getInventorySize(fromSide)
    if not size then
      return 0
    end
    for slot = 1, size do
      local stack = tp.getStackInSlot(fromSide, slot)
      if is_drone(stack) then
        local pure = select(1, analyzer.is_pure(stack))
        if not pure then
          moved = moved + (move(fromSide, toTrashSide, stack.size or 1, slot) or 0)
        end
      end
    end
    return moved
  end

  self.move = move
  self.roles = roles

  return self
end

return {
  new = new,
}
