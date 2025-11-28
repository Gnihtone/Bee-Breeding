-- export_bee_data.lua
-- Export bee mutation and requirement data from an OpenComputers apiary.

local component = require("component")
local fs = require("filesystem")

local MUT_FILE = "bee_mutations.txt"
local REQ_FILE = "bee_requirements.txt"

local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function norm_scalar(s)
  if not s then return nil end
  return (tostring(s):upper():gsub("%s+", "_"))
end

local function ensure_apiary()
  if not component.isAvailable("apiary") then
    error("apiary component not found")
  end
  return component.apiary
end

local function get_species_map(apiary)
  local ok, data = pcall(apiary.listAllSpecies)
  if not ok or not data or not data[1] then
    io.stderr:write("warn: cannot read species list; defaulting to NORMAL/NORMAL\n")
    return {}
  end
  local map = {}
  for _, spec in pairs(data[1]) do
    local name = spec.name or spec.displayName or spec.uid
    if not name and type(spec.getName) == "function" then
      local okn, n = pcall(spec.getName)
      if okn then name = n end
    end
    if name then
      map[name] = {
        climate = norm_scalar(spec.temperature or spec.climate) or "NORMAL",
        humidity = norm_scalar(spec.humidity) or "NORMAL",
      }
    end
  end
  return map
end

local function parse_conditions(list, defaults)
  local req = {
    climate = defaults.climate or "NORMAL",
    humidity = defaults.humidity or "NORMAL",
    block = defaults.block or "none",
    dim = defaults.dim or "none",
  }
  for _, cond in ipairs(list or {}) do
    local lc = string.lower(tostring(cond))
    local hv = lc:match("^requires%s+([%w%s%-]+)%s+humidity")
    if hv then
      req.humidity = norm_scalar(hv) or req.humidity
    end
    local cv = lc:match("^requires%s+([%w%s%-]+)%s+temperature") or lc:match("^requires%s+([%w%s%-]+)%s+climate")
    if cv then
      req.climate = norm_scalar(cv) or req.climate
    end
    local block = lc:match("^requires%s+(.+)%s+as a foundation") or lc:match("^requires%s+(.+)%s+as foundation")
    if block then
      req.block = trim(cond:gsub("Requires%s+", ""):gsub("%s+as a foundation%.?", ""))
    end
    local dim = lc:match("^required%s+dimension%s+(.+)") or lc:match("^requires%s+dimension%s+(.+)")
    if dim then
      req.dim = trim(cond:gsub("Required Dimension%s+", ""):gsub("Requires Dimension%s+", ""))
    end
  end
  return req
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
  local reqs_by_child = {}

  for _, entry in pairs(data[1]) do
    local child = entry.result
    local p1 = entry.allele1
    local p2 = entry.allele2
    if child and p1 and p2 then
      table.insert(mutations, string.format("%s:%s,%s", child, p1, p2))
      if not reqs_by_child[child] then
        local base = species_map[child] or {climate = "NORMAL", humidity = "NORMAL"}
        reqs_by_child[child] = parse_conditions(entry.specialConditions or {}, {
          climate = base.climate,
          humidity = base.humidity,
          block = "none",
          dim = "none",
        })
      end
    end
  end

  table.sort(mutations)
  local req_lines = {}
  local keys = {}
  for k in pairs(reqs_by_child) do table.insert(keys, k) end
  table.sort(keys)
  for _, child in ipairs(keys) do
    local r = reqs_by_child[child]
    table.insert(req_lines, string.format("%s;climate:%s;humidity:%s;block:%s;dim:%s",
      child, r.climate, r.humidity, r.block, r.dim))
  end

  write_lines(MUT_FILE, mutations)
  write_lines(REQ_FILE, req_lines)
  print(string.format("Wrote %d mutations to %s", #mutations, MUT_FILE))
  print(string.format("Wrote %d requirements to %s", #req_lines, REQ_FILE))
end

main()
