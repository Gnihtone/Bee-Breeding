-- ui.lua
-- Minimal CLI placeholders.

local function choose_target()
  -- Placeholder: interactive selection to be implemented.
  return nil, "not implemented"
end

local function status(msg)
  io.write(msg .. "\n")
end

return {
  choose_target = choose_target,
  status = status,
}
