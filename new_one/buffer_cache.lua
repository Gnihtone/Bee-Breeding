-- buffer_cache.lua
-- Caches buffer inventory state to minimize getAllStacks calls.
-- Supports smart invalidation: individual slots can be marked dirty.

local component = require("component")
local analyzer = require("analyzer")
local utils = require("utils")

local device_nodes = utils.device_nodes

local cache_mt = {}
cache_mt.__index = cache_mt

-- Build stack key for consolidation (same logic as utils.lua)
local function build_stack_key(stack)
  local key = (stack.name or "") .. "|" .. (stack.label or "")
  if stack.hasTag and stack.tag then
    key = key .. "|" .. tostring(stack.tag)
  end
  return key
end

-- Extract minimal data from stack (does NOT keep reference to original stack)
local function extract_slot_data(stack)
  if not stack or not stack.name then
    return nil
  end
  
  local data = {
    size = stack.size or 1,
    max_size = stack.maxSize or 64,
    stack_key = build_stack_key(stack),
  }
  
  -- Bee-specific data
  if stack.individual then
    data.is_bee = true
    data.species = analyzer.get_species(stack)
    data.is_princess = analyzer.is_princess(stack)
    data.is_pure = analyzer.is_pure(stack)
    data.is_analyzed = stack.individual.isAnalyzed or false
    
    -- Acclimatization data (only extract if needed later)
    data.climate = analyzer.get_climate(stack)
    data.humidity = analyzer.get_humidity(stack)
    data.is_acclimatized = analyzer.is_acclimatized(stack)
  end
  
  return data
end

-- Full refresh: load all slots from transposer
function cache_mt:refresh()
  local nodes = device_nodes(self.buffer_dev)
  if #nodes == 0 then
    self._slots = {}
    self._dirty = {}
    self._valid = true
    return
  end
  
  local node = nodes[1]
  local tp = component.proxy(node.tp)
  
  local ok, stacks = pcall(tp.getAllStacks, node.side)
  if not ok or not stacks then
    self._slots = {}
    self._dirty = {}
    self._valid = true
    return
  end
  
  local slots = {}
  local slot = 0
  for stack in stacks do
    slot = slot + 1
    slots[slot] = extract_slot_data(stack)
  end
  
  -- Help GC
  stacks = nil
  
  self._slots = slots
  self._size = slot
  self._dirty = {}
  self._valid = true
  self._node = node
  self._tp = tp
end

-- Refresh only dirty slots
function cache_mt:refresh_dirty()
  if not self._valid then
    self:refresh()
    return
  end
  
  if not next(self._dirty) then
    return  -- Nothing dirty
  end
  
  local tp = self._tp
  local side = self._node.side
  
  for slot_num in pairs(self._dirty) do
    local ok, stack = pcall(tp.getStackInSlot, side, slot_num)
    if ok then
      self._slots[slot_num] = extract_slot_data(stack)
    end
  end
  
  self._dirty = {}
end

-- Ensure cache is valid (refresh if needed)
function cache_mt:ensure_valid()
  if not self._valid then
    self:refresh()
  elseif next(self._dirty) then
    self:refresh_dirty()
  end
end

-- Mark entire cache as invalid (will refresh on next access)
function cache_mt:invalidate()
  self._valid = false
  self._dirty = {}
end

-- Mark specific slot as dirty (smart invalidation)
function cache_mt:mark_dirty(slot)
  if self._valid then
    self._dirty[slot] = true
  end
end

-- Mark multiple slots as dirty
function cache_mt:mark_slots_dirty(slots)
  if self._valid then
    for _, slot in ipairs(slots) do
      self._dirty[slot] = true
    end
  end
end

-- Get slot data (nil if empty)
function cache_mt:get_slot(slot)
  self:ensure_valid()
  return self._slots[slot]
end

-- Get buffer size
function cache_mt:get_size()
  self:ensure_valid()
  return self._size or 0
end

-- Find first free slot
-- Returns: slot number or nil
function cache_mt:find_free_slot()
  self:ensure_valid()
  for slot = 1, self._size do
    if not self._slots[slot] then
      return slot
    end
  end
  return nil
end

-- Find princess matching valid species list
-- Returns: {slot, species, is_pure} or nil
function cache_mt:find_princess(valid_species)
  self:ensure_valid()
  
  local valid_set = {}
  if valid_species then
    for _, sp in ipairs(valid_species) do
      valid_set[sp] = true
    end
  end
  
  for slot = 1, self._size do
    local data = self._slots[slot]
    if data and data.is_bee and data.is_princess then
      -- If valid_species provided, check match; otherwise accept any princess
      if not valid_species or valid_set[data.species] or true then
        -- Note: we accept ANY princess (can be "fixed" by breeding)
        return {
          slot = slot,
          species = data.species or "unknown",
          is_pure = data.is_pure,
        }
      end
    end
  end
  return nil
end

-- Find drones grouped by species
-- valid_species: list of species to include
-- Returns: {species -> list of {slot, is_pure}}, invalid_drones list
function cache_mt:find_drones(valid_species)
  self:ensure_valid()
  
  local valid_set = {}
  local drones = {}
  for _, sp in ipairs(valid_species) do
    valid_set[sp] = true
    drones[sp] = {}
  end
  
  local invalid_drones = {}
  
  for slot = 1, self._size do
    local data = self._slots[slot]
    if data and data.is_bee and not data.is_princess then
      local species = data.species
      if species and valid_set[species] then
        table.insert(drones[species], {
          slot = slot,
          is_pure = data.is_pure,
        })
      else
        table.insert(invalid_drones, {
          slot = slot,
          species = species or "unknown",
          size = data.size,
        })
      end
    end
  end
  
  return drones, invalid_drones
end

-- Find unanalyzed bees
-- Returns: list of slots, list of empty slots
function cache_mt:find_unanalyzed()
  self:ensure_valid()
  
  local unanalyzed = {}
  local empty = {}
  
  for slot = 1, self._size do
    local data = self._slots[slot]
    if not data then
      table.insert(empty, slot)
    elseif data.is_bee and not data.is_analyzed then
      table.insert(unanalyzed, slot)
    end
  end
  
  return unanalyzed, empty
end

-- Check if bee needs acclimatization
local function needs_acclimatization(data)
  if not data or not data.is_bee then return false end
  if data.is_acclimatized then return false end
  
  local climate = data.climate and string.upper(data.climate) or "NORMAL"
  local humidity = data.humidity and string.upper(data.humidity) or "NORMAL"
  
  return climate ~= "NORMAL" or humidity ~= "NORMAL"
end

-- Find bees needing acclimatization
-- Returns: {princess = {...} or nil, drones = list of {...}}
function cache_mt:find_needing_acclimatization()
  self:ensure_valid()
  
  local result = {princess = nil, drones = {}}
  
  for slot = 1, self._size do
    local data = self._slots[slot]
    if data and needs_acclimatization(data) then
      if data.is_princess then
        if not result.princess then
          result.princess = {
            slot = slot,
            climate = data.climate,
            humidity = data.humidity,
          }
        end
      else
        table.insert(result.drones, {
          slot = slot,
          count = data.size,
        })
      end
    end
  end
  
  return result
end

-- Count target species (pure only)
-- Returns: {max_drone_stack, total_drones, has_princess}
function cache_mt:count_target(target_species)
  self:ensure_valid()
  
  local result = {max_drone_stack = 0, total_drones = 0, has_princess = false}
  
  for slot = 1, self._size do
    local data = self._slots[slot]
    if data and data.is_bee and data.species == target_species and data.is_pure then
      if data.is_princess then
        result.has_princess = true
      else
        result.total_drones = result.total_drones + data.size
        if data.size > result.max_drone_stack then
          result.max_drone_stack = data.size
        end
      end
    end
  end
  
  return result
end

-- Get all slots grouped by stack_key for consolidation
-- Returns: {stack_key -> list of {slot, size, max_size}}
function cache_mt:get_consolidation_groups()
  self:ensure_valid()
  
  local by_key = {}
  
  for slot = 1, self._size do
    local data = self._slots[slot]
    if data and data.stack_key then
      local key = data.stack_key
      by_key[key] = by_key[key] or {}
      table.insert(by_key[key], {
        slot = slot,
        size = data.size,
        max_size = data.max_size,
      })
    end
  end
  
  return by_key
end

-- Update slot data after consolidation move (without re-reading from transposer)
-- src_slot: source slot
-- dst_slot: destination slot  
-- moved: number of items moved
function cache_mt:update_after_transfer(src_slot, dst_slot, moved)
  if not self._valid then return end
  
  local src = self._slots[src_slot]
  local dst = self._slots[dst_slot]
  
  if src and moved > 0 then
    src.size = src.size - moved
    if src.size <= 0 then
      self._slots[src_slot] = nil
    end
  end
  
  if dst and moved > 0 then
    dst.size = dst.size + moved
  end
end

-- Mark slot as occupied (placeholder) so find_free_slot won't return it.
-- Used when moving items INTO buffer from external source.
-- The slot will be properly refreshed on next dirty refresh.
function cache_mt:mark_slot_occupied(slot)
  if not self._valid then return end
  
  if not self._slots[slot] then
    -- Create placeholder entry
    self._slots[slot] = {
      size = 1,
      max_size = 64,
      stack_key = "_placeholder_",
      is_bee = false,
    }
  end
  -- Also mark as dirty so it gets properly refreshed later
  self._dirty[slot] = true
end

-- Mark slot as empty (for when moving items OUT of buffer)
function cache_mt:mark_slot_empty(slot)
  if not self._valid then return end
  self._slots[slot] = nil
  -- Also mark as dirty in case we need to verify
  self._dirty[slot] = true
end

-- Consolidate identical items in buffer (merge into stacks).
-- Uses transposer's transferItem and updates cache logically.
function cache_mt:consolidate()
  self:ensure_valid()
  
  local by_key = self:get_consolidation_groups()
  local tp = self._tp
  local side = self._node.side
  
  for _, group in pairs(by_key) do
    if #group < 2 then goto continue_group end
    
    local target = group[1]
    for i = 2, #group do
      local source = group[i]
      if source.size <= 0 then goto continue_source end
      
      local space = target.max_size - target.size
      if space <= 0 then
        -- Target full, make source the new target
        target = source
        goto continue_source
      end
      
      local to_move = math.min(space, source.size)
      local ok_move, moved = pcall(tp.transferItem, side, side, to_move, source.slot, target.slot)
      if ok_move and moved and moved > 0 then
        -- Update cache logically (no re-read needed)
        self:update_after_transfer(source.slot, target.slot, moved)
        target.size = target.size + moved
        source.size = source.size - moved
      end
      
      ::continue_source::
    end
    
    ::continue_group::
  end
end

-- Get transposer and node for direct operations
function cache_mt:get_transposer()
  self:ensure_valid()
  return self._tp, self._node
end

-- Get buffer device
function cache_mt:get_buffer_dev()
  return self.buffer_dev
end

-- Create new buffer cache
local function new(buffer_dev)
  if not buffer_dev then
    error("buffer_dev required", 2)
  end
  
  local obj = {
    buffer_dev = buffer_dev,
    _slots = {},
    _size = 0,
    _dirty = {},
    _valid = false,
    _node = nil,
    _tp = nil,
  }
  
  return setmetatable(obj, cache_mt)
end

return {
  new = new,
}

