-- planner.lua
-- Build mutation plans and unknown-species queues.

local function set_of(tbl)
  local s = {}
  for _, v in ipairs(tbl) do
    s[v] = true
  end
  return s
end

local function copy_set(src)
  local dst = {}
  for k, v in pairs(src) do
    dst[k] = v
  end
  return dst
end

-- Recursively find a plan to obtain targetSpecies.
-- have is a set { species = true } that we already possess (pure drones).
-- Returns list of mutations (in execution order parents first) or nil+err.
local function solve(db, targetSpecies, have, visiting)
  if have[targetSpecies] then
    return {}
  end
  visiting = visiting or {}
  if visiting[targetSpecies] then
    return nil, "cycle at " .. targetSpecies
  end
  visiting[targetSpecies] = true

  local options = db.byChild[targetSpecies]
  if not options or #options == 0 then
    return nil, "no mutation for " .. targetSpecies
  end

  for _, mut in ipairs(options) do
    local new_plan = {}
    local local_have = copy_set(have)
    -- Plan for parent1
    local p1_plan, err1 = solve(db, mut.p1, local_have, visiting)
    local parent_ok = true
    if not p1_plan and not local_have[mut.p1] then
      parent_ok = false
    end
    if parent_ok and p1_plan then
      for _, step in ipairs(p1_plan) do table.insert(new_plan, step) end
      local_have[mut.p1] = true
    end

    if parent_ok then
      -- Plan for parent2
      local p2_plan, err2 = solve(db, mut.p2, local_have, visiting)
      if not p2_plan and not local_have[mut.p2] then
        parent_ok = false
      end
      if parent_ok and p2_plan then
        for _, step in ipairs(p2_plan) do table.insert(new_plan, step) end
        local_have[mut.p2] = true
      end
    end

    if parent_ok then
      table.insert(new_plan, mut)
      return new_plan
    end
  end

  visiting[targetSpecies] = nil
  return nil, "no viable mutation for " .. targetSpecies
end

local function plan_to_target(db, targetSpecies, haveSpecies)
  local have = copy_set(haveSpecies or {})
  local plan, err = solve(db, targetSpecies, have, {})
  return plan, err
end

local function unknown_species(db, haveSpecies)
  local unknown = {}
  for child, _ in pairs(db.byChild or {}) do
    if not haveSpecies[child] then
      table.insert(unknown, child)
    end
  end
  return unknown
end

return {
  plan_to_target = plan_to_target,
  unknown_species = unknown_species,
}
