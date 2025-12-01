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
    return false
  end
  local active = stack.individual.active
  local inactive = stack.individual.inactive
  if not active or not inactive then
    return false
  end
  local pure = active.species.uid == inactive.species.uid
  return pure
end

local function is_princess(stack)
  if not stack or not stack.individual then
    return false
  end
  return stack.name == "Forestry:beePrincessGE"
end

local function is_pristine_princess(stack)
  if not is_princess(stack) then
    return false
  end
  return stack.individual.isNatural == true
end

-- Get preferred climate (temperature) from bee NBT.
-- Returns: "Normal", "HOT", "WARM", "COLD", "ICY", "HELLISH", etc.
local function get_climate(stack)
  if not stack or not stack.individual then
    return "Normal"
  end
  
  -- Try different possible NBT paths
  local active = stack.individual.active
  if active then
    -- Path 1: active.species.temperature
    if active.species and active.species.temperature then
      return active.species.temperature
    end
    -- Path 2: active.temperature
    if active.temperature then
      return active.temperature
    end
  end
  
  -- Path 3: direct on individual
  if stack.individual.temperature then
    return stack.individual.temperature
  end
  
  return "Normal"
end

-- Get preferred humidity from bee NBT.
-- Returns: "Normal", "DAMP", "ARID", etc.
local function get_humidity(stack)
  if not stack or not stack.individual then
    return "Normal"
  end
  
  -- Try different possible NBT paths
  local active = stack.individual.active
  if active then
    -- Path 1: active.species.humidity
    if active.species and active.species.humidity then
      return active.species.humidity
    end
    -- Path 2: active.humidity
    if active.humidity then
      return active.humidity
    end
  end
  
  -- Path 3: direct on individual
  if stack.individual.humidity then
    return stack.individual.humidity
  end
  
  return "Normal"
end

-- Get both climate and humidity requirements.
local function get_requirements(stack)
  return {
    climate = get_climate(stack),
    humidity = get_humidity(stack),
  }
end

return {
  get_species = get_species,
  is_pure = is_pure,
  is_pristine_princess = is_pristine_princess,
  is_princess = is_princess,
  get_climate = get_climate,
  get_humidity = get_humidity,
  get_requirements = get_requirements,
}
