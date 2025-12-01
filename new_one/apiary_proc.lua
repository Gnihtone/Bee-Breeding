-- apiary_proc.lua
-- Handles breeding cycles in a Forestry Apiary.
-- Selects bee pairs from buffer, loads into apiary, waits for cycle, unloads results.

local component = require("component")
local mover = require("mover")
local analyzer = require("analyzer")
local utils = require("utils")

-- Forestry Apiary slots
local PRINCESS_SLOT = 1
local DRONE_SLOT = 2
local OUTPUT_SLOTS = {6, 7, 8, 9, 10, 11, 12}

local device_nodes = utils.device_nodes
local find_free_slot = utils.find_free_slot

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

-- Scan buffer and return categorized bees.
-- Returns: { princess = {...}, drones = {species -> list} }
local function scan_buffer(buffer_node, valid_species)
  local result = {
    princess = nil,  -- {slot, stack, species, is_pure}
    drones = {},     -- species -> list of {slot, stack, is_pure}
  }
  
  for _, species in ipairs(valid_species) do
    result.drones[species] = {}
  end
  
  local tp = component.proxy(buffer_node.tp)
  local ok_size, size = pcall(tp.getInventorySize, buffer_node.side)
  if not ok_size or type(size) ~= "number" then
    return result
  end
  
  for slot = 1, size do
    local ok_stack, stack = pcall(tp.getStackInSlot, buffer_node.side, slot)
    if ok_stack and stack and stack.individual then
      local species = analyzer.get_species(stack)
      if species then
        -- Check if species is one of valid_species
        local valid = false
        for _, s in ipairs(valid_species) do
          if s == species then valid = true; break end
        end
        
        if valid then
          local is_pure = analyzer.is_pure(stack)
          
          if analyzer.is_princess(stack) then
            if not result.princess then
              result.princess = {
                slot = slot,
                stack = stack,
                species = species,
                is_pure = is_pure,
              }
            end
          else
            -- Drone
            table.insert(result.drones[species], {
              slot = slot,
              stack = stack,
              is_pure = is_pure,
            })
          end
        end
      end
    end
  end
  
  return result
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
  
  -- Always try target first
  table.insert(priority, target)
  
  -- Then opposite parent
  if princess_species == target then
    -- Princess is target, use any parent
    table.insert(priority, parent1)
    table.insert(priority, parent2)
  elseif princess_species == parent1 then
    table.insert(priority, parent2)
  elseif princess_species == parent2 then
    table.insert(priority, parent1)
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
    if ok_stack and stack then
      -- Check if it's a princess (not queen) - cycle complete
      if analyzer.is_princess(stack) then
        return true
      end
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
function apiary_mt:breed_cycle(timeout_sec)
  if not self.target then
    return nil, "no breeding task set"
  end
  
  -- Find shared transposer nodes
  local buffer_node, apiary_node, shared_err = find_shared_nodes(self.buffer_dev, self.apiary_dev)
  if not buffer_node then
    return nil, shared_err
  end
  
  -- Scan buffer for available bees
  local scan = scan_buffer(buffer_node, self.valid_species)
  
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
  
  -- Load drone into apiary slot 2
  local moved_d, derr = mover.move_between_nodes(
    buffer_node, apiary_node, 64, drone.slot, DRONE_SLOT
  )
  if not moved_d or moved_d == 0 then
    -- Unload princess back
    local _, free_slot = find_free_slot(self.buffer_dev)
    if free_slot then
      mover.move_between_nodes(apiary_node, buffer_node, 1, PRINCESS_SLOT, free_slot)
    end
    return nil, "failed to load drone: " .. tostring(derr)
  end
  
  -- Wait for cycle to complete
  local cycle_ok, cycle_err = wait_cycle(apiary_node, timeout_sec)
  if not cycle_ok then
    return nil, cycle_err
  end
  
  -- Unload all output slots to buffer
  for _, out_slot in ipairs(OUTPUT_SLOTS) do
    local _, dst_slot = find_free_slot(self.buffer_dev)
    if dst_slot then
      mover.move_between_nodes(apiary_node, buffer_node, 64, out_slot, dst_slot)
    end
  end
  
  -- Unload new princess from slot 1
  local _, dst_slot = find_free_slot(self.buffer_dev)
  if dst_slot then
    mover.move_between_nodes(apiary_node, buffer_node, 1, PRINCESS_SLOT, dst_slot)
  end
  
  return true
end

-- Get current breeding task info.
function apiary_mt:get_task()
  return {
    parent1 = self.parent1,
    parent2 = self.parent2,
    target = self.target,
  }
end

local function new(buffer_dev, apiary_dev)
  if not buffer_dev then error("buffer device required", 2) end
  if not apiary_dev then error("apiary device required", 2) end
  
  return setmetatable({
    buffer_dev = buffer_dev,
    apiary_dev = apiary_dev,
    parent1 = nil,
    parent2 = nil,
    target = nil,
    valid_species = {},
  }, apiary_mt)
end

return {
  new = new,
}
