-- CHT Drift Judge – what is drawn on the track, and when. Pure Lua (testable offline).
--
-- Every drawn element (zone names, zone lines, colour fill, off-track strip, gates, last run's trace,
-- coverage) has a mode per role:
--   'always' – always visible
--   'editor' – only while the Pálya (editor) tab is open
--   'never'  – never
-- Role: 'pilot' | 'judge' | 'streamer'. For now it is chosen on each PC in Beállítások; in phase 2 the
-- judge and streamer roles will come from the Steam ID list, the visibility choices stay per person.
-- Stored in settings.ui.role and settings.ui.vis = { pilot = { names = 'editor', ... }, judge = {...}, ... }

local V = {}

V.items = {
  { key = 'names', label = 'Zónák és kapuk nevei', desc = 'A feliratok a pálya fölött (pl. „OZ 1 (22,3 p)”, „JUDGING”).' },
  { key = 'zones', label = 'Zónák vonalai és sávhatárai', desc = 'A zónák vonala és a 100% / 0% távolság halvány vonalai.' },
  { key = 'fills', label = 'Zónák színes kitöltése', desc = 'Az átlátszó színes terület a zónákon.' },
  { key = 'offtrack', label = 'Pályaelhagyás sáv (piros)', desc = 'A pályahatár vonalakon túli piros sáv.' },
  { key = 'gates', label = 'Kapuk (START / JUDGING / FINISH)', desc = 'A kapuk vonala a pályán.' },
  { key = 'trace', label = 'Utolsó futás nyomvonala', desc = 'Az utolsó futás útja a pályán.' },
  { key = 'bins', label = 'Lefedettség színezése a zónákon', desc = 'Az utolsó futás után a zóna szeletei: zöld = jó, piros = gyenge / kimaradt.' },
}

V.modes = {
  { 'always', 'Mindig' },
  { 'editor', 'Csak a Pálya fülön' },
  { 'never', 'Soha' },
}
V.modeLabel = {}
for _, m in ipairs(V.modes) do V.modeLabel[m[1]] = m[2] end

V.roles = {
  { 'pilot', 'Pilóta', 'Aki vezet: alapból a zónák nevei csak szerkesztéskor (a Pálya fülön) látszanak, a zónák és a színek vezetés közben is.' },
  { 'judge', 'Bíró', 'Aki pontoz / figyel: alapból minden látszik.' },
  { 'streamer', 'Közvetítő', 'A közvetítés képe: alapból csak a zónák és a színes kitöltés látszik, feliratok, kapuk, nyomvonal nélkül.' },
}
V.roleLabel = {}
for _, r in ipairs(V.roles) do V.roleLabel[r[1]] = r[2] end

V.defaults = {
  pilot = { names = 'editor', zones = 'always', fills = 'always', offtrack = 'always', gates = 'always', trace = 'always', bins = 'always' },
  judge = { names = 'always', zones = 'always', fills = 'always', offtrack = 'always', gates = 'always', trace = 'always', bins = 'always' },
  streamer = { names = 'never', zones = 'always', fills = 'always', offtrack = 'never', gates = 'never', trace = 'never', bins = 'never' },
}

local validMode = { always = true, editor = true, never = true }

function V.role(settings)
  local r = settings.ui and settings.ui.role
  if r == 'judge' or r == 'streamer' then return r end
  return 'pilot'
end

function V.setRole(settings, role)
  settings.ui.role = (role == 'judge' or role == 'streamer') and role or nil
end

local function store(settings)
  settings.ui = settings.ui or {}
  if type(settings.ui.vis) ~= 'table' then settings.ui.vis = {} end
  return settings.ui.vis
end

function V.mode(settings, key, role)
  role = role or V.role(settings)
  local t = store(settings)[role]
  local m = type(t) == 'table' and t[key] or nil
  if validMode[m] then return m end
  return (V.defaults[role] or V.defaults.pilot)[key] or 'always'
end

function V.set(settings, key, mode, role)
  role = role or V.role(settings)
  local s = store(settings)
  if type(s[role]) ~= 'table' then s[role] = {} end
  if mode == (V.defaults[role] or {})[key] then s[role][key] = nil else s[role][key] = mode end
end

function V.isChanged(settings, key, role)
  role = role or V.role(settings)
  return V.mode(settings, key, role) ~= (V.defaults[role] or {})[key]
end

function V.reset(settings, role)
  local s = store(settings)
  if role then s[role] = nil else settings.ui.vis = {} end
end

-- Main switch (E01, 0.3.8): one click / hotkey hides or shows everything the app draws on the track,
-- whatever the per-role settings say. Stored in settings.ui.trackDraw (nil = on). While a point is being
-- placed in the editor, the drawings are shown anyway (the caller handles that).
function V.masterOn(settings)
  return not (settings.ui and settings.ui.trackDraw == false)
end

function V.setMaster(settings, on)
  settings.ui = settings.ui or {}
  if on == false then settings.ui.trackDraw = false else settings.ui.trackDraw = nil end
end

function V.toggleMaster(settings)
  local on = not V.masterOn(settings)
  V.setMaster(settings, on)
  return on
end

-- Is the element drawn now? editorActive = the Pálya tab is open (or a point is being placed).
function V.visible(settings, key, editorActive)
  if not V.masterOn(settings) then return false end
  local m = V.mode(settings, key)
  if m == 'always' then return true end
  if m == 'editor' then return editorActive == true end
  return false
end

-- Older versions had simple on/off switches (labels, show3D, showTrace, showBins, fillZones,
-- fillOffTrack). A switched-off element becomes 'never' for the pilot role, once.
function V.migrate(settings)
  local u = settings.ui or {}
  if u.visMigrated then return false end
  local map = { labels = 'names', showTrace = 'trace', showBins = 'bins', fillZones = 'fills', fillOffTrack = 'offtrack' }
  for old, key in pairs(map) do
    if u[old] == false then V.set(settings, key, 'never', 'pilot') end
    u[old] = nil
  end
  if u.show3D == false then
    for _, it in ipairs(V.items) do V.set(settings, it.key, 'never', 'pilot') end
  end
  u.show3D = nil
  u.visMigrated = true
  return true
end

return V
