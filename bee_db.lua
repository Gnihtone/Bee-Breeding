-- bee_db.lua
-- Parse bee_mutations.txt and provide simple query helpers.

local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function split(str, sep)
  local result = {}
  for part in string.gmatch(str, "([^" .. sep .. "]+)") do
    table.insert(result, part)
  end
  return result
end

local function parse_line(line)
  -- Format: Child:Parent1,Parent2;climate:X;humidity:Y;block:Z;dim:D
  local child_part, rest = line:match("^([^:]+):(.*)$")
  if not child_part or not rest then
    return nil, "invalid line"
  end
  local parents_part, reqs_part = rest:match("^([^;]+);(.+)$")
  if not parents_part or not reqs_part then
    return nil, "invalid parent/req"
  end

  local parents = split(parents_part, ",")
  if #parents ~= 2 then
    return nil, "expected two parents"
  end

  local reqs = {}
  for token in string.gmatch(reqs_part, "([^;]+)") do
    local k, v = token:match("([^:]+):(.+)")
    if k and v then
      reqs[trim(k)] = trim(v)
    end
  end

  return {
    child = trim(child_part),
    p1 = trim(parents[1]),
    p2 = trim(parents[2]),
    reqs = {
      climate = reqs["climate"] or "NORMAL",
      humidity = reqs["humidity"] or "NORMAL",
      block = reqs["block"] or "none",
      dim = reqs["dim"] or "none",
    }
  }
end

local function load(path)
  local file, err = io.open(path, "r")
  if not file then
    return nil, err
  end

  local db = {
    mutations = {},
    byChild = {},
    byParents = {}
  }

  for line in file:lines() do
    if line ~= "" then
      local entry, perr = parse_line(line)
      if entry then
        table.insert(db.mutations, entry)
        db.byChild[entry.child] = db.byChild[entry.child] or {}
        table.insert(db.byChild[entry.child], entry)

        db.byParents[entry.p1] = db.byParents[entry.p1] or {}
        db.byParents[entry.p1][entry.p2] = db.byParents[entry.p1][entry.p2] or {}
        table.insert(db.byParents[entry.p1][entry.p2], entry.child)
      else
        io.stderr:write("bee_db: skip line: " .. perr .. " :: " .. line .. "\n")
      end
    end
  end
  file:close()
  return db
end

local function get_requirements(db, species)
  local list = db.byChild[species]
  if not list or not list[1] then
    return nil
  end
  return list[1].reqs
end

return {
  load = load,
  get_requirements = get_requirements,
}
