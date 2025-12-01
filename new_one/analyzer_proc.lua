-- analyzer_proc.lua
-- Processes unanalyzed bees from a buffer through a Forestry Analyzer.

local component = require("component")
local analyzer = require("analyzer")
local mover = require("mover")

local analyzer_mt = {}
analyzer_mt.__index = analyzer_mt

local INPUT_SLOT = 1
local OUTPUT_SLOT = 8

local function device_nodes(dev)
  if not dev then return {} end
  if dev.nodes then return dev.nodes end
  if dev.side and dev.tp then return {dev} end
  if dev[1] and dev[1].side and dev[1].tp then return dev end
  return {}
end

-- Find first stack in buffer that is not analyzed.
local function find_unanalyzed(buffer_dev)
  for _, node in ipairs(device_nodes(buffer_dev)) do
    local tp = component.proxy(node.tp)
    local ok_size, size_or_err = pcall(tp.getInventorySize, node.side)
    if ok_size and type(size_or_err) == "number" then
      for slot = 1, size_or_err do
        local ok_stack, stack = pcall(tp.getStackInSlot, node.side, slot)
        if ok_stack and stack and not (stack.individual and stack.individual.isAnalyzed) then
          return node, slot, stack
        end
      end
    end
  end
  return nil
end

local function find_free_slot(buffer_dev)
  for _, node in ipairs(device_nodes(buffer_dev)) do
    local tp = component.proxy(node.tp)
    local ok_size, size_or_err = pcall(tp.getInventorySize, node.side)
    if ok_size and type(size_or_err) == "number" then
      for slot = 1, size_or_err do
        local ok_stack, stack = pcall(tp.getStackInSlot, node.side, slot)
        if ok_stack and not stack then
          return node, slot
        end
      end
    end
  end
  return nil, nil, "no free slot in buffer"
end

-- Ensure analyzer IO slots are clear; if not, try to move contents back to buffer.
local function flush_analyzer_io(analyzer_dev, buffer_dev)
  local nodes = device_nodes(analyzer_dev)
  if #nodes == 0 then
    return nil, "no analyzer nodes"
  end
  local an_node = nodes[1]
  local tp = component.proxy(an_node.tp)

  for _, slot in ipairs({INPUT_SLOT, OUTPUT_SLOT}) do
    local ok_stack, stack = pcall(tp.getStackInSlot, an_node.side, slot)
    if ok_stack and stack then
      local dst_node, dst_slot = find_free_slot(buffer_dev)
      if not dst_node then
        return nil, "no free slot in buffer to flush analyzer"
      end
      local moved, merr = mover.move_between_devices(analyzer_dev, buffer_dev, nil, slot, dst_slot)
      if not moved then
        return nil, "flush failed: " .. tostring(merr)
      end
    end
  end
  return true
end

local function wait_for_output(analyzer_dev, timeout_ticks)
  local nodes = device_nodes(analyzer_dev)
  if #nodes == 0 then return nil, "no analyzer nodes" end
  local an_node = nodes[1]
  local tp = component.proxy(an_node.tp)
  local waited = 0
  while true do
    local ok_stack, stack = pcall(tp.getStackInSlot, an_node.side, OUTPUT_SLOT)
    if ok_stack and stack then
      return stack
    end
    if timeout_ticks and waited >= timeout_ticks then
      return nil, "analyzer timeout"
    end
    os.sleep(0.5)
    waited = waited + 0.5
  end
end

-- Process one unanalyzed bee; returns true if one processed, false if none found.
function analyzer_mt:step(timeout_ticks)
  -- Ensure analyzer IO clear.
  local ok_flush, ferr = flush_analyzer_io(self.analyzer_dev, self.buffer_dev)
  if not ok_flush then
    error(ferr, 2)
  end

  local src_node, src_slot = find_unanalyzed(self.buffer_dev)
  if not src_node then
    return false
  end

  -- Move to analyzer input.
  local moved_in, ierr = mover.move_between_devices(self.buffer_dev, self.analyzer_dev, nil, src_slot, INPUT_SLOT)
  if not moved_in then
    error("move to analyzer failed: " .. tostring(ierr), 2)
  end

  -- Wait for output in slot 8.
  local analyzed_stack, werr = wait_for_output(self.analyzer_dev, timeout_ticks)
  if not analyzed_stack then
    error(werr, 2)
  end

  -- Move analyzed stack back to buffer.
  local dst_node, dst_slot, free_err = find_free_slot(self.buffer_dev)
  if not dst_node then
    error(free_err, 2)
  end
  local moved_out, oerr = mover.move_between_devices(self.analyzer_dev, self.buffer_dev, nil, OUTPUT_SLOT, dst_slot)
  if not moved_out then
    error("move from analyzer failed: " .. tostring(oerr), 2)
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
