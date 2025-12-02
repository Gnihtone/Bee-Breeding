-- orchestrator.lua
-- Executes a single mutation breeding task.
-- Assumes parent species are available in ME (64+ drones, 1+ princess).

local component = require("component")
local analyzer = require("analyzer")
local mover = require("mover")
local utils = require("utils")

local apiary_proc = require("apiary_proc")
local analyzer_proc = require("analyzer_proc")
local acclimatizer_proc = require("acclimatizer_proc")
local foundation = require("foundation")
local me_interface = require("me_interface")

local config = require("config")
local DRONES_NEEDED = config.DRONES_NEEDED
local INITIAL_DRONES_PER_PARENT = config.INITIAL_DRONES_PER_PARENT

local device_nodes = utils.device_nodes
local find_free_slot = utils.find_free_slot

local orch_mt = {}
orch_mt.__index = orch_mt

-- Get climate/humidity requirements for a species from NBT.
-- First tries to find bee in ME and read its NBT.
local function get_requirements(self, species)
  -- Try to find bee in ME and read NBT
  local items = self.me:list_items()
  if items then
    for _, item in ipairs(items) do
      if item.individual and item.individual.displayName == species then
        local climate = analyzer.get_climate(item)
        local humidity = analyzer.get_humidity(item)
        return climate, humidity
      end
    end
  end
  
  -- Fallback to requirements file if available
  if self.requirements_data and self.requirements_data.byBee then
    local req = self.requirements_data.byBee[species]
    if req then
      return req.climate or "Normal", req.humidity or "Normal"
    end
  end
  
  return "Normal", "Normal"
end

-- Count target bees in buffer.
-- Returns: {max_drone_stack = N, total_drones = N, has_princess = bool}
local function count_target_in_buffer(buffer_dev, target_species)
  local result = {max_drone_stack = 0, total_drones = 0, has_princess = false}
  
  -- Use only first node - all nodes point to the same physical inventory
  local nodes = device_nodes(buffer_dev)
  local node = nodes[1]
  if not node then return result end
  
  local tp = component.proxy(node.tp)
  local ok, stacks = pcall(tp.getAllStacks, node.side)
  if ok and stacks then
    for stack in stacks do
      if stack and stack.individual then
        local species = analyzer.get_species(stack)
        if species == target_species and analyzer.is_pure(stack) then
          if analyzer.is_princess(stack) then
            result.has_princess = true
          else
            local size = stack.size or 1
            result.total_drones = result.total_drones + size
            if size > result.max_drone_stack then
              result.max_drone_stack = size
            end
          end
        end
      end
    end
  end
  
  return result
end

-- Sort buffer contents after breeding is complete.
-- Pure target and pure parents → ME, hybrids → trash
local function sort_buffer(self, target_species, parent1, parent2)
  local valid_species = {target_species}
  if parent1 ~= target_species then table.insert(valid_species, parent1) end
  if parent2 ~= target_species and parent2 ~= parent1 then table.insert(valid_species, parent2) end
  
  for _, node in ipairs(device_nodes(self.buffer_dev)) do
    local tp = component.proxy(node.tp)
    local ok_size, size = pcall(tp.getInventorySize, node.side)
    if not ok_size or type(size) ~= "number" then
      goto continue_node
    end
    
    for slot = 1, size do
      local ok_stack, stack = pcall(tp.getStackInSlot, node.side, slot)
      if not ok_stack or not stack or not stack.individual then
        goto continue_slot
      end
      
      local species = analyzer.get_species(stack)
      local is_pure = analyzer.is_pure(stack)
      
      -- Check if it's a valid species
      local is_valid_species = false
      for _, vs in ipairs(valid_species) do
        if species == vs then is_valid_species = true; break end
      end
      
      if is_pure and is_valid_species then
        -- Pure bee of valid species → ME
        local _, dst_slot = find_free_slot(self.me_output_dev)
        if dst_slot then
          mover.move_between_devices(self.buffer_dev, self.me_output_dev, stack.size or 64, slot, dst_slot)
        end
      else
        -- Hybrid or unknown → trash
        local _, dst_slot = find_free_slot(self.trash_dev)
        if dst_slot then
          mover.move_between_devices(self.buffer_dev, self.trash_dev, stack.size or 64, slot, dst_slot)
        end
      end
      
      ::continue_slot::
    end
    ::continue_node::
  end
end

-- Find bee in ME network by species and type.
local function find_bee_in_me(self, species, is_princess)
  -- Get all items and filter manually for more control
  local items, err = self.me:list_items()
  if not items then
    return nil, err
  end
  
  for _, item in ipairs(items) do
    -- Check if it's a bee with matching species
    if item.individual and item.individual.displayName == species then
      -- Check princess vs drone by item name
      local is_item_princess = item.name and item.name:find("Princess")
      if is_princess and is_item_princess then
        return item
      elseif not is_princess and not is_item_princess then
        return item
      end
    end
  end
  
  return nil, "bee not found: " .. species .. (is_princess and " Princess" or " Drone")
end

-- Request bees from ME to buffer.
local function request_bees_from_me(self, species, count, is_princess)
  -- First find the bee to get its exact filter
  local filter, find_err = find_bee_in_me(self, species, is_princess)
  if not filter then
    return nil, find_err
  end

  -- Configure ME interface to output the bees
  -- Use slots 2 and 3 (slot 1 is reserved for role marker)
  local slot_idx = is_princess and 2 or 3
  local ok, err = self.me:configure_output_slot(filter, {slot_idx = slot_idx, size = count})
  if not ok then
    return nil, "failed to configure ME: " .. tostring(err)
  end
  
  -- Wait a bit for items to appear
  os.sleep(0.5)
  
  -- Move from ME interface to buffer
  local _, dst_slot = find_free_slot(self.buffer_dev)
  if not dst_slot then
    return nil, "no free slot in buffer"
  end
  
  local moved = mover.move_between_devices(self.me_input_dev, self.buffer_dev, count, slot_idx, dst_slot)
  if not moved or moved == 0 then
    return nil, "failed to move bees from ME to buffer"
  end
  
  -- Clear ME interface slot configuration after successful move
  self.me:clear_slot(slot_idx)
  
  return moved
end

-- Load initial bees for a mutation.
local function load_initial_bees(self, parent1, parent2)
  -- Request princess (we need one of either parent)
  -- Try parent1 first
  local princess_moved = request_bees_from_me(self, parent1, 1, true)
  if not princess_moved then
    -- Try parent2
    princess_moved = request_bees_from_me(self, parent2, 1, true)
    if not princess_moved then
      return nil, "no princess available for " .. parent1 .. " or " .. parent2
    end
  end
  
  -- Request drones
  if parent1 == parent2 then
    -- Same parent, request 16 drones
    local drones_moved, derr = request_bees_from_me(self, parent1, INITIAL_DRONES_PER_PARENT, false)
    if not drones_moved then
      return nil, "failed to get drones: " .. tostring(derr)
    end
  else
    -- Different parents, request 16 of each
    local d1_moved, d1err = request_bees_from_me(self, parent1, INITIAL_DRONES_PER_PARENT, false)
    if not d1_moved then
      return nil, "failed to get " .. parent1 .. " drones: " .. tostring(d1err)
    end
    
    local d2_moved, d2err = request_bees_from_me(self, parent2, INITIAL_DRONES_PER_PARENT, false)
    if not d2_moved then
      return nil, "failed to get " .. parent2 .. " drones: " .. tostring(d2err)
    end
  end
  
  return true
end

-- Execute a single mutation.
-- mutation = {parent1, parent2, child, block}
-- Returns true on success, error on failure.
function orch_mt:execute_mutation(mutation)
  if not mutation then error("mutation required", 2) end
  if not mutation.parent1 then error("mutation.parent1 required", 2) end
  if not mutation.parent2 then error("mutation.parent2 required", 2) end
  if not mutation.child then error("mutation.child required", 2) end
  
  local parent1 = mutation.parent1
  local parent2 = mutation.parent2
  local target = mutation.child
  local block = mutation.block or "none"
  
  -- Get climate/humidity requirements for target species
  local climate, humidity = get_requirements(self, target)
  
  print(string.format("Starting mutation: %s + %s → %s", parent1, parent2, target))
  print(string.format("  Requirements: climate=%s, humidity=%s, block=%s", climate, humidity, block))
  
  -- Setup foundation if needed
  if block ~= "none" then
    local ok, err = self.foundation:ensure(block)
    if not ok then
      error("failed to setup foundation: " .. tostring(err))
    end
    print("  Foundation ready: " .. block)
  end
  
  -- Load initial bees from ME
  local ok_load, lerr = load_initial_bees(self, parent1, parent2)
  if not ok_load then
    error("failed to load initial bees: " .. tostring(lerr))
  end
  print("  Loaded initial bees")
  
  -- Build requirements table for acclimatizer
  local requirements_by_bee = {}
  if climate ~= "Normal" or humidity ~= "Normal" then
    requirements_by_bee.climate = climate
    requirements_by_bee.humidity = humidity
  end
  
  -- Setup apiary breeding task
  self.apiary:set_breeding_task(parent1, parent2, target)
  
  -- Initial acclimatization if needed
  if requirements_by_bee.climate or requirements_by_bee.humidity then
    self.acclimatizer:process_all(requirements_by_bee)
    print("  Initial acclimatization complete")
  end
  
  -- Breeding loop
  local cycle_count = 0
  while true do
    cycle_count = cycle_count + 1
    print(string.format("  Cycle %d...", cycle_count))
    
    -- Breed
    local breed_ok, breed_err = self.apiary:breed_cycle(self.cycle_timeout)
    if not breed_ok then
      error("breeding failed: " .. tostring(breed_err))
    end
    
    -- Analyze all
    self.analyzer:process_all(self.analyze_timeout)
    
    -- Consolidate identical bees into stacks
    utils.consolidate_buffer(self.buffer_dev)
    
    -- Count target bees
    local counts = count_target_in_buffer(self.buffer_dev, target)
    print(string.format("    Target: %d/%d drones (max stack: %d), princess: %s", 
      counts.total_drones, DRONES_NEEDED, counts.max_drone_stack, 
      counts.has_princess and "yes" or "no"))
    
    -- Check if goal reached (need a single stack of DRONES_NEEDED)
    if counts.max_drone_stack >= DRONES_NEEDED and counts.has_princess then
      print(string.format("  Goal reached for %s!", target))
      break
    end
    
    -- Acclimatize princess (and drone if self-breeding) for next cycle
    if requirements_by_bee.climate or requirements_by_bee.humidity then
      self.acclimatizer:process_all(requirements_by_bee)
    end
    
    -- Free memory periodically
    os.sleep(0) -- yield to allow garbage collection
  end
  
  -- Sort buffer: pure → ME, hybrids → trash
  sort_buffer(self, target, parent1, parent2)
  print("  Sorting complete")
  
  return true
end

-- Create orchestrator instance.
local function new(config)
  if not config then error("config required", 2) end
  
  -- Required configs
  if not config.buffer_dev then error("buffer_dev required", 2) end
  if not config.apiary_dev then error("apiary_dev required", 2) end
  if not config.analyzer_dev then error("analyzer_dev required", 2) end
  if not config.accl_dev then error("accl_dev required", 2) end
  if not config.accl_mats_dev then error("accl_mats_dev required", 2) end
  if not config.me_input_dev then error("me_input_dev required", 2) end
  if not config.me_output_dev then error("me_output_dev required", 2) end
  if not config.trash_dev then error("trash_dev required", 2) end
  if not config.foundation_dev then error("foundation_dev required", 2) end
  if not config.me_address then error("me_address required", 2) end
  if not config.requirements_data then error("requirements_data required", 2) end
  
  -- Create sub-modules
  local me = me_interface.new(config.me_address, config.db_address)
  local apiary = apiary_proc.new(config.buffer_dev, config.apiary_dev)
  local analyzer_p = analyzer_proc.new(config.buffer_dev, config.analyzer_dev)
  local accl = acclimatizer_proc.new(config.buffer_dev, config.accl_dev, config.accl_mats_dev)
  local found = foundation.new(config.me_input_dev, config.foundation_dev, config.db_address)
  
  local obj = {
    -- Devices
    buffer_dev = config.buffer_dev,
    me_input_dev = config.me_input_dev,
    me_output_dev = config.me_output_dev,
    trash_dev = config.trash_dev,
    
    -- Sub-modules
    me = me,
    apiary = apiary,
    analyzer = analyzer_p,
    acclimatizer = accl,
    foundation = found,
    
    -- Data
    requirements_data = config.requirements_data,
    
    -- Timeouts (seconds)
    cycle_timeout = config.cycle_timeout or 600,
    analyze_timeout = config.analyze_timeout or 30,
  }
  
  return setmetatable(obj, orch_mt)
end

return {
  new = new,
}
