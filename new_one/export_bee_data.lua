-- export_bee_data.lua
-- Export bee mutation and requirement data from an OpenComputers apiary.

local component = require("component")
local fs = require("filesystem")

local MUT_FILE = "bee_mutations.txt"
local REQ_FILE = "bee_requirements.txt"

local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function ensure_apiary()
  local apiary_addr = component.list("tile_for_apiculture")()
  if apiary_addr then return component.proxy(apiary_addr) end
  error("apiary component not found")
end

local function get_species_map(apiary)
  local ok, data = pcall(apiary.listAllSpecies)
  if not ok or not data or not data[1] then
    io.stderr:write("warn: cannot read species list; requirements will be empty\n")
    return {}
  end
  local map = {}
  for _, spec in pairs(data) do
    local name = spec.name or spec.displayName or spec.uid
    if not name and type(spec.getName) == "function" then
      local okn, n = pcall(spec.getName)
      if okn then name = n end
    end
    if name then
      map[name] = {
        climate = tostring(spec.temperature or spec.climate or "Normal"),
        humidity = tostring(spec.humidity or "Normal"),
      }
    end
  end
  return map
end

local function write_lines(path, lines)
  local f, err = io.open(path, "w")
  if not f then
    error("cannot write " .. path .. ": " .. tostring(err))
  end
  for _, line in ipairs(lines) do
    f:write(line, "\n")
  end
  f:close()
end

local function main()
  local apiary = ensure_apiary()
  local species_map = get_species_map(apiary)

  local ok, data = pcall(apiary.getBeeBreedingData)
  if not ok or not data or not data[1] then
    error("cannot read bee breeding data")
  end

  local mutations = {}
  for _, entry in pairs(data) do
    local child = entry.result
    local p1 = entry.allele1
    local p2 = entry.allele2
    if child and p1 and p2 then
      local block = "none"
      local other_list = {}
      for _, cond in ipairs(entry.specialConditions or {}) do
        local cstr = tostring(cond)
        local block_raw = cstr:match("^Requires%s+(.+)%s+as a foundation%.?") or cstr:match("^Requires%s+(.+)%s+as foundation%.?")
        if block_raw then
          block = trim(block_raw)
        else
          table.insert(other_list, cstr)
        end
      end
      local other = (#other_list > 0) and table.concat(other_list, " | ") or "none"
      table.insert(mutations, string.format("%s:%s,%s;block:%s;other:%s", child, p1, p2, block, other))
    end
  end

  table.sort(mutations)
  local req_lines = {}
  local keys = {}
  for k in pairs(species_map) do table.insert(keys, k) end
  table.sort(keys)
  for _, name in ipairs(keys) do
    local r = species_map[name]
    table.insert(req_lines, string.format("%s;climate:%s;humidity:%s", name, r.climate, r.humidity))
  end

  write_lines(MUT_FILE, mutations)
  write_lines(REQ_FILE, req_lines)
  print(string.format("Wrote %d mutations to %s", #mutations, MUT_FILE))
  print(string.format("Wrote %d requirements to %s", #req_lines, REQ_FILE))
end

main()
