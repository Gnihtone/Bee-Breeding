-- bee_data_parser.lua
-- Parse bee_mutations.txt and bee_requirements.txt into Lua tables.

local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function read_lines(path)
  local f, err = io.open(path, "r")
  if not f then
    return nil, err
  end
  local lines = {}
  for line in f:lines() do
    if line ~= "" then
      table.insert(lines, line)
    end
  end
  f:close()
  return lines
end

local function parse_req_line(line)
  -- Format: bee;climate:X;humidity:Y
  local bee, rest = line:match("^([^;]+);(.+)$")
  if not bee then
    return nil, "invalid requirement line"
  end
  local req = {bee = trim(bee)}
  for token in rest:gmatch("([^;]+)") do
    local k, v = token:match("([^:]+):(.+)")
    if k and v then
      req[trim(k)] = trim(v)
    end
  end
  req.climate = req.climate or "Normal"
  req.humidity = req.humidity or "Normal"
  return req
end

local function parse_mut_line(line)
  -- Format: child:p1,p2;block:...;other:...
  local child, rest = line:match("^([^:]+):(.+)$")
  if not child or not rest then
    return nil, "invalid mutation line"
  end
  local parents_part, tail = rest:match("^([^;]+);?(.*)$")
  if not parents_part then
    return nil, "missing parents"
  end
  local p1, p2 = parents_part:match("^([^,]+),(.+)$")
  if not p1 or not p2 then
    return nil, "expected two parents"
  end
  local entry = {
    child = trim(child),
    p1 = trim(p1),
    p2 = trim(p2),
    block = "none",
    other = "none",
    extra = {},
  }
  for token in tail:gmatch("([^;]+)") do
    local k, v = token:match("([^:]+):(.+)")
    if k and v then
      local key = trim(k)
      local val = trim(v)
      if key == "block" then
        entry.block = val
      elseif key == "other" then
        entry.other = val
      else
        entry.extra[key] = val
      end
    end
  end
  return entry
end

local function parse_requirements(path)
  local lines, err = read_lines(path)
  if not lines then
    return nil, err
  end
  local list = {}
  local byBee = {}
  for _, line in ipairs(lines) do
    local req, perr = parse_req_line(line)
    if req then
      table.insert(list, req)
      byBee[req.bee] = req
    else
      io.stderr:write("skip requirement: " .. tostring(perr) .. " :: " .. line .. "\n")
    end
  end
  return {list = list, byBee = byBee}
end

local function parse_mutations(path)
  local lines, err = read_lines(path)
  if not lines then
    return nil, err
  end
  local list = {}
  local byChild = {}
  local byParents = {}
  for _, line in ipairs(lines) do
    local mut, perr = parse_mut_line(line)
    if mut then
      table.insert(list, mut)
      byChild[mut.child] = byChild[mut.child] or {}
      table.insert(byChild[mut.child], mut)

      byParents[mut.p1] = byParents[mut.p1] or {}
      byParents[mut.p1][mut.p2] = byParents[mut.p1][mut.p2] or {}
      table.insert(byParents[mut.p1][mut.p2], mut)
    else
      io.stderr:write("skip mutation: " .. tostring(perr) .. " :: " .. line .. "\n")
    end
  end
  return {list = list, byChild = byChild, byParents = byParents}
end

return {
  parse_requirements = parse_requirements,
  parse_mutations = parse_mutations,
}
