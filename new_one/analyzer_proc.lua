-- analyzer_proc.lua
-- Processes unanalyzed bees from a buffer through a Forestry Analyzer.

local component = require("component")
local mover = require("mover")
local utils = require("utils")

local analyzer_mt = {}
analyzer_mt.__index = analyzer_mt

local INPUT_SLOT = 3
local OUTPUT_SLOT = 9

local device_nodes = utils.device_nodes

-- Find shared nodes between buffer and analyzer.
local function find_shared_nodes(buffer_dev, analyzer_dev)
  for _, buf_node in ipairs(device_nodes(buffer_dev)) do
    for _, an_node in ipairs(device_nodes(analyzer_dev)) do
      if buf_node.tp == an_node.tp then
        return buf_node, an_node
      end
    end
  end
  return nil, nil, "no shared transposer between buffer and analyzer"
end

-- Wait for analyzer output slot to have items.
local function wait_for_output(tp, analyzer_side, timeout_sec)
  local waited = 0
  while true do
    local ok_stack, stack = pcall(tp.getStackInSlot, analyzer_side, OUTPUT_SLOT)
    if ok_stack and stack then
      return stack
    end
    if timeout_sec and waited >= timeout_sec then
      return nil, "analyzer timeout"
    end
    os.sleep(0.5)
    waited = waited + 0.5
  end
end

-- Process all unanalyzed bees in buffer (uses cache).
function analyzer_mt:process_all(timeout_sec)
  -- Find shared transposer nodes (once)
  local buffer_node, analyzer_node, shared_err = find_shared_nodes(self.buffer_dev, self.analyzer_dev)
  if not buffer_node then
    error(shared_err or "no shared transposer", 2)
  end
  
  local tp = component.proxy(buffer_node.tp)
  local cache = self.cache
  
  -- Get unanalyzed bees from cache
  local unanalyzed_slots, empty_slots = cache:find_unanalyzed()
  
  -- Flush any stuck items in analyzer IO slots
  for _, slot in ipairs({INPUT_SLOT, OUTPUT_SLOT}) do
    local ok_stack, stack = pcall(tp.getStackInSlot, analyzer_node.side, slot)
    if ok_stack and stack then
      if #empty_slots > 0 then
        local dst = empty_slots[1]
        mover.move_between_nodes(analyzer_node, buffer_node, nil, slot, dst)
        cache:mark_slot_occupied(dst)
        table.remove(empty_slots, 1)
      end
    end
  end

  if #unanalyzed_slots == 0 then
    return true  -- Nothing to analyze
  end
  
  -- Process each unanalyzed slot
  local empty_idx = 1
  
  for _, src_slot in ipairs(unanalyzed_slots) do
    -- Move to analyzer input
    local moved_in, ierr = mover.move_between_nodes(buffer_node, analyzer_node, 64, src_slot, INPUT_SLOT)
    if not moved_in or moved_in == 0 then
      error("move to analyzer failed: " .. tostring(ierr), 2)
    end
    cache:mark_slot_empty(src_slot)
    
    -- The source slot is now empty, add to empty_slots
    table.insert(empty_slots, src_slot)

    -- Wait for output
    local analyzed_stack, werr = wait_for_output(tp, analyzer_node.side, timeout_sec)
    if not analyzed_stack then
      error(werr, 2)
    end

    -- Move back to buffer using tracked empty slot
    local dst_slot = empty_slots[empty_idx]
    empty_idx = empty_idx + 1
    
    local moved_out, oerr = mover.move_between_nodes(analyzer_node, buffer_node, nil, OUTPUT_SLOT, dst_slot)
    if not moved_out then
      error("move from analyzer failed: " .. tostring(oerr), 2)
    end
    -- Mark as occupied (analyzed bee is different from original)
    cache:mark_slot_occupied(dst_slot)
  end

  return true
end

local function new(buffer_dev, analyzer_dev, cache)
  if not buffer_dev then
    error("buffer device required", 2)
  end
  if not analyzer_dev then
    error("analyzer device required", 2)
  end
  if not cache then
    error("buffer cache required", 2)
  end
  return setmetatable({
    buffer_dev = buffer_dev,
    analyzer_dev = analyzer_dev,
    cache = cache,
  }, analyzer_mt)
end

return {
  new = new,
}
