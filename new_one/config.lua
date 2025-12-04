-- config.lua
-- Centralized configuration for bee breeder

local config = {}

-- ============================================================================
-- BREEDING SETTINGS
-- ============================================================================

-- Target number of drones to produce
config.DRONES_NEEDED = 64

-- Number of princesses needed (should be 1)
config.PRINCESS_NEEDED = 1

-- Initial drones to request per parent species
config.INITIAL_DRONES_PER_PARENT = 8

-- ============================================================================
-- ACCLIMATIZATION SETTINGS
-- ============================================================================

-- Minimum tolerance level required (both temp and humidity must be >= this)
config.MIN_TOLERANCE_LEVEL = 3

-- At least one tolerance must reach this level
config.MAX_TOLERANCE_LEVEL = 5

-- Amount of reagent to load at once
config.REAGENT_COUNT = 64

-- Reagent mappings: climate (temperature) preference -> reagent item
config.CLIMATE_ITEMS = {
  HOT = "Ice",
  WARM = "Ice",
  HELLISH = "Ice",
  COLD = "Blaze Rod",
  ICY = "Blaze Rod",
}

-- Reagent mappings: humidity preference -> reagent item
config.HUMIDITY_ITEMS = {
  DAMP = "Sand",
  ARID = "Water Can",
}

-- Default reagents when one parameter is already Normal
config.DEFAULT_CLIMATE_REAGENT = "Ice"
config.DEFAULT_HUMIDITY_REAGENT = "Water Can"

-- ============================================================================
-- DATA FILES
-- ============================================================================

config.MUTATIONS_FILE = "bee_mutations.txt"
config.REQUIREMENTS_FILE = "bee_requirements.txt"

-- ============================================================================
-- FRAMES SETTINGS
-- ============================================================================

-- Frame to use for mutations (when breeding new species, not self-breeding)
config.MUTATION_FRAME = "Mutagenic Frame"

-- Frame slot in apiary (using first frame slot)
config.FRAME_SLOT = 10

-- ============================================================================
-- TIMEOUTS (seconds)
-- ============================================================================

config.ACCLIMATIZATION_TIMEOUT = 300
config.BREEDING_CYCLE_TIMEOUT = 600
config.ANALYZER_TIMEOUT = 120

return config
