-- apiary_proc.lua
-- Handles breeding cycles in a Forestry Apiary.
-- Selects bee pairs from buffer, loads into apiary, waits for cycle, unloads results.

local component = require("component")
local mover = require("mover")
local utils = require("utils")
local config = require("config")

-- Forestry Apiary slots
local PRINCESS_SLOT = 1
local DRONE_SLOT = 2
local OUTPUT_SLOTS = {3, 4, 5, 6, 7, 8, 9}  -- Output slots
local FRAME_SLOT = config.FRAME_SLOT or 10  -- First frame slot

local device_nodes = utils.device_nodes

local apiary_mt = {}
apiary_mt.__index = apiary_mt

-- Find a pair of nodes (buffer_node, apiary_node) that share the same transposer.
local function find_shared_nodes(buffer_dev, apiary_dev)
  for _, buf_node in ipairs(device_nodes(buffer_dev)) do
    for _, api_node in ipairs(device_nodes(apiary_dev)) do
      if buf_node.tp == api_node.tp then
        return buf_node, api_node
      end
    end
  end
  return nil, nil, "no shared transposer between buffer and apiary"
end

-- Scan buffer using cache and return categorized bees.
-- Returns: { princess = {...}, drones = {species -> list}, invalid_drones = {...} }
local function scan_buffer_cached(cache, valid_species)
  -- Use cache methods directly
  local princess = cache:find_princess(valid_species)
  local drones, invalid_drones = cache:find_drones(valid_species)
  
  return {
    princess = princess,
    drones = drones,
    invalid_drones = invalid_drones,
  }
end

-- Select best drone from a list (prioritize pure).
local function select_best_drone(drone_list)
  if not drone_list or #drone_list == 0 then
    return nil
  end
  
  -- First try to find pure drone
  for _, d in ipairs(drone_list) do
    if d.is_pure then
      return d
    end
  end
  
  -- Otherwise return first available
  return drone_list[1]
end

-- Determine which drone species to use based on princess species.
local function get_drone_species_priority(princess_species, parent1, parent2, target)
  local priority = {}
  
  if princess_species == target then
    -- Princess is already target species - breed with target first, then parents
    table.insert(priority, target)
    table.insert(priority, parent1)
    table.insert(priority, parent2)
  elseif princess_species == parent1 then
    -- Princess is parent1 - breed with parent2 to get mutation (NO target drone!)
    table.insert(priority, parent2)
    table.insert(priority, parent1)  -- Self-breeding as fallback
  elseif princess_species == parent2 then
    -- Princess is parent2 - breed with parent1 to get mutation (NO target drone!)
    table.insert(priority, parent1)
    table.insert(priority, parent2)  -- Self-breeding as fallback
  else
    -- Princess is "foreign" species (side mutation) - fix it with parents
    table.insert(priority, parent1)
    table.insert(priority, parent2)
  end
  
  return priority
end

-- Select a drone based on priority list.
local function select_drone(drones_by_species, priority_species)
  for _, species in ipairs(priority_species) do
    local drone = select_best_drone(drones_by_species[species])
    if drone then
      return drone, species
    end
  end
  return nil
end

-- Wait for breeding cycle to complete.
-- Cycle is complete when slot 1 contains a princess (not a queen).
local function wait_cycle(apiary_node, timeout_sec)
  local tp = component.proxy(apiary_node.tp)
  local waited = 0
  
  while true do
    local ok_stack, stack = pcall(tp.getStackInSlot, apiary_node.side, PRINCESS_SLOT)
    if ok_stack and not stack then
      return true
    end
    
    if timeout_sec and waited >= timeout_sec then
      return nil, "apiary cycle timeout"
    end
    
    os.sleep(1)
    waited = waited + 1
  end
end

-- Set the breeding task.
function apiary_mt:set_breeding_task(parent1, parent2, target)
  if not parent1 or not parent2 or not target then
    error("parent1, parent2, and target species required", 2)
  end
  self.parent1 = parent1
  self.parent2 = parent2
  self.target = target
  self.valid_species = {parent1, parent2, target}
end

-- Perform one breeding cycle.
-- Returns true on success, nil + error on failure.
-- Returns true, scan on success (scan contains princess info for logging)
-- If trash_dev is provided, invalid drones are automatically trashed before breeding.
function apiary_mt:breed_cycle(timeout_sec, trash_dev)
  if not self.target then
    return nil, "no breeding task set"
  end
  
  -- Find shared transposer nodes
  local buffer_node, apiary_node, shared_err = find_shared_nodes(self.buffer_dev, self.apiary_dev)
  if not buffer_node then
    return nil, shared_err
  end
  
  -- Scan buffer for available bees using cache
  local scan = scan_buffer_cached(self.cache, self.valid_species)
  
  -- Trash invalid drones before breeding (if trash_dev provided)
  -- Note: trashing is handled by orchestrator now, just return invalid_drones in scan
  
  if not scan.princess then
    return nil, "no princess found in buffer"
  end
  
  local princess = scan.princess
  
  -- Determine drone priority based on princess species
  local drone_priority = get_drone_species_priority(
    princess.species, self.parent1, self.parent2, self.target
  )
  
  -- Select drone
  local drone, drone_species = select_drone(scan.drones, drone_priority)
  if not drone then
    local needed = table.concat(drone_priority, " or ")
    return nil, "no suitable drone found (need " .. needed .. ")"
  end
  
  -- Load princess into apiary slot 1
  local moved_p, perr = mover.move_between_nodes(
    buffer_node, apiary_node, 1, princess.slot, PRINCESS_SLOT
  )
  if not moved_p or moved_p == 0 then
    return nil, "failed to load princess: " .. tostring(perr)
  end
  self.cache:mark_dirty(princess.slot)
  
  -- Load drone into apiary slot 2
  local moved_d, derr = mover.move_between_nodes(
    buffer_node, apiary_node, 1, drone.slot, DRONE_SLOT
  )
  if not moved_d or moved_d == 0 then
    -- Unload princess back
    local free_slot = self.cache:find_free_slot()
    if free_slot then
      mover.move_between_nodes(apiary_node, buffer_node, 1, PRINCESS_SLOT, free_slot)
      self.cache:mark_dirty(free_slot)
    end
    return nil, "failed to load drone: " .. tostring(derr)
  end
  self.cache:mark_dirty(drone.slot)
  
  -- Wait for cycle to complete
  local cycle_ok, cycle_err = wait_cycle(apiary_node, timeout_sec)
  if not cycle_ok then
    return nil, cycle_err
  end
  
  -- Unload all output slots to buffer
  local dirty_slots = {}
  for _, out_slot in ipairs(OUTPUT_SLOTS) do
    local dst_slot = self.cache:find_free_slot()
    if dst_slot then
      local moved = mover.move_between_nodes(apiary_node, buffer_node, 64, out_slot, dst_slot)
      if moved and moved > 0 then
        table.insert(dirty_slots, dst_slot)
      end
    end
  end
  
  -- Mark all destination slots as dirty
  self.cache:mark_slots_dirty(dirty_slots)
  
  return true, scan
end

-- Get current breeding task info.
function apiary_mt:get_task()
  return {
    parent1 = self.parent1,
    parent2 = self.parent2,
    target = self.target,
  }
end

-- Scan buffer and return categorized bees without breeding (uses cache).
-- Useful for checking invalid bees that need to be cleaned.
function apiary_mt:scan_buffer()
  return scan_buffer_cached(self.cache, self.valid_species)
end

-- Get buffer node for external operations.
function apiary_mt:get_buffer_node()
  local buffer_node = find_shared_nodes(self.buffer_dev, self.apiary_dev)
  return buffer_node
end

-- Check if frame is present in apiary frame slot.
-- Returns true if frame exists, false otherwise.
function apiary_mt:has_frame()
  local buffer_node, apiary_node = find_shared_nodes(self.buffer_dev, self.apiary_dev)
  if not apiary_node then return false end
  
  local tp = component.proxy(apiary_node.tp)
  local ok, stack = pcall(tp.getStackInSlot, apiary_node.side, FRAME_SLOT)
  return ok and stack ~= nil
end

-- Load frame from ME interface into apiary.
-- me_dev: ME interface device with frame configured in output slot
-- me_slot: slot in ME interface where frame is available
-- Returns true on success, nil + error on failure.
function apiary_mt:load_frame_from(me_dev, me_slot)
  local buffer_node, apiary_node = find_shared_nodes(self.buffer_dev, self.apiary_dev)
  if not apiary_node then
    return nil, "no apiary node"
  end
  
  -- Move frame from ME interface to apiary
  local moved = mover.move_between_devices(me_dev, self.apiary_dev, 1, me_slot, FRAME_SLOT)
  if not moved or moved == 0 then
    return nil, "failed to move frame to apiary"
  end
  
  return true
end

-- Unload frame from apiary to destination device.
-- Returns true on success, false if no frame or failed.
function apiary_mt:unload_frame_to(dst_dev)
  local buffer_node, apiary_node = find_shared_nodes(self.buffer_dev, self.apiary_dev)
  if not apiary_node then return false end
  
  local tp = component.proxy(apiary_node.tp)
  local ok, stack = pcall(tp.getStackInSlot, apiary_node.side, FRAME_SLOT)
  if not ok or not stack then
    return false  -- No frame to unload
  end
  
  -- Use utils.find_free_slot for non-buffer devices
  local _, dst_slot = utils.find_free_slot(dst_dev)
  if not dst_slot then
    return false
  end
  
  local moved = mover.move_between_devices(self.apiary_dev, dst_dev, 64, FRAME_SLOT, dst_slot)
  return moved and moved > 0
end

-- Get apiary node for direct operations.
function apiary_mt:get_apiary_node()
  local _, apiary_node = find_shared_nodes(self.buffer_dev, self.apiary_dev)
  return apiary_node
end

-- Get frame slot number.
function apiary_mt:get_frame_slot()
  return FRAME_SLOT
end

local function new(buffer_dev, apiary_dev, cache)
  if not buffer_dev then error("buffer device required", 2) end
  if not apiary_dev then error("apiary device required", 2) end
  if not cache then error("buffer cache required", 2) end
  
  return setmetatable({
    buffer_dev = buffer_dev,
    apiary_dev = apiary_dev,
    cache = cache,
    parent1 = nil,
    parent2 = nil,
    target = nil,
    valid_species = {},
  }, apiary_mt)
end

return {
  new = new,
}
