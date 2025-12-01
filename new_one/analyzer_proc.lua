-- analyzer_proc.lua
-- Processes unanalyzed bees from a buffer through a Forestry Analyzer.

local component = require("component")
local analyzer = require("analyzer")
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

-- Ensure analyzer IO slots are clear; if not, try to move contents back to buffer.
local function flush_analyzer_io(buffer_node, analyzer_node)
  local tp = component.proxy(analyzer_node.tp)

  for _, slot in ipairs({INPUT_SLOT, OUTPUT_SLOT}) do
    local ok_stack, stack = pcall(tp.getStackInSlot, analyzer_node.side, slot)
    if ok_stack and stack then
      -- Find free slot in buffer
      local ok_size, size = pcall(tp.getInventorySize, buffer_node.side)
      if ok_size and type(size) == "number" then
        for dst_slot = 1, size do
          local ok_dst, dst_stack = pcall(tp.getStackInSlot, buffer_node.side, dst_slot)
          if ok_dst and not dst_stack then
            local moved = mover.move_between_nodes(analyzer_node, buffer_node, nil, slot, dst_slot)
            if moved then break end
          end
        end
      end
    end
  end
  return true
end

local function wait_for_output(analyzer_node, timeout_sec)
  local tp = component.proxy(analyzer_node.tp)
  local waited = 0
  while true do
    local ok_stack, stack = pcall(tp.getStackInSlot, analyzer_node.side, OUTPUT_SLOT)
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

-- Process one unanalyzed bee; returns true if one processed, false if none found.
function analyzer_mt:step(timeout_sec)
  -- Find shared transposer nodes
  local buffer_node, analyzer_node, shared_err = find_shared_nodes(self.buffer_dev, self.analyzer_dev)
  if not buffer_node then
    error(shared_err or "no shared transposer", 2)
  end
  
  -- Debug: verify nodes are valid
  if not buffer_node.tp or not buffer_node.side then
    error("invalid buffer_node: tp=" .. tostring(buffer_node.tp) .. " side=" .. tostring(buffer_node.side), 2)
  end
  if not analyzer_node.tp or not analyzer_node.side then
    error("invalid analyzer_node: tp=" .. tostring(analyzer_node.tp) .. " side=" .. tostring(analyzer_node.side), 2)
  end

  -- Ensure analyzer IO clear.
  flush_analyzer_io(buffer_node, analyzer_node)

  -- Find unanalyzed bee in buffer
  local tp = component.proxy(buffer_node.tp)
  local ok_size, size = pcall(tp.getInventorySize, buffer_node.side)
  if not ok_size or type(size) ~= "number" then
    return false
  end

  local src_slot = nil
  for slot = 1, size do
    local ok_stack, stack = pcall(tp.getStackInSlot, buffer_node.side, slot)
    if ok_stack and stack and stack.individual and not stack.individual.isAnalyzed then
      src_slot = slot
      break
    end
  end

  if not src_slot then
    return false  -- No unanalyzed bees
  end

  -- Move entire stack to analyzer input
  local moved_in, ierr = mover.move_between_nodes(buffer_node, analyzer_node, 64, src_slot, INPUT_SLOT)
  if not moved_in or moved_in == 0 then
    error("move to analyzer failed: " .. tostring(ierr), 2)
  end

  -- Wait for output
  local analyzed_stack, werr = wait_for_output(analyzer_node, timeout_sec)
  if not analyzed_stack then
    error(werr, 2)
  end

  -- Find free slot in buffer and move analyzed bee back
  for dst_slot = 1, size do
    local ok_dst, dst_stack = pcall(tp.getStackInSlot, buffer_node.side, dst_slot)
    if ok_dst and not dst_stack then
      local moved_out, oerr = mover.move_between_nodes(analyzer_node, buffer_node, nil, OUTPUT_SLOT, dst_slot)
      if not moved_out then
        error("move from analyzer failed: " .. tostring(oerr), 2)
      end
      break
    end
  end

  return true
end

function analyzer_mt:process_all(timeout_ticks)
  while true do
    local processed = self:step(timeout_ticks)
    if not processed then
      return true
    end
  end
end

local function new(buffer_dev, analyzer_dev)
  if not buffer_dev then
    error("buffer device required", 2)
  end
  if not analyzer_dev then
    error("analyzer device required", 2)
  end
  return setmetatable({buffer_dev = buffer_dev, analyzer_dev = analyzer_dev}, analyzer_mt)
end

return {
  new = new,
}
