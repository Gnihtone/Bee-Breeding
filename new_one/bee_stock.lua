-- bee_stock.lua
-- Maintains a local view of bee counts in an ME network by species and stage.
-- Assumes only pure, pristine bees are stored; no hybrids/frames/honeycombs.

local analyzer = require("analyzer")

local stock_mt = {}
stock_mt.__index = stock_mt

-- Internal: tally a stack into the counts table.
local function tally_stack(counts, stack)
  local species = analyzer.get_species(stack)
  if not species then
    return
  end
  local entry = counts[species] or {princess = 0, drone = 0}
  if analyzer.is_princess(stack) then
    entry.princess = entry.princess + (stack.size or 1)
  else
    entry.drone = entry.drone + (stack.size or 1)
  end
  counts[species] = entry
end

-- Rescan ME network and rebuild counts.
function stock_mt:rescan()
  local items, err = self.me:list_items()
  if not items then
    error("rescan failed: " .. tostring(err), 2)
  end
  local counts = {}
  for _, stack in ipairs(items) do
    tally_stack(counts, stack)
  end
  self._counts = counts
  return counts
end

-- Get counts table for a species: {princess=..., drone=...} or nil.
function stock_mt:get(species)
  return self._counts[species]
end

-- Whether there is at least one princess or drone of this species.
function stock_mt:has(species)
  local c = self._counts[species]
  return c ~= nil and (c.princess > 0 or c.drone > 0)
end

-- Whether there is enough stock to start breeding: >=1 princess and >=64 drones.
function stock_mt:breeding_ready(species)
  local c = self._counts[species]
  if not c then return false end
  return c.princess >= 1 and c.drone >= 64
end

-- Return the whole counts table.
function stock_mt:all()
  return self._counts
end

local function new(me_obj)
  if not (me_obj and me_obj.list_items) then
    error("bee_stock.new expects me_interface instance with list_items()", 2)
  end
  local obj = {me = me_obj, _counts = {}}
  return setmetatable(obj, stock_mt)
end

return {
  new = new,
}
