-- CHT Drift Judge – Verseny tab (0.4.0): qualifying table, Top 32 bracket, tandem battles, judges' votes.
-- The logic is in src/event.lua (and src/bracket.lua, src/tandem.lua); this file only draws.

local callable = require('src/fn').callable
local U = require('src/ui_common')
local platform = require('src/platform')
local bracket = require('src/bracket')
local decelmap = require('src/decelmap')

local V = {}

local view = nil              -- 'quali' | 'bracket' | 'battle' | 'log' (nil = by the phase)
local newName = 'CHT verseny'
local dedDraft = {}
local showSettings = false

local function t1(v) if v == nil then return '–' end return U.t1(v) end
local function pct(v) if v == nil then return '–' end return string.format('%.0f%%', v * 100) end
local function m1(v) if v == nil then return '–' end return string.format('%.1f m', v) end

local function copy(app, text, what)
  if callable(ac.setClipboardText) then pcall(ac.setClipboardText, text) end
  if app.status then app.status(what .. ' a vágólapon.', U.col.green) end
end

local function tabButton(id, label, active, tip)
  if U.button((active and '● ' or '') .. label .. '##evv_' .. id, 0, false, tip) then view = id end
  ui.sameLine(0, 6)
end

local phaseText = { quali = 'KVALIFIKÁCIÓ', bracket = 'TÁBLA', done = 'VÉGE' }
local stateText = {
  idle = 'vár (élesítés előtt)', armed = 'élesítve – vár a START vonalra', running = 'fut', review = 'futás kész',
  voting = 'szavazás', decided = 'eldőlt',
}

-- No competition ------------------------------------------------------------------------------------------
local function noEvent(app, E)
  U.sectionTitle('Verseny', 'kvalifikáció · Top 32 tábla · tandem csaták · bírói döntés')
  U.wrapped('Itt fut a verseny: a kvalifikáció rangsora (2 futás, a jobb számít; 3. esély kézzel), a Top 32 / 16 / 8 tábla bye-okkal, '
    .. 'a tandem csaták mérése (közelség, szög, vonal, kontaktus, gyorsítási / lassítási térkép) és a bírók szavazata (Lead / Chase / One More Time). '
    .. 'Egy gép vezeti (a versenyigazgató: szerveradmin vagy bíró); a többi bíró és a közvetítő gépe magától követi.', 12, U.col.dim)
  ui.offsetCursorY(6)
  if E.canDirect() then
    U.text('Új verseny', 14, U.col.text, true)
    local t = ui.inputText('Név##evNewName', newName)
    if type(t) == 'string' then newName = t end
    ui.sameLine(0, 8)
    if U.button('Új verseny indítása##evCreate', 0, false, 'Létrehozza a versenyt ezzel a pályatervvel (' .. tostring(app.layout and app.layout.name) .. '). '
      .. 'A kvalifikáció most kezdődik: csak az ezután futott körök számítanak. Te leszel a versenyigazgató; a gépeden megmarad.') then
      E.create(newName)
      view = 'quali'
    end
    local list = E.list()
    if #list > 0 then
      ui.offsetCursorY(6)
      U.text('Korábbi versenyek ezen a gépen', 13, U.col.text, true)
      for i, ev in ipairs(list) do
        if i > 8 then break end
        U.text(string.format('%s · %s · %s · %s', tostring(ev.name), tostring(ev.updated or ''), phaseText[ev.phase] or tostring(ev.phase), tostring(ev.layout or '')), 12, U.col.dim)
        ui.sameLine(0, 10)
        if U.button('Megnyitás##evOpen' .. i, 0, false, 'A verseny folytatása ezen a gépen (te leszel a versenyigazgató).') then
          E.open(ev)
          if ev.director and ev.director.name ~= (select(2, pcall(ac.getDriverName, 0))) then E.takeOver() end
        end
      end
    end
  else
    U.wrapped('A versenyt a versenyigazgató indítja (szerveradmin vagy bíró). Ha már elindult, pár másodpercen belül itt megjelenik.', 13, U.col.text)
  end
  ui.offsetCursorY(6)
  local f = E.fetch
  U.text('A táblázatban: ' .. (f.state == 'loading' and 'keresés…' or (f.state == 'error' and ('nem sikerült (' .. tostring(f.error) .. ')') or 'még nem kerestem')), 12, U.col.dim)
  ui.sameLine(0, 10)
  if U.button('Keresés a táblázatban##evFind', 0, f.state == 'loading', 'A pályán futó (vagy legutóbbi) verseny betöltése a közös táblázatból.') then E.fetchLatest() end
  for i, e in ipairs(E.remoteList or {}) do
    if i > 6 then break end
    U.text(string.format('%s · %s · %s · vezeti: %s', tostring(e.name), tostring(e.updated or ''), phaseText[e.phase] or tostring(e.phase), tostring(e.director or '?')), 12, U.col.dim)
    ui.sameLine(0, 10)
    if U.button('Betöltés##evLoad' .. i, 0, false, 'A verseny betöltése (követés).') then E.fetchEvent(e.id) end
  end
end

-- Header -------------------------------------------------------------------------------------------------
local function judgeCandidates(app, E)
  local out, seen = {}, {}
  local okN, me = pcall(ac.getDriverName, 0)
  if E.isJudge() and okN and me then out[#out + 1] = me; seen[me] = true end
  for idx, p in pairs(app.netsync and app.netsync.peers or {}) do
    local r = app.roles and app.roles.roleOf and app.roles.roleOf(p.steamId)
    if (r == 'judge' or p.role == 'judge' or p.role == 'admin') and p.name and not seen[p.name] then out[#out + 1] = p.name; seen[p.name] = true end
  end
  for _, j in ipairs(E.ev and E.ev.judges or {}) do if not seen[j] then out[#out + 1] = j; seen[j] = true end end
  table.sort(out)
  return out
end

local function settingsPanel(app, E)
  local ev = E.ev
  U.text('Bírók száma a döntéshez:', 12, U.col.dim)
  ui.sameLine(170)
  local v, ch = U.numberBox('evJudgeN', E.judgeNeeded(), 1, 5, '%.0f', 50, 'Ennyi szavazat kell a döntéshez (A04: 2 bíró). Többségi döntés; ha nincs többség: One More Time, utána kötelező dönteni.', 1, 5)
  if ch then ev.judgeCount = math.floor(v + 0.5); E.touch('bírók száma: ' .. ev.judgeCount) end
  ui.sameLine(0, 16)
  local auto = E.autoNext
  if U.button((auto and '● ' or '○ ') .. 'A 2. futás magától élesedik##evAuto', 0, false, 'Az 1. futás után a 2. (csere: a másik vezet) magától élesedik. Kikapcsolva minden futást kézzel kell élesíteni.') then
    E.autoNext = not auto
    app.settings.ui.eventAutoNext = E.autoNext
    if app.saveSoon then app.saveSoon() end
  end
  U.text('Kijelölt bírók (az 1. a Leadet, a 2. a Chase-t nézi – A13):', 12, U.col.dim)
  local judges = ev.judges or {}
  ev.judges = judges
  for i, name in ipairs(judgeCandidates(app, E)) do
    local idx = nil
    for k, j in ipairs(judges) do if j == name then idx = k end end
    if i > 1 then ui.sameLine(0, 6) end
    if U.button((idx and (idx .. '. ') or '+ ') .. name .. '##evJ_' .. name, 0, false,
      idx and 'Kattintásra kikerül a bírók közül.' or 'Kattintásra bíró lesz ennél a versenynél (a szavazata számít, és a versenyigazgató be is írhatja helyette).') then
      if idx then table.remove(judges, idx) else judges[#judges + 1] = name end
      E.touch('bírók: ' .. (#judges > 0 and table.concat(judges, ', ') or 'nincs kijelölve'))
    end
  end
  if #judgeCandidates(app, E) == 0 then U.text('Még nincs bíró a szerveren (Versenyzők fül → Bíró).', 12, U.col.dim) end
  U.text('Szavazni a kijelölt bírók és a bíró / admin szerepűek tudnak a saját gépükről.', 12, U.col.dim)
  ui.offsetCursorY(4)
  if U.button('Verseny bezárása ezen a gépen##evClose', 0, false, 'A verseny ezen a gépen elmentve megmarad (Verseny fül → Korábbi versenyek → Megnyitás); a többi gép a legutóbbi állapotot látja.') then
    E.ev = nil
  end
end

local function header(app, E, ev)
  local director = E.isDirector()
  U.sectionTitle('Verseny – ' .. tostring(ev.name), (phaseText[ev.phase] or tostring(ev.phase)) .. string.format(' · %d. változat', ev.rev or 0))
  local dname = ev.director and ev.director.name or '?'
  U.text('Versenyigazgató: ' .. dname .. (director and ' (te)' or ''), 13, director and U.col.purple or U.col.text, true)
  ui.sameLine(0, 14)
  U.text('Pályaterv: ' .. tostring(ev.layout), 12, U.col.dim)
  if app.layout and ev.layout and ev.layout ~= '' and app.layout.name ~= ev.layout then
    ui.sameLine(0, 10)
    U.text('– most „' .. tostring(app.layout.name) .. '” van betöltve!', 12, U.col.orange, true)
    U.tip('A tandem mérés és a kvalifikáció a betöltött pályatervvel számol. Töltsd be a verseny pályatervét (Pálya fül).')
  end
  if director then
    ui.sameLine(0, 14)
    local st = E.saveState
    U.text(st == 'sending' and 'küldés…' or (st == 'error' and ('nem ment el: ' .. tostring(E.saveError)) or (st == 'ok' and 'elmentve a táblázatba' or 'elmentve ezen a gépen')), 12,
      st == 'error' and U.col.orange or U.col.dim)
  else
    ui.sameLine(0, 14)
    local f = E.fetch
    U.text(f.state == 'loading' and 'frissítés…' or (f.state == 'error' and ('nem sikerült: ' .. tostring(f.error)) or 'követés'), 12, f.state == 'error' and U.col.orange or U.col.dim)
    if E.canDirect() then
      ui.sameLine(0, 10)
      if U.button('Átveszem a vezetést##evTake', 0, false, 'Ha a versenyigazgató gépe kiesett: ezen a gépen folytatódik a verseny (a mostani állapottal). A másik gép követővé válik.') then E.takeOver() end
    end
  end
  local bc = app.settings.ui.broadcastHud == true
  if U.button((bc and '● ' or '○ ') .. 'Közvetítői HUD##evBc', 0, false, 'Teljes képernyős közvetítői HUD (1920×1080-ra tervezve): párosítás, a két autó adatai, közelség, kvali-táblázat. A közvetítő gépén kapcsold be.') then
    app.settings.ui.broadcastHud = not bc
    if app.saveSoon then app.saveSoon() end
  end
  if director then
    ui.sameLine(0, 10)
    if U.button((showSettings and '▾ ' or '▸ ') .. 'Beállítások##evSet', 0, false, 'Bírók, a döntéshez kellő szavazatok, automatikus élesítés.') then showSettings = not showSettings end
    -- what the broadcaster's HUD shows (0.4.1): the director switches it, the broadcaster's PC follows
    U.text('Közvetítői kép:', 12, U.col.dim)
    local cur = ev.screen or 'auto'
    for _, sc in ipairs({ { 'auto', 'Automatikus', 'Csata közben a párosítás és a két autó, a döntés után 10 mp-cel az ágrajz; kvalifikációban a kvali-táblázat.' },
      { 'battle', 'Csata', 'A párosítás és a két autó adatai.' }, { 'bracket', 'Ágrajz', 'A teljes tábla a képernyőn (a győztesek zölddel, a mostani csata kiemelve).' },
      { 'quali', 'Kvali-táblázat', 'A kvalifikáció végeredménye nagyban (legfeljebb 32 sor).' } }) do
      ui.sameLine(0, 6)
      if U.button((cur == sc[1] and '● ' or '') .. sc[2] .. '##evScr_' .. sc[1], 0, false, sc[3] .. ' A közvetítő gépe ezt követi (ha ott „A versenyigazgató szerint” van beállítva).') then E.setScreen(sc[1]) end
    end
  end
  if director and showSettings then
    ui.offsetCursorX(12)
    ui.beginGroup()
    settingsPanel(app, E)
    ui.endGroup()
  end
  ui.offsetCursorY(4)
  local v = view or (ev.phase == 'quali' and 'quali' or 'battle')
  tabButton('quali', 'Kvalifikáció', v == 'quali', 'A kvalifikáció rangsora (C13), 3. esély, kivétel, a tábla összeállítása.')
  tabButton('bracket', 'Tábla', v == 'bracket', 'A Top 32 / 16 / 8 tábla.')
  tabButton('battle', 'Csata', v == 'battle', 'Az aktuális tandem csata: élesítés, mérés, levonás, szavazás.')
  tabButton('log', 'Napló', v == 'log', 'Minden döntés és változás időrendben.')
  ui.dummy(vec2(0, 0))
  ui.separator()
  return v
end

-- Qualifying ----------------------------------------------------------------------------------------------
local function runText(r)
  if not r then return '–' end
  if r.zero then return 'NULLÁS' end
  return t1(r.final)
end

local function qualiView(app, E, ev)
  local director = E.isDirector()
  local rows = E.qualiTable()
  local nOk = 0
  for _, e in ipairs(rows) do if e.status == 'ok' then nOk = nOk + 1 end end
  if ev.phase == 'quali' then
    U.text(string.format('A kvalifikáció kezdete: %s – csak az ezután futott körök számítanak (pilótánként az első 2, 3. eséllyel 3).', tostring(ev.quali.from or '')), 12, U.col.dim)
    if director then
      ui.sameLine(0, 10)
      if U.button('Újraindítás##evQRestart', 0, false, 'A kvalifikáció újrakezdődik: csak az ezután futott körök számítanak (pl. a tesztkörök után).') then E.restartQuali() end
    end
  else
    U.text(string.format('A kvalifikáció lezárva (%s – %s). A tábla ebből a rangsorból készült.', tostring(ev.quali.from or ''), tostring(ev.quali.to or '')), 12, U.col.dim)
  end
  U.text(string.format('%d továbbjutó · rangsor: legjobb futás → második → a legjobb Line / Angle / Stílus pontja → a másodiké (C13).', nOk), 12, U.col.dim)
  -- table
  local y0 = ui.getCursorY()
  local cols = { 0, 42, 230, 310, 390, 600, 660 }
  local hdr = { 'Hely', 'Pilóta', 'Legjobb', '2.', 'Line · Angle · Stílus (legjobb)', 'Futás', 'Állapot' }
  for i, h in ipairs(hdr) do
    if i > 1 then ui.sameLine(cols[i]) end
    U.text(h, 12, U.col.dim, true)
  end
  for i, e in ipairs(rows) do
    local col = e.status == 'ok' and U.col.text or U.col.dim
    U.text(e.place and (e.place .. '.') or '–', 13, col, true)
    ui.sameLine(cols[2]); U.text(e.name, 13, col, e.status == 'ok')
    if e.connected then ui.sameLine(); ui.textColored('●', U.col.green) end
    ui.sameLine(cols[3]); ui.textColored(runText(e.best), e.best and (e.best.zero and U.col.red or U.col.green) or U.col.dim)
    if e.best and e.best.zero and e.best.reason then U.tip('Nullás: ' .. tostring(e.best.reason)) end
    ui.sameLine(cols[4]); ui.textColored(runText(e.second), U.col.dim)
    ui.sameLine(cols[5])
    local b = e.best
    U.text(b and not b.zero and string.format('%s · %s · %s', t1(b.line), t1(b.angle), t1(b.style)) or '', 12, U.col.dim)
    ui.sameLine(cols[6]); U.text(string.format('%d/%d', e.runs or 0, e.third and 3 or 2) .. ((e.all or 0) > (e.runs or 0) and string.format(' (+%d)', e.all - e.runs) or ''), 12, U.col.dim)
    if (e.all or 0) > (e.runs or 0) then U.tip('A további futások nem számítanak (csak az első 2, 3. eséllyel 3).') end
    ui.sameLine(cols[7])
    U.text(e.status == 'ok' and (e.third and '3. esély' or 'továbbjut') or tostring(e.why or e.status), 12,
      e.status == 'ok' and U.col.green or (e.status == 'out' and U.col.red or U.col.dim))
    if director and ev.phase == 'quali' then
      local m = ev.quali.manual[e.name] or {}
      ui.sameLine(820)
      if U.button((m.third and '● ' or '') .. '3. esély##evq3_' .. i, 0, false, 'Egy 3. kör is számít ennek a pilótának (A02: kézzel, pl. technikai hiba után).') then E.setManual(e.name, 'third', not m.third) end
      ui.sameLine(0, 4)
      if U.button((m.out and '● ' or '') .. 'Kivétel##evqo_' .. i, 0, false, 'Kikerül a rangsorból (pl. kizárás, visszalépés).') then E.setManual(e.name, 'out', not m.out) end
      if e.status == 'out' or m.back then
        ui.sameLine(0, 4)
        if U.button((m.back and '● ' or '') .. 'Mégis továbbjut##evqb_' .. i, 0, false, 'Két nullás kör ellenére a rangsorban marad (bírói döntés).') then E.setManual(e.name, 'back', not m.back) end
      end
    end
  end
  if #rows == 0 then U.text('Még nincs futás a kvalifikáció kezdete óta.', 12, U.col.dim) end
  ui.offsetCursorY(6)
  if U.button('Kvali táblázat másolása##evQCopy', 0, #rows == 0, 'A rangsor a vágólapra (tabulátorral elválasztva): táblázatba, Discordra.') then copy(app, E.qualiText(), 'A kvali táblázat') end
  ui.sameLine(0, 8)
  if U.button('Challonge lista másolása##evQChal', 0, nOk == 0, 'A továbbjutók kiemelési sorrendben, soronként egy név – Challonge „Bulk add”, majd „Seed” sorrend.') then copy(app, E.challongeText(), 'A Challonge lista') end
  if director and ev.phase == 'quali' then
    ui.offsetCursorY(6)
    U.text('Tábla összeállítása:', 13, U.col.text, true)
    local sizes = E.sizesFor(nOk)
    for _, s in ipairs(sizes) do
      ui.sameLine(0, 8)
      if U.button(string.format('Top %d##evBuild%d', s, s), 0, false, string.format('A legjobb %d továbbjutóval (%d van): bye-ok a legjobbaknak, kiemelés 1–%d, 2–%d … (DM). A kvalifikáció ezzel lezárul.', s, nOk, s, s - 1)) then
        local ok, err = E.buildBracket(s)
        if ok then view = 'bracket' elseif app.status then app.status('A tábla nem készült el: ' .. tostring(err), U.col.orange) end
      end
    end
    if #sizes == 0 then ui.sameLine(0, 8); U.text('legalább 2 továbbjutó kell', 12, U.col.dim) end
  elseif director and ev.phase ~= 'quali' then
    local started = false
    for _, round in ipairs(ev.bracket and ev.bracket.rounds or {}) do
      for _, b in ipairs(round.battles) do if #(b.runs or {}) > 0 then started = true end end
    end
    ui.offsetCursorY(6)
    if U.button('Tábla törlése, vissza a kvalifikációhoz##evUnbuild', 0, started, started and 'Már volt tandem futás – a tábla nem törölhető.' or 'A tábla törlődik, a kvalifikáció folytatódik (a futások megmaradnak).') then E.unbuildBracket() end
  end
end

-- Bracket ------------------------------------------------------------------------------------------------
local function bracketView(app, E, ev)
  local br = ev.bracket
  if not br then
    U.text('A tábla még nincs összeállítva (Kvalifikáció → Tábla összeállítása).', 13, U.col.dim)
    return
  end
  local champ = bracket.champion(br)
  if champ then U.text('GYŐZTES: ' .. champ, 20, U.col.green, true) end
  local curId = ev.current and ev.current.battle or (E.live and E.live.battle)
  local origin = ui.getCursor()
  local boxW, boxH, colW, gap = 190, 40, 214, 8
  local n1 = #br.rounds[1].battles
  local totalH = n1 * (boxH + gap)
  local director = E.isDirector()
  for r, round in ipairs(br.rounds) do
    local x = origin.x + (r - 1) * colW
    U.drawText(round.name, 13, vec2(x, origin.y), U.col.dim, true)
    local slotH = totalH / #round.battles
    for i, b in ipairs(round.battles) do
      local y = origin.y + 20 + (i - 1) * slotH + (slotH - boxH) / 2
      local p0, p1 = vec2(x, y), vec2(x + boxW, y + boxH)
      local isCur = b.id == curId
      ui.drawRectFilled(p0, p1, rgbm(1, 1, 1, isCur and 0.12 or 0.05), 4)
      ui.drawRect(p0, p1, isCur and U.col.accent or rgbm(1, 1, 1, 0.12), 4)
      for k, side in ipairs({ 'a', 'b' }) do
        local name = b[side]
        local seed = side == 'a' and b.seedA or b.seedB
        local won = b.winner == side
        local col = name and (b.winner and (won and U.col.green or U.col.dim) or U.col.text) or U.col.dim
        local txt = name and string.format('%s%s', seed and ('(' .. seed .. ') ') or '', name) or (b.bye and '– (bye)' or '…')
        U.drawText(txt, 12, vec2(x + 6, y + 3 + (k - 1) * 18), col, won)
      end
      if b.omt then U.drawText('OMT', 11, vec2(x + boxW - 30, y + 3), U.col.yellow, true) end
      if r < #br.rounds then
        local ny = origin.y + 20 + (math.ceil(i / 2) - 1) * (totalH / #br.rounds[r + 1].battles) + (totalH / #br.rounds[r + 1].battles - boxH) / 2 + boxH / 2
        ui.drawLine(vec2(x + boxW, y + boxH / 2), vec2(x + colW - 6, ny), rgbm(1, 1, 1, 0.15), 1)
      end
      if director and b.a and b.b and not b.winner then
        ui.setCursorX(x)
        ui.setCursorY(y)
        if ui.invisibleButton('##evBr_' .. b.id, vec2(boxW, boxH)) then E.select(b.id); view = 'battle' end
        U.tip('Kattintásra ez lesz a következő csata.')
      end
    end
  end
  ui.setCursorX(origin.x)
  ui.setCursorY(origin.y + 24 + totalH)
  ui.dummy(vec2(#br.rounds * colW, 4))
  if U.button('Eredmények másolása##evResCopy', 0, false, 'Minden csata (kör, párosítás, győztes, OMT) a vágólapra, tabulátorral elválasztva.') then copy(app, E.resultsText(), 'Az eredmények') end
end

-- Battle -------------------------------------------------------------------------------------------------
local function liveBox(app, E)
  local tr = E.tracker
  if not tr then return end
  local lv = tr:live()
  U.text('Mérés ezen a gépen', 13, U.col.text, true)
  if tr.state == 'armed' then
    U.text(string.format('Vár: %s (lead) áthalad a START vonalon…', tostring(tr.cars.leadName)), 13, U.col.yellow)
    return
  end
  if not lv then return end
  local d = lv.prox
  local col = d == nil and U.col.dim or (d <= 3 and U.col.green or (d <= 4 and U.col.yellow or U.col.orange))
  U.text(d and string.format('Közelség: %.1f m', d) or 'Közelség: –', 22, col, true)
  ui.sameLine(0, 18)
  U.text(string.format('Lead %.0f° · %.0f km/h   Chase %.0f° · %.0f km/h', lv.leadAngle or 0, lv.leadSpeed or 0, lv.chaseAngle or 0, lv.chaseSpeed or 0), 14, U.col.text)
  if lv.contacts > 0 then ui.sameLine(0, 14); U.text(string.format('KONTAKTUS: %d', lv.contacts), 14, U.col.red, true) end
  if lv.pass then ui.sameLine(0, 14); U.text('ELŐZÉS', 14, U.col.orange, true) end
end

local function resultLine(label, r, own)
  local txt = r and (r.zero and ('NULLÁS: ' .. table.concat(r.zeroReasons or {}, ', ')) or string.format('%s pont (Line %s · Angle %s · Stílus %s)', t1(r.final), t1(r.line), t1(r.angle), t1(r.style))) or '–'
  U.text(label .. txt, 12, r and r.zero and U.col.red or U.col.dim)
  if own then
    ui.sameLine(0, 10)
    U.text(string.format('· a pilóta gépe: %s', own.zero and 'NULLÁS' or t1(own.final)), 12, U.col.green)
    U.tip('A pilóta saját programja (minden képkockával mérve) ennyit adott erre a futásra soloként.')
  end
end

local function listLines(list, color, prefix)
  for _, t in ipairs(list or {}) do U.wrapped((prefix or '• ') .. tostring(t), 12, color) end
end

local function deductionPanel(app, E, b, run, target)
  local key = b.id .. '#' .. tostring(run.n) .. '#' .. target
  for _, d in pairs(run.deductions or {}) do
    if d.target == target then
      U.text(string.format('%s: −%s %s', tostring(d.judge), t1(d.amount), d.note ~= '' and ('· ' .. d.note) or ''), 12, U.col.orange)
    end
  end
  if not E.isJudge() then return end
  local dd = dedDraft[key] or { amount = 0, note = '' }
  dedDraft[key] = dd
  U.text('Levonás:', 12, U.col.dim)
  ui.sameLine(70)
  local v, ch = U.numberBox('evDed_' .. key, dd.amount, 0, target == 'lead' and 60 or 40, '%.1f', 56, 'Bírói levonás pontban (A16: a program nem javasol számot).', 0, 100)
  if ch then dd.amount = v end
  ui.sameLine(0, 6)
  local t = ui.inputText('##evDedN_' .. key, dd.note)
  if type(t) == 'string' then dd.note = t end
  U.tip('Megjegyzés (pl. „kontakt a 2. zónában”, „lassú indítás”).')
  ui.sameLine(0, 6)
  if U.button('Mentés##evDedS_' .. key, 0, false, 'A levonás / megjegyzés a versenyhez kerül (a versenyigazgató gépére megy). 0 pont és üres szöveg = törlés.') then
    local ok = E.sendDeduction(b.id, run.n, target, dd.amount, dd.note)
    if app.status then app.status(ok and 'Levonás elküldve.' or 'A levonás nem ment el (nincs kapcsolat a versenyigazgatóval).', ok and U.col.green or U.col.orange) end
  end
end

local function runCard(app, E, b, run, measuredHere)
  local s = run.summary or {}
  ui.offsetCursorY(4)
  U.text(string.format('%d. futás%s · Lead: %s · Chase: %s', run.n or 0, (run.pair or 1) == 2 and ' (OMT)' or '', tostring(run.lead), tostring(run.chase)), 14, U.col.text, true)
  if measuredHere then ui.sameLine(0, 10); U.text('(ennek a gépnek a mérése – a versenyigazgatóé még nem érkezett meg)', 12, U.col.purple) end
  ui.sameLine(0, 12)
  U.text(tostring(run.at or ''), 12, U.col.dim)
  ui.offsetCursorX(14)
  ui.beginGroup()
  -- lead
  local lDed, cDed = E.deductionTotal(run, 'lead'), E.deductionTotal(run, 'chase')
  U.text(string.format('LEAD %s – javasolt %s / 60%s', tostring(run.lead), t1(math.max(0, (s.leadPts or 0) - lDed)), lDed > 0 and string.format(' (−%s)', t1(lDed)) or ''), 13, U.col.cyan, true)
  resultLine('  solo mérés: ', s.leadResult, run.leadOwn)
  listLines(s.incomplete and s.incomplete.lead, U.col.red, '  INCOMPLETE? ')
  listLines(s.warnings and s.warnings.lead, U.col.orange, '  ! ')
  if s.map and s.map.has then
    if (s.map.count or 0) == 0 then U.text('  Gyorsítási / lassítási térkép: rendben', 12, U.col.green)
    else
      U.text(string.format('  Gyorsítási / lassítási térkép: %d eltérés', s.map.count), 12, U.col.orange, true)
      for _, v in ipairs(s.map.violations or {}) do U.text('    ' .. decelmap.violationText(v), 12, U.col.orange) end
    end
  end
  deductionPanel(app, E, b, run, 'lead')
  -- chase
  local cPts = E.chasePoints(run)
  U.text(string.format('CHASE %s – javasolt %s / 40%s%s', tostring(run.chase), t1(math.max(0, cPts - cDed)), cDed > 0 and string.format(' (−%s)', t1(cDed)) or '',
    (run.measured and run.measured.chase) and ' (a chase gépének közelségével)' or ''), 13, U.col.purple, true)
  resultLine('  solo mérés: ', s.chaseResult, run.chaseOwn)
  local p = s.prox or {}
  U.text(string.format('  Közelség: átlag %s · legkisebb %s · 3 m-en belül %s · 3–4 m %s · 4 m fölött %s', m1(p.avg), m1(p.min), pct(p.near), pct(p.weak), pct(p.far)), 12,
    (p.avg or 99) <= 3 and U.col.green or ((p.avg or 99) <= 4 and U.col.yellow or U.col.orange))
  local init = s.init or {}
  U.text(init.diff and string.format('  Indítás: %+.2f s a leadhez képest%s', init.diff, init.late and ' – KÉSŐBB indított' or '')
    or (init.late and '  Indítás: a chase nem indított driftet' or '  Indítás: –'), 12, init.late and U.col.orange or U.col.dim)
  local a, l = s.angle or {}, s.line or {}
  U.text(string.format('  Szög a leadhez képest: %s · a lead szögénél nem kisebb (−5°-on belül) az idő %s-ában · Vonal: átlag %s a lead nyomvonalától',
    a.avgDiff and string.format('%+.0f°', a.avgDiff) or '–', pct(a.within), m1(l.avgDev)), 12, U.col.dim)
  listLines(s.incomplete and s.incomplete.chase, U.col.red, '  INCOMPLETE? ')
  listLines(s.warnings and s.warnings.chase, U.col.orange, '  ! ')
  deductionPanel(app, E, b, run, 'chase')
  -- the pilots' own PCs (0.4.1)
  local ms = run.measured
  if ms and (ms.lead or ms.chase) then
    U.text('Mérés a pilóták saját gépén', 13, U.col.text, true)
    U.tip('A chase gépén a saját autója pontos (nem a hálózatról jön), ezért ott a közelség a pontosabb – a pontjavaslat ezt használja. A lead gépén a saját pedáljai vannak, ezért ott pontosabb a gyorsítási / lassítási térkép ellenőrzése.')
    for _, role in ipairs({ 'chase', 'lead' }) do
      local m = ms[role]
      if m then
        U.text(string.format('  %s gépe (%s): közelség átlag %s · legkisebb %s · 3 m-en belül %s · 3–4 m %s · 4 m fölött %s', tostring(m.by), role == 'lead' and 'lead' or 'chase',
          m1(m.proxAvg), m1(m.proxMin), pct(m.near), pct(m.weak), pct(m.far)), 12, (m.proxAvg or 99) <= 3 and U.col.green or ((m.proxAvg or 99) <= 4 and U.col.yellow or U.col.orange))
        local parts = {}
        if m.contacts and m.contacts > 0 then parts[#parts + 1] = string.format('kontaktus %d (%s)', m.contacts, m.fault == 'lead' and 'a lead hibája lehet' or 'a chase hibája lehet') end
        if m.mapCount and m.mapCount > 0 then
          parts[#parts + 1] = string.format('térkép: %d eltérés%s', m.mapCount, m.map1 and (' – ' .. decelmap.violationText(m.map1)) or '')
        elseif role == 'lead' and s.map and s.map.has then
          parts[#parts + 1] = 'térkép: rendben'
        end
        if m.pass then parts[#parts + 1] = 'előzés' end
        if m.solo then parts[#parts + 1] = m.soloZero and ('solo: NULLÁS' .. (m.zeroReason ~= '' and (' (' .. m.zeroReason .. ')') or '')) or ('solo: ' .. t1(m.solo)) end
        if #parts > 0 then U.text('    ' .. table.concat(parts, ' · '), 12, U.col.dim) end
      end
    end
  end
  -- contacts
  if (s.contactCount or 0) > 0 then
    U.text(string.format('KONTAKTUS: %d', s.contactCount), 13, U.col.red, true)
    for _, c in ipairs(s.contacts or {}) do
      U.wrapped(string.format('  %.1f s: %s – %s%s', c.t or 0, c.leadFault and 'a LEAD hibája lehet' or 'a CHASE hibája lehet', table.concat(c.reasons or {}, ', '),
        c.mapColor and (' (' .. (decelmap.short[c.mapColor] or c.mapColor) .. ' szakasz)') or ''), 12, U.col.orange)
    end
    U.text('  (DM 1.16: a lead a hibás, ha elvesztette a driftet, elhagyta a pályát vagy túl hirtelen lassított – a bírók döntenek, A06)', 11, U.col.dim)
  end
  ui.endGroup()
end

local voteNames = { a = 'A', b = 'B', omt = 'OMT' }

local function votePanel(app, E, ev, b, live)
  local director = E.isDirector()
  local pair = E.pairOf(b)
  if live and live.battle == b.id and live.pair then pair = live.pair end
  local votes = director and E.votesOf(b, pair) or (b.votes and b.votes['p' .. pair]) or {}
  local n, needed = 0, E.judgeNeeded()
  for _ in pairs(votes) do n = n + 1 end
  local complete = #E.pairRuns(b, pair) >= 2 or (live and live.battle == b.id and live.phase == 'voting')
  U.text(string.format('Döntés%s – %d / %d bíró szavazott', pair == 2 and ' (One More Time után kötelező)' or '', n, needed), 14, U.col.text, true)
  if b.winner then
    local dcs = b.decision or {}
    U.text(string.format('NYERT: %s (%s)', bracket.winnerName(b) or '?', tostring(dcs.how or '')), 16, U.col.green, true)
  end
  -- the judges' votes: shown once all are in (so nobody follows the other)
  if n >= needed or b.winner then
    for j, v in pairs(votes) do
      U.text(string.format('  %s: %s', j, v == 'omt' and 'One More Time' or ((v == 'a' and b.a or b.b) .. ' nyert')), 12, U.col.dim)
    end
  else
    for j in pairs(votes) do U.text('  ' .. j .. ': szavazott', 12, U.col.dim) end
  end
  if b.winner then
    if director then
      if U.button('Döntés visszavonása##evUndo', 0, false, 'Ha tévedés volt: a csata újra nyitott (csak amíg a győztes következő csatája el nem kezdődött).') then
        local ok, err = E.undoDecision(b.id)
        if not ok and app.status then app.status('Nem vonható vissza: ' .. tostring(err), U.col.orange) end
      end
    end
    return
  end
  -- own vote
  if E.isJudge() then
    local mine = E.myVotes[b.id .. '#p' .. pair]
    U.text('Szavazatod:', 12, U.col.dim)
    ui.sameLine(90)
    for _, opt in ipairs({ { 'a', (b.a or 'A') .. ' nyert' }, { 'b', (b.b or 'B') .. ' nyert' }, { 'omt', 'One More Time' } }) do
      local disabled = (opt[1] == 'omt' and (b.omt or pair == 2)) or not complete
      if U.button((mine == opt[1] and '● ' or '') .. opt[2] .. '##evVote_' .. opt[1], 0, disabled,
        not complete and 'Mindkét futás után lehet szavazni.' or (opt[1] == 'omt' and (b.omt and 'Egy OMT után kötelező dönteni (DM 1.11).' or 'Nincs egyértelmű győztes: még egy futáspár.') or 'Erre a pilótára szavazol.')) then
        local ok, err = E.vote(opt[1])
        if app.status then app.status(ok and 'Szavazat elküldve.' or ('A szavazat nem ment el: ' .. tostring(err)), ok and U.col.green or U.col.orange) end
      end
      ui.sameLine(0, 6)
    end
    ui.dummy(vec2(0, 0))
  end
  -- director: votes typed in for the judges (e.g. said on Discord), and the final say after an OMT
  if director then
    for _, j in ipairs(ev.judges or {}) do
      U.text('  ' .. j .. ':', 12, U.col.dim)
      ui.sameLine(150)
      for _, opt in ipairs({ 'a', 'b', 'omt' }) do
        local dis = not complete or (opt == 'omt' and b.omt)
        if U.button((votes[j] == opt and '● ' or '') .. voteNames[opt] .. '##evJV_' .. j .. opt, 44, dis, 'A bíró szavazatának beírása (ha szóban mondta).') then E.addVote(b.id, pair, j, opt) end
        ui.sameLine(0, 4)
      end
      if votes[j] and U.button('×##evJVx_' .. j, 24, false, 'A szavazat törlése') then E.clearVote(b.id, pair, j) end
      ui.dummy(vec2(0, 0))
    end
    U.text('Kézi döntés (versenyigazgató):', 12, U.col.dim)
    ui.sameLine(0, 8)
    if U.button((b.a or 'A') .. ' nyert##evManA', 0, not b.a, 'A versenyigazgató dönt (pl. ha az OMT után sincs többség, vagy a bírók szóban döntöttek).') then E.setWinner(b, 'a', 'versenyigazgató döntése') end
    ui.sameLine(0, 6)
    if U.button((b.b or 'B') .. ' nyert##evManB', 0, not b.b, 'A versenyigazgató dönt.') then E.setWinner(b, 'b', 'versenyigazgató döntése') end
  end
end

local function battleView(app, E, ev)
  if not ev.bracket then
    U.text('A tábla még nincs összeállítva (Kvalifikáció → Tábla összeállítása).', 13, U.col.dim)
    return
  end
  local director = E.isDirector()
  local live = E.live
  local b, cur
  if director then b, cur = E.current() else
    b = live and E.battle(live.battle) or nil
    if not b then b, cur = E.current() end
  end
  if director then
    -- battle choice
    local ready = {}
    for _, round in ipairs(ev.bracket.rounds) do
      for _, x in ipairs(round.battles) do if x.a and x.b and not x.winner then ready[#ready + 1] = { x, round.name } end end
    end
    U.text('Csata:', 12, U.col.dim)
    for i, rb in ipairs(ready) do
      if i > 8 then break end
      ui.sameLine(0, 6)
      local x = rb[1]
      if U.button(string.format('%s%s: %s – %s##evSel_%s', b and b.id == x.id and '● ' or '', rb[2], x.a, x.b, x.id), 0, false, 'Ez legyen az aktuális csata.') then E.select(x.id) b, cur = E.current() end
    end
    if #ready == 0 then ui.sameLine(0, 6); U.text(bracket.champion(ev.bracket) and 'minden csata eldőlt' or 'nincs futtatható csata', 12, U.col.dim) end
  end
  if not b then
    U.text(director and 'Válassz csatát fent (vagy a Tábla nézetben).' or 'A versenyigazgató még nem választott csatát.', 13, U.col.dim)
    return
  end
  local roundName = ev.bracket.rounds[b.round] and ev.bracket.rounds[b.round].name or ''
  ui.offsetCursorY(4)
  U.text(string.format('%s · %s%s  –  %s%s', roundName, b.seedA and ('(' .. b.seedA .. ') ') or '', tostring(b.a), b.seedB and ('(' .. b.seedB .. ') ') or '', tostring(b.b)), 20, U.col.text, true)
  local st = director and cur and cur.state or (live and live.battle == b.id and live.phase) or 'idle'
  U.text('Állapot: ' .. (stateText[st] or st) .. (b.omt and ' · One More Time' or ''), 13, st == 'running' and U.col.green or U.col.dim)
  if director and not b.winner then
    local nextSide = E.nextLead(b)
    if #(b.runs or {}) == 0 then
      U.text('Először vezet:', 12, U.col.dim)
      for _, side in ipairs({ 'a', 'b' }) do
        ui.sameLine(0, 6)
        if U.button(((b.firstLead or 'a') == side and '● ' or '') .. tostring(b[side]) .. '##evFirst' .. side, 0, false, 'Ő vezet az 1. futásban (a 2.-ban a másik). Alapból a jobb kvalifikációs helyezett.') then E.setFirstLead(side) end
      end
    end
    if E.tracker then
      if U.button('Élesítés visszavonása##evDisarm', 0, false, 'A futás nem lesz mérve (pl. rossz rajt).') then E.disarm() end
      ui.sameLine(0, 6)
      if U.button('Futás lezárása most##evFinish', 0, E.tracker.state ~= 'running', 'Ha az autók a FINISH előtt megálltak: a futás itt véget ér, és bekerül a csatához.') then E.finishNow() end
    elseif nextSide then
      local lead = nextSide == 'a' and b.a or b.b
      if U.button(string.format('Élesítés: %d. futás – %s vezet##evArm', #(b.runs or {}) + 1, tostring(lead)), 0, false,
        'A program a lead START vonalon való áthaladásától méri a két autót (közelség, szög, vonal, kontaktus, térkép). A FINISH után magától lezárul.') then
        local ok, err = E.arm()
        if not ok and app.status then app.status('Nem élesíthető: ' .. tostring(err), U.col.orange) end
      end
    end
    if #(b.runs or {}) > 0 and not E.tracker then
      ui.sameLine(0, 6)
      if U.button('Utolsó futás törlése (újrafutás)##evDelRun', 0, false, 'Rossz rajt, technikai hiba: az utolsó futás törlődik, és újra lehet futni.') then E.deleteLastRun() end
    end
  end
  -- camera: judge 1 follows the lead, judge 2 the chase (A13); the broadcaster either
  if callable(ac.focusCar) then
    local leadSide = (director and cur and cur.leadSide) or (live and live.battle == b.id and live.leadSide) or E.nextLead(b) or b.firstLead or 'a'
    local carOf = function(side)
      if not director and live and live.battle == b.id then return side == 'a' and live.carA or live.carB end
      return E.carOf(b[side])
    end
    U.text('Kamera:', 12, U.col.dim)
    for _, side in ipairs({ leadSide, leadSide == 'a' and 'b' or 'a' }) do
      local idx = carOf(side)
      ui.sameLine(0, 6)
      if U.button(string.format('%s (%s)##evCam_%s', tostring(b[side]), side == leadSide and 'lead' or 'chase', side), 0, idx == nil,
        'A kamera erre az autóra vált (A13: az 1. bíró a leadet, a 2. a chase-t nézi).') then pcall(ac.focusCar, idx) end
    end
  end
  ui.separator()
  liveBox(app, E)
  -- runs
  local shown = {}
  for _, run in ipairs(b.runs or {}) do
    runCard(app, E, b, run, false)
    shown[tostring(run.n)] = true
  end
  if not director then
    for k, s in pairs(E.localRuns) do
      local bid, n = k:match('^(.-)#(%d+)$')
      if bid == b.id and not shown[n] then
        runCard(app, E, b, { n = tonumber(n), lead = s.lead, chase = s.chase, summary = s, pair = live and live.pair or 1, deductions = {} }, true)
      end
    end
  end
  if #(b.runs or {}) == 0 and not E.tracker then U.text('Még nincs futás ebben a csatában.', 12, U.col.dim) end
  -- suggestion
  local sug = E.suggestion(b)
  local parts = {}
  for _, side in ipairs({ 'a', 'b' }) do
    local name = b[side]
    local v = name and sug[name]
    if v then parts[#parts + 1] = string.format('%s: %s + %s = %s', name, t1(v.lead), t1(v.chase), t1(v.total)) end
  end
  if #parts > 0 then
    ui.offsetCursorY(4)
    U.text('Javaslat (csak tájékoztató, lead 60 + chase 40): ' .. table.concat(parts, '   ·   '), 13, U.col.cyan)
    U.tip('A program mérései alapján (a lead solo pontjának 60%-a; a chase közelség / szög / vonal alapján, max 40), a bírói levonások után. A győztest a bírók szavazata dönti el (A03).')
  end
  ui.separator()
  votePanel(app, E, ev, b, live)
end

local function logView(app, E, ev)
  for i, m in ipairs(E.messages) do
    if i > 10 then break end
    U.text(string.format('%s  %s', tostring(m.t), tostring(m.text)), 12, m.level == 'error' and U.col.red or (m.level == 'warn' and U.col.orange or U.col.dim))
  end
  if #E.messages > 0 then ui.separator() end
  for i, l in ipairs(ev.log or {}) do
    if i > 150 then break end
    U.text(string.format('%s  %s  (%s)', tostring(l.t), tostring(l.text), tostring(l.by or '')), 12, U.col.text)
  end
end

function V.drawTab(app)
  local E = app.event
  if not E then return end
  local ev = E.ev
  if not ev then noEvent(app, E) return end
  local v = header(app, E, ev)
  ui.childWindow('##evBody', vec2(ui.availableSpaceX(), ui.availableSpaceY()), false, ui.WindowFlags.None, function()
    if v == 'quali' then qualiView(app, E, ev)
    elseif v == 'bracket' then bracketView(app, E, ev)
    elseif v == 'battle' then battleView(app, E, ev)
    else logView(app, E, ev) end
  end)
end

function V.setView(v) view = v end

return V
