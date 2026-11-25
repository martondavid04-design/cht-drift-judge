-- CHT Drift Judge – zone colours (3D drawing on the track, 2D map). Changeable in
-- Beállítások → Zónák színei; stored in settings.ui.zoneColors = { OZ = { r, g, b }, ... } (0..1).

local C = {}

C.keys = { 'OZ', 'IZ', 'WALL', 'TNG', 'IC', 'LIMIT', 'OFF' }
C.labels = {
  OZ = 'OZ (outer zone)', IZ = 'IZ (inner zone / clip)', WALL = 'Falas zóna', TNG = 'Touch and go', IC = 'IC (belső érintési pont)',
  LIMIT = 'HATÁR vonal', OFF = 'Pályaelhagyás sáv (a vonalon túl)',
}
C.defaults = {
  OZ = { 1.00, 0.85, 0.10 },   -- sárga
  IZ = { 0.20, 0.60, 1.00 },   -- kék
  WALL = { 1.00, 0.50, 0.10 }, -- narancs
  TNG = { 0.25, 0.90, 0.35 },  -- zöld
  IC = { 0.10, 0.95, 0.95 },   -- türkiz
  LIMIT = { 0.95, 0.30, 0.85 },-- lila-rózsaszín (a piros a pályaelhagyásé)
  OFF = { 1.00, 0.12, 0.12 },  -- piros
}

local function valid(c)
  return type(c) == 'table' and type(c[1]) == 'number' and type(c[2]) == 'number' and type(c[3]) == 'number'
end

-- { r, g, b } for a zone type ('OFF' = off-track strip).
function C.get(settings, key)
  local t = settings and settings.ui and settings.ui.zoneColors
  local c = t and t[key]
  if valid(c) then return c end
  return C.defaults[key] or { 1, 1, 1 }
end

function C.set(settings, key, r, g, b)
  settings.ui.zoneColors = type(settings.ui.zoneColors) == 'table' and settings.ui.zoneColors or {}
  settings.ui.zoneColors[key] = { r, g, b }
end

function C.reset(settings, key)
  if type(settings.ui.zoneColors) ~= 'table' then return end
  if key then settings.ui.zoneColors[key] = nil else settings.ui.zoneColors = nil end
end

function C.isChanged(settings, key)
  local c, d = C.get(settings, key), C.defaults[key]
  return math.abs(c[1] - d[1]) + math.abs(c[2] - d[2]) + math.abs(c[3] - d[3]) > 1e-3
end

return C
