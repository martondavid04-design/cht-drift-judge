-- CHT Drift Judge – result breakdown (FullSend-style) with zone cards and a 2D track map (CSP only).

local geom = require('src/geom')
local U = require('src/ui_common')
local layoutMod = require('src/layout')
local modlist = require('src/modlist')

local R = {}

-- Sections of the Eredmény tab (switchable / reorderable in Beállítások → Eredmény fül szekciói).
R.sections = {
  { key = 'summary', label = 'Összegzés', desc = 'Végső pontszám, levonások, hibák kategóriánként.' },
  { key = 'warnings', label = 'Figyelmeztetések', desc = 'Ha valami gyanús a futásban vagy a pályatervben – mit kell javítani.' },
  { key = 'zones', label = 'Zónák', desc = 'Zónakártyák: Line, Angle, pont. Kattints egyre a részletekért.' },
  { key = 'style', label = 'Stílus (mérhető)', desc = 'Indítás (5), folyamatosság (10), elkötelezettség (5) – a DM-szabálykönyv stíluspontjai, mérhető jelekből.' },
  { key = 'map', label = 'Pályatérkép és zóna részletei', desc = 'Felülnézet a nyomvonallal, a zónákkal és az eseményekkel.' },
  { key = 'events', label = 'Események', desc = 'Minden jelzés időrendben.' },
  { key = 'stats', label = 'Futás adatai', desc = 'Idő, sebességek, szögek.' },
}
local sectionDefaultOpen = { summary = true, warnings = true, zones = true, style = true, map = true, events = true, stats = false }

function R.sectionState(app)
  local ui_ = app.settings.ui
  if type(ui_.resultMods) ~= 'table' then ui_.resultMods = { order = {}, off = {} } end
  return modlist.normalize(ui_.resultMods, R.sections)
end

local selectedZone = 1

local colors = require('src/colors')
R.settings = nil -- set by R.draw (zone colours on the map)
local function mapZoneColor(t)
  local c = colors.get(R.settings, t)
  return rgbm(c[1], c[2], c[3], 1)
end
local gateCol = { start = rgbm(0.35, 0.9, 0.5, 1), judging = rgbm(0.9, 0.9, 0.9, 1), finish = rgbm(1, 0.4, 0.4, 1) }

local function header(res, meta)
  meta = meta or {}
  local h = meta.header or {}
  local title = (h.driver and h.driver ~= '' and h.driver or 'Pilóta') .. (h.car and h.car ~= '' and ('  ·  ' .. h.car) or '')
  U.sectionTitle('Részletes bontás', meta.time or h.time)
  U.text(title .. (meta.layoutName and ('  ·  ' .. meta.layoutName) or ''), 14, U.col.dim)
  if not res.finished then
    ui.textColored('A futás nem a FINISH vonalon ért véget (kézzel lezárva / újrapontozva).', U.col.orange)
  end
  ui.offsetCursorY(6)
end

local function cards(res, meta, app)
  local avail = ui.availableSpaceX()
  local gap = 10
  local w = math.max(130, (avail - gap * 4) / 5)
  local h = 76
  local f = res.faults or {}
  local sub = string.format('max %s', U.t1(res.maxTotal or 100))
  if res.split and (res.split.styleMax or 0) > 0 then
    sub = string.format('zónák %s + stílus %s', U.t1(res.zoneSum), U.t1(res.split.style))
  elseif (res.styleWeight or 0) > 0 then
    sub = string.format('zónák %s + stílus', U.t1(res.zoneSum))
  end
  U.card('##c1', w, h, 'Levonások előtt', U.t1(res.beforeDeductions), U.col.text, false, sub)
  ui.sameLine(0, gap)
  U.card('##c2', w, h, 'Korrekciók', tostring(f.corrections or 0), (f.corrections or 0) > 0 and U.col.orange or U.col.text)
  ui.sameLine(0, gap)
  U.card('##c2b', w, h, 'Fal utáni mentés', tostring(f.wallSaves or 0), (f.wallSaves or 0) > 0 and U.col.orange or U.col.text)
  ui.sameLine(0, gap)
  local offTxt = string.format('%d / %d', f.oneWheel or 0, f.twoWheel or 0)
  U.card('##c3', w, h, 'Pályaelhagyás (1 kerék / 2+ kerék)', offTxt, ((f.oneWheel or 0) + (f.twoWheel or 0)) > 0 and U.col.red or U.col.text)
  ui.sameLine(0, gap)
  if res.zeroRun then
    U.card('##c4', w, h, 'Végső pontszám', 'NULLÁS KÖR', U.col.red, true, table.concat(res.zeroReasons or {}, ', '))
  else
    U.card('##c4', w, h, 'Végső pontszám', U.t1(res.final), U.col.green, true,
      (res.deductionTotal or 0) > 0 and string.format('levonás: −%s', U.t1(res.deductionTotal)) or nil)
  end
  -- points by criterion (Drift Masters 2025: Line 60, Angle 20, Style 20)
  local sp = res.split
  if sp then
    ui.offsetCursorY(4)
    local items = { { 'Line', sp.line, sp.lineMax }, { 'Angle', sp.angle, sp.angleMax } }
    if (sp.styleMax or 0) > 0 then items[#items + 1] = { 'Stílus', sp.style, sp.styleMax } end
    local bw = math.max(120, (ui.availableSpaceX() - 24 * #items) / #items - 90)
    for i, it in ipairs(items) do
      if i > 1 then ui.sameLine(0, 24) end
      ui.beginGroup()
      U.text(string.format('%s  %s / %s', it[1], U.t1(it[2]), U.t1(it[3])), 14, U.col.text, true)
      U.bar(bw, 6, (it[3] or 0) > 0 and it[2] / it[3] or 0, U.scoreColor((it[3] or 0) > 0 and it[2] / it[3] * 100 or 0))
      ui.endGroup()
    end
  end
  U.text('Az értékek tizedre levágva jelennek meg; az összegek teljes pontossággal számolnak.', 12, U.col.dim)

  -- secondary fault pills
  local pills = {}
  if (f.overRotations or 0) > 0 then pills[#pills + 1] = { string.format('Túldobás: %d', f.overRotations), U.col.yellow } end
  if (f.spins or 0) > 0 then pills[#pills + 1] = { string.format('Beforgás: %d', f.spins), U.col.red } end
  if (f.wallFlow or 0) > 0 then pills[#pills + 1] = { string.format('Falérintés flowban: %d', f.wallFlow), U.col.cyan } end
  if (f.straight or 0) > 0 then pills[#pills + 1] = { string.format('Kiegyenesedés: %d', f.straight), U.col.dim } end
  if (f.carContacts or 0) > 0 then pills[#pills + 1] = { string.format('Autóval érintkezés: %d', f.carContacts), U.col.cyan } end
  if (f.slow or 0) > 0 then pills[#pills + 1] = { 'Minimális tempó alatt', U.col.orange } end
  for i, p in ipairs(pills) do
    if i > 1 then ui.sameLine(0, 6) end
    U.pill(p[1], p[2])
  end
  for _, d in ipairs(res.deductions or {}) do
    ui.textColored(string.format('−%s  %s', U.t1(d.amount), d.label), U.col.orange)
  end
  R.judgeDeduction(res, meta, app)
end

-- Judge's deduction (A12, A16): the judges take points off the program's score case by case, using the
-- program's notes (Események: corrections, over-rotation, wall touches – with time and zone). There is
-- no fixed amount: the judge types it in (default 0) with an optional note. Saved per run file.
function R.judgeDeduction(res, meta, app)
  if not app or not app.getDeduction then return end
  meta = meta or {}
  ui.offsetCursorY(8)
  U.text('Bírói levonás', 14, U.col.text, true)
  U.tip('A bírók a program pontjából vonnak le, esettől függően (A16). Az alapérték 0; a levonás és a megjegyzés a futás mellé mentődik.')
  if not meta.file then
    U.text('A futás mentése folyamatban (vagy ez egy újrapontozott eredmény) – levonás mentett futáshoz írható be.', 12, U.col.dim)
    return
  end
  local d = app.getDeduction(meta.file) or {}
  local amount = tonumber(d.amount) or 0
  local note = tostring(d.note or '')
  local v, ch = U.numberBox('ded_' .. meta.file, amount, 0, 100, '%.1f', 64, 'A bíró levonása pontban (0–100).', 0, 100)
  if ch then app.setDeduction(meta.file, v, note); amount = v end
  ui.sameLine(0, 6)
  U.text('pont', 13, U.col.dim)
  ui.sameLine(0, 12)
  ui.setNextItemWidth(math.max(200, ui.availableSpaceX() - 10))
  local F = ui.InputTextFlags
  local nt, nch = ui.inputText('Megjegyzés (pl. korrekció az OZ 2-ben)##dedNote_' .. meta.file, note, bit.bor(F.Placeholder or 0))
  if nch and nt ~= nil and nt ~= note then app.setDeduction(meta.file, amount, nt) end
  if res.zeroRun then
    U.text('Nullás kör: a levonás nem változtat rajta.', 12, U.col.dim)
  elseif amount > 0 then
    U.text(string.format('Végső a bírói levonás után: %s pont (program: %s, levonás: −%s)', U.t1(math.max(0, (res.final or 0) - amount)), U.t1(res.final), U.t1(amount)), 15, U.col.green, true)
  end
end

local function zoneCards(res)
  U.text('Kattints egy zónára a részletekért (a Pályatérkép szekcióban jelennek meg).', 12, U.col.dim)
  local zones = res.zones or {}
  if #zones == 0 then ui.textColored('Nincs pontozott zóna.', U.col.dim) return end
  local avail = ui.availableSpaceX()
  local gap = 10
  local w = 190
  local perRow = math.max(1, math.floor((avail + gap) / (w + gap)))
  local h = 112
  for i, z in ipairs(zones) do
    if (i - 1) % perRow ~= 0 then ui.sameLine(0, gap) end
    local p = ui.getCursor()
    if ui.invisibleButton('##zone' .. i, vec2(w, h)) then selectedZone = i end
    local sel = selectedZone == i
    ui.drawRectFilled(p, p + vec2(w, h), sel and U.col.cardHi or U.col.card, 6)
    ui.drawRect(p, p + vec2(w, h), sel and U.col.borderHi or U.col.border, 6, nil, 1)
    U.drawText(string.format('%s  ·  %s', z.name, layoutMod.zoneTypeShort[z.type] or z.type), 13, p + vec2(12, 10), U.col.dim)
    local sc = U.t1(z.score)
    local m = U.measure(sc, 22, true)
    U.drawText(sc, 22, p + vec2(w - 12 - m.x, 6), U.scoreColor(z.score), true)
    U.drawText(string.format('Line  %s', U.t1(z.line)), 13, p + vec2(12, 40), U.col.text)
    local at = string.format('Angle  %s', U.t1(z.angle))
    local am = U.measure(at, 13)
    U.drawText(at, 13, p + vec2(w - 12 - am.x, 40), U.col.text)
    if (z.nogo or 0) > 0 then
      U.drawText(string.format('No-go  −%s', U.t1(z.nogo)), 13, p + vec2(12, 60), U.col.red)
    elseif z.type == 'TNG' or z.type == 'IC' then
      U.drawText(z.minDist and string.format('Legkisebb táv  %.2f m', z.minDist) or 'Nem érintette', 13, p + vec2(12, 60), U.col.dim)
    end
    local pt = string.format('%s / %s pont', U.t1(z.points), U.t1(z.maxPoints or 0))
    U.drawText(pt, 12, p + vec2(12, 80), U.col.dim)
    -- bar
    local bp = p + vec2(12, h - 14)
    local bw = w - 24
    ui.drawRectFilled(bp, bp + vec2(bw, 4), rgbm(1, 1, 1, 0.08), 2)
    ui.drawRectFilled(bp, bp + vec2(bw * geom.clamp(z.score / 100, 0, 1), 4), U.scoreColor(z.score), 2)
  end
end

-- Style section of results made before 0.3.7 (four information-only parts).
local function styleSectionOld(st, res)
  local w = res.styleWeight or 0
  U.text(string.format('Stílus: %s  ·  %s', U.t1(st.score),
    w > 0 and string.format('az összpont %d%%-a', math.floor(w * 100 + 0.5)) or 'csak információ – nem számított bele az összpontba'), 14, U.col.text, true)
  U.text('Ez a futás a 0.3.7 előtti stílusmérést használta; az Újrapontozás a mostani szerint számolja újra.', 12, U.col.dim)
  local items = {
    { 'Indítás', st.initiation, function(p) return string.format('%.0f° · %.0f km/h az indításnál', p.angle or 0, p.speed or 0) end },
    { 'Egyenletesség', st.smoothness, function(p) return p.wobble and string.format('±%.1f° ingadozás', p.wobble) or 'kevés adat' end },
    { 'Irányváltás', st.transitions, function(p) return (p.count or 0) > 0 and string.format('%.2f s átlag · %d db', p.avgTime or 0, p.count) or 'nem volt irányváltás' end },
    { 'Lendület', st.momentum, function(p) return p.retention and string.format('%.0f%% sebességtartás', p.retention * 100) or 'kevés adat' end },
  }
  local avail = ui.availableSpaceX()
  local gap = 10
  local cw = math.max(150, (avail - gap * 3) / 4)
  for i, it in ipairs(items) do
    if i > 1 then ui.sameLine(0, gap) end
    local part = it[2] or {}
    local sc = part.score
    U.card('##st' .. i, cw, 76, it[1], sc and U.t1(sc) or '–', sc and U.scoreColor(sc) or U.col.dim, false, it[3](part))
  end
end

local function pctText(v) return type(v) == 'number' and (U.t1(v) .. '%') or '–' end

local function styleSection(res)
  local st = res.style
  if not st then ui.textColored('Ehhez a futáshoz nincs stílusadat.', U.col.dim) return end
  if not st.fluidity then styleSectionOld(st, res) return end
  local sp = res.split or {}
  if (sp.styleMax or 0) > 0 then
    U.text(string.format('Stílus: %s / %s pont  (%s%%)', U.t1(sp.style), U.t1(sp.styleMax), U.t1(st.score)), 14, U.col.text, true)
  else
    U.text(string.format('Stílus: %s%%  ·  csak információ – nem számít bele az összpontba', U.t1(st.score)), 14, U.col.text, true)
  end
  U.text('A Drift Masters 2025 stíluspontjai (1.6), a telemetriából mérhető jelekkel. A bírók a korrekciókért, túldobásért és falérintésért külön vonnak le.', 12, U.col.dim)
  local ini, flu, com = st.initiation or {}, st.fluidity or {}, st.commitment or {}
  local function sub(p, k) return type(p) == 'table' and type(p[k]) == 'table' and p[k] or {} end
  local early, rate, entry = sub(ini, 'early'), sub(ini, 'rate'), sub(ini, 'entry')
  local rot, lock, flow = sub(flu, 'rotation'), sub(flu, 'lock'), sub(flu, 'flow')
  local thr, pace = sub(com, 'throttle'), sub(com, 'pace')
  local tempo = type(pace.tempo) == 'table' and pace.tempo or nil
  local parts = {
    { 'Indítás', ini, {
      { 'Korai indítás', early.score, ini.drifted == false and 'nem volt drift' or ((early.dist or 0) < 0.5 and 'már a JUDGING vonalon driftelt' or string.format('%.0f m-rel a JUDGING után', early.dist or 0)) },
      { 'Szögfelvétel', rate.score, rate.time and string.format('%.2f s a célszög 80%%-áig', rate.time) or 'nem érte el a célszög 80%-át' },
      { 'Szögvesztés nélkül', entry.score, (entry.drop or 0) > 0 and string.format('%.0f° szögvesztés az indításban', entry.drop) or 'nem vesztett szöget' },
    } },
    { 'Folyamatosság', flu, {
      { 'Forgás (irányváltás)', rot.score, (rot.count or 0) > 0 and string.format('%.2f s átlag · %d db', rot.avgTime or 0, rot.count) or 'nem volt irányváltás' },
      { 'Lock to lock', lock.score, (lock.count or 0) > 0 and string.format('%.0f° átlag a váltások két oldalán', lock.avgAngle or 0) or 'nem volt irányváltás' },
      { 'Flow (egyenletesség)', flow.score, flow.wobble and string.format('±%.1f° szögingadozás', flow.wobble) or 'kevés adat' },
    } },
    { 'Elkötelezettség', com, {
      { 'Gázadás', thr.score, thr.liftShare and string.format('az út %.0f%%-a 30%% alatti gázzal', thr.liftShare * 100) or 'kevés adat' },
      { 'Tempótartás', pace.consistency or pace.score, pace.ratio and string.format('leglassabb 10%%: %.0f km/h · közép: %.0f km/h', pace.p10 or 0, pace.median or 0) or 'kevés adat' },
      { 'Minimális tempó', tempo and tempo.score, tempo and string.format('átlag %.0f km/h · min. %.0f, teljes %.0f km/h', tempo.avg or 0, tempo.min or 0, tempo.full or 0)
        or 'a pályatervben nincs megadva (Pálya fül → Tempó)' },
    } },
  }
  local avail = ui.availableSpaceX()
  local gap = 12
  local cw = math.max(220, (avail - gap * 2) / 3)
  for i, pt in ipairs(parts) do
    if i > 1 then ui.sameLine(0, gap) end
    ui.beginGroup()
    local p = pt[2]
    local val = (sp.styleMax or 0) > 0 and string.format('%s / %s', U.t1(p.points or 0), U.t1(p.max or 0)) or pctText(p.score)
    U.card('##stp' .. i, cw, 76, pt[1], val, U.scoreColor(p.score or 0), false, string.format('%s · súly %d%%', pctText(p.score), math.floor((p.weight or 0) * 100 + 0.5)))
    for j, it in ipairs(pt[3]) do
      ui.pushID('sts' .. i .. '_' .. j)
      U.text(it[1], 13, U.col.text, true)
      ui.sameLine(math.max(140, cw - 70))
      U.text(pctText(it[2]), 13, type(it[2]) == 'number' and U.scoreColor(it[2]) or U.col.dim, true)
      U.text(it[3], 12, U.col.dim)
      ui.popID()
    end
    ui.endGroup()
  end
end

local function zoneDetail(res)
  local z = (res.zones or {})[selectedZone]
  if not z then return end
  ui.beginGroup()
  U.text(z.name, 18, U.col.text, true)
  U.text((layoutMod.zoneTypeNames[z.type] or z.type), 12, U.col.dim)
  ui.offsetCursorY(6)
  local function row(label, value, color)
    ui.textColored(label, U.col.dim)
    ui.sameLine(170)
    ui.textColored(value, color or U.col.text)
  end
  row(z.entered and 'Értékelve' or 'Nem érintette', '')
  if z.type == 'TNG' or z.type == 'IC' then
    row(z.type == 'IC' and 'Legkisebb távolság (első lökhárító – pont)' or 'Legkisebb távolság', z.minDist and string.format('%.2f m', z.minDist) or '–')
    row('Közelség pont', U.t1(z.lineGross) .. '%')
  else
    row('Bruttó lefedettség', U.t1(z.coverage) .. '%')
    row('Mélység', U.t1(z.depth) .. '%')
    row('Line (mélységgel)', U.t1(z.lineGross) .. '%')
  end
  row('No-go lefedettség', U.t1(z.nogo) .. '%', (z.nogo or 0) > 0 and U.col.red or nil)
  if z.avgSpeed then
    row('Átlagsebesség a zónában', string.format('%.0f km/h', z.avgSpeed))
    row('Belépő → kilépő sebesség', string.format('%.0f → %.0f km/h', z.entrySpeed or 0, z.exitSpeed or 0))
  end
  row('Line', U.t1(z.line))
  row('Angle', U.t1(z.angle))
  ui.separator()
  row('Zónapont', U.t1(z.score), U.scoreColor(z.score))
  row('Hozzájárulás', string.format('%s / %s pont', U.t1(z.points), U.t1(z.maxPoints or 0)))
  if z.linePoints then
    row('Ebből Line / Angle', string.format('%s + %s pont', U.t1(z.linePoints), U.t1(z.anglePoints or 0)))
  end
  if z.weight and math.abs((z.weight or 0) - (z.maxPoints or 0)) > 0.01 then
    row('Súly a pályatervben', string.format('%g (a zónák pontjára arányosítva)', z.weight))
  end
  ui.endGroup()
end

-- 2D map of the run ---------------------------------------------------------------------------------

local function bounds(l, res)
  local x0, z0, x1, z1 = math.huge, math.huge, -math.huge, -math.huge
  local function add(x, z) x0, z0, x1, z1 = math.min(x0, x), math.min(z0, z), math.max(x1, x), math.max(z1, z) end
  if l then
    for _, g in pairs(l.gates or {}) do add(g.a.x, g.a.z); add(g.b.x, g.b.z) end
    for _, zz in ipairs(l.zones or {}) do for _, p in ipairs(zz.points) do add(p.x, p.z) end end
  end
  for _, t in ipairs(res.trace or {}) do add(t[1], t[2]) end
  if x0 == math.huge then return nil end
  return x0, z0, x1, z1
end

function R.drawMap(res, l, compiled, size)
  local x0, z0, x1, z1 = bounds(l, res)
  local p = ui.getCursor()
  ui.drawRectFilled(p, p + size, rgbm(0.04, 0.04, 0.05, 1), 6)
  ui.dummy(size)
  if not x0 then return end
  local pad = 18
  local sw, sh = size.x - pad * 2, size.y - pad * 2
  local wx, wz = math.max(1, x1 - x0), math.max(1, z1 - z0)
  local scale = math.min(sw / wx, sh / wz)
  local ox = p.x + pad + (sw - wx * scale) / 2
  local oz = p.y + pad + (sh - wz * scale) / 2
  local function sp(x, z) return vec2(ox + (x - x0) * scale, oz + (z - z0) * scale) end

  -- trace
  local tr = res.trace or {}
  for i = 1, #tr - 1 do
    local a, b = tr[i], tr[i + 1]
    local t = geom.clamp((a[3] or 0) / 75, 0, 1)
    ui.drawLine(sp(a[1], a[2]), sp(b[1], b[2]), rgbm(1, 1, 1, 0.25 + 0.6 * t), 2)
  end
  -- zones
  if l then
    for i, zz in ipairs(l.zones or {}) do
      local c = mapZoneColor(zz.type)
      local sel = selectedZone == i
      for k = 1, #zz.points - 1 do
        ui.drawLine(sp(zz.points[k].x, zz.points[k].z), sp(zz.points[k + 1].x, zz.points[k + 1].z), c, sel and 5 or 3)
      end
      if zz.type == 'IC' and zz.points[1] then
        ui.drawCircleFilled(sp(zz.points[1].x, zz.points[1].z), sel and 6 or 4.5, c, 12)
      end
      for _, poly in ipairs(zz.nogo or {}) do
        for k = 1, #poly do
          local a, b = poly[k], poly[k % #poly + 1]
          ui.drawLine(sp(a.x, a.z), sp(b.x, b.z), U.col.red, 1.5)
        end
      end
      if #zz.points > 0 then
        local mid = zz.points[math.max(1, math.floor((#zz.points + 1) / 2))]
        local q = sp(mid.x, mid.z)
        local label = (layoutMod.zoneTypeShort[zz.type] or '') .. ' ' .. i
        local m = U.measure(label, 12, true)
        ui.drawRectFilled(q + vec2(8, -10), q + vec2(16 + m.x, 10), rgbm(0, 0, 0, 0.7), 4)
        U.drawText(label, 12, q + vec2(12, -8), U.col.text, true)
      end
    end
    for key, g in pairs(l.gates or {}) do
      local a, b = sp(g.a.x, g.a.z), sp(g.b.x, g.b.z)
      ui.drawLine(a, b, gateCol[key] or U.col.white, 2)
      local name = ({ start = 'START', judging = 'JUDGING', finish = 'FINISH' })[key] or key
      local m = U.measure(name, 12, true)
      ui.drawRectFilled(b + vec2(6, -10), b + vec2(14 + m.x, 10), rgbm(0, 0, 0, 0.7), 4)
      U.drawText(name, 12, b + vec2(10, -8), gateCol[key] or U.col.white, true)
    end
  end
  -- events
  for _, e in ipairs(res.events or {}) do
    if e.x and e.z then
      local c = U.eventColors[e.type] or U.col.white
      ui.drawCircleFilled(sp(e.x, e.z), 5, c, 12)
    end
  end
end

local function legend()
  local items = {
    { 'Zónák', U.col.purple }, { 'Korrekciók', U.col.orange }, { 'Pályaelhagyás / beforgás', U.col.red },
    { 'Túldobás', U.col.yellow }, { 'Érintés', U.col.cyan },
  }
  for i, it in ipairs(items) do
    if i > 1 then ui.sameLine(0, 14) end
    local p = ui.getCursor()
    ui.drawCircleFilled(p + vec2(6, 9), 5, it[2], 12)
    ui.dummy(vec2(14, 18))
    ui.sameLine(0, 2)
    ui.textColored(it[1], U.col.dim)
  end
end

local function events(res)
  local ev = res.events or {}
  if #ev == 0 then ui.textColored('Nem volt jelzett esemény.', U.col.dim) return end
  for _, e in ipairs(ev) do
    ui.textColored(string.format('%6.2f s', e.t or 0), U.col.dim)
    ui.sameLine(70)
    ui.textColored(e.label or e.type, U.eventColors[e.type] or U.col.text)
  end
end

local function stats(res, app, l)
  local rows = {
    { 'Időtartam (JUDGING–FINISH)', string.format('%.2f s', res.duration or 0) },
    { 'Sebesség a JUDGING vonalnál', string.format('%.0f km/h', res.entrySpeed or 0) },
    { 'Szög a JUDGING vonalnál', string.format('%.0f°', res.entryAngle or 0) },
    { 'Átlagsebesség (út szerint)', string.format('%.0f km/h', res.avgSpeed or 0) .. (res.tempo and res.tempo.min and string.format('  ·  a pályaterv minimuma %.0f km/h', res.tempo.min) or '') },
    { 'Legkisebb sebesség', string.format('%.0f km/h', res.minSpeed or 0) },
    { 'Átlagos szög (távolság szerint)', string.format('%.1f°', res.avgAngle or 0) },
    { 'Legnagyobb szög', string.format('%.1f°', res.maxAngle or 0) },
  }
  for _, r in ipairs(rows) do
    ui.textColored(r[1], U.col.dim)
    ui.sameLine(230)
    ui.text(r[2])
  end
  if app and l == app.layout and not res.zeroRun and (res.avgSpeed or 0) > 10 then
    local full = math.floor(res.avgSpeed + 0.5)
    if U.button(string.format('Ez legyen a pálya referencia-tempója (minimum %d, teljes pont %d km/h)##tempoRes', math.floor(full * 0.9 + 0.5), full), 0, false,
      'A pályaterv minimális tempója ennek a futásnak az átlagsebességéből: a 90%-a a minimum, a teljes átlag a 100%. Utána mentsd el a pályatervet.') then
      app.setTempoFromResult(res)
    end
  end
end

local function warningsSection(res, app, l)
  local items = res.warningItems
  if not items then
    items = {}
    for _, w in ipairs(res.warnings or {}) do items[#items + 1] = { kind = 'other', text = w, zones = {} } end
  end
  for i, w in ipairs(items) do
    if w.kind == 'zoneLine' then
      local canJump = app and l == app.layout and w.zones and w.zones[1]
      local b = U.notice('rw' .. i, 'error', 'A vonal nem a pálya szélén van', w.text ..
        ' Teendő: a Pálya fülön rajzold újra a vonalat a pálya szélén, majd menj egy tesztkört.',
        canJump and { { 'Zóna megnyitása a Pálya fülön', 'Átvált a Pálya fülre, és kijelöli a zónát.' } } or nil)
      if b == 1 and app then app.openZone(w.zones[1]) end
    else
      U.notice('rw' .. i, 'warn', 'Ellenőrizd', w.text)
    end
  end
end

local function warningCount(res)
  if res.warningItems then return #res.warningItems end
  return #(res.warnings or {})
end

local function mapSection(res, l, compiled)
  local avail = ui.availableSpaceX()
  local mapW = math.max(260, avail - 300)
  ui.beginGroup()
  R.drawMap(res, l, compiled, vec2(mapW, 360))
  legend()
  ui.endGroup()
  ui.sameLine(0, 14)
  ui.beginGroup()
  zoneDetail(res)
  ui.endGroup()
end

-- res: result table; meta: {header, time, layoutName}; l: layout used (for the map); compiled optional;
-- app optional (for the "jump to zone" actions).
function R.draw(res, meta, l, compiled, app)
  if not res then
    U.notice('nores', 'info', 'Még nincs eredmény', 'Tegyél meg egy futást START → JUDGING → FINISH között, vagy tölts be egyet a Futások fülön.')
    return
  end
  R.settings = app and app.settings or nil
  header(res, meta)
  local state = app and R.sectionState(app) or modlist.normalize({}, R.sections)
  for _, sec in ipairs(modlist.ordered(state, R.sections)) do
    if sec.on then
      local k = sec.key
      local opts = { defaultOpen = sectionDefaultOpen[k], tip = sec.desc }
      if k == 'summary' then
        opts.sub = res.zeroRun and 'NULLÁS KÖR' or ('végső: ' .. U.t1(res.final))
        opts.badge = res.zeroRun and 'NULLÁS' or nil
        opts.badgeColor = U.col.red
        local ded = app and app.getDeduction and meta and meta.file and app.getDeduction(meta.file)
        if ded and not res.zeroRun and (ded.amount or 0) > 0 then
          opts.sub = string.format('végső: %s (bírói levonás után)', U.t1(math.max(0, (res.final or 0) - ded.amount)))
        end
        U.collapsible('res_summary', sec.label, opts, function() cards(res, meta, app) end)
      elseif k == 'warnings' then
        local n = warningCount(res)
        if n > 0 then
          opts.badge = string.format('%d teendő', n)
          opts.badgeColor = U.col.orange
          opts.level = 'warn'
          opts.defaultOpen = true
          U.collapsible('res_warnings', sec.label, opts, function() warningsSection(res, app, l) end)
        end
      elseif k == 'zones' then
        opts.sub = string.format('%d zóna', #(res.zones or {}))
        U.collapsible('res_zones', sec.label, opts, function() zoneCards(res) end)
      elseif k == 'style' then
        if res.style and res.split and (res.split.styleMax or 0) > 0 then
          opts.sub = string.format('%s / %s pont', U.t1(res.split.style), U.t1(res.split.styleMax))
        else
          opts.sub = res.style and ('összesen ' .. U.t1(res.style.score) .. '% · csak információ') or nil
        end
        U.collapsible('res_style', sec.label, opts, function() styleSection(res) end)
      elseif k == 'map' then
        U.collapsible('res_map', sec.label, opts, function() mapSection(res, l, compiled) end)
      elseif k == 'events' then
        opts.sub = string.format('%d esemény', #(res.events or {}))
        U.collapsible('res_events', sec.label, opts, function() events(res) end)
      elseif k == 'stats' then
        opts.sub = string.format('%.1f s · átlag %.0f km/h', res.duration or 0, res.avgSpeed or 0)
        U.collapsible('res_stats', sec.label, opts, function() stats(res, app, l) end)
      end
    end
  end
end

return R
