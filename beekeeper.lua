-- beekeeper.lua
-- State machine for apiary automation (one princess in circulation).

local analyzer = require("analyzer")
local climate = require("climate")
local tp_utils = require("tp_utils")

local STATES = {
  IDLE = "IDLE",
  LOAD = "LOAD",
  WAIT = "WAIT",
  COLLECT = "COLLECT",
  EVAL = "EVAL",
  STABILIZE = "STABILIZE",
  REPRO = "REPRO",
  DONE = "DONE",
  ERROR = "ERROR",
}

local function is_drone(stack)
  return stack and stack.name == "Forestry:beeDroneGE"
end

local function is_princess(stack)
  return stack and stack.name == "Forestry:beePrincessGE"
end

local function scan_buffer(tp_map, bufferNodes, targetSpecies)
  local info = {
    princess = nil,
    princess_pure = false,
    princess_pristine = false,
    drones_total = 0,
    drones_pure = 0,
  }
  local node, tp = tp_utils.pick_node(tp_map, bufferNodes)
  if not node or not tp then return info end
  local size = tp.getInventorySize(node.side)
  if not size then return info end
  for slot = 1, size do
    local stack = tp.getStackInSlot(node.side, slot)
    if stack then
      if is_princess(stack) then
        local pure, species = analyzer.is_pure(stack)
        if not targetSpecies or species == targetSpecies then
          info.princess = info.princess or {slot = slot, stack = stack}
          info.princess_pure = pure
          info.princess_pristine = analyzer.is_pristine_princess(stack)
        end
      elseif is_drone(stack) then
        local pure, species = analyzer.is_pure(stack)
        if not targetSpecies or species == targetSpecies then
          info.drones_total = info.drones_total + (stack.size or 1)
          if pure then
            info.drones_pure = info.drones_pure + (stack.size or 1)
          end
        end
      end
    end
  end
  return info
end

local function clear_apiary(tp_map, apiaryNodes, bufferNodes)
  local route, err = tp_utils.find_common(tp_map, apiaryNodes, bufferNodes)
  if not route then return nil, err end
  local tp = route.tp
  local size = tp.getInventorySize(route.a.side)
  if not size then return true end
  for slot = 1, size do
    local stack = tp.getStackInSlot(route.a.side, slot)
    if stack then
      tp.transferItem(route.a.side, route.b.side, stack.size or 1, slot)
    end
  end
  return true
end

local function apiary_cycle_done(tp_map, apiaryNodes)
  local node, tp = tp_utils.pick_node(tp_map, apiaryNodes)
  if not node or not tp then return false end
  local s1 = tp.getStackInSlot(node.side, 1)
  local s2 = tp.getStackInSlot(node.side, 2)
  return not s1 and not s2
end

local function load_pair(tp_map, apiaryNodes, bufferNodes, princessSlot, droneSlot)
  local route, err = tp_utils.find_common(tp_map, bufferNodes, apiaryNodes)
  if not route then return nil, err end
  clear_apiary(tp_map, apiaryNodes, bufferNodes)
  local movedP = route.tp.transferItem(route.a.side, route.b.side, 1, princessSlot, 1)
  local movedD = route.tp.transferItem(route.a.side, route.b.side, 1, droneSlot, 2)
  return (movedP and movedP > 0) and (movedD and movedD > 0), nil
end

local function collect_to_buffer(tp_map, apiaryNodes, bufferNodes)
  local route, err = tp_utils.find_common(tp_map, apiaryNodes, bufferNodes)
  if not route then return nil, err end
  local size = route.tp.getInventorySize(route.a.side)
  local moved = 0
  if not size then return 0 end
  for slot = 1, size do
    local stack = route.tp.getStackInSlot(route.a.side, slot)
    if stack then
      moved = moved + (route.tp.transferItem(route.a.side, route.b.side, stack.size or 1, slot) or 0)
    end
  end
  return moved
end

local function first_free_slot(tp_map, nodes)
  local node, tp = tp_utils.pick_node(tp_map, nodes)
  if not node or not tp then return nil end
  local size = tp.getInventorySize(node.side)
  if not size then return nil end
  for slot = 1, size do
    if not tp.getStackInSlot(node.side, slot) then
      return slot
    end
  end
  return size
end

local function analyze_buffer(tp_map, bufferNodes, analyzerNodes, targetSpecies, forcePrincess)
  if not analyzerNodes or #analyzerNodes == 0 then
    return true
  end
  local route, err = tp_utils.find_common(tp_map, bufferNodes, analyzerNodes)
  if not route then
    return nil, "no common transposer for buffer<->analyzer: " .. tostring(err)
  end
  local tp = route.tp
  local size = tp.getInventorySize(route.a.side)
  if not size then
    return nil, "no buffer inventory"
  end
  for slot = 1, size do
    local stack = tp.getStackInSlot(route.a.side, slot)
    if stack and (is_princess(stack) or is_drone(stack)) then
      local pure, species = analyzer.is_pure(stack)
      local need = false
      if is_princess(stack) then
        need = forcePrincess or not (stack.individual and stack.individual.active)
      elseif is_drone(stack) then
        if not (stack.individual and stack.individual.active) then
          need = true
        end
      end
      if targetSpecies and species and species ~= targetSpecies then
        need = need or not pure
      end
      if need then
        tp.transferItem(route.a.side, route.b.side, stack.size or 1, slot, 3)
        local analyzed = nil
        local attempts = 0
        repeat
          analyzed = tp.getStackInSlot(route.b.side, 9)
          if analyzed and analyzed.individual and analyzed.individual.active then break end
          attempts = attempts + 1
          os.sleep(0.5)
        until attempts >= 120
        if not analyzed or not analyzed.individual then
          return nil, "analyzer timeout"
        end
        local free = first_free_slot(tp_map, bufferNodes) or slot
        tp.transferItem(route.b.side, route.a.side, analyzed.size or 1, 9, free)
      end
    end
  end
  local leftover = tp.getStackInSlot(route.b.side, 3)
  if leftover then
    tp.transferItem(route.b.side, route.a.side, leftover.size or 1, 3)
  end
  local leftover9 = tp.getStackInSlot(route.b.side, 9)
  if leftover9 then
    tp.transferItem(route.b.side, route.a.side, leftover9.size or 1, 9)
  end
  return true
end

local function new(ctx)
  -- ctx: tp_map, apiaryNodes, bufferNodes, analyzerNodes, trashNodes, acclNodes, acclimNodes, bee_me (me_bees instance)
  local self = {
    state = STATES.IDLE,
    ctx = ctx or {},
    target = nil,
  }

  local function fail(err)
    self.state = STATES.ERROR
    self.last_error = err
    return self.state, err
  end

  function self:start(targetSpecies, reqs)
    self.target = {species = targetSpecies, reqs = reqs}
    self.state = STATES.LOAD
  end

  function self:tick()
    local tp_map = self.ctx.tp_map
    local bufNodes = self.ctx.bufferNodes
    local apiaryNodes = self.ctx.apiaryNodes
    if not tp_map or not bufNodes or not apiaryNodes then
      return fail("missing transposer map/apiary/buffer")
    end

    if self.state == STATES.IDLE or self.state == STATES.ERROR then
      return self.state
    elseif self.state == STATES.LOAD then
      local ok, err = analyze_buffer(tp_map, bufNodes, self.ctx.analyzerNodes, self.target.species, true)
      if not ok then
        return fail("analyze before load failed: " .. tostring(err))
      end
      ok, err = climate.ensure_princess(self.target.reqs, tp_map, bufNodes, self.ctx.acclNodes, self.ctx.acclimNodes)
      if not ok then
        return fail("acclimatization failed: " .. tostring(err))
      end
      local info = scan_buffer(tp_map, bufNodes, self.target.species)
      if not info.princess then
        return fail("no princess in buffer for load")
      end
      local droneSlot = nil
      local node, tp = tp_utils.pick_node(tp_map, bufNodes)
      if not node or not tp then
        return fail("no buffer access")
      end
      local size = tp.getInventorySize(node.side)
      for slot = 1, size do
        local stack = tp.getStackInSlot(node.side, slot)
        if is_drone(stack) then
          local _, sp = analyzer.is_pure(stack)
          if sp == self.target.species then
            droneSlot = slot
            break
          end
        end
      end
      if not droneSlot then
        return fail("no drone in buffer for load")
      end
      local loaded, lerr = load_pair(tp_map, apiaryNodes, bufNodes, info.princess.slot, droneSlot)
      if not loaded then
        return fail("failed to load apiary: " .. tostring(lerr))
      end
      self.state = STATES.WAIT
      return self.state
    elseif self.state == STATES.WAIT then
      if apiary_cycle_done(tp_map, apiaryNodes) then
        self.state = STATES.COLLECT
      end
      return self.state
    elseif self.state == STATES.COLLECT then
      local _, err = collect_to_buffer(tp_map, apiaryNodes, bufNodes)
      local ok, aerr = analyze_buffer(tp_map, bufNodes, self.ctx.analyzerNodes, self.target.species, true)
      if not ok then
        return fail("analyze failed: " .. tostring(aerr))
      end
      self.state = STATES.EVAL
      return self.state
    elseif self.state == STATES.EVAL then
      local info = scan_buffer(tp_map, bufNodes, self.target.species)
      if info.princess and info.princess_pure and info.princess_pristine and info.drones_pure >= 64 then
        self.state = STATES.DONE
      else
        self.state = STATES.STABILIZE
      end
      return self.state
    elseif self.state == STATES.STABILIZE then
      local info = scan_buffer(tp_map, bufNodes, self.target.species)
      if not info.princess then
        return fail("no princess during stabilize")
      end
      if info.princess_pure and info.princess_pristine then
        self.state = STATES.REPRO
        return self.state
      end
      local node, tp = tp_utils.pick_node(tp_map, bufNodes)
      if not node or not tp then return fail("no buffer access") end
      local droneSlot = nil
      local size = tp.getInventorySize(node.side)
      for slot = 1, size do
        local stack = tp.getStackInSlot(node.side, slot)
        if is_drone(stack) then
          local _, sp = analyzer.is_pure(stack)
          if sp == self.target.species then
            droneSlot = slot
            break
          end
        end
      end
      if not droneSlot then
        return fail("no drone for stabilize")
      end
      local loaded, lerr = load_pair(tp_map, apiaryNodes, bufNodes, info.princess.slot, droneSlot)
      if not loaded then
        return fail("failed to load apiary (stabilize): " .. tostring(lerr))
      end
      self.state = STATES.WAIT
      return self.state
    elseif self.state == STATES.REPRO then
      local info = scan_buffer(tp_map, bufNodes, self.target.species)
      if info.princess_pure and info.princess_pristine and info.drones_pure >= 64 then
        self.state = STATES.DONE
        return self.state
      end
      local node, tp = tp_utils.pick_node(tp_map, bufNodes)
      if not node or not tp then return fail("no buffer access") end
      local droneSlot = nil
      local size = tp.getInventorySize(node.side)
      for slot = 1, size do
        local stack = tp.getStackInSlot(node.side, slot)
        if is_drone(stack) then
          local pure, sp = analyzer.is_pure(stack)
          if sp == self.target.species and pure then
            droneSlot = slot
            break
          end
        end
      end
      if not droneSlot then
        return fail("no pure drone for reproduction")
      end
      local loaded, lerr = load_pair(tp_map, apiaryNodes, bufNodes, info.princess.slot, droneSlot)
      if not loaded then
        return fail("failed to load apiary (repro): " .. tostring(lerr))
      end
      self.state = STATES.WAIT
      return self.state
    elseif self.state == STATES.DONE then
      local node, tp = tp_utils.pick_node(tp_map, bufNodes)
      if not node or not tp then return fail("no buffer access") end
      local bee_me = self.ctx.bee_me
      local size = tp.getInventorySize(node.side)
      for slot = 1, size do
        local stack = tp.getStackInSlot(node.side, slot)
        if stack then
          local pure, sp = analyzer.is_pure(stack)
          if sp == self.target.species and pure and bee_me then
            local moved, merr = bee_me:return_bee(bufNodes, slot, stack.size or 1, 1)
            if not moved or moved == 0 then
              return fail("failed to return bee to bee ME from slot " .. slot .. (merr and (" :: " .. tostring(merr)) or ""))
            end
          elseif is_drone(stack) and self.ctx.trashNodes then
            local route, terr = tp_utils.find_common(tp_map, bufNodes, self.ctx.trashNodes)
            if not route then
              return fail("no common transposer to trash: " .. tostring(terr))
            end
            local moved = route.tp.transferItem(route.a.side, route.b.side, stack.size or 1, slot)
            if not moved or moved == 0 then
              return fail("failed to move dirty drone to trash from slot " .. slot)
            end
          elseif sp == self.target.species and pure and not bee_me then
            return fail("pure bee ready but bee ME not available")
          end
        end
      end
      return self.state
    end
    return self.state
  end

  return self
end

return {
  new = new,
  STATES = STATES,
}
