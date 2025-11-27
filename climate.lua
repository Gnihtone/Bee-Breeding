-- climate.lua
-- Acclimatization helper (assumes acclimatizer inventory layout: slot 5 princess, slot 6 reagent, slot 9 output).
-- Reagent mapping must be configured by the user in CLIMATE_ITEMS / HUMIDITY_ITEMS.

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

local function find_stack(transposer, side, matcher)
  local size = transposer.getInventorySize(side)
  if not size then return nil end
  for slot = 1, size do
    local stack = transposer.getStackInSlot(side, slot)
    if stack and matcher(stack) then
      return slot, stack
    end
  end
  return nil
end

-- Ensure princess from buffer is acclimatized according to req.
-- Assumes: acclimatizer slots: 5=princess in, 6=reagent in, 9=output.
-- Keeps slot 6 filled while waiting. Returns true on success, nil+err on timeout/missing reagent.
local function ensure_princess(req, transposer, bufferSide, acclSide, acclimSide)
  if not needs_acclimatization(req) then
    return true
  end
  if not transposer or not bufferSide or not acclSide or not acclimSide then
    return nil, "acclimatization requires transposer, buffer, accl and acclim sides"
  end

  local reagents = select_reagent(req)
  if #reagents == 0 then
    return nil, "no reagents configured for climate/humidity"
  end

  -- Find princess in buffer.
  local princessSlot = find_stack(transposer, bufferSide, function(s) return s.name == "Forestry:beePrincessGE" end)
  if not princessSlot then
    return nil, "no princess in buffer to acclimatize"
  end

  local function ensure_reagent()
    if transposer.getStackInSlot(acclSide, 6) then
      return true
    end
    for _, label in ipairs(reagents) do
      local reagentSlot = find_stack(transposer, acclimSide, function(s) return s.label == label or s.name == label end)
      if reagentSlot then
        local moved = transposer.transferItem(acclimSide, acclSide, 1, reagentSlot, 6)
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
  local moved = transposer.transferItem(bufferSide, acclSide, 1, princessSlot, 5)
  if not moved or moved == 0 then
    return nil, "failed to move princess to acclimatizer"
  end

  -- Wait for output to appear in slot 9, then pull back to buffer (first free slot).
  local attempts = 0
  local outSlot = 9
  local princessOut = nil
  while attempts < 600 do -- 5 minutes @0.5s
    ensure_reagent()
    princessOut = transposer.getStackInSlot(acclSide, outSlot)
    if princessOut then break end
    attempts = attempts + 1
    os.sleep(0.5)
  end
  if not princessOut then
    return nil, "acclimatization timeout"
  end

  -- Move result back to buffer (append to first free slot).
  local bufSize = transposer.getInventorySize(bufferSide)
  local targetSlot = nil
  for slot = 1, bufSize do
    if not transposer.getStackInSlot(bufferSide, slot) then
      targetSlot = slot
      break
    end
  end
  if not targetSlot then
    return nil, "buffer is full, cannot return acclimatized princess"
  end
  transposer.transferItem(acclSide, bufferSide, princessOut.size or 1, outSlot, targetSlot)

  -- Cleanup reagent if any leftover in slot 6.
  local leftover = transposer.getStackInSlot(acclSide, 6)
  if leftover then
    transposer.transferItem(acclSide, acclimSide, leftover.size or 1, 6)
  end

  return true
end

return {
  needs_acclimatization = needs_acclimatization,
  ensure_princess = ensure_princess,
  select_reagent = select_reagent,
}
