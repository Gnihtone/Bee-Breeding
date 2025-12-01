-- main.lua
-- Main entry point for the bee breeder.
-- Usage:
--   main              → breed all missing species
--   main Industrious  → breed specific species

local discovery = require("discovery")
local bee_data_parser = require("bee_data_parser")
local bee_stock = require("bee_stock")
local me_interface = require("me_interface")
local pathfinder = require("pathfinder")
local orchestrator = require("orchestrator")

local MUTATIONS_FILE = "bee_mutations.txt"
local REQUIREMENTS_FILE = "bee_requirements.txt"

local DRONES_NEEDED = 64
local PRINCESS_NEEDED = 1

-- Global state
local devices = nil
local mutations_data = nil
local requirements_data = nil
local stock = nil
local orch = nil

-- Check if species is ready (has enough princess and drones).
local function is_ready(species)
  local counts = stock:get(species)
  if not counts then return false end
  return counts.princess >= PRINCESS_NEEDED and counts.drone >= DRONES_NEEDED
end

-- Find a donor princess (any species with princess > 1).
local function find_donor_princess()
  local all = stock:all()
  for species, counts in pairs(all) do
    if counts.princess > 1 then
      return species
    end
  end
  return nil
end

-- Check if species is a "base" species (cannot be mutated).
local function is_base_species(species)
  if not mutations_data or not mutations_data.byChild then
    return true
  end
  local muts = mutations_data.byChild[species]
  return not muts or #muts == 0
end

-- Get mutation info for a species.
local function get_mutation(species)
  if not mutations_data or not mutations_data.byChild then
    return nil
  end
  local muts = mutations_data.byChild[species]
  if not muts or #muts == 0 then
    return nil
  end
  return muts[1]  -- Take first available mutation
end

-- Ensure a species is ready (recursive).
-- Will breed/convert/mutate as needed.
local function ensure_species(species, depth)
  depth = depth or 0
  local indent = string.rep("  ", depth)
  
  print(indent .. "Checking " .. species .. "...")
  stock:rescan()
  
  local counts = stock:get(species) or {princess = 0, drone = 0}
  print(indent .. string.format("  Stock: %d princess, %d drones", counts.princess, counts.drone))
  
  -- Case 1: Ready
  if counts.princess >= PRINCESS_NEEDED and counts.drone >= DRONES_NEEDED then
    print(indent .. "  ✓ Ready!")
    return true
  end
  
  -- Case 2: Has princess but not enough drones → breed more
  if counts.princess >= PRINCESS_NEEDED and counts.drone < DRONES_NEEDED then
    print(indent .. "  → Breeding more drones...")
    orch:execute_mutation({
      parent1 = species,
      parent2 = species,
      child = species,
      block = "none",
    })
    return true
  end
  
  -- Case 3: No princess but has drones → convert from donor
  if counts.princess < PRINCESS_NEEDED and counts.drone > 0 then
    local donor = find_donor_princess()
    if not donor then
      error("No donor princess available for converting to " .. species)
    end
    print(indent .. "  → Converting princess from " .. donor .. "...")
    orch:execute_mutation({
      parent1 = donor,
      parent2 = species,
      child = species,
      block = "none",
    })
    return true
  end
  
  -- Case 4: No princess and no drones → mutate from parents
  if is_base_species(species) then
    error("Base species " .. species .. " not available and cannot be mutated")
  end
  
  local mutation = get_mutation(species)
  if not mutation then
    error("No mutation found for " .. species)
  end
  
  print(indent .. "  → Mutating from " .. mutation.p1 .. " + " .. mutation.p2 .. "...")
  
  -- Ensure parents are ready first (recursive)
  ensure_species(mutation.p1, depth + 1)
  ensure_species(mutation.p2, depth + 1)
  
  -- Now execute the mutation
  orch:execute_mutation({
    parent1 = mutation.p1,
    parent2 = mutation.p2,
    child = species,
    block = mutation.block or "none",
  })
  
  return true
end

-- Get all species that are not ready.
local function get_missing_species()
  local missing = {}
  
  if not mutations_data or not mutations_data.list then
    return missing
  end
  
  -- Collect all known species
  local all_species = {}
  for _, mut in ipairs(mutations_data.list) do
    all_species[mut.child] = true
    all_species[mut.p1] = true
    all_species[mut.p2] = true
  end
  
  -- Check which are missing
  stock:rescan()
  for species in pairs(all_species) do
    if not is_ready(species) then
      table.insert(missing, species)
    end
  end
  
  -- Sort for consistent order
  table.sort(missing)
  
  return missing
end

-- Initialize everything.
local function init()
  print("=== Bee Breeder Initializing ===")
  
  -- Discover devices
  print("Discovering devices...")
  local dev, derr = discovery.discover()
  if not dev then
    error("Discovery failed: " .. tostring(derr))
  end
  devices = dev
  
  -- Verify required devices
  local required_roles = {
    "ROLE:BUFFER",
    "ROLE:TRASH", 
    "ROLE:ACCL-MATS",
    "ROLE:FOUNDATION",
    "ROLE:ME-BEES",
    "ROLE:ME-BLOCKS",
  }
  
  for _, role in ipairs(required_roles) do
    if not devices.storages[role] and not devices.me_interfaces[role] then
      error("Missing required device: " .. role)
    end
  end
  
  if #devices.apiary == 0 then
    error("No apiary found")
  end
  if #devices.analyzer == 0 then
    error("No analyzer found")
  end
  if #devices.accl == 0 then
    error("No acclimatizer found")
  end
  
  print("  Found " .. #devices.apiary .. " apiary(s)")
  print("  Found " .. #devices.analyzer .. " analyzer(s)")
  print("  Found " .. #devices.accl .. " acclimatizer(s)")
  
  -- Parse bee data
  print("Loading bee data...")
  mutations_data = bee_data_parser.parse_mutations(MUTATIONS_FILE)
  if not mutations_data then
    error("Failed to parse " .. MUTATIONS_FILE)
  end
  print("  Loaded " .. #mutations_data.list .. " mutations")
  
  requirements_data = bee_data_parser.parse_requirements(REQUIREMENTS_FILE)
  if not requirements_data then
    error("Failed to parse " .. REQUIREMENTS_FILE)
  end
  print("  Loaded " .. #requirements_data.list .. " requirements")
  
  -- Get ME interface address
  local me_bees = devices.me_interfaces["ROLE:ME-BEES"]
  if not me_bees or not me_bees.address then
    error("ME-BEES interface address not found")
  end
  
  -- Find database component
  local db_addr = nil
  for addr in require("component").list("database") do
    db_addr = addr
    break
  end
  if not db_addr then
    error("Database component not found")
  end
  
  -- Create ME interface and stock tracker
  local me = me_interface.new(me_bees.address, db_addr)
  stock = bee_stock.new(me)
  
  -- Create orchestrator
  orch = orchestrator.new({
    buffer_dev = devices.storages["ROLE:BUFFER"],
    apiary_dev = devices.apiary,
    analyzer_dev = devices.analyzer,
    accl_dev = devices.accl,
    accl_mats_dev = devices.storages["ROLE:ACCL-MATS"],
    me_input_dev = devices.me_interfaces["ROLE:ME-BEES"],
    me_output_dev = devices.me_interfaces["ROLE:ME-BEES"],
    trash_dev = devices.storages["ROLE:TRASH"],
    foundation_dev = devices.storages["ROLE:FOUNDATION"],
    me_address = me_bees.address,
    db_address = db_addr,
    requirements_data = requirements_data,
  })
  
  print("=== Initialization Complete ===\n")
end

-- Main entry point.
local function main(args)
  init()
  
  local targets = {}
  
  if #args == 0 then
    -- No arguments → breed all missing species
    print("Finding missing species...")
    targets = get_missing_species()
    if #targets == 0 then
      print("All species are ready!")
      return
    end
    print("Missing species: " .. #targets)
    for i, species in ipairs(targets) do
      print("  " .. i .. ". " .. species)
    end
    print()
  else
    -- Specific species requested
    targets = {args[1]}
  end
  
  -- Process each target
  for i, target in ipairs(targets) do
    print(string.format("\n=== [%d/%d] Breeding %s ===", i, #targets, target))
    
    local ok, err = pcall(ensure_species, target, 0)
    if not ok then
      print("ERROR: " .. tostring(err))
      print("Continuing with next species...\n")
    else
      print(target .. " complete!\n")
    end
    
    -- Rescan stock after each target
    stock:rescan()
  end
  
  print("\n=== All Done! ===")
end

-- Run
local args = {...}
main(args)

