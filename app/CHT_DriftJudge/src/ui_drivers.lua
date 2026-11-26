-- CHT Drift Judge – Versenyzők tab: every competitor's points on their own (for the judges).
--
-- Sources, per driver:
--   „pilóta gépe”  the result the pilot's own program sent to everyone on the server (src/netsync.lua):
--                  measured with every frame on that PC, so this is the one the ranking uses;
--   „ez a gép”     runs scored on this PC: your own driving, or the car you follow with the camera as a
--                  spectator / judge (remote cars come with fewer updates, so these are for checking).
-- Ranking (qualifying, A04 / C07 / C13): best run, then the second best, then the best run's Line, Angle,
-- Stílus, then the second's. A judge's deduction (A16) is taken off first; a zero run counts as 0.

local callable = require('src/fn').callable
local U = require('src/ui_common')
local platform = require('src/platform')
local Runs = require('src/ui_runs')

local D = {}

local allLayouts = false
local onlyConnected = false
local filter = ''
local openDriver = {}

local function num(v) return tonumber(v) or 0 end

local function deductionKey(r)
  if r.source == 'local' then return r.file end
  return 'srv:' .. tostring(r.driver or '?') .. ':' .. tostring(r.runId or '') .. ':' .. tostring(r.time or '')
end

local function finalOf(app, r)
  if r.zero then return 0 end
  local d = app.getDeduction and app.getDeduction(deductionKey(r))
  return math.max(0, num(r.final) - (d and num(d.amount) or 0)), d and num(d.amount) or 0
end

-- All drivers with their runs for the current layout (or all layouts), ranked.
function D.collect(app)
  local layoutName = app.layout and app.layout.name
  local map, list = {}, {}
  local function get(name, carIndex)
    local k = tostring(name or '?')
    if k == '' then k = '?' end
    local d = map[k]
    if not d then
      d = { name = k, carIndex = nil, runs = {}, connected = false }
      map[k] = d
      list[#list + 1] = d
    end
    if carIndex and carIndex >= 0 then d.carIndex = carIndex end
    return d
  end
  -- everyone on the server now (also those without a run yet)
  local okS, sim = pcall(ac.getSim)
  local n = okS and sim and sim.carsCount or 1
  for i = 0, n - 1 do
    local okC, car = pcall(ac.getCar, i)
    if okC and car and car.isConnected ~= false and car.isAIControlled ~= true then
      local okN, name = pcall(ac.getDriverName, i)
      if okN and name and name ~= '' then get(name, i).connected = true end
    end
  end
  -- results sent by the pilots' programs
  for _, e in ipairs(app.netsync and app.netsync.runs or {}) do
    if allLayouts or e.layout == '' or e.layout == layoutName then
      local d = get(e.driver, e.carIndex)
      d.runs[#d.runs + 1] = {
        source = 'pilot', driver = e.driver, runId = e.runId, time = e.time, final = e.final, zero = e.zero, zeroReason = e.zeroReason,
        line = e.line, angle = e.angle, style = e.style, layout = e.layout, avgSpeed = e.avgSpeed, duration = e.duration,
        oneWheel = e.oneWheel, twoWheel = e.twoWheel, corrections = e.corrections, wallSaves = e.wallSaves, overRot = e.overRot,
        appVersion = e.appVersion,
      }
    end
  end
  -- runs scored on this PC (own or followed car); free recordings and aborted runs are not results.
  -- Your own run may also come back from the server as a „pilot” result: listed once.
  local ownSent = {}
  for _, e in ipairs(app.netsync and app.netsync.runs or {}) do
    if e.carIndex == 0 then ownSent[string.format('%s|%.3f|%s', tostring(e.driver), num(e.final), tostring(e.zero == true))] = true end
  end
  for _, e in ipairs(Runs.entries() or {}) do
    local dup = not e.spectated and ownSent[string.format('%s|%.3f|%s', tostring(e.driver), num(e.final), tostring(e.zero == true))]
    if e.tag == nil and e.final ~= nil and not dup and (allLayouts or e.layout == layoutName) then
      local d = get(e.driver, e.carIndex)
      d.runs[#d.runs + 1] = {
        source = 'local', file = e.file, driver = e.driver, time = e.time, final = e.final, zero = e.zero, zeroReason = e.zeroReason,
        line = e.line, angle = e.angle, style = e.style, layout = e.layout, spectated = e.spectated,
        oneWheel = e.oneWheel, twoWheel = e.twoWheel, corrections = e.corrections, wallSaves = e.wallSaves, overRot = e.overRot,
      }
    end
  end
  for _, d in ipairs(list) do
    table.sort(d.runs, function(a, b) return tostring(a.time or '') > tostring(b.time or '') end)
    local pilot = {}
    for _, r in ipairs(d.runs) do if r.source == 'pilot' then pilot[#pilot + 1] = r end end
    -- the ranking uses the pilot's own results when there are any, else the ones scored here
    local ranked = #pilot > 0 and pilot or d.runs
    d.rankSource = #pilot > 0 and 'pilot' or (#d.runs > 0 and 'local' or nil)
    local scored = {}
    for _, r in ipairs(ranked) do
      r.effective = finalOf(app, r)
      scored[#scored + 1] = r
    end
    table.sort(scored, function(a, b)
      if a.effective ~= b.effective then return a.effective > b.effective end
      if num(a.line) ~= num(b.line) then return num(a.line) > num(b.line) end
      if num(a.angle) ~= num(b.angle) then return num(a.angle) > num(b.angle) end
      return num(a.style) > num(b.style)
    end)
    d.best, d.second = scored[1], scored[2]
    d.count = #ranked
    d.zeros = 0
    for _, r in ipairs(ranked) do if r.zero then d.zeros = d.zeros + 1 end end
    d.last = ranked[1]
  end
  local function key(r, field) if not r then return -1 end if field == 'final' then return r.effective or 0 end return num(r[field]) end
  table.sort(list, function(a, b)
    if (a.best ~= nil) ~= (b.best ~= nil) then return a.best ~= nil end
    for _, part in ipairs({ { 'best', 'final' }, { 'second', 'final' }, { 'best', 'line' }, { 'best', 'angle' }, { 'best', 'style' },
      { 'second', 'line' }, { 'second', 'angle' }, { 'second', 'style' } }) do
      local x, y = key(a[part[1]], part[2]), key(b[part[1]], part[2])
      if x ~= y then return x > y end
    end
    return a.name:lower() < b.name:lower()
  end)
  return list
end

local function scoreStr(app, r)
  if not r then return '–' end
  if r.zero then return 'NULLÁS' end
  local v, ded = finalOf(app, r)
  if ded and ded > 0 then return string.format('%s (−%s)', U.t1(v), U.t1(ded)) end
  return U.t1(v)
end

local function faults(r)
  return string.format('1k %d · 2k %d · korr. %d · fal %d · túld. %d', num(r.oneWheel), num(r.twoWheel), num(r.corrections), num(r.wallSaves), num(r.overRot))
end

local function copyTable(app, list)
  local lines = { 'Hely\tPilóta\tLegjobb\t2. legjobb\tFutás\tNullás\tLine\tAngle\tStílus\tForrás' }
  local place = 0
  for _, d in ipairs(list) do
    if d.best then
      place = place + 1
      lines[#lines + 1] = table.concat({ tostring(place), d.name, scoreStr(app, d.best), scoreStr(app, d.second), tostring(d.count), tostring(d.zeros),
        U.t1(d.best.line), U.t1(d.best.angle), U.t1(d.best.style), d.rankSource == 'pilot' and 'pilóta gépe' or 'ez a gép' }, '\t')
    end
  end
  local text = table.concat(lines, '\n')
  if callable(ac.setClipboardText) then pcall(ac.setClipboardText, text) end
  if app.status then app.status(string.format('Rangsor a vágólapon (%d pilóta).', place), U.col.green) end
end

local function driverRuns(app, d)
  if #d.runs == 0 then
    U.text('Még nincs futása ezen a pályaterven.', 12, U.col.dim)
    return
  end
  for i, r in ipairs(d.runs) do
    if i > 40 then U.text(string.format('… és még %d', #d.runs - 40), 12, U.col.dim) break end
    local id = d.name .. '_' .. i
    ui.textColored(string.format('%-19s', tostring(r.time or '')), U.col.dim)
    ui.sameLine(160)
    if r.source == 'pilot' then ui.textColored('pilóta gépe', U.col.green) else ui.textColored(r.spectated and 'ez a gép (néző)' or 'ez a gép', U.col.purple) end
    U.tip(r.source == 'pilot' and 'A pilóta saját programja számolta és küldte el (minden képkockával mérve) – a rangsor ezt használja.'
      or 'Ezen a gépen számolva (saját vezetés, vagy a kamerával követett autó). Távoli autónál kevesebb az adat, ezért tájékoztató.')
    ui.sameLine(280)
    ui.textColored(scoreStr(app, r), r.zero and U.col.red or U.col.green)
    if r.zero then U.tip('Nullás kör: ' .. tostring(r.zeroReason or '')) end
    ui.sameLine(390)
    U.text(r.zero and tostring(r.zeroReason or '') or string.format('Line %s · Angle %s · Stílus %s', U.t1(r.line), U.t1(r.angle), U.t1(r.style)), 12, U.col.dim)
    ui.sameLine(640)
    U.text(faults(r), 12, U.col.dim)
    -- the judge's deduction (A16), also for the results sent by the pilots
    local key = deductionKey(r)
    local ded = app.getDeduction and app.getDeduction(key) or {}
    ui.sameLine(900)
    local v, ch = U.numberBox('dd_' .. id, num(ded.amount), 0, 100, '%.1f', 56, 'Bírói levonás pontban erre a futásra (0–100).', 0, 100)
    if ch and app.setDeduction then app.setDeduction(key, v, ded.note) end
    if r.source == 'local' and r.file then
      ui.sameLine()
      if U.button('Megnyitás##do_' .. id, 90, false, 'A futás részletei az Eredmény fülön (zónák, pályatérkép, stílus).') then app.openRun(r.file, false) end
    end
  end
end

function D.drawTab(app)
  if not platform.canSeeScores() then
    U.wrapped('A pontokat ezen a szerveren csak a bírók és a közvetítő látják.', 13, U.col.dim)
    return
  end
  local list = D.collect(app)
  local withRuns = 0
  for _, d in ipairs(list) do if d.best then withRuns = withRuns + 1 end end
  U.sectionTitle('Versenyzők – ' .. tostring(app.layout and app.layout.name or ''), string.format('%d pilóta, %d futással', #list, withRuns))
  U.text('Pilótánként az összes futás és pont. A rangsor: legjobb futás, aztán a második legjobb, aztán a legjobb Line / Angle / Stílus pontja (C13). A bírói levonás már le van vonva.', 12, U.col.dim)
  if ui.checkbox('Minden pályaterv##drvAll', allLayouts) then allLayouts = not allLayouts end
  ui.sameLine(0, 16)
  if ui.checkbox('Csak akik most fent vannak##drvConn', onlyConnected) then onlyConnected = not onlyConnected end
  ui.sameLine(0, 16)
  if U.button('Másolás táblázatként##drvCopy', 0, withRuns == 0, 'A rangsor a vágólapra kerül (tabulátorral elválasztva): beilleszthető táblázatba, Challonge-ba, Discordra.') then copyTable(app, list) end
  filter = U.searchBox('drvFlt', 'Keresés: pilóta neve…', filter, 260)
  local judged = app.watchedCar
  local live = app.judge and app.judge.state ~= 'idle'
  ui.separator()
  ui.childWindow('##drivers', vec2(ui.availableSpaceX(), ui.availableSpaceY()), false, ui.WindowFlags.None, function()
    local place = 0
    for _, d in ipairs(list) do
      if d.best then place = place + 1 end
      local show = (not onlyConnected or d.connected) and (filter == '' or d.name:lower():find(filter:lower(), 1, true))
      if show then
        local open = openDriver[d.name] == true
        local label = string.format('%s %s##drv_%s', open and '▾' or '▸', d.best and (tostring(place) .. '.') or '–', d.name)
        if U.button(label, 46, false, 'Futások megnyitása / bezárása') then openDriver[d.name] = not open end
        ui.sameLine(56)
        ui.text(d.name)
        if d.connected then ui.sameLine(); ui.textColored('●', U.col.green); U.tip('Most fent van a szerveren.') end
        if judged ~= nil and d.carIndex == judged then
          ui.sameLine()
          ui.textColored(live and ' ▶ most fut (ezt pontozza ez a gép)' or ' ◉ ezt követi a kamera', U.col.purple)
        end
        ui.sameLine(330)
        U.text('Legjobb', 12, U.col.dim)
        ui.sameLine(390)
        ui.textColored(scoreStr(app, d.best), d.best and (d.best.zero and U.col.red or U.col.green) or U.col.dim)
        ui.sameLine(500)
        U.text('2.', 12, U.col.dim)
        ui.sameLine(520)
        ui.textColored(scoreStr(app, d.second), U.col.dim)
        ui.sameLine(620)
        U.text(string.format('%d futás · %d nullás', d.count, d.zeros), 12, U.col.dim)
        if d.rankSource == 'local' then ui.sameLine(); U.text('(ez a gép)', 12, U.col.purple); U.tip('Ettől a pilótától nem jött eredmény a saját gépéről, ezért az itt számoltak szerint áll a rangsorban.') end
        if d.carIndex ~= nil and d.connected and callable(ac.focusCar) then
          ui.sameLine(800)
          if U.button('Követés##fc_' .. d.name, 80, false, 'A kamera erre az autóra vált (nézőként / bíróként): a program ezt az autót pontozza és mutatja a HUD-on.') then
            pcall(ac.focusCar, d.carIndex)
          end
        end
        if open then
          ui.offsetCursorX(20)
          ui.beginGroup()
          driverRuns(app, d)
          ui.endGroup()
          ui.offsetCursorY(6)
        end
      end
    end
    if #list == 0 then U.text('Nincs pilóta a szerveren, és még nem érkezett futás.', 12, U.col.dim) end
  end)
end

return D
