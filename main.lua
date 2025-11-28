-- main.lua
-- Entry point for bee breeder automation.

local component = require("component")
local discovery = require("discovery")
local bee_db = require("bee_db")
local me_bees = require("me_bees")
local me_main = require("me")
local inventory = require("inventory")
local planner = require("planner")
local analyzer = require("analyzer")
local bee_stock = require("bee_stock")
local climate = require("climate")
local beekeeper = require("beekeeper")
local tp_utils = require("tp_utils")

local function log(msg)
  io.write("[*] " .. msg .. "\n")
end

local function fatal(msg)
  io.stderr:write("[!] " .. msg .. "\n")
  os.exit(1)
end

local devices, err = discovery.discover()
if not devices then
  fatal("discovery failed: " .. tostring(err))
end

if not devices.transposers or #devices.transposers == 0 then
  fatal("no transposers found")
end

local tp_map = tp_utils.build_proxy_map(devices.transposers)

log("discovery complete")

if not devices.apiary or #devices.apiary == 0 then fatal("apiary not found") end
if not devices.analyzer or #devices.analyzer == 0 then fatal("analyzer not found") end

local bee_me_rec = devices.me_interfaces["ROLE:ME-BEES"]
local main_me_rec = devices.me_interfaces["ROLE:ME-MAIN"]

if not bee_me_rec or not bee_me_rec.address or not bee_me_rec.nodes or #bee_me_rec.nodes == 0 then fatal("bee ME interface not found (ROLE:ME-BEES marker missing)") end
if not main_me_rec or not main_me_rec.address or not main_me_rec.nodes or #main_me_rec.nodes == 0 then fatal("main ME interface not found (ROLE:ME-MAIN marker missing)") end

local bee_me, err = me_bees.new(bee_me_rec.address, bee_me_rec.nodes, tp_map)
if not bee_me then fatal("bee ME init failed: " .. tostring(err)) end

local main_me, err = me_main.new(main_me_rec.address, main_me_rec.nodes, tp_map)
if not main_me then fatal("main ME init failed: " .. tostring(err)) end

-- Load mutations database.
local db, dberr = bee_db.load("bee_mutations.txt")
if not db then
  fatal("cannot load bee_mutations.txt: " .. tostring(dberr))
end

log(string.format("loaded %d mutations", #db.mutations))

-- Snapshot available pure species from bee ME (counts drones).
local have_counts = bee_stock.build_have_set(component.proxy(bee_me_rec.address))
local function have_count(species)
  return have_counts[species] or 0
end
local function recalc_have()
  have_counts = bee_stock.build_have_set(component.proxy(bee_me_rec.address))
end
do
  local c = 0
  for _ in pairs(have_counts) do c = c + 1 end
  log(string.format("known pure species (drones) in bee ME: %d", c))
end

-- Build inventory helper.
local bufferNodes = devices.storages["ROLE:BUFFER"]
local trashNodes = devices.storages["ROLE:TRASH"]
local blocksNodes = devices.storages["ROLE:BLOCKS"]
local acclimNodes = devices.storages["ROLE:ACCLIM"]

if not bufferNodes or #bufferNodes == 0 then
  fatal("buffer storage ROLE:BUFFER not found")
end

local inv = inventory.new(tp_map, {
  buffer = bufferNodes,
  trash = trashNodes,
  blocks = blocksNodes,
  acclim = acclimNodes,
})

if not inv then
  fatal("inventory init failed")
end

local function first_free_slot(nodes)
  return inv:first_free_slot(nodes)
end

local function is_bee(stack)
  return stack and (stack.name == "Forestry:beePrincessGE" or stack.name == "Forestry:beeDroneGE" or stack.name == "Forestry:beeQueenGE")
end

-- Clear buffer only after a successful step: move pure bees of target species to bee ME, dirty drones to TRASH.
local function clear_buffer(target_species)
  local node, tp = tp_utils.pick_node(tp_map, bufferNodes)
  if not node or not tp then return end
  local size = tp.getInventorySize(node.side)
  if not size then return end
  for slot = 1, size do
    local stack = tp.getStackInSlot(node.side, slot)
    if stack and is_bee(stack) then
      local pure, sp = analyzer.is_pure(stack)
      if pure and sp and sp == target_species then
        if bee_me then
          local moved, merr = bee_me:return_bee(bufferNodes, slot, stack.size or 1, 1)
          if not moved or moved == 0 then
            fatal("failed to return pure bee " .. tostring(sp) .. " to bee ME from buffer slot " .. slot .. (merr and (" :: " .. tostring(merr)) or ""))
          end
        else
          fatal("pure bee " .. tostring(sp) .. " in buffer and bee ME unavailable")
        end
      elseif not pure and trashNodes then
        local route, err = tp_utils.find_common(tp_map, bufferNodes, trashNodes)
        if not route then
          fatal("failed to move dirty bee to trash (no common transposer): " .. tostring(err))
        end
        local moved = route.tp.transferItem(route.a.side, route.b.side, stack.size or 1, slot)
        if not moved or moved == 0 then
          fatal("failed to move dirty bee to trash from buffer slot " .. slot)
        end
      end
    end
  end
end

local function request_parent(species, expect_princess)
  local attempts = 0
  while attempts < 5 do
    local targetSlot = first_free_slot(bufferNodes)
    if not targetSlot then
      return nil, "buffer is full, cannot request " .. tostring(species)
    end
    -- Princess: request 1; Drone: request up to 8 to have buffer for changing princess species.
    local count = expect_princess and 1 or 8
    local moved, reqErr = bee_me:request_species(species, bufferNodes, targetSlot, nil, nil, count, expect_princess)
    if not moved or moved == 0 then
      return nil, "failed to request " .. species .. " from bee ME: " .. tostring(reqErr)
    end
    local node, tp = tp_utils.pick_node(tp_map, bufferNodes)
    local stack = node and tp and tp.getStackInSlot(node.side, targetSlot)
    if stack and stack.individual then
      local pure, sp = analyzer.is_pure(stack)
      if sp == species then
        if expect_princess and stack.name == "Forestry:beePrincessGE" then
          return targetSlot
        elseif (not expect_princess) and stack.name == "Forestry:beeDroneGE" then
          return targetSlot
        end
      end
    end
    if stack then
      bee_me:return_bee(bufferNodes, targetSlot, stack.size or 1, 1)
    end
    attempts = attempts + 1
  end
  return nil, "no suitable " .. (expect_princess and "princess" or "drone") .. " of " .. species
end

local ensure_princess_available

-- want_bulk=false: just get a drone into buffer.
-- want_bulk=true: breed up to 64 pure drones using beekeeper.
local function ensure_drone_available(species, allow_skip, want_bulk)
  want_bulk = want_bulk or false
  if want_bulk and have_count(species) >= 64 then
    return true
  end
  local ok, err = request_parent(species, false)
  if ok then
    have_counts[species] = (have_counts[species] or 0) + 1
    if want_bulk and have_count(species) < 64 then
      log("drone count for " .. species .. " below 64, attempting to breed up")
      local reqs = bee_db.get_requirements(db, species) or {climate = "NORMAL", humidity = "NORMAL", block = "none", dim = "none"}
      local bk_repro = beekeeper.new({
        tp_map = tp_map,
        apiaryNodes = devices.apiary,
        bufferNodes = bufferNodes,
        analyzerNodes = devices.analyzer,
        trashNodes = devices.storages["ROLE:TRASH"],
        acclNodes = devices.accl,
        acclimNodes = acclimNodes,
        bee_me = bee_me,
        reqs_lookup = reqs_lookup,
      })
      local okP, errP = ensure_princess_available(species, allow_skip, false)
      if not okP then
        return nil, errP
      end
      bk_repro:start(species, reqs, {p1 = species, p2 = species})
      while have_count(species) < 64 do
        local state = bk_repro:tick()
        if state == beekeeper.STATES.ERROR then
          return nil, "repro beekeeper error: " .. tostring(bk_repro.last_error)
        elseif state == beekeeper.STATES.DONE then
          have_counts = bee_stock.build_have_set(component.proxy(bee_me_rec.address))
          break
        end
        os.sleep(2)
      end
    end
    return true
  end
  if allow_skip then
    log("no drone available for " .. species .. ", skipping")
    return nil, "skip"
  end
  return nil, err
end

local function collect_ancestors(species)
  local queue = {species}
  local seen = {}
  local out = {}
  while #queue > 0 do
    local cur = table.remove(queue, 1)
    local muts = db.byChild[cur]
    if muts then
      for _, mut in ipairs(muts) do
        for _, parent in ipairs({mut.p1, mut.p2}) do
          if not seen[parent] then
            seen[parent] = true
            table.insert(out, parent)
            table.insert(queue, parent)
          end
        end
      end
    end
  end
  return out
end

-- want_bulk=false: just fetch a princess.
-- want_bulk=true: breed up to 64 drones using this princess.
ensure_princess_available = function(species, allow_skip, want_bulk)
  want_bulk = want_bulk or false
  local ok, err = request_parent(species, true)
  if ok then
    if want_bulk and have_count(species) < 64 then
      log("drone count for " .. species .. " below 64, breeding up with obtained princess")
      local reqs = bee_db.get_requirements(db, species) or {climate = "NORMAL", humidity = "NORMAL", block = "none", dim = "none"}
      local bk_repro = beekeeper.new({
        tp_map = tp_map,
        apiaryNodes = devices.apiary,
        bufferNodes = bufferNodes,
        analyzerNodes = devices.analyzer,
        trashNodes = devices.storages["ROLE:TRASH"],
        acclNodes = devices.accl,
        acclimNodes = acclimNodes,
        bee_me = bee_me,
        reqs_lookup = reqs_lookup,
      })
      local dok, derr = ensure_drone_available(species, allow_skip, true)
      if not dok then
        return nil, derr
      end
      bk_repro:start(species, reqs, {p1 = species, p2 = species})
      while have_count(species) < 64 do
        local state = bk_repro:tick()
        if state == beekeeper.STATES.ERROR then
          return nil, "breed-up beekeeper error: " .. tostring(bk_repro.last_error)
        elseif state == beekeeper.STATES.DONE then
          recalc_have()
          break
        end
        os.sleep(2)
      end
    end
    return true
  end
  local candidates = collect_ancestors(species)
  if not candidates or #candidates == 0 then
    return nil, err or ("no mutation for " .. species)
  end
  for _, anc in ipairs(candidates) do
    if have_count(anc) == 0 then
      goto continue_anc
    end
    log("attempting to recover princess of " .. species .. " using ancestor princess " .. anc)
    clear_buffer()
    local okA, errA = request_parent(anc, true)
    if not okA then
      goto continue_anc
    end
    local okD, errD = request_parent(species, false)
    if not okD then
      goto continue_anc
    end
    local reqs = bee_db.get_requirements(db, species) or {climate = "NORMAL", humidity = "NORMAL", block = "none", dim = "none"}
    local bk_recover = beekeeper.new({
      tp_map = tp_map,
      apiaryNodes = devices.apiary,
      bufferNodes = bufferNodes,
      analyzerNodes = devices.analyzer,
      trashNodes = devices.storages["ROLE:TRASH"],
      acclNodes = devices.accl,
      acclimNodes = acclimNodes,
      bee_me = bee_me,
      reqs_lookup = reqs_lookup,
    })
    bk_recover:start(species, reqs)
    while true do
      local state = bk_recover:tick()
      if state == beekeeper.STATES.ERROR then
        break
      elseif state == beekeeper.STATES.DONE then
        recalc_have()
        return true
      end
      os.sleep(2)
    end
    ::continue_anc::
  end
  if allow_skip then
    log("no ancestor princess available for " .. species .. ", skipping")
    return nil, "skip"
  end
  return nil, "no ancestor princess available for " .. species
end

local function available_mutations()
  local list = {}
  for _, mut in ipairs(db.mutations) do
    if have_count(mut.child) < 64 and have_count(mut.p1) > 0 and have_count(mut.p2) > 0 then
      table.insert(list, mut)
    end
  end
  return list
end

local function reqs_lookup(species)
  return bee_db.get_requirements(db, species)
end

local bk = beekeeper.new({
  tp_map = tp_map,
  apiaryNodes = devices.apiary,
  bufferNodes = bufferNodes,
  analyzerNodes = devices.analyzer,
  trashNodes = devices.storages["ROLE:TRASH"],
  acclNodes = devices.accl,
  acclimNodes = acclimNodes,
  bee_me = bee_me,
  reqs_lookup = reqs_lookup,
})

io.write("Enter target species (exact displayName), or 'auto' to discover new, empty to exit: ")
local target = io.read("*l")
if not target or target == "" then
  log("exiting.")
  os.exit(0)
end

local plan, perr
local discovery_mode = false
if target == "auto" then
  discovery_mode = true
else
  plan, perr = planner.plan_to_target(db, target, have_counts)
  if not plan then
    fatal("planning failed: " .. tostring(perr))
  end
  log("plan length: " .. #plan)
end

if discovery_mode then
  local muts = available_mutations()
  log("discovery available mutations: " .. #muts)
  for _, step in ipairs(muts) do
    log(string.format("Try: %s x %s -> %s", step.p1, step.p2, step.child))
    local ok1, err1 = ensure_princess_available(step.p1, true)
    if not ok1 then
      log("skip step for " .. step.child .. ": " .. tostring(err1))
      goto continue_step_discovery
    end
    local ok2a, err2a = ensure_drone_available(step.p1, true, true)
    if not ok2a then
      log("skip step for " .. step.child .. ": " .. tostring(err2a))
      goto continue_step_discovery
    end
    local ok2b, err2b = ensure_drone_available(step.p2, true, true)
    if not ok2b then
      log("skip step for " .. step.child .. ": " .. tostring(err2b))
      goto continue_step_discovery
    end
  bk:start(step.child, step.reqs, {p1 = step.p1, p2 = step.p2})
    while true do
      local state = bk:tick()
      log("state: " .. tostring(state))
      if state == beekeeper.STATES.ERROR then
        log("beekeeper error: " .. tostring(bk.last_error))
        break
      elseif state == beekeeper.STATES.DONE then
        log("step done: " .. step.child)
        recalc_have()
        clear_buffer(step.child)
        break
      end
      os.sleep(2)
    end
    ::continue_step_discovery::
  end
  log("Discovery pass completed")
else
  for i, step in ipairs(plan) do
    log(string.format("Step %d/%d: %s x %s -> %s", i, #plan, step.p1, step.p2, step.child))
    -- Ensure parents available; bulk-drone up to 64 for stability.
    local ok1, err1 = ensure_princess_available(step.p1, false, false)
    if not ok1 then fatal(err1) end
    local ok2a, err2a = ensure_drone_available(step.p1, false, true)
    if not ok2a then fatal(err2a) end
    local ok2b, err2b = ensure_drone_available(step.p2, false, true)
    if not ok2b then fatal(err2b) end
    bk:start(step.child, step.reqs, {p1 = step.p1, p2 = step.p2})
    while true do
      local state = bk:tick()
      log("state: " .. tostring(state))
      if state == beekeeper.STATES.ERROR then
        fatal("beekeeper error: " .. tostring(bk.last_error))
      elseif state == beekeeper.STATES.DONE then
        log("step done: " .. step.child .. " (stabilized and repro in-step)")
        recalc_have()
        clear_buffer(step.child)
        -- If after clear we still have <64 pure drones of child, run a separate repro cycle with child parents.
        if have_count(step.child) < 64 then
          log("pure drones of " .. step.child .. " below 64, running follow-up reproduction")
          local repro_req = bee_db.get_requirements(db, step.child) or {climate = "NORMAL", humidity = "NORMAL", block = "none", dim = "none"}
          local okP, errP = ensure_princess_available(step.child, false, true)
          if not okP then fatal(errP) end
          local okD, errD = ensure_drone_available(step.child, false, true)
          if not okD then fatal(errD) end
          bk:start(step.child, repro_req, {p1 = step.child, p2 = step.child})
          while true do
            local st2 = bk:tick()
            log("repro-followup state: " .. tostring(st2))
            if st2 == beekeeper.STATES.ERROR then
              fatal("repro follow-up error: " .. tostring(bk.last_error))
            elseif st2 == beekeeper.STATES.DONE then
              log("follow-up reproduction done for " .. step.child)
              recalc_have()
              clear_buffer(step.child)
              break
            end
            os.sleep(2)
          end
        end
        break
      end
      os.sleep(2)
    end
  end
  log("All steps completed for target " .. target)
end
