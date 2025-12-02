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

-- Check if mutation has special conditions we can't handle automatically.
local function has_special_conditions(mut)
  return mut.other and mut.other ~= "none" and mut.other ~= ""
end

-- Build a path of mutations from available species to target.
-- Returns: list of {parent1, parent2, child, block, climate, humidity} or nil, error
-- If skip_special is true, mutations with special conditions are skipped.
local function build_path_internal(target, mutations_data, requirements_data, stock, skip_special)
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
      -- Skip mutations with special conditions if requested
      if skip_special and has_special_conditions(mut) then
        goto continue
      end
      
      local p1_ok = available[mut.p1] or visited[mut.p1]
      local p2_ok = available[mut.p2] or visited[mut.p2]
      if p1_ok and p2_ok and not visited[mut.child] then
        table.insert(possible, mut)
      end
      
      ::continue::
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
  
  -- Find best mutation for species (prefer ones without special conditions)
  local function find_best_mutation(species)
    local muts = mutations_data.byChild[species]
    if not muts then return nil end
    
    -- First try to find mutation without special conditions
    if skip_special then
      for _, mut in ipairs(muts) do
        if not has_special_conditions(mut) then
          return mut
        end
      end
    end
    
    -- Fallback to first mutation
    return muts[1]
  end
  
  -- Find all species we need to produce
  local function add_needed(species)
    if produced[species] or needed[species] then
      return
    end
    needed[species] = true
    
    local mut = find_best_mutation(species)
    if mut then
      if not produced[mut.p1] then add_needed(mut.p1) end
      if not produced[mut.p2] then add_needed(mut.p2) end
    end
  end
  
  add_needed(target)
  
  -- Topological sort - produce in correct order
  local remaining = {}
  for species in pairs(needed) do
    local mut = find_best_mutation(species)
    if mut then
      remaining[species] = mut
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

-- Public function: build path, preferring mutations without special conditions.
-- If no path found without special conditions, tries with them and warns user.
function pathfinder.build_path(target, mutations_data, requirements_data, stock)
  -- First try without special conditions
  local path, err = build_path_internal(target, mutations_data, requirements_data, stock, true)
  
  if path then
    return path
  end
  
  -- No path found, try with special conditions
  local path_with_special, err2 = build_path_internal(target, mutations_data, requirements_data, stock, false)
  
  if not path_with_special then
    return nil, err  -- Return original error
  end
  
  -- Found path but requires special conditions - find which ones
  local special_mutations = {}
  for _, step in ipairs(path_with_special) do
    -- Find the original mutation to check its 'other' field
    local muts = mutations_data.byChild[step.child]
    if muts then
      for _, mut in ipairs(muts) do
        if mut.p1 == step.parent1 and mut.p2 == step.parent2 then
          if has_special_conditions(mut) then
            table.insert(special_mutations, {
              child = step.child,
              conditions = mut.other
            })
          end
          break
        end
      end
    end
  end
  
  if #special_mutations > 0 then
    local msg = "Path requires mutations with special conditions:\n"
    for _, sm in ipairs(special_mutations) do
      msg = msg .. "  - " .. sm.child .. ": " .. sm.conditions .. "\n"
    end
    msg = msg .. "These conditions cannot be handled automatically."
    return nil, msg
  end
  
  return path_with_special
end

return pathfinder

