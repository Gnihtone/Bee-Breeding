-- climate.lua
-- Acclimatization helper (assumes acclimatizer inventory layout: slot 5 princess, slot 6 reagent, slot 9 output).
-- Reagent mapping must be configured by the user in CLIMATE_ITEMS / HUMIDITY_ITEMS.

local tp_utils = require("tp_utils")

local CLIMATE_ITEMS = {
  HOT = "Blaze Rod",
  WARM = "Blaze Rod",
  HELLISH = "Blaze Rod",
  COLD = "Ice",
  ICY = "Ice",
}

local HUMIDITY_ITEMS = {
  DAMP = "Water Can",
  ARID = "Sand",
}

local function needs_acclimatization(req)
  if not req then return false end
  return (req.climate and req.climate ~= "NORMAL") or (req.humidity and req.humidity ~= "NORMAL")
end

local function select_reagent(req)
  local items = {}
  if req.climate and req.climate ~= "NORMAL" then
    local item = CLIMATE_ITEMS[req.climate]
    if item then table.insert(items, item) end
  end
  if req.humidity and req.humidity ~= "NORMAL" then
    local item = HUMIDITY_ITEMS[req.humidity]
    if item then table.insert(items, item) end
  end
  return items
end

local function find_stack(tp, side, matcher)
  local size = tp.getInventorySize(side)
  if not size then return nil end
  for slot = 1, size do
    local stack = tp.getStackInSlot(side, slot)
    if stack and matcher(stack) then
      return slot, stack
    end
  end
  return nil
end

-- Ensure princess from buffer is acclimatized according to req.
-- Assumes: acclimatizer slots: 5=princess in, 6=reagent in, 9=output.
-- Keeps slot 6 filled while waiting. Returns true on success, nil+err on timeout/missing reagent.
-- bufferNodes/acclNodes/acclimNodes are node lists; tp_map maps transposer addresses to proxies.
local function ensure_princess(req, tp_map, bufferNodes, acclNodes, acclimNodes)
  if not needs_acclimatization(req) then
    return true
  end
  if not tp_map or not bufferNodes or not acclNodes or not acclimNodes then
    return nil, "acclimatization requires tp_map, buffer, accl and acclim nodes"
  end

  local reagents = select_reagent(req)
  if #reagents == 0 then
    return nil, "no reagents configured for climate/humidity"
  end

  local route_buf_accl, rerr1 = tp_utils.find_common(tp_map, bufferNodes, acclNodes)
  if not route_buf_accl then
    return nil, "no common transposer for buffer->accl: " .. tostring(rerr1)
  end
  local route_acclim_accl, rerr2 = tp_utils.find_common(tp_map, acclimNodes, acclNodes)
  if not route_acclim_accl then
    return nil, "no common transposer for acclim->accl: " .. tostring(rerr2)
  end

  local tp_buf = route_buf_accl.tp
  local tp_accl = route_acclim_accl.tp

  -- Find princess in buffer.
  local princessSlot = find_stack(tp_buf, route_buf_accl.a.side, function(s) return s.name == "Forestry:beePrincessGE" end)
  if not princessSlot then
    return nil, "no princess in buffer to acclimatize"
  end

  local function ensure_reagent()
    if tp_accl.getStackInSlot(route_acclim_accl.b.side, 6) then
      return true
    end
    for _, label in ipairs(reagents) do
      local reagentSlot = find_stack(tp_accl, route_acclim_accl.a.side, function(s) return s.label == label or s.name == label end)
      if reagentSlot then
        local moved = tp_accl.transferItem(route_acclim_accl.a.side, route_acclim_accl.b.side, 1, reagentSlot, 6)
        if moved and moved > 0 then
          return true
        end
      end
    end
    return false
  end

  if not ensure_reagent() then
    return nil, "reagent not found for acclimatization"
  end

  -- Move princess to acclimatizer slot 5.
  local moved = tp_buf.transferItem(route_buf_accl.a.side, route_buf_accl.b.side, 1, princessSlot, 5)
  if not moved or moved == 0 then
    return nil, "failed to move princess to acclimatizer"
  end

  -- Wait for output to appear in slot 9, then pull back to buffer (first free slot).
  local attempts = 0
  local outSlot = 9
  local princessOut = nil
  while attempts < 600 do -- 5 minutes @0.5s
    ensure_reagent()
    princessOut = tp_accl.getStackInSlot(route_acclim_accl.b.side, outSlot)
    if princessOut then break end
    attempts = attempts + 1
    os.sleep(0.5)
  end
  if not princessOut then
    return nil, "acclimatization timeout"
  end

  -- Move result back to buffer (append to first free slot).
  local bufSize = tp_buf.getInventorySize(route_buf_accl.a.side)
  local targetSlot = nil
  for slot = 1, bufSize do
    if not tp_buf.getStackInSlot(route_buf_accl.a.side, slot) then
      targetSlot = slot
      break
    end
  end
  if not targetSlot then
    return nil, "buffer is full, cannot return acclimatized princess"
  end
  tp_accl.transferItem(route_acclim_accl.b.side, route_buf_accl.a.side, princessOut.size or 1, outSlot, targetSlot)

  -- Cleanup reagent if any leftover in slot 6.
  local leftover = tp_accl.getStackInSlot(route_acclim_accl.b.side, 6)
  if leftover then
    tp_accl.transferItem(route_acclim_accl.b.side, route_acclim_accl.a.side, leftover.size or 1, 6)
  end

  return true
end

return {
  needs_acclimatization = needs_acclimatization,
  ensure_princess = ensure_princess,
  select_reagent = select_reagent,
}
