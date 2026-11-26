-- CHT Drift Judge – live view: the Élő tab (switchable, reorderable blocks) and the HUD window
-- (switchable, reorderable modules, presets, size and background). CSP only.

local geom = require('src/geom')
local U = require('src/ui_common')
local telemetry = require('src/telemetry')
local modlist = require('src/modlist')
local platform = require('src/platform')
local visibility = require('src/visibility')

local Live = {}

local stateNames = {
  idle = 'Várakozás – hajts át a START (vagy JUDGING) vonalon',
  started = 'Futás elindult – a bírálat a JUDGING vonalnál kezdődik',
  judging = 'BÍRÁLAT FOLYAMATBAN',
}
local stateColors = { idle = U.col.dim, started = U.col.yellow, judging = U.col.green }

-- HUD modules ---------------------------------------------------------------------------------------

Live.hudItems = {
  { key = 'angle', label = 'Driftszög', desc = 'Középről mutat balra / jobbra. Zöld sáv: célszög fölött, sárga: túldobás, piros: beforgás.' },
  { key = 'speed', label = 'Sebesség', desc = 'km/h, nagy számmal.' },
  { key = 'gear', label = 'Fokozat és fordulatszám', desc = 'Fokozat, rpm és egy sáv, ami a tiltó előtt pirosra vált.' },
  { key = 'steer', label = 'Kormányállás', desc = 'Középről kitérő sáv, fokban.' },
  { key = 'gas', label = 'Gáz', desc = 'Gázpedál 0–100%.' },
  { key = 'brake', label = 'Fék', desc = 'Fékpedál 0–100%.' },
  { key = 'handbrake', label = 'Kézifék', desc = 'Kézifék 0–100%.' },
  { key = 'clutch', label = 'Kuplung', desc = 'Kuplungpedál: 100% = teljesen lenyomva (nincs hajtás).' },
  { key = 'drive', label = 'Hajtás jelző', desc = 'VAN / NINCS (és miért: üres, kuplung, nincs gáz). (A kipörgésjelzőt a megrendelő kérésére kivettük, D26: hibásan mutatott.)' },
  { key = 'zone', label = 'Aktuális zóna', desc = 'Melyik zónában vagy éppen.' },
  { key = 'faults', label = 'Hibaszámláló', desc = '1 kerék, 2 kerék, korrekció, fal utáni mentés, túldobás – a futás alatt.' },
  { key = 'last', label = 'Utolsó futás pontja', desc = 'Futás után a végső pontszám (vagy NULLÁS).' },
  { key = 'summary', label = 'Futás összesítő', desc = 'Futás közben az eddig szerzett zónapont; futás után a végső pont Line / Angle / Stílus bontásban és a hibák.' },
}

Live.hudPresets = {
  { id = 'practice', label = 'Edzés', desc = 'Élő adatok (szög, sebesség, fokozat, kormány, pedálok, hajtás, zóna, hibák) és a futás összesítője.',
    on = { 'angle', 'speed', 'gear', 'steer', 'gas', 'brake', 'handbrake', 'clutch', 'drive', 'zone', 'faults', 'summary' } },
  { id = 'full', label = 'Részletes', desc = 'Minden modul be van kapcsolva (hangolás, hibakeresés).',
    on = { 'angle', 'speed', 'gear', 'steer', 'gas', 'brake', 'handbrake', 'clutch', 'drive', 'zone', 'faults', 'last', 'summary' } },
  { id = 'minimal', label = 'Minimál', desc = 'Csak a szög, a sebesség, a fokozat, a zóna és az utolsó pont.',
    on = { 'angle', 'speed', 'gear', 'zone', 'last' } },
  { id = 'stream', label = 'Közvetítő', desc = 'Nézőknek: szög, sebesség, kormány, pedálok, zóna, hibák, pont.',
    on = { 'angle', 'speed', 'steer', 'gas', 'brake', 'handbrake', 'zone', 'faults', 'last' } },
}

-- HUD state lives in settings.ui.hudMods = { order, off }. Older versions stored settings.ui.hud[key] = false.
function Live.hudState(app)
  local ui_ = app.settings.ui
  if type(ui_.hudMods) ~= 'table' then
    ui_.hudMods = { order = {}, off = {} }
    if type(ui_.hud) == 'table' then
      for k, v in pairs(ui_.hud) do if v == false then ui_.hudMods.off[k] = true end end
    end
  end
  return modlist.normalize(ui_.hudMods, Live.hudItems)
end

-- Modules that show points are hidden on an online pilot PC when the server keeps the points for the
-- judges (pilotScores = 0 in the server's [SCRIPT_…] section).
local scoreModules = { last = true, summary = true }
function Live.hudEnabled(app, key)
  if scoreModules[key] and not platform.canSeeScores() then return false end
  return modlist.isOn(Live.hudState(app), key)
end

-- Élő tab blocks ------------------------------------------------------------------------------------

Live.tabBlocks = {
  { key = 'gauge', label = 'Driftszög és autó adatai', desc = 'A HUD moduljai nagyban (a HUD-nál kikapcsolt modulok itt is rejtve vannak).' },
  { key = 'faults', label = 'Hibaszámláló', desc = 'A futás hibái kategóriánként, a szabállyal együtt.' },
  { key = 'zones', label = 'Zónák eddig', desc = 'Futás közben zónánként a Line, az Angle és a pont.' },
  { key = 'controls', label = 'Futás kezelése', desc = 'Futás lezárása, elvetése, szabad felvétel.' },
}

function Live.tabState(app)
  local ui_ = app.settings.ui
  if type(ui_.liveMods) ~= 'table' then ui_.liveMods = { order = {}, off = {} } end
  return modlist.normalize(ui_.liveMods, Live.tabBlocks)
end

-- Clutch: AC reports 1 = engaged (pedal up) on most setups, but some docs say the opposite. The meaning
-- is detected while driving (in gear, on throttle, at speed the clutch must be engaged).
local clutchVote = 0
function Live.clutchPressed(car)
  local c = car.clutch or 0
  if (car.gear or 0) > 0 and (car.speedKmh or 0) > 30 and (car.gas or 0) > 0.5 then
    clutchVote = geom.clamp(clutchVote + (c > 0.5 and 1 or -1), -200, 200)
  end
  if clutchVote >= 0 then return 1 - c end -- engaged-value semantics
  return c
end

-- Drawing helpers (k = scale) -----------------------------------------------------------------------

local function angleGauge(angle, dir, size, cfg, flip)
  local p = ui.getCursor()
  local c = p + vec2(size / 2, size * 0.56)
  local r = size * 0.44
  local maxDeg = 120
  local function arcPoint(deg)
    local a = math.rad(270 + deg / maxDeg * 90)
    return c + vec2(math.cos(a), math.sin(a)) * r
  end
  local function seg(d0, d1, col, th)
    local steps = math.max(1, math.floor(math.abs(d1 - d0) / 3))
    for i = 0, steps - 1 do
      local a0 = d0 + (d1 - d0) * i / steps
      local a1 = d0 + (d1 - d0) * (i + 1) / steps
      ui.drawLine(arcPoint(a0), arcPoint(a1), col, th)
    end
  end
  local th = math.max(6, size * 0.045)
  seg(-maxDeg, maxDeg, rgbm(1, 1, 1, 0.1), th)
  for _, sgn in ipairs({ -1, 1 }) do
    seg(sgn * cfg.angleMin, sgn * cfg.angleTarget, rgbm(0.35, 0.88, 0.55, 0.25), th)
    seg(sgn * cfg.angleTarget, sgn * math.min(cfg.overAngle, maxDeg), rgbm(0.35, 0.88, 0.55, 0.6), th)
    seg(sgn * math.min(cfg.overAngle, maxDeg), sgn * math.min(cfg.spinAngle, maxDeg), rgbm(1, 0.75, 0.2, 0.55), th)
    seg(sgn * math.min(cfg.spinAngle, maxDeg), sgn * maxDeg, rgbm(1, 0.35, 0.35, 0.55), th)
  end
  ui.drawLine(arcPoint(0) + vec2(0, -th), arcPoint(0) + vec2(0, th), rgbm(1, 1, 1, 0.5), 2)
  local a = angle or 0
  local sd = (dir or 0) * (flip and -1 or 1)
  local shown = geom.clamp(a, 0, maxDeg) * (sd == 0 and 1 or sd)
  local col = a >= cfg.spinAngle and U.col.red or (a >= cfg.overAngle and U.col.orange or (a >= cfg.angleTarget and U.col.green or U.col.text))
  ui.drawLine(c, arcPoint(shown), col, math.max(3, size * 0.02))
  ui.drawCircleFilled(c, math.max(5, size * 0.03), col, 16)
  local txt = string.format('%.0f°', a)
  local fs = size * 0.19
  local m = U.measure(txt, fs, true)
  U.drawText(txt, fs, c + vec2(-m.x / 2, size * 0.05), col, true)
  local ls = math.max(11, size * 0.06)
  U.drawText('BAL', ls, c + vec2(-r - ls * 1.2, size * 0.05), U.col.dim)
  local jm = U.measure('JOBB', ls)
  U.drawText('JOBB', ls, c + vec2(r + ls * 1.2 - jm.x, size * 0.05), U.col.dim)
  ui.dummy(vec2(size, size * 0.86))
end

Live.angleGauge = angleGauge -- (the broadcaster HUD uses it too)

local function hbar(label, v, col, width, labelW, k, valueText)
  U.text(label, 13 * k, U.col.dim)
  ui.sameLine(labelW)
  local w = width - labelW - (valueText and 46 * k or 0)
  U.bar(math.max(20, w), 10 * k, v, col)
  if valueText then
    ui.sameLine(0, 6)
    U.text(valueText, 13 * k, U.col.text)
  end
end

local function cbar(label, v, width, labelW, text, k)
  U.text(label, 13 * k, U.col.dim)
  ui.sameLine(labelW)
  local p = ui.getCursor()
  local w = math.max(20, width - labelW - 46 * k)
  local h = 10 * k
  ui.drawRectFilled(p, p + vec2(w, h), rgbm(1, 1, 1, 0.08), h / 2)
  local mid = p.x + w / 2
  local f = geom.clamp(v or 0, -1, 1)
  local x2 = mid + f * w / 2
  ui.drawRectFilled(vec2(math.min(mid, x2), p.y), vec2(math.max(mid, x2), p.y + h), U.col.cyan, 3)
  ui.drawLine(vec2(mid, p.y - 2), vec2(mid, p.y + h + 2), rgbm(1, 1, 1, 0.6), 1)
  ui.dummy(vec2(w, h))
  if text then
    ui.sameLine(0, 6)
    U.text(text, 13 * k, U.col.text)
  end
end

local gearNames = { [-1] = 'R', [0] = 'N' }
local function pct(v) return string.format('%.0f%%', geom.clamp(v or 0, 0, 1) * 100) end

-- Module drawers: function(ctx) where ctx = { app, live, car, s, cfg, width, k, big, labelW }
local drawers = {}

drawers.angle = function(c)
  angleGauge(c.live.angle, c.live.dir, math.min(c.width, (c.big and 300 or 220) * c.k), c.cfg, c.app.settings.ui.hudFlipDir == true)
end
drawers.speed = function(c)
  U.text(string.format('%.0f km/h', c.live.speed or 0), (c.big and 28 or 22) * c.k, U.col.text, true)
end
drawers.gear = function(c)
  local car = c.car
  if not car then return end
  local g = car.gear or 0
  U.text(string.format('%s  ·  %.0f rpm', gearNames[g] or tostring(g), car.rpm or 0), (c.big and 20 or 16) * c.k, U.col.dim, true)
  local lim = (car.rpmLimiter and car.rpmLimiter > 0) and car.rpmLimiter or 8000
  local f = (car.rpm or 0) / lim
  U.bar(c.width, 6 * c.k, f, f > 0.95 and U.col.red or U.col.purple)
end
drawers.steer = function(c)
  local car = c.car
  if not car then return end
  local lock = (car.steerLock and car.steerLock > 1) and car.steerLock or 450
  cbar('Kormány', (car.steer or 0) / lock, c.width, c.labelW, string.format('%.0f°', car.steer or 0), c.k)
end
drawers.gas = function(c) if c.car then hbar('Gáz', c.car.gas, U.col.green, c.width, c.labelW, c.k, pct(c.car.gas)) end end
drawers.brake = function(c) if c.car then hbar('Fék', c.car.brake, U.col.red, c.width, c.labelW, c.k, pct(c.car.brake)) end end
drawers.handbrake = function(c) if c.car then hbar('Kézifék', c.car.handbrake, U.col.orange, c.width, c.labelW, c.k, pct(c.car.handbrake)) end end
drawers.clutch = function(c)
  if not c.car then return end
  local v = Live.clutchPressed(c.car)
  hbar('Kuplung', v, U.col.yellow, c.width, c.labelW, c.k, pct(v))
end
drawers.drive = function(c)
  local car = c.car
  if not car then return end
  local pressed = Live.clutchPressed(car)
  local engaged = (car.gear or 0) ~= 0 and pressed < 0.5 and (car.gas or 0) > 0.05
  local why = ''
  if not engaged then
    if (car.gear or 0) == 0 then why = ' (üres)' elseif pressed >= 0.5 then why = ' (kuplung)' else why = ' (nincs gáz)' end
  end
  U.text('Hajtás', 13 * c.k, U.col.dim)
  ui.sameLine(c.labelW)
  U.text(engaged and 'VAN' or ('NINCS' .. why), 14 * c.k, engaged and U.col.green or U.col.orange, true)
  -- (0.3.14: the wheelspin bar is gone – the client found it wrong on the HUD, D26; the recording still
  -- keeps the driven-wheel slip „dslip” for analysis)
end
drawers.zone = function(c)
  if c.live.activeZone then U.text('Zóna: ' .. c.live.activeZone, 15 * c.k, U.col.purple, true) end
end
drawers.faults = function(c)
  local f = c.live.faults
  if f then
    U.text(string.format('1K %d · 2K %d · Korr %d · Fal %d · Túl %d', f.oneWheel, f.twoWheel, f.corrections, f.wallSaves, f.overRotations), 13 * c.k, U.col.dim)
  elseif c.live.state == 'idle' then
    U.text('Hibák: futás közben látszanak', 13 * c.k, U.col.dim)
  end
end
drawers.last = function(c)
  local r = c.app.lastResult
  if r and c.live.state == 'idle' then
    U.text(r.zeroRun and 'Utolsó: NULLÁS' or ('Utolsó: ' .. U.t1(r.final)), 16 * c.k, r.zeroRun and U.col.red or U.col.green, true)
  end
end
-- run summary: during the run the zone points so far, after it the final score by criterion and the faults
drawers.summary = function(c)
  local live, app, k = c.live, c.app, c.k
  if live.state == 'judging' then
    local lp = app.livePartial
    if lp then U.text(string.format('Eddig: %s pont (zónák)', U.t1(lp.sum or 0)), 15 * k, U.col.text, true) end
    return
  end
  local r = app.lastResult
  if not r or live.state ~= 'idle' then
    if live.state == 'idle' then U.text('Összesítő: futás után', 13 * k, U.col.dim) end
    return
  end
  if r.zeroRun then
    U.text('NULLÁS KÖR', 18 * k, U.col.red, true)
    U.text(table.concat(r.zeroReasons or {}, ', '), 12 * k, U.col.red)
  else
    U.text(string.format('Pont: %s', U.t1(r.final)), 18 * k, U.col.green, true)
    if (r.deductionTotal or 0) > 0 then U.text(string.format('levonás: −%s', U.t1(r.deductionTotal)), 12 * k, U.col.orange) end
  end
  local sp = r.split
  if sp then
    local txt = string.format('Line %s/%s · Angle %s/%s', U.t1(sp.line), U.t1(sp.lineMax), U.t1(sp.angle), U.t1(sp.angleMax))
    if (sp.styleMax or 0) > 0 then txt = txt .. string.format(' · Stílus %s/%s', U.t1(sp.style), U.t1(sp.styleMax)) end
    U.text(txt, 13 * k, U.col.text)
  end
  local f = r.faults or {}
  U.text(string.format('1K %d · 2K %d · Korr %d · Fal %d · Túl %d', f.oneWheel or 0, f.twoWheel or 0, f.corrections or 0, f.wallSaves or 0, f.overRotations or 0), 12 * k, U.col.dim)
  U.text(string.format('%.1f s · átlag %.0f km/h · max %.0f°', r.duration or 0, r.avgSpeed or 0, r.maxAngle or 0), 12 * k, U.col.dim)
end

-- Draws the enabled HUD modules in the chosen order.
function Live.drawDetails(app, width, big, k)
  k = k or 1
  local live = app.judge and app.judge:live() or { state = 'idle' }
  local ctx = {
    app = app, live = live, car = app.car(), s = app.lastSample, cfg = app.cfg,
    width = width, k = k, big = big, labelW = (big and 90 or 74) * k,
  }
  for _, m in ipairs(modlist.ordered(Live.hudState(app), Live.hudItems)) do
    if m.on and drawers[m.key] then drawers[m.key](ctx) end
  end
  return live
end

-- Spectating / following a car with the camera (0.3.14): whose run is shown.
function Live.watchedName(app)
  local idx = app.watchedCar
  if not idx or idx == 0 then return nil end
  local ok, n = pcall(ac.getDriverName, idx)
  return ok and n and n ~= '' and n or ('autó #' .. tostring(idx))
end
function Live.drawWatched(app, k)
  local n = Live.watchedName(app)
  if not n then return end
  U.text('Néző mód – ' .. n, 13 * (k or 1), U.col.purple, true)
  U.tip('A program azt az autót pontozza és mutatja, amelyiket a kamera követ. Ez az eredmény tájékoztató: a hivatalos pontot a pilóta saját programja küldi (Versenyzők fül). Beállítások → Figyelt autó.')
end

-- Élő tab ---------------------------------------------------------------------------------------------

local function faultRow(f)
  f = f or {}
  local items = {
    { '1 kerék', f.oneWheel or 0, U.col.red, 'Egykerekes pályaelhagyás: −1 pont darabonként, a 3. nullás kör (Beállítások → Pályaelhagyás).' },
    { '2+ kerék', f.twoWheel or 0, U.col.red, 'Kétkerekes pályaelhagyás: nullás kör.' },
    { 'Korrekció', f.corrections or 0, U.col.orange, 'Gyors szögesés majd visszanövés, vagy legyezés. Csak jelzés (alapból nem von le).' },
    { 'Fal utáni mentés', f.wallSaves or 0, U.col.orange, 'Korrekció falérintés után – külön kategória, csak jelzés.' },
    { 'Túldobás', f.overRotations or 0, U.col.yellow, 'A szög a túldobás határa (90°) fölött – csak jelzés.' },
    { 'Beforgás', f.spins or 0, U.col.red, 'A szög a beforgás határa (100°) fölött 0,25 mp-ig – nullás kör.' },
    { 'Fal (flow)', f.wallFlow or 0, U.col.cyan, 'Falhúzás folyamatos driftben – nem von le.' },
  }
  for i, it in ipairs(items) do
    if i > 1 then ui.sameLine(0, 6) end
    U.pill(string.format('%s: %d', it[1], it[2]), it[2] > 0 and it[3] or U.col.dim)
    U.tip(it[4])
  end
end

local editBlocks = false

local blockDraw = {}
blockDraw.gauge = function(app, live)
  ui.beginGroup()
  Live.drawDetails(app, 360, true)
  ui.endGroup()
end
blockDraw.faults = function(app, live)
  faultRow(live.faults)
  U.text('Vidd az egeret egy kategória fölé a szabályért.', 12, U.col.dim)
end
blockDraw.zones = function(app, live)
  local partial, sum = nil, nil
  if app.livePartial then partial, sum = app.livePartial.zones, app.livePartial.sum end
  if not partial then
    U.text('Futás közben itt látszik zónánként a Line, az Angle és a pont.', 13, U.col.dim)
    return
  end
  U.text(string.format('Zónák eddig: %s pont', U.t1(sum)), 16, U.col.text, true)
  for _, z in ipairs(partial) do
    ui.textColored(string.format('%-10s', z.name), U.col.text)
    ui.sameLine(110)
    ui.textColored(string.format('Line %s   Angle %s   = %s / %s', U.t1(z.line), U.t1(z.angle), U.t1(z.points), U.t1(z.maxPoints)), z.entered and U.col.text or U.col.dim)
  end
end
blockDraw.controls = function(app, live)
  if U.button('Futás lezárása most', 150, live.state ~= 'judging', 'A futást itt lezárja és kiértékeli (mintha átment volna a FINISH-en).') then app.finishNow() end
  ui.sameLine()
  if U.button('Futás elvetése', 110, live.state == 'idle', 'A futás eredmény nélkül elvész (nem mentődik).') then app.discardRun() end
  ui.sameLine()
  local rec = app.freeRecorder:active()
  if U.button(rec and 'Szabad felvétel leállítása' or 'Szabad felvétel indítása', 190, false,
    'Pályaterv nélkül is rögzíti a telemetriát (max. 10 perc). A fájlt elküldve offline is ki tudjuk értékelni.') then
    app.toggleFreeRecording()
  end
  if rec then ui.textColored(string.format('Felvétel: %.0f s', app.freeRecordTime()), U.col.red) end
end

local blockSub = {
  gauge = 'szög, sebesség, pedálok, hajtás', faults = 'kategóriák és szabályok', zones = 'élő részpontok', controls = 'lezárás, elvetés, felvétel',
}

function Live.drawTab(app)
  local live = app.judge and app.judge:live() or { state = 'idle' }
  Live.drawWatched(app, 1.1)
  U.text(stateNames[live.state] or live.state, 15, stateColors[live.state] or U.col.text, true)
  if live.zeroReasons and #live.zeroReasons > 0 then
    ui.sameLine(0, 12)
    U.text('NULLÁS KÖR: ' .. table.concat(live.zeroReasons, ', '), 15, U.col.red, true)
  end
  ui.sameLine(math.max(300, ui.availableSpaceX() - 150))
  if U.button(editBlocks and 'Elrendezés kész' or 'Elrendezés…', 140, false, 'Az Élő fül blokkjainak ki-be kapcsolása és sorrendje.') then
    editBlocks = not editBlocks
  end
  ui.offsetCursorY(4)
  if editBlocks then
    U.notice('liveLayout', 'info', 'Élő fül elrendezése', 'Kapcsold ki, amit nem használsz, a Fel / Le gombokkal pedig rendezd a blokkokat. A HUD saját modulokat használ (Beállítások → HUD modulok).')
    if U.moduleManager('live', Live.tabState(app), Live.tabBlocks) then app.saveSettings() end
    ui.separator()
  end
  for _, b in ipairs(modlist.ordered(Live.tabState(app), Live.tabBlocks)) do
    if b.on and blockDraw[b.key] and not (b.key == 'zones' and not platform.canSeeScores()) then
      U.collapsible('live_' .. b.key, b.label, { sub = blockSub[b.key], tip = b.desc }, function() blockDraw[b.key](app, live) end)
    end
  end
end

-- HUD window -----------------------------------------------------------------------------------------

function Live.drawHud(app)
  local ui_ = app.settings.ui
  local alpha = ui_.hudBg
  if type(alpha) ~= 'number' then alpha = 0.55 end
  if alpha > 0 then
    local sz = ui.windowSize()
    if sz then ui.drawRectFilled(vec2(0, 0), sz, rgbm(0.04, 0.04, 0.06, alpha), 8) end
  end
  local k = type(ui_.hudScale) == 'number' and geom.clamp(ui_.hudScale, 0.75, 1.5) or 1
  local w = math.max(160, ui.availableSpaceX())
  Live.drawWatched(app, k)
  Live.drawDetails(app, w, false, k)
  if not visibility.masterOn(app.settings) then
    U.text('Pályarajz: KI' .. (app.hotkeyText and ('  (' .. app.hotkeyText('zones') .. ')') or ''), 12 * k, U.col.dim)
  end
end

-- HUD settings: HUD window's settings (gear) button and Beállítások → HUD modulok.
function Live.drawHudSettings(app)
  local ui_ = app.settings.ui
  local changed = false
  U.text('HUD modulok', 15, U.col.text, true)
  U.text('Pipa = látszik. Fel / Le = sorrend. Az Élő fül „Driftszög és autó adatai” blokkja is ezt követi.', 12, U.col.dim)
  if U.moduleManager('hud', Live.hudState(app), Live.hudItems, Live.hudPresets) then changed = true end
  ui.offsetCursorY(6)
  U.text('Megjelenés', 14, U.col.text, true)
  ui.setNextItemWidth(200)
  local sc, scc = ui.slider('##hudScale', type(ui_.hudScale) == 'number' and ui_.hudScale or 1, 0.75, 1.5, 'Méret: %.2f×')
  U.tip('A HUD betűi és sávjai ekkora méretben jelennek meg (az ablakot is igazítsd hozzá).')
  if scc then ui_.hudScale = sc; changed = true end
  ui.sameLine(0, 12)
  ui.setNextItemWidth(200)
  local bg, bgc = ui.slider('##hudBg', (type(ui_.hudBg) == 'number' and ui_.hudBg or 0.55) * 100, 0, 100, 'Háttér: %.0f%%', 1)
  U.tip('A HUD sötét hátterének erőssége (0% = nincs saját háttér).')
  if bgc then ui_.hudBg = bg / 100; changed = true end
  if ui.checkbox('Szögmérő irányának megfordítása (ha a jobbos drift balra mutat)', ui_.hudFlipDir == true) then
    ui_.hudFlipDir = not (ui_.hudFlipDir == true); changed = true
  end
  if changed then app.saveSettings() end
  return changed
end

return Live
