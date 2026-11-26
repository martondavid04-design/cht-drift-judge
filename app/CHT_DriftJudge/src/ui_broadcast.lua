-- CHT Drift Judge – broadcaster HUD (B03, B04, 0.4.0): a full-screen overlay for the stream (Streamlabs,
-- designed for 1920×1080, scaled to the screen).
--   tandem battle: pairing bar (round, seeds, who leads), the two cars side by side (angle, speed, RPM,
--                  gear, pedals, drive indicator), proximity meter, contact flag, the winner when decided;
--   qualifying / solo: the followed car's data, its last result, the qualifying table;
--   0.4.1: the whole bracket (Top 32 … final, the winners in green, the current battle marked) and the
--   qualifying standings in big – the race director chooses (Verseny tab → Közvetítői kép), or the
--   broadcaster's own setting; Automatikus = the bracket 10 s after a decision, until the next battle.
-- Online: Beállítások → Közvetítői HUD (or the Verseny tab); installed app: the „CHT Közvetítő HUD”
-- window (it draws over the whole screen wherever the window is).

local U = require('src/ui_common')
local geom = require('src/geom')
local Live = require('src/ui_live')
local bracket = require('src/bracket')

local B = {}

local panelBg = rgbm(0.03, 0.035, 0.05, 0.82)
local panelLine = rgbm(1, 1, 1, 0.14)
local leadCol = rgbm(0.3, 0.85, 1.0, 1)
local chaseCol = rgbm(0.75, 0.5, 1.0, 1)

local function car(i)
  if i == nil then return nil end
  local ok, c = pcall(ac.getCar, i)
  if ok and c and c.isConnected ~= false then return c end
  return nil
end

local function nameOf(i)
  local ok, n = pcall(ac.getDriverName, i)
  return ok and n and tostring(n) or '?'
end

local function angleOf(c, cfg)
  if not c or (c.speedKmh or 0) < (cfg and cfg.minSpeed or 15) then return 0, 0 end
  local lv = c.localVelocity
  if not lv then return 0, 0 end
  return geom.driftAngle(lv.x or 0, lv.z or 0)
end

-- Panel helpers (o = origin of the 1920×1080 canvas on this window, k = scale)
local function rect(o, k, x, y, w, h, col, r)
  ui.drawRectFilled(o + vec2(x * k, y * k), o + vec2((x + w) * k, (y + h) * k), col or panelBg, (r or 8) * k)
end
local function frame(o, k, x, y, w, h, col)
  ui.drawRect(o + vec2(x * k, y * k), o + vec2((x + w) * k, (y + h) * k), col or panelLine, 8 * k, nil, 1.5)
end
local function text(o, k, s, size, x, y, col, bold)
  U.drawText(tostring(s), size * k, o + vec2(x * k, y * k), col or U.col.text, bold)
end
local function textC(o, k, s, size, cx, y, col, bold)
  local m = U.measure(tostring(s), size * k, bold)
  U.drawText(tostring(s), size * k, o + vec2(cx * k - m.x / 2, y * k), col or U.col.text, bold)
end
local function textR(o, k, s, size, rx, y, col, bold)
  local m = U.measure(tostring(s), size * k, bold)
  U.drawText(tostring(s), size * k, o + vec2(rx * k - m.x, y * k), col or U.col.text, bold)
end
local function hbar(o, k, x, y, w, h, f, col)
  rect(o, k, x, y, w, h, rgbm(1, 1, 1, 0.08), h / 2)
  f = geom.clamp(f or 0, 0, 1)
  if f > 0 then rect(o, k, x, y, w * f, h, col, h / 2) end
end

local gearNames = { [-1] = 'R', [0] = 'N' }

-- One car: name, role badge, angle gauge, speed, gear / RPM, pedals, drive indicator.
local function carPanel(app, o, k, x, y, idx, role)
  local c = car(idx)
  local w, h = 330, 470
  rect(o, k, x, y, w, h)
  local rc = role == 'LEAD' and leadCol or (role == 'CHASE' and chaseCol or U.col.accent)
  frame(o, k, x, y, w, h, rc)
  text(o, k, idx and nameOf(idx) or '–', 26, x + 16, y + 12, U.col.text, true)
  if role then
    local m = U.measure(role, 16 * k, true)
    rect(o, k, x + w - 16 - m.x / k - 16, y + 16, m.x / k + 16, 26, rc, 6)
    text(o, k, role, 16, x + w - 16 - m.x / k - 8, y + 19, rgbm(0, 0, 0, 1), true)
  end
  if not c then
    text(o, k, 'nincs a szerveren', 16, x + 16, y + 60, U.col.dim)
    return
  end
  local cfg = app.cfg
  local a, dir = angleOf(c, cfg)
  -- gauge (uses the layout cursor: put it where the panel is)
  local gsize = 240
  ui.setCursorX(o.x + (x + (w - gsize) / 2) * k)
  ui.setCursorY(o.y + (y + 52) * k)
  Live.angleGauge(a, dir, gsize * k, cfg, app.settings.ui.hudFlipDir == true)
  local yy = y + 52 + gsize * 0.86 + 4
  text(o, k, string.format('%.0f', c.speedKmh or 0), 44, x + 16, yy, U.col.text, true)
  text(o, k, 'km/h', 16, x + 110, yy + 22, U.col.dim)
  local g = c.gear or 0
  textR(o, k, gearNames[g] or tostring(g), 44, x + w - 16, yy, U.col.yellow, true)
  yy = yy + 58
  local lim = (c.rpmLimiter and c.rpmLimiter > 0) and c.rpmLimiter or 8000
  local f = (c.rpm or 0) / lim
  hbar(o, k, x + 16, yy, w - 32, 10, f, f > 0.95 and U.col.red or U.col.purple)
  textR(o, k, string.format('%.0f rpm', c.rpm or 0), 13, x + w - 16, yy + 12, U.col.dim)
  yy = yy + 30
  local pressed = Live.clutchPressed(c)
  local bars = { { 'GÁZ', c.gas, U.col.green }, { 'FÉK', c.brake, U.col.red }, { 'KÉZIFÉK', c.handbrake, U.col.orange }, { 'KUPLUNG', pressed, U.col.yellow } }
  for i, bdef in ipairs(bars) do
    local by = yy + (i - 1) * 20
    text(o, k, bdef[1], 12, x + 16, by - 2, U.col.dim, true)
    hbar(o, k, x + 100, by, w - 116, 10, bdef[2], bdef[3])
  end
  yy = yy + 4 * 20 + 2
  local engaged = (c.gear or 0) ~= 0 and pressed < 0.5 and (c.gas or 0) > 0.05
  text(o, k, 'HAJTÁS', 12, x + 16, yy, U.col.dim, true)
  text(o, k, engaged and 'VAN' or 'NINCS', 15, x + 100, yy - 2, engaged and U.col.green or U.col.orange, true)
end

-- Proximity meter (0–8 m: green up to 3 m, yellow 3–4 m, orange above – A14 / A17).
local function proximity(o, k, d, contacts, pass)
  local x, y, w, h = 660, 960, 600, 92
  rect(o, k, x, y, w, h)
  textC(o, k, 'KÖZELSÉG', 13, x + w / 2, y + 8, U.col.dim, true)
  local col = d == nil and U.col.dim or (d <= 3 and U.col.green or (d <= 4 and U.col.yellow or U.col.orange))
  textC(o, k, d and string.format('%.1f m', d) or '–', 30, x + w / 2, y + 24, col, true)
  local bx, by, bw, bh = x + 20, y + 66, w - 40, 10
  rect(o, k, bx, by, bw * 3 / 8, bh, rgbm(0.35, 0.88, 0.55, 0.35), 3)
  rect(o, k, bx + bw * 3 / 8, by, bw / 8, bh, rgbm(1, 0.86, 0.3, 0.35), 3)
  rect(o, k, bx + bw * 4 / 8, by, bw / 2, bh, rgbm(1, 0.62, 0.22, 0.25), 3)
  if d then
    local px = bx + bw * geom.clamp(d / 8, 0, 1)
    ui.drawLine(o + vec2(px * k, (by - 4) * k), o + vec2(px * k, (by + bh + 4) * k), rgbm(1, 1, 1, 1), 3 * k)
  end
  if contacts and contacts > 0 then textR(o, k, 'KONTAKTUS', 18, x + w - 16, y + 30, U.col.red, true) end
  if pass then text(o, k, 'ELŐZÉS', 18, x + 16, y + 30, U.col.orange, true) end
end

-- Current battle as this PC knows it: { b (battle or nil), names, cars, leadSide, phase, run, pair, winner }
local function battleState(app)
  local E = app.event
  if not E or not E.ev then return nil end
  if E.isDirector() then
    local b, cur = E.current()
    if not b then return nil end
    return { b = b, a = b.a, bName = b.b, carA = E.carOf(b.a), carB = E.carOf(b.b), leadSide = cur and cur.leadSide or E.nextLead(b),
      phase = cur and cur.state or 'idle', run = cur and cur.run or 0, pair = E.pairOf(b), winner = b.winner,
      round = E.ev.bracket.rounds[b.round] and E.ev.bracket.rounds[b.round].name }
  end
  local lv = E.live
  if not lv or lv.battle == '' or lv.eventId ~= E.ev.id then return nil end
  local b = E.battle(lv.battle)
  return { b = b, a = lv.a ~= '' and lv.a or (b and b.a), bName = lv.b ~= '' and lv.b or (b and b.b), carA = lv.carA, carB = lv.carB,
    leadSide = lv.leadSide, phase = lv.phase, run = lv.run, pair = lv.pair, winner = lv.winner or (b and b.winner),
    round = b and E.ev.bracket and E.ev.bracket.rounds[b.round] and E.ev.bracket.rounds[b.round].name or nil }
end

local function pairingBar(o, k, st)
  local x, y, w, h = 510, 18, 900, 96
  rect(o, k, x, y, w, h)
  frame(o, k, x, y, w, h, U.col.accent)
  textC(o, k, (st.round or 'Csata') .. (st.pair == 2 and ' · ONE MORE TIME' or '') .. (st.run and st.run > 0 and string.format(' · %d. futás', st.run) or ''), 15, x + w / 2, y + 8, U.col.dim, true)
  local b = st.b
  local sa, sb = b and b.seedA, b and b.seedB
  local la = st.leadSide == 'a' and 'LEAD' or (st.leadSide == 'b' and 'CHASE' or nil)
  local lb = st.leadSide == 'b' and 'LEAD' or (st.leadSide == 'a' and 'CHASE' or nil)
  local wa, wb = st.winner == 'a', st.winner == 'b'
  textR(o, k, (sa and ('(' .. sa .. ') ') or '') .. tostring(st.a or '–'), 30, x + w / 2 - 50, y + 34, wa and U.col.green or (st.winner and U.col.dim or U.col.text), true)
  textC(o, k, 'VS', 22, x + w / 2, y + 40, U.col.accent, true)
  text(o, k, tostring(st.bName or '–') .. (sb and (' (' .. sb .. ')') or ''), 30, x + w / 2 + 50, y + 34, wb and U.col.green or (st.winner and U.col.dim or U.col.text), true)
  if la then textR(o, k, la, 13, x + w / 2 - 50, y + 72, la == 'LEAD' and leadCol or chaseCol, true) end
  if lb then text(o, k, lb, 13, x + w / 2 + 50, y + 72, lb == 'LEAD' and leadCol or chaseCol, true) end
end

local function qualiPanel(app, o, k, x, y, maxRows)
  local E = app.event
  local rows = {}
  if E and E.ev then
    for _, e in ipairs(E.qualiTable()) do
      if e.status == 'ok' then rows[#rows + 1] = { place = e.place, name = e.name, best = e.best and (e.best.zero and 0 or e.best.final), zero = e.best and e.best.zero } end
    end
  elseif app.drivers then
    local place = 0
    for _, d in ipairs(app.drivers.collect(app)) do
      if d.best then
        place = place + 1
        rows[#rows + 1] = { place = place, name = d.name, best = d.best.zero and 0 or d.best.effective, zero = d.best.zero }
      end
    end
  end
  local n = math.min(#rows, maxRows or 16)
  local w, h = 420, 56 + n * 30
  rect(o, k, x, y, w, h)
  text(o, k, 'KVALIFIKÁCIÓ', 18, x + 16, y + 12, U.col.accent, true)
  for i = 1, n do
    local r = rows[i]
    local ry = y + 44 + (i - 1) * 30
    if i % 2 == 0 then rect(o, k, x + 6, ry - 3, w - 12, 28, rgbm(1, 1, 1, 0.04), 4) end
    text(o, k, tostring(r.place) .. '.', 17, x + 16, ry, U.col.dim, true)
    text(o, k, r.name, 17, x + 60, ry, U.col.text, i <= 3)
    textR(o, k, r.zero and '0' or U.t1(r.best), 17, x + w - 16, ry, i == 1 and U.col.green or U.col.text, true)
  end
  if n == 0 then text(o, k, 'még nincs futás', 15, x + 16, y + 44, U.col.dim) end
end

-- Last result of a driver (the pilot's own, sent to everyone; else scored here).
local function lastResultOf(app, name)
  for _, e in ipairs(app.netsync and app.netsync.runs or {}) do
    if e.driver == name then return { final = e.final, zero = e.zero, reason = e.zeroReason, line = e.line, angle = e.angle, style = e.style } end
  end
  return nil
end

-- The whole bracket: one column per round (Top 32 … Döntő) and the winner, the current battle marked.
function B.drawBracket(app, o, k)
  local E = app.event
  local ev = E and E.ev
  local br = ev and ev.bracket
  if not br then return false end
  local champ = bracket.champion(br)
  rect(o, k, 40, 18, 1840, 70)
  frame(o, k, 40, 18, 1840, 70, U.col.accent)
  text(o, k, tostring(ev.name or 'Verseny'), 30, 64, 34, U.col.text, true)
  textR(o, k, champ and ('GYŐZTES: ' .. champ) or 'ÁGRAJZ', 26, 1856, 38, champ and U.col.green or U.col.dim, true)
  local cur = nil
  local st = battleState(app)
  if st and st.b then cur = st.b.id end
  local R = #br.rounds
  local cols = R + 1
  local colW = math.min(380, 1840 / cols)
  local left = 40 + (1840 - colW * cols) / 2
  local boxW = colW - 36
  local top, avail = 150, 900
  local n1 = #br.rounds[1].battles
  local boxH = math.max(34, math.min(84, avail / n1 - 10))
  local fs = math.max(12, math.min(20, boxH * 0.34))
  local function slotY(r, i)
    local n = #br.rounds[r].battles
    local h = avail / n
    return top + (i - 1) * h + (h - boxH) / 2
  end
  for r, round in ipairs(br.rounds) do
    local x = left + (r - 1) * colW
    textC(o, k, round.name, 16, x + boxW / 2, top - 30, U.col.dim, true)
    for i, b in ipairs(round.battles) do
      local y = slotY(r, i)
      local isCur = b.id == cur and not b.winner
      rect(o, k, x, y, boxW, boxH, rgbm(0.03, 0.035, 0.05, 0.86), 6)
      frame(o, k, x, y, boxW, boxH, isCur and U.col.accent or (b.winner and rgbm(0.35, 0.88, 0.55, 0.35) or panelLine))
      for kk, side in ipairs({ 'a', 'b' }) do
        local name = b[side]
        local seed = side == 'a' and b.seedA or b.seedB
        local won = b.winner == side
        local col = name and (b.winner and (won and U.col.green or U.col.dim) or U.col.text) or U.col.dim
        local label = name and string.format('%s%s', seed and (seed .. '. ') or '', name) or (b.bye and '–' or '')
        text(o, k, label, fs, x + 10, y + (kk == 1 and boxH * 0.08 or boxH * 0.52), col, won)
      end
      if b.omt then textR(o, k, 'OMT', 11, x + boxW - 6, y + 4, U.col.yellow, true) end
      -- connector to the next round (or to the winner box)
      local ny
      if r < R then
        ny = slotY(r + 1, math.ceil(i / 2)) + boxH / 2
      else
        ny = top + avail / 2
      end
      local mx = x + boxW + (colW - boxW) / 2
      local yMid = y + boxH / 2
      local lc = b.winner and rgbm(0.35, 0.88, 0.55, 0.55) or rgbm(1, 1, 1, 0.18)
      ui.drawLine(o + vec2((x + boxW) * k, yMid * k), o + vec2(mx * k, yMid * k), lc, 2 * k)
      ui.drawLine(o + vec2(mx * k, yMid * k), o + vec2(mx * k, ny * k), lc, 2 * k)
      ui.drawLine(o + vec2(mx * k, ny * k), o + vec2((x + colW) * k, ny * k), lc, 2 * k)
    end
  end
  -- the winner
  local x = left + R * colW
  local y = top + avail / 2 - boxH * 0.7
  rect(o, k, x, y, boxW, boxH * 1.4, rgbm(0.03, 0.035, 0.05, 0.9), 8)
  frame(o, k, x, y, boxW, boxH * 1.4, champ and U.col.green or panelLine)
  textC(o, k, 'GYŐZTES', 14, x + boxW / 2, y + 8, U.col.dim, true)
  textC(o, k, champ or '?', math.max(16, fs * 1.2), x + boxW / 2, y + boxH * 0.55, champ and U.col.green or U.col.dim, true)
  return true
end

-- The qualifying standings in big (up to 32 rows, two columns).
function B.drawQualiBig(app, o, k)
  local E = app.event
  local ev = E and E.ev
  if not ev then return false end
  local rows = {}
  for _, e in ipairs(E.qualiTable()) do if e.status == 'ok' then rows[#rows + 1] = e end end
  rect(o, k, 40, 18, 1840, 70)
  frame(o, k, 40, 18, 1840, 70, U.col.accent)
  text(o, k, tostring(ev.name or 'Verseny'), 30, 64, 34, U.col.text, true)
  textR(o, k, 'KVALIFIKÁCIÓ', 26, 1856, 38, U.col.dim, true)
  local perCol = 16
  local rowH = 54
  for i = 1, math.min(32, #rows) do
    local e = rows[i]
    local col = math.floor((i - 1) / perCol)
    local x = 60 + col * 920
    local y = 120 + ((i - 1) % perCol) * rowH
    rect(o, k, x, y, 880, rowH - 8, i % 2 == 0 and rgbm(0.03, 0.035, 0.05, 0.82) or rgbm(0.06, 0.065, 0.085, 0.86), 6)
    if i <= 3 then frame(o, k, x, y, 880, rowH - 8, i == 1 and U.col.green or rgbm(1, 1, 1, 0.25)) end
    text(o, k, tostring(e.place or i) .. '.', 22, x + 16, y + 10, U.col.dim, true)
    text(o, k, e.name, 22, x + 80, y + 10, U.col.text, i <= 8)
    local function sc(r) if not r then return '–' end if r.zero then return '0' end return U.t1(r.final) end
    textR(o, k, sc(e.second), 18, x + 740, y + 13, U.col.dim)
    textR(o, k, sc(e.best), 24, x + 864, y + 9, i == 1 and U.col.green or U.col.text, true)
  end
  if #rows == 0 then text(o, k, 'még nincs futás', 22, 80, 140, U.col.dim) end
  return true
end

-- Which screen to show now: 'battle' | 'bracket' | 'quali' | 'solo'.
function B.screen(app)
  local E = app.event
  local ev = E and E.ev
  local mode = app.settings.ui.broadcastScreen or 'director'
  if mode == 'director' then mode = E and E.requestedScreen and E.requestedScreen() or 'auto' end
  local st = battleState(app)
  local hasBracket = ev and ev.bracket ~= nil
  if mode == 'bracket' then return hasBracket and 'bracket' or (ev and 'quali' or 'solo') end
  if mode == 'quali' then return ev and 'quali' or 'solo' end
  if mode == 'battle' then return st and 'battle' or (hasBracket and 'bracket' or 'solo') end
  -- automatic
  if st then
    local decided = st.winner and st.b and E.decidedAt and E.decidedAt[st.b.id]
    local clk = (E.clockFn or os.clock)()
    if decided and clk - decided > 10 then return 'bracket' end
    if st.winner and not decided and hasBracket then return 'bracket' end
    return 'battle'
  end
  if hasBracket then return 'bracket' end
  return 'solo'
end

-- Draws the whole overlay. o = where the 1920×1080 canvas starts in this window's coordinates, sw / sh =
-- the screen size in pixels.
function B.draw(app, o, sw, sh)
  local k = math.min(sw / 1920, sh / 1080)
  o = o + vec2((sw - 1920 * k) / 2, (sh - 1080 * k) / 2)
  local scr = B.screen(app)
  B.lastScreen = scr
  if scr == 'bracket' and B.drawBracket(app, o, k) then return end
  if scr == 'quali' and B.drawQualiBig(app, o, k) then return end
  local st = scr == 'battle' and battleState(app) or nil
  if st then
    pairingBar(o, k, st)
    carPanel(app, o, k, 30, 160, st.carA, st.leadSide == 'a' and 'LEAD' or (st.leadSide == 'b' and 'CHASE' or nil))
    carPanel(app, o, k, 1920 - 360, 160, st.carB, st.leadSide == 'b' and 'LEAD' or (st.leadSide == 'a' and 'CHASE' or nil))
    local E = app.event
    local lv = E.tracker and E.tracker:live() or nil
    if st.phase == 'armed' or st.phase == 'running' or lv then
      proximity(o, k, lv and lv.prox, lv and lv.contacts, lv and lv.pass)
    end
    if st.winner then
      local wname = st.winner == 'a' and st.a or st.bName
      rect(o, k, 660, 130, 600, 64)
      frame(o, k, 660, 130, 600, 64, U.col.green)
      textC(o, k, 'TOVÁBBJUT: ' .. tostring(wname), 28, 960, 144, U.col.green, true)
    elseif st.phase == 'voting' then
      rect(o, k, 760, 130, 400, 48)
      textC(o, k, 'A BÍRÓK DÖNTENEK…', 22, 960, 140, U.col.yellow, true)
    end
    if app.settings.ui.broadcastQuali == true then qualiPanel(app, o, k, 750, 330, 10) end
    return
  end
  -- qualifying / solo: the followed car + its last result + the table
  local idx = app.carIndex and app.carIndex() or 0
  carPanel(app, o, k, 30, 160, idx, nil)
  local name = nameOf(idx)
  local r = lastResultOf(app, name)
  if not r and app.lastResult and app.watchedCar == idx then
    local lr = app.lastResult
    r = { final = lr.final, zero = lr.zeroRun, reason = table.concat(lr.zeroReasons or {}, ', '), line = lr.split and lr.split.line, angle = lr.split and lr.split.angle, style = lr.split and lr.split.style }
  end
  if r then
    rect(o, k, 30, 645, 330, 96)
    text(o, k, 'UTOLSÓ FUTÁS', 13, 46, 655, U.col.dim, true)
    text(o, k, r.zero and 'NULLÁS' or U.t1(r.final), 36, 46, 672, r.zero and U.col.red or U.col.green, true)
    text(o, k, r.zero and tostring(r.reason or '') or string.format('Line %s · Angle %s · Stílus %s', U.t1(r.line), U.t1(r.angle), U.t1(r.style)), 13, 46, 716, U.col.dim)
  end
  if app.settings.ui.broadcastQuali ~= false then qualiPanel(app, o, k, 1920 - 450, 160, 16) end
  local E = app.event
  if E and E.ev then
    rect(o, k, 660, 18, 600, 50)
    textC(o, k, tostring(E.ev.name) .. ' · KVALIFIKÁCIÓ', 22, 960, 30, U.col.text, true)
  end
end

-- Online: a transparent window over the whole screen (no inputs: clicks go to the game).
function B.drawOnline(app, sw, sh)
  ui.transparentWindow('chtBroadcastHud', vec2(0, 0), vec2(sw, sh), false, false, function()
    B.draw(app, vec2(0, 0), sw, sh)
  end)
end

-- Installed app: inside its own window, but drawn over the whole screen.
function B.drawInWindow(app, sw, sh)
  local wp = ui.windowPos()
  local pushed = pcall(ui.pushClipRectFullScreen)
  B.draw(app, vec2(-(wp and wp.x or 0), -(wp and wp.y or 0)), sw, sh)
  if pushed then pcall(ui.popClipRect) end
end

return B
