-- analyzer.lua
-- Helpers to inspect bee stacks for purity and pristine status.

local function get_species(stack)
  -- Prefer human-readable species name from displayName (e.g., "Forest", "Common").
  if stack and stack.individual and stack.individual.displayName then
    return stack.individual.displayName
  end
  if stack and stack.individual and stack.individual.active and stack.individual.active.species then
    return stack.individual.active.species
  end
  return nil
end

local function is_pure(stack)
  if not stack or not stack.individual then
    return false, nil
  end
  local active = stack.individual.active
  local inactive = stack.individual.inactive
  if not active or not inactive then
    return false, nil
  end
  local pure = active.species == inactive.species
  -- Return displayName if available, otherwise species id.
  local name = stack.individual.displayName or active.species
  return pure, name
end

local function is_pristine_princess(stack)
  if not stack or not stack.individual then
    return false
  end
  if stack.name ~= "Forestry:beePrincessGE" then
    return false
  end
  return stack.individual.isNatural == true
end

return {
  get_species = get_species,
  is_pure = is_pure,
  is_pristine_princess = is_pristine_princess,
}
