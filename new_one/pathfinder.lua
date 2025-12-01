-- pathfinder.lua
-- Builds a mutation path from available species to a target species.
-- Uses BFS to find the shortest path.

local pathfinder = {}

-- Check if species is available (has >= 64 drones + 1 princess).
local function is_available(species, stock)
  local s = stock:get(species)
  if not s then return false end
  return s.drone >= 64 and s.princess >= 1
end

-- Build a path of mutations from available species to target.
-- Returns: list of {parent1, parent2, child, block, climate, humidity} or nil, error
function pathfinder.build_path(target, mutations_data, requirements_data, stock)
  if not mutations_data or not mutations_data.byChild then
    return nil, "mutations data required"
  end
  
  -- Check if target is already available
  if is_available(target, stock) then
    return {}, nil  -- Empty path, already have it
  end
  
  -- BFS to find path
  -- State: species we can produce
  -- We start with all available species
  
  local available = {}  -- species -> true
  local all_species = stock:all()
  for species, counts in pairs(all_species) do
    if counts.drone >= 64 and counts.princess >= 1 then
      available[species] = true
    end
  end
  
  -- If we have no available species, we can't breed anything
  if not next(available) then
    return nil, "no available species in stock"
  end
  
  -- BFS queue: each entry is {species, path_to_get_here}
  local queue = {}
  local visited = {}
  
  -- Initialize queue with all species we can produce from available
  for species in pairs(available) do
    visited[species] = true
  end
  
  -- Find all mutations we can do with available species
  local function get_possible_mutations()
    local possible = {}
    for _, mut in ipairs(mutations_data.list) do
      local p1_ok = available[mut.p1] or visited[mut.p1]
      local p2_ok = available[mut.p2] or visited[mut.p2]
      if p1_ok and p2_ok and not visited[mut.child] then
        table.insert(possible, mut)
      end
    end
    return possible
  end
  
  -- Build parent map for backtracking
  local parent_map = {}  -- child -> mutation that produces it
  
  -- BFS
  local found = false
  local max_iterations = 1000
  local iteration = 0
  
  while iteration < max_iterations do
    iteration = iteration + 1
    local possible = get_possible_mutations()
    
    if #possible == 0 then
      break
    end
    
    local new_species = {}
    for _, mut in ipairs(possible) do
      if not visited[mut.child] then
        visited[mut.child] = true
        parent_map[mut.child] = mut
        table.insert(new_species, mut.child)
        
        if mut.child == target then
          found = true
          break
        end
      end
    end
    
    if found then
      break
    end
    
    if #new_species == 0 then
      break
    end
  end
  
  if not found then
    return nil, "no path found to " .. target
  end
  
  -- Backtrack to build path
  local path = {}
  local current = target
  
  while parent_map[current] do
    local mut = parent_map[current]
    
    -- Get requirements for this species
    local req = requirements_data and requirements_data.byBee and requirements_data.byBee[mut.child]
    local climate = req and req.climate or "Normal"
    local humidity = req and req.humidity or "Normal"
    
    table.insert(path, 1, {
      parent1 = mut.p1,
      parent2 = mut.p2,
      child = mut.child,
      block = mut.block,
      climate = climate,
      humidity = humidity,
    })
    
    -- Move to parents if they weren't originally available
    if not available[mut.p1] and parent_map[mut.p1] then
      current = mut.p1
    elseif not available[mut.p2] and parent_map[mut.p2] then
      current = mut.p2
    else
      break
    end
  end
  
  -- Rebuild path properly - we need to order by dependencies
  -- Start fresh with proper dependency resolution
  path = {}
  local produced = {}
  for species in pairs(available) do
    produced[species] = true
  end
  
  local function can_produce(mut)
    return produced[mut.p1] and produced[mut.p2]
  end
  
  local to_produce = {target}
  local needed = {}
  needed[target] = true
  
  -- Find all species we need to produce
  local function add_needed(species)
    if produced[species] or needed[species] then
      return
    end
    needed[species] = true
    
    local muts = mutations_data.byChild[species]
    if muts and muts[1] then
      local mut = muts[1]  -- Take first mutation option
      if not produced[mut.p1] then add_needed(mut.p1) end
      if not produced[mut.p2] then add_needed(mut.p2) end
    end
  end
  
  add_needed(target)
  
  -- Topological sort - produce in correct order
  local remaining = {}
  for species in pairs(needed) do
    local muts = mutations_data.byChild[species]
    if muts and muts[1] then
      remaining[species] = muts[1]
    end
  end
  
  while next(remaining) do
    local progress = false
    for species, mut in pairs(remaining) do
      if can_produce(mut) then
        local req = requirements_data and requirements_data.byBee and requirements_data.byBee[species]
        local climate = req and req.climate or "Normal"
        local humidity = req and req.humidity or "Normal"
        
        table.insert(path, {
          parent1 = mut.p1,
          parent2 = mut.p2,
          child = species,
          block = mut.block,
          climate = climate,
          humidity = humidity,
        })
        
        produced[species] = true
        remaining[species] = nil
        progress = true
      end
    end
    
    if not progress then
      return nil, "circular dependency or missing species"
    end
  end
  
  return path
end

return pathfinder

