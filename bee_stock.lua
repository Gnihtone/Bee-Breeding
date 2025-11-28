-- bee_stock.lua
-- Helpers to derive available pure species from bee ME interface.

local analyzer = require("analyzer")

local function build_have_set(bee_iface)
  local have = {}
  if not bee_iface then return have end
  local items = bee_iface.getItemsInNetwork()
  if not items then return have end
  for _, entry in ipairs(items) do
    if entry.individual then
      local pure, species = analyzer.is_pure(entry)
      if pure and species then
        if entry.name == "Forestry:beeDroneGE" then
          have[species] = (have[species] or 0) + (entry.size or 0)
        end
      end
    end
  end
  return have
end

return {
  build_have_set = build_have_set,
  build_have_set_with_iface = function(addr)
    local comp = require("component")
    local iface = comp.proxy(addr)
    return build_have_set(iface)
  end
}
