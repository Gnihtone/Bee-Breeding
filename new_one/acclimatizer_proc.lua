-- acclimatizer_proc.lua
-- Adjusts bees in a buffer to required climate/humidity via an Acclimatizer.

local component = require("component")
local mover = require("mover")
local utils = require("utils")
local config = require("config")

local INPUT_SLOT = 1
local CLIMATE_SLOT = 6   -- Reagent for temperature
local HUMIDITY_SLOT = 7  -- Reagent for humidity
local OUTPUT_SLOT = 9

local CLIMATE_ITEMS = config.CLIMATE_ITEMS
local HUMIDITY_ITEMS = config.HUMIDITY_ITEMS
local DEFAULT_CLIMATE_REAGENT = config.DEFAULT_CLIMATE_REAGENT
local DEFAULT_HUMIDITY_REAGENT = config.DEFAULT_HUMIDITY_REAGENT

local device_nodes = utils.device_nodes
local find_slot_with = utils.find_slot_with

local function find_accl_node(dev)
  local nodes = device_nodes(dev)
  if #nodes == 0 then
    return nil, "no acclimatizer nodes"
  end
  return nodes[1]
end

-- Find the acclimatizer node that shares a transposer with the given source node.
local function find_accl_node_for(accl_dev, src_node)
  for _, node in ipairs(device_nodes(accl_dev)) do
    if node.tp == src_node.tp then
      return node
    end
  end
  return nil, "no acclimatizer shares transposer with source"
end

local accl_mt = {}
accl_mt.__index = accl_mt

-- Clear a specific slot in acclimatizer, move contents to mats storage.
local function clear_slot(self, accl_node, slot)
  local tp = component.proxy(accl_node.tp)
  local ok_stack, stack = pcall(tp.getStackInSlot, accl_node.side, slot)
  if not ok_stack or not stack then
    return true  -- Already empty
  end
  
  local dst_node, dst_slot = utils.find_free_slot(self.mats_dev)
  if not dst_node then
    return nil, "no free slot in mats storage"
  end
  
  local accl_for_dst = find_accl_node_for(self.accl_dev, dst_node)
  if not accl_for_dst then
    return nil, "cannot return reagent: no shared transposer"
  end
  
  mover.move_between_nodes(accl_for_dst, dst_node, nil, slot, dst_slot)
  return true
end

-- Load reagent into a specific slot (up to 64).
local function load_to_slot(self, accl_node, slot, label)
  -- Find reagent in mats storage
  local src_node, src_slot = find_slot_with(self.mats_dev, label)
  if not src_node then
    return nil, "reagent not found: " .. label
  end
  
  local accl_for_src = find_accl_node_for(self.accl_dev, src_node)
  if not accl_for_src then
    return nil, "cannot load reagent: no shared transposer"
  end
  
  local moved = mover.move_between_nodes(src_node, accl_for_src, 64, src_slot, slot)
  return moved and moved > 0
end

-- Refill reagent slot if running low.
local function refill_slot_if_needed(self, accl_node, slot, label, min_count)
  min_count = min_count or 8
  local tp = component.proxy(accl_node.tp)
  
  local ok_stack, stack = pcall(tp.getStackInSlot, accl_node.side, slot)
  local current = 0
  if ok_stack and stack then
    current = stack.size or 0
  end
  
  if current >= min_count then
    return true
  end
  
  -- Try to refill
  load_to_slot(self, accl_node, slot, label)
  return true
end

-- Get reagent label for climate requirement.
local function get_climate_reagent(climate)
  if not climate then return nil end
  local upper = string.upper(climate)
  return CLIMATE_ITEMS[upper]
end

-- Get reagent label for humidity requirement.
local function get_humidity_reagent(humidity)
  if not humidity then return nil end
  local upper = string.upper(humidity)
  return HUMIDITY_ITEMS[upper]
end

-- Process bee (princess or drone) through acclimatizer.
-- Uses slot 6 for climate reagent, slot 7 for humidity reagent.
-- Keeps refilling reagents until output appears.
-- Returns dst_slot where bee was moved back to.
local function process_bee(self, buffer_node, src_slot, climate, humidity, timeout_sec)
  local accl_node = find_accl_node_for(self.accl_dev, buffer_node)
  if not accl_node then
    return nil, "no acclimatizer shares transposer with buffer"
  end
  
  local tp = component.proxy(accl_node.tp)
  
  -- Determine reagents
  local climate_reagent = get_climate_reagent(climate) or DEFAULT_CLIMATE_REAGENT
  local humidity_reagent = get_humidity_reagent(humidity) or DEFAULT_HUMIDITY_REAGENT
  
  -- Clear both slots first
  clear_slot(self, accl_node, CLIMATE_SLOT)
  clear_slot(self, accl_node, HUMIDITY_SLOT)
  
  -- Load initial reagents (64 each)
  local ok1, err1 = load_to_slot(self, accl_node, CLIMATE_SLOT, climate_reagent)
  if not ok1 then
    return nil, "failed to load climate reagent: " .. tostring(err1)
  end
  
  local ok2, err2 = load_to_slot(self, accl_node, HUMIDITY_SLOT, humidity_reagent)
  if not ok2 then
    return nil, "failed to load humidity reagent: " .. tostring(err2)
  end
  
  -- Move bee into acclimatizer
  local moved_in = mover.move_between_nodes(buffer_node, accl_node, 1, src_slot, INPUT_SLOT)
  if not moved_in then
    return nil, "failed to move bee to acclimatizer"
  end
  
  -- Wait for output, refilling reagents as needed
  local waited = 0
  while true do
    local ok_stack, stack = pcall(tp.getStackInSlot, accl_node.side, OUTPUT_SLOT)
    if ok_stack and stack then
      -- Move back to buffer using cache for free slot
      local dst_slot = self.cache:find_free_slot()
      if dst_slot then
        mover.move_between_nodes(accl_node, buffer_node, 1, OUTPUT_SLOT, dst_slot)
        -- Clear reagent slots
        clear_slot(self, accl_node, CLIMATE_SLOT)
        clear_slot(self, accl_node, HUMIDITY_SLOT)
        return dst_slot
      else
        return nil, "no free slot in buffer for acclimatized bee"
      end
    end
    
    -- Refill reagents if running low
    refill_slot_if_needed(self, accl_node, CLIMATE_SLOT, climate_reagent, 8)
    refill_slot_if_needed(self, accl_node, HUMIDITY_SLOT, humidity_reagent, 8)
    
    if timeout_sec and waited >= timeout_sec then
      return nil, "acclimatizer timeout"
    end
    os.sleep(0.5)
    waited = waited + 0.5
  end
end

-- Process princess and drones - acclimatize those that need it (uses cache).
-- Only bees with non-Normal native climate/humidity need acclimatization.
-- requirements: {climate = "Hot", humidity = "Arid"} (can be "Normal")
-- timeout_sec: timeout in seconds
function accl_mt:process_all(requirements, timeout_sec)
  local climate = requirements and requirements.climate
  local humidity = requirements and requirements.humidity
  
  -- Get bees needing acclimatization from cache
  local needs_accl = self.cache:find_needing_acclimatization()
  
  -- Get buffer node for operations
  local nodes = device_nodes(self.buffer_dev)
  if #nodes == 0 then return true end
  local buffer_node = nodes[1]
  
  local dirty_slots = {}
  
  -- Process princess if found
  if needs_accl.princess then
    local princess = needs_accl.princess
    local bee_climate = princess.climate or "Normal"
    local bee_humidity = princess.humidity or "Normal"
    print(string.format("    Acclimatizing princess (native: %s/%s)", bee_climate, bee_humidity))
    
    local dst_slot, err = process_bee(
      self, 
      buffer_node, 
      princess.slot, 
      climate, 
      humidity, 
      timeout_sec
    )
    
    if not dst_slot then
      error("princess acclimatization failed: " .. tostring(err), 2)
    end
    
    table.insert(dirty_slots, princess.slot)
    table.insert(dirty_slots, dst_slot)
  end
  
  -- Acclimatize all drones that need it
  local drones = needs_accl.drones
  if #drones > 0 then
    local total_drones = 0
    for _, d in ipairs(drones) do
      total_drones = total_drones + d.count
    end
    print("    Acclimatizing " .. total_drones .. " drone(s) in " .. #drones .. " slot(s)")
    
    for _, drone in ipairs(drones) do
      table.insert(dirty_slots, drone.slot)
      
      -- Process each drone in the stack one by one
      for j = 1, drone.count do
        local dst_slot, err = process_bee(
          self, 
          buffer_node, 
          drone.slot, 
          climate, 
          humidity, 
          timeout_sec
        )
        if not dst_slot then
          error("drone acclimatization failed: " .. tostring(err), 2)
        end
        table.insert(dirty_slots, dst_slot)
      end
    end
  end
  
  -- Mark all affected slots as dirty
  self.cache:mark_slots_dirty(dirty_slots)
  
  return true
end

local function new(buffer_dev, accl_dev, mats_dev, cache)
  if not buffer_dev then error("buffer device required", 2) end
  if not accl_dev then error("acclimatizer device required", 2) end
  if not mats_dev then error("acclimatizer mats storage required", 2) end
  if not cache then error("buffer cache required", 2) end
  return setmetatable({
    buffer_dev = buffer_dev,
    accl_dev = accl_dev,
    mats_dev = mats_dev,
    cache = cache,
  }, accl_mt)
end

return {
  new = new,
}
