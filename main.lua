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

log("discovery complete")

if not devices.apiary then fatal("apiary not found") end
if not devices.analyzer then fatal("analyzer not found") end

local bee_me_rec = devices.me_interfaces["ROLE:ME-BEES"]
local main_me_rec = devices.me_interfaces["ROLE:ME-MAIN"]

if not bee_me_rec then fatal("bee ME interface not found (ROLE:ME-BEES marker missing)") end
if not main_me_rec then fatal("main ME interface not found (ROLE:ME-MAIN marker missing)") end

local bee_me, err = me_bees.new(bee_me_rec.address, bee_me_rec.side, devices.transposer)
if not bee_me then fatal("bee ME init failed: " .. tostring(err)) end

local main_me, err = me_main.new(main_me_rec.address, main_me_rec.side, devices.transposer)
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
local inv = inventory.new(devices.transposer, {
  buffer = devices.storages["ROLE:BUFFER"],
  trash = devices.storages["ROLE:TRASH"],
  blocks = devices.storages["ROLE:BLOCKS"],
  acclim = devices.storages["ROLE:ACCLIM"],
})

if not inv then
  fatal("inventory init failed")
end

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

-- Prepare buffer utilities
local bufferSide = devices.storages["ROLE:BUFFER"]
if not bufferSide then
  fatal("buffer storage ROLE:BUFFER not found")
end

local function first_free_slot(side)
  local size = devices.transposer.getInventorySize(side)
  if not size then return nil end
  for slot = 1, size do
    if not devices.transposer.getStackInSlot(side, slot) then
      return slot
    end
  end
  return nil
end

local function clear_buffer()
  local size = devices.transposer.getInventorySize(bufferSide)
  if not size then return end
  for slot = 1, size do
    local stack = devices.transposer.getStackInSlot(bufferSide, slot)
    if stack then
      local pure, sp = analyzer.is_pure(stack)
      if pure and sp then
        if bee_me then
          local moved = bee_me:return_bee(bufferSide, slot, stack.size or 1, 1)
          if not moved or moved == 0 then
            fatal("failed to return pure bee " .. tostring(sp) .. " to bee ME from buffer slot " .. slot)
          end
        else
          fatal("pure bee " .. tostring(sp) .. " in buffer and bee ME unavailable")
        end
      else
        local trash = devices.storages["ROLE:TRASH"]
        if trash then
          local moved = devices.transposer.transferItem(bufferSide, trash, stack.size or 1, slot)
          if not moved or moved == 0 then
            fatal("failed to move dirty bee to trash from buffer slot " .. slot)
          end
        else
          fatal("dirty bee in buffer and no TRASH available (slot " .. slot .. ")")
        end
      end
    end
  end
end

local function request_parent(species, expect_princess)
  local attempts = 0
  while attempts < 5 do
    local targetSlot = first_free_slot(bufferSide)
    if not targetSlot then
      return nil, "buffer is full, cannot request " .. tostring(species)
    end
    local moved = bee_me:request_species(species, bufferSide, targetSlot)
    if not moved or moved == 0 then
      return nil, "failed to request " .. species .. " from bee ME"
    end
    local stack = devices.transposer.getStackInSlot(bufferSide, targetSlot)
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
      bee_me:return_bee(bufferSide, targetSlot, stack.size or 1, 1)
    end
    attempts = attempts + 1
  end
  return nil, "no suitable " .. (expect_princess and "princess" or "drone") .. " of " .. species
end

local function ensure_drone_available(species, allow_skip)
  -- If drone count already >=64, good.
  if have_count(species) >= 64 then
    return true
  end
  -- Attempt to fetch a drone; if fetched, return it back to bee ME immediately.
  local ok, err = request_parent(species, false)
  if ok then
    have_counts[species] = (have_counts[species] or 0) + 1
    -- If still below 64 and discovery is allowed, try to breed up.
    if allow_skip and have_count(species) < 64 then
      log("drone count for " .. species .. " below 64, attempting to breed up")
      local reqs = bee_db.get_requirements(db, species) or {climate = "NORMAL", humidity = "NORMAL", block = "none", dim = "none"}
      local bk_repro = beekeeper.new({
        transposer = devices.transposer,
        apiarySide = devices.apiary,
        bufferSide = bufferSide,
        analyzerSide = devices.analyzer,
        trashSide = devices.storages["ROLE:TRASH"],
        acclSide = devices.accl,
        acclimSide = devices.storages["ROLE:ACCLIM"],
        bee_me = bee_me,
      })
      -- Need a princess of species; try to recover.
      local okP, errP = ensure_princess_available(species, allow_skip)
      if not okP then
        return nil, errP
      end
      bk_repro:start(species, reqs)
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

local function ensure_princess_available(species, allow_skip)
  -- Try direct
  local ok, err = request_parent(species, true)
  if ok then
    -- Ensure drones exist in sufficient quantity for this species; if not, breed up using this princess.
    if have_count(species) < 64 then
      log("drone count for " .. species .. " below 64, breeding up with obtained princess")
      local reqs = bee_db.get_requirements(db, species) or {climate = "NORMAL", humidity = "NORMAL", block = "none", dim = "none"}
      local bk_repro = beekeeper.new({
        transposer = devices.transposer,
        apiarySide = devices.apiary,
        bufferSide = bufferSide,
        analyzerSide = devices.analyzer,
        trashSide = devices.storages["ROLE:TRASH"],
        acclSide = devices.accl,
        acclimSide = devices.storages["ROLE:ACCLIM"],
        bee_me = bee_me,
      })
      -- We already have princess; need a drone. If none, try to fetch; if still none and allow_skip, bail.
      local dok, derr = ensure_drone_available(species, allow_skip)
      if not dok then
        return nil, derr
      end
      bk_repro:start(species, reqs)
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
  -- Fallback: try ancestors present in mutation tree that we may have.
  local candidates = collect_ancestors(species)
  if not candidates or #candidates == 0 then
    return nil, err or ("no mutation for " .. species)
  end
  for _, anc in ipairs(candidates) do
    if not have[anc] then
      -- skip ancestors we don't have pure drones for
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
      transposer = devices.transposer,
      apiarySide = devices.apiary,
      bufferSide = bufferSide,
      analyzerSide = devices.analyzer,
      trashSide = devices.storages["ROLE:TRASH"],
      acclSide = devices.accl,
      acclimSide = devices.storages["ROLE:ACCLIM"],
      bee_me = bee_me,
    })
    bk_recover:start(species, reqs)
    while true do
      local state = bk_recover:tick()
      if state == beekeeper.STATES.ERROR then
        break
      elseif state == beekeeper.STATES.DONE then
        have[species] = true
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

local bk = beekeeper.new({
  transposer = devices.transposer,
  apiarySide = devices.apiary,
  bufferSide = bufferSide,
  analyzerSide = devices.analyzer,
  trashSide = devices.storages["ROLE:TRASH"],
  acclSide = devices.accl,
  acclimSide = devices.storages["ROLE:ACCLIM"],
  bee_me = bee_me,
})

if discovery_mode then
  local muts = available_mutations()
  log("discovery available mutations: " .. #muts)
  for _, step in ipairs(muts) do
    log(string.format("Try: %s x %s -> %s", step.p1, step.p2, step.child))
    clear_buffer()
    local ok1, err1 = ensure_princess_available(step.p1, true)
    if not ok1 then
      log("skip step for " .. step.child .. ": " .. tostring(err1))
      goto continue_step_discovery
    end
    local ok2, err2 = ensure_drone_available(step.p2, true)
    if not ok2 then
      log("skip step for " .. step.child .. ": " .. tostring(err2))
      goto continue_step_discovery
    end
    bk:start(step.child, step.reqs)
    while true do
      local state = bk:tick()
      log("state: " .. tostring(state))
      if state == beekeeper.STATES.ERROR then
        log("beekeeper error: " .. tostring(bk.last_error))
        break
      elseif state == beekeeper.STATES.DONE then
        log("step done: " .. step.child)
        recalc_have()
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
    clear_buffer()
    local ok1, err1 = ensure_princess_available(step.p1, false)
    if not ok1 then fatal(err1) end
    local ok2, err2 = ensure_drone_available(step.p2, false)
    if not ok2 then fatal(err2) end
    bk:start(step.child, step.reqs)
    while true do
      local state = bk:tick()
      log("state: " .. tostring(state))
      if state == beekeeper.STATES.ERROR then
        fatal("beekeeper error: " .. tostring(bk.last_error))
      elseif state == beekeeper.STATES.DONE then
        log("step done: " .. step.child)
        recalc_have()
        break
      end
      os.sleep(2)
    end
  end
  log("All steps completed for target " .. target)
end
