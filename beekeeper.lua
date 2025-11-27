-- beekeeper.lua
-- State machine for apiary automation (one princess in circulation).

local analyzer = require("analyzer")
local climate = require("climate")

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

local function scan_buffer(tp, bufferSide, targetSpecies)
  local info = {
    princess = nil,
    princess_pure = false,
    princess_pristine = false,
    drones_total = 0,
    drones_pure = 0,
  }
  local size = tp.getInventorySize(bufferSide)
  if not size then return info end
  for slot = 1, size do
    local stack = tp.getStackInSlot(bufferSide, slot)
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

local function clear_apiary(tp, apiarySide, bufferSide)
  local size = tp.getInventorySize(apiarySide)
  if not size then return end
  for slot = 1, size do
    local stack = tp.getStackInSlot(apiarySide, slot)
    if stack then
      tp.transferItem(apiarySide, bufferSide, stack.size or 1, slot)
    end
  end
end

local function apiary_cycle_done(tp, apiarySide)
  -- Heuristic: if no princess in slot 1 or 2 -> cycle ended / empty.
  local s1 = tp.getStackInSlot(apiarySide, 1)
  local s2 = tp.getStackInSlot(apiarySide, 2)
  return not s1 and not s2
end

local function load_pair(tp, apiarySide, bufferSide, princessSlot, droneSlot)
  clear_apiary(tp, apiarySide, bufferSide)
  local movedP = tp.transferItem(bufferSide, apiarySide, 1, princessSlot, 1)
  local movedD = tp.transferItem(bufferSide, apiarySide, 1, droneSlot, 2)
  return (movedP and movedP > 0) and (movedD and movedD > 0)
end

local function collect_to_buffer(tp, apiarySide, bufferSide)
  local size = tp.getInventorySize(apiarySide)
  if not size then return 0 end
  local moved = 0
  for slot = 1, size do
    local stack = tp.getStackInSlot(apiarySide, slot)
    if stack then
      moved = moved + (tp.transferItem(apiarySide, bufferSide, stack.size or 1, slot) or 0)
    end
  end
  return moved
end

local function first_free_slot(tp, side)
  local size = tp.getInventorySize(side)
  if not size then return nil end
  for slot = 1, size do
    if not tp.getStackInSlot(side, slot) then
      return slot
    end
  end
  return size
end

local function analyze_buffer(tp, bufferSide, analyzerSide, targetSpecies, forcePrincess)
  if not analyzerSide then
    return true
  end
  local size = tp.getInventorySize(bufferSide)
  if not size then
    return nil, "no buffer inventory"
  end
  for slot = 1, size do
    local stack = tp.getStackInSlot(bufferSide, slot)
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
        -- still analyze to learn its traits if not analyzed
        need = need or not pure
      end
      if need then
        tp.transferItem(bufferSide, analyzerSide, stack.size or 1, slot, 3)
        local analyzed = nil
        local attempts = 0
        repeat
          analyzed = tp.getStackInSlot(analyzerSide, 9)
          if analyzed and analyzed.individual and analyzed.individual.active then break end
          attempts = attempts + 1
          os.sleep(0.5)
        until attempts >= 120
        if not analyzed or not analyzed.individual then
          return nil, "analyzer timeout"
        end
        local free = first_free_slot(tp, bufferSide) or slot
        tp.transferItem(analyzerSide, bufferSide, analyzed.size or 1, 9, free)
      end
    end
  end
  -- cleanup analyzer slots 3 and 9
  local leftover = tp.getStackInSlot(analyzerSide, 3)
  if leftover then
    tp.transferItem(analyzerSide, bufferSide, leftover.size or 1, 3)
  end
  local leftover9 = tp.getStackInSlot(analyzerSide, 9)
  if leftover9 then
    tp.transferItem(analyzerSide, bufferSide, leftover9.size or 1, 9)
  end
  return true
end

local function new(ctx)
  -- ctx: transposer, apiarySide, bufferSide, analyzerSide, trashSide, acclSide, acclimSide, bee_me (me_bees instance)
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
    local tp = self.ctx.transposer
    local buf = self.ctx.bufferSide
    local apiary = self.ctx.apiarySide
    if not tp or not buf or not apiary then
      return fail("missing transposer/apiary/buffer")
    end

    if self.state == STATES.IDLE or self.state == STATES.ERROR then
      return self.state
    elseif self.state == STATES.LOAD then
      -- Make sure existing bees are analyzed (princess priority).
      local ok, err = analyze_buffer(tp, buf, self.ctx.analyzerSide, self.target.species, true)
      if not ok then
        return fail("analyze before load failed: " .. tostring(err))
      end
      -- Ensure acclimatization if needed.
      ok, err = climate.ensure_princess(self.target.reqs, tp, buf, self.ctx.acclSide, self.ctx.acclimSide)
      if not ok then
        return fail("acclimatization failed: " .. tostring(err))
      end
      local info = scan_buffer(tp, buf, self.target.species)
      if not info.princess then
        return fail("no princess in buffer for load")
      end
      local droneSlot = nil
      -- Pick any drone of target species (pure preferred handled by buffer preparation).
      local size = tp.getInventorySize(buf)
      for slot = 1, size do
        local stack = tp.getStackInSlot(buf, slot)
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
      if not load_pair(tp, apiary, buf, info.princess.slot, droneSlot) then
        return fail("failed to load apiary")
      end
      self.state = STATES.WAIT
      return self.state
    elseif self.state == STATES.WAIT then
      if apiary_cycle_done(tp, apiary) then
        self.state = STATES.COLLECT
      end
      return self.state
    elseif self.state == STATES.COLLECT then
      collect_to_buffer(tp, apiary, buf)
      local ok, err = analyze_buffer(tp, buf, self.ctx.analyzerSide, self.target.species, true)
      if not ok then
        return fail("analyze failed: " .. tostring(err))
      end
      self.state = STATES.EVAL
      return self.state
    elseif self.state == STATES.EVAL then
      local info = scan_buffer(tp, buf, self.target.species)
      if info.princess and info.princess_pure and info.princess_pristine and info.drones_pure >= 64 then
        self.state = STATES.DONE
      else
        self.state = STATES.STABILIZE
      end
      return self.state
    elseif self.state == STATES.STABILIZE then
      -- Keep target princess + drone in apiary to purify, then move to REPRO when pure.
      local info = scan_buffer(tp, buf, self.target.species)
      if not info.princess then
        return fail("no princess during stabilize")
      end
      -- If princess pure and pristine -> move to REPRO; else keep cycling.
      if info.princess_pure and info.princess_pristine then
        self.state = STATES.REPRO
        return self.state
      end
      -- pick any drone of target species
      local droneSlot = nil
      local size = tp.getInventorySize(buf)
      for slot = 1, size do
        local stack = tp.getStackInSlot(buf, slot)
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
      load_pair(tp, apiary, buf, info.princess.slot, droneSlot)
      self.state = STATES.WAIT
      return self.state
    elseif self.state == STATES.REPRO then
      local info = scan_buffer(tp, buf, self.target.species)
      if info.princess_pure and info.princess_pristine and info.drones_pure >= 64 then
        self.state = STATES.DONE
        return self.state
      end
      -- Keep cycling same pure princess + pure drone.
      local droneSlot = nil
      local size = tp.getInventorySize(buf)
      for slot = 1, size do
        local stack = tp.getStackInSlot(buf, slot)
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
      load_pair(tp, apiary, buf, info.princess.slot, droneSlot)
      self.state = STATES.WAIT
      return self.state
    elseif self.state == STATES.DONE then
      -- Finalize: move pure bees of target species to bee ME, dirty drones to trash.
      local bee_me = self.ctx.bee_me
      local trash = self.ctx.trashSide
      local size = tp.getInventorySize(buf)
      for slot = 1, size do
        local stack = tp.getStackInSlot(buf, slot)
        if stack then
          local pure, sp = analyzer.is_pure(stack)
          if sp == self.target.species and pure and bee_me then
            local moved = bee_me:return_bee(buf, slot, stack.size or 1, 1)
            if not moved or moved == 0 then
              return fail("failed to return bee to bee ME from slot " .. slot)
            end
          elseif is_drone(stack) and trash then
            local moved = tp.transferItem(buf, trash, stack.size or 1, slot)
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
