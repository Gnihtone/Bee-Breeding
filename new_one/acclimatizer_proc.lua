-- acclimatizer_proc.lua
-- Adjusts bees in a buffer to required climate/humidity via an Acclimatizer.

local component = require("component")
local mover = require("mover")
local utils = require("utils")
local analyzer = require("analyzer")

local INPUT_SLOT = 1
local ITEM_SLOT = 6
local OUTPUT_SLOT = 9

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

local device_nodes = utils.device_nodes
local find_free_slot = utils.find_free_slot
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

-- Clear the item slot if it contains the wrong reagent.
local function clear_wrong_reagent(self, accl_node, needed_label)
  local tp = component.proxy(accl_node.tp)
  local ok_stack, stack = pcall(tp.getStackInSlot, accl_node.side, ITEM_SLOT)
  if not ok_stack or not stack then
    return true -- slot is empty
  end
  if stack.label == needed_label then
    return true -- correct reagent already there
  end
  
  -- Wrong reagent - move it back to mats storage
  local dst_node, dst_slot = find_free_slot(self.mats_dev)
  if not dst_node then
    return nil, "no free slot in mats storage for old reagent"
  end
  
  -- Find accl node that shares transposer with dst_node
  local accl_for_dst = find_accl_node_for(self.accl_dev, dst_node)
  if not accl_for_dst then
    return nil, "cannot return reagent: no shared transposer"
  end
  
  local moved, merr = mover.move_between_nodes(accl_for_dst, dst_node, nil, ITEM_SLOT, dst_slot)
  if not moved then
    return nil, "failed to remove old reagent: " .. tostring(merr)
  end
  return true
end

-- Load a specific reagent into acclimatizer item slot.
local function load_reagent(self, accl_node, label)
  local tp = component.proxy(accl_node.tp)
  
  -- Check if correct reagent already present
  local ok_stack, stack = pcall(tp.getStackInSlot, accl_node.side, ITEM_SLOT)
  if ok_stack and stack and stack.label == label then
    return true
  end
  
  -- Find reagent in mats storage
  local src_node, src_slot = find_slot_with(self.mats_dev, label)
  if not src_node then
    return nil, "reagent not found in mats storage: " .. label
  end
  
  -- Find accl node that shares transposer with src_node
  local accl_for_src = find_accl_node_for(self.accl_dev, src_node)
  if not accl_for_src then
    return nil, "cannot load reagent: no shared transposer with mats"
  end
  
  local moved, merr = mover.move_between_nodes(src_node, accl_for_src, nil, src_slot, ITEM_SLOT)
  if not moved then
    return nil, "move reagent failed: " .. tostring(merr)
  end
  return true
end

-- Determine which reagents are needed for given climate/humidity requirements.
local function get_needed_reagents(climate, humidity)
  local reagents = {}
  if climate and CLIMATE_ITEMS[climate] then
    table.insert(reagents, CLIMATE_ITEMS[climate])
  end
  if humidity and HUMIDITY_ITEMS[humidity] then
    local h_item = HUMIDITY_ITEMS[humidity]
    -- Avoid duplicates
    local found = false
    for _, r in ipairs(reagents) do
      if r == h_item then found = true; break end
    end
    if not found then
      table.insert(reagents, h_item)
    end
  end
  return reagents
end

-- Refill reagent in acclimatizer if low or empty.
local function refill_reagent_if_needed(self, accl_node, reagent_label, min_count)
  min_count = min_count or 16
  local tp = component.proxy(accl_node.tp)
  
  local ok_stack, stack = pcall(tp.getStackInSlot, accl_node.side, ITEM_SLOT)
  
  -- Check if refill needed
  local current_count = 0
  if ok_stack and stack then
    if stack.label ~= reagent_label then
      -- Wrong reagent, don't touch it here (should have been cleared before)
      return true
    end
    current_count = stack.size or 1
  end
  
  if current_count >= min_count then
    return true -- Enough reagent
  end
  
  -- Need to refill - find reagent in mats storage
  local src_node, src_slot, src_stack = find_slot_with(self.mats_dev, reagent_label)
  if not src_node then
    -- No more reagent available, but we might have some left
    if current_count > 0 then
      return true -- Use what we have
    end
    return nil, "reagent depleted: " .. reagent_label
  end
  
  -- Find accl node that shares transposer with src_node
  local accl_for_src = find_accl_node_for(self.accl_dev, src_node)
  if not accl_for_src then
    if current_count > 0 then
      return true -- Can't refill but have some
    end
    return nil, "cannot refill: no shared transposer with mats"
  end
  
  -- Move reagent to acclimatizer (will stack with existing)
  local to_move = src_stack and src_stack.size or 64
  mover.move_between_nodes(src_node, accl_for_src, to_move, src_slot, ITEM_SLOT)
  
  return true
end

-- Process bee through acclimatizer with a single reagent.
-- Returns processed stack or nil, error.
local function process_with_reagent(self, accl_node, bee_node, bee_slot, reagent_label, timeout_sec)
  -- Clear wrong reagent and load correct one
  local ok_clear, cerr = clear_wrong_reagent(self, accl_node, reagent_label)
  if not ok_clear then
    return nil, cerr
  end
  
  local ok_load, lerr = load_reagent(self, accl_node, reagent_label)
  if not ok_load then
    return nil, lerr
  end
  
  -- Find accl node that shares transposer with bee_node
  local accl_for_bee = find_accl_node_for(self.accl_dev, bee_node)
  if not accl_for_bee then
    return nil, "no acclimatizer shares transposer with bee buffer"
  end
  
  -- Move bee into acclimatizer
  local moved_in, ierr = mover.move_between_nodes(bee_node, accl_for_bee, nil, bee_slot, INPUT_SLOT)
  if not moved_in then
    return nil, "move to acclimatizer failed: " .. tostring(ierr)
  end
  
  -- Wait for output, refilling reagent as needed
  local tp = component.proxy(accl_for_bee.tp)
  local waited = 0
  local out_stack = nil
  while true do
    -- Check if output ready
    local ok_stack, stack = pcall(tp.getStackInSlot, accl_for_bee.side, OUTPUT_SLOT)
    if ok_stack and stack then
      out_stack = stack
      break
    end
    
    -- Refill reagent if running low
    local ok_refill, refill_err = refill_reagent_if_needed(self, accl_for_bee, reagent_label, 16)
    if not ok_refill then
      return nil, refill_err
    end
    
    if timeout_sec and waited >= timeout_sec then
      return nil, "acclimatizer timeout"
    end
    os.sleep(0.5)
    waited = waited + 0.5
  end
  
  return out_stack, accl_for_bee
end

-- Find first bee in buffer whose requirement is not Normal/Normal.
-- Reads requirements directly from bee NBT.
local function find_pending(self)
  for _, node in ipairs(device_nodes(self.buffer_dev)) do
    local tp = component.proxy(node.tp)
    local ok_size, size_or_err = pcall(tp.getInventorySize, node.side)
    if ok_size and type(size_or_err) == "number" then
      for slot = 1, size_or_err do
        local ok_stack, stack = pcall(tp.getStackInSlot, node.side, slot)
        if ok_stack and stack and stack.individual then
          -- Read requirements from NBT
          local climate = analyzer.get_climate(stack)
          local humidity = analyzer.get_humidity(stack)
          
          if climate ~= "Normal" or humidity ~= "Normal" then
            local req = {climate = climate, humidity = humidity}
            return node, slot, stack, req
          end
        end
      end
    end
  end
  return nil
end

-- Process one bee needing acclimatization; returns true if processed, false if none pending.
-- timeout_sec: timeout in seconds (not ticks!)
-- requirements_by_bee is optional (legacy), now reads from NBT directly.
function accl_mt:step(requirements_by_bee, timeout_sec)
  local src_node, src_slot, stack, req = find_pending(self)
  if not src_node then
    return false
  end

  -- Get list of reagents needed (may be 1 or 2)
  local reagents = get_needed_reagents(req.climate, req.humidity)
  if #reagents == 0 then
    return false
  end

  local current_node = src_node
  local current_slot = src_slot
  local last_accl_node = nil
  
  -- Process through each reagent
  for i, reagent in ipairs(reagents) do
    local accl_node = find_accl_node_for(self.accl_dev, current_node)
    if not accl_node then
      error("no acclimatizer shares transposer with buffer", 2)
    end
    
    local out_stack, used_accl_node = process_with_reagent(
      self, accl_node, current_node, current_slot, reagent, timeout_sec
    )
    if not out_stack then
      error(used_accl_node, 2) -- used_accl_node contains error message
    end
    
    last_accl_node = used_accl_node
    
    -- If more reagents to process, move to buffer temporarily
    if i < #reagents then
      local tmp_node, tmp_slot, ferr = find_free_slot(self.buffer_dev)
      if not tmp_node then
        error(ferr or "no free slot in buffer for intermediate", 2)
      end
      
      local accl_for_tmp = find_accl_node_for(self.accl_dev, tmp_node)
      if not accl_for_tmp then
        error("no shared transposer for intermediate move", 2)
      end
      
      local moved_tmp, terr = mover.move_between_nodes(accl_for_tmp, tmp_node, nil, OUTPUT_SLOT, tmp_slot)
      if not moved_tmp then
        error("intermediate move failed: " .. tostring(terr), 2)
      end
      
      current_node = tmp_node
      current_slot = tmp_slot
    end
  end
  
  -- Move final result back to buffer
  local dst_node, dst_slot, ferr = find_free_slot(self.buffer_dev)
  if not dst_node then
    error(ferr or "no free slot in buffer", 2)
  end
  
  local accl_for_dst = find_accl_node_for(self.accl_dev, dst_node)
  if not accl_for_dst then
    error("no shared transposer for final move", 2)
  end
  
  local moved_out, oerr = mover.move_between_nodes(accl_for_dst, dst_node, nil, OUTPUT_SLOT, dst_slot)
  if not moved_out then
    error("move from acclimatizer failed: " .. tostring(oerr), 2)
  end
  
  return true
end

-- Process all pending bees.
-- timeout_sec: timeout per bee in seconds
function accl_mt:process_all(requirements_by_bee, timeout_sec)
  while true do
    local processed = self:step(requirements_by_bee, timeout_sec)
    if not processed then
      return true
    end
  end
end

local function new(buffer_dev, accl_dev, mats_dev)
  if not buffer_dev then error("buffer device required", 2) end
  if not accl_dev then error("acclimatizer device required", 2) end
  if not mats_dev then error("acclimatizer mats storage required", 2) end
  return setmetatable({buffer_dev = buffer_dev, accl_dev = accl_dev, mats_dev = mats_dev}, accl_mt)
end

return {
  new = new,
}
