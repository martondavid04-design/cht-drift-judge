-- CHT Drift Judge – switchable, reorderable module lists (HUD items, Élő tab blocks, Eredmény sections).
-- State is a plain table stored in settings.ui: { order = { key, ... }, off = { [key] = true } }.
-- Pure Lua (testable offline).

local M = {}

-- defs: array of { key, label, desc, default = true|false }
function M.normalize(state, defs)
  state.order = type(state.order) == 'table' and state.order or {}
  state.off = type(state.off) == 'table' and state.off or {}
  local known, seen, order = {}, {}, {}
  for _, d in ipairs(defs) do known[d.key] = d end
  for _, k in ipairs(state.order) do
    if known[k] and not seen[k] then order[#order + 1] = k; seen[k] = true end
  end
  for _, d in ipairs(defs) do
    if not seen[d.key] then
      order[#order + 1] = d.key
      seen[d.key] = true
      if d.default == false and state.off[d.key] == nil then state.off[d.key] = true end
    end
  end
  state.order = order
  return state
end

function M.isOn(state, key) return not (state.off and state.off[key]) end

function M.setOn(state, key, on)
  state.off = state.off or {}
  state.off[key] = (not on) and true or nil
end

-- Ordered defs with `.on` flags (copies, the defs are not modified).
function M.ordered(state, defs)
  M.normalize(state, defs)
  local byKey = {}
  for _, d in ipairs(defs) do byKey[d.key] = d end
  local r = {}
  for i, k in ipairs(state.order) do
    local d = byKey[k]
    r[#r + 1] = { key = k, label = d.label, desc = d.desc, on = M.isOn(state, k), pos = i }
  end
  return r
end

-- Moves `key` by delta positions (-1 = up). Returns true if it moved.
function M.move(state, defs, key, delta)
  M.normalize(state, defs)
  local o = state.order
  for i, k in ipairs(o) do
    if k == key then
      local j = i + delta
      if j < 1 or j > #o then return false end
      o[i], o[j] = o[j], o[i]
      return true
    end
  end
  return false
end

-- preset: { on = { key, ... }, order = { key, ... }? } – keys not listed are switched off.
function M.applyPreset(state, defs, preset)
  local on = {}
  for _, k in ipairs(preset.on or {}) do on[k] = true end
  state.off = {}
  for _, d in ipairs(defs) do if not on[d.key] then state.off[d.key] = true end end
  if preset.order then state.order = {} for i, k in ipairs(preset.order) do state.order[i] = k end end
  M.normalize(state, defs)
end

-- Name of the preset the state matches exactly (on/off only), or nil.
function M.matchingPreset(state, defs, presets)
  for _, p in ipairs(presets) do
    local on = {}
    for _, k in ipairs(p.on or {}) do on[k] = true end
    local ok = true
    for _, d in ipairs(defs) do
      if (on[d.key] == true) ~= M.isOn(state, d.key) then ok = false break end
    end
    if ok then return p.id end
  end
  return nil
end

return M
