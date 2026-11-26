-- CHT Drift Judge – saved runs list (CSP only).

local callable = require('src/fn').callable
local U = require('src/ui_common')
local storage = require('src/storage')
local platform = require('src/platform')

local M = {}

local runsCache, runsCacheT = nil, -1
local function now() return ac.getSim().time / 1000 end
local filter = ''

function M.invalidate() runsCache = nil end

local function loadIndex()
  local dir = storage.runsDir()
  local idx = storage.readJSON(dir .. '/index.json')
  if type(idx) ~= 'table' then idx = {} end
  -- add files that are not in the index (e.g. copied in by hand)
  local known = {}
  for _, e in ipairs(idx) do known[e.file] = true end
  local _, files = storage.listRuns()
  for _, f in ipairs(files) do
    if not storage.isRunFile(f) then known[f] = true end
    if f ~= 'index.json' and not known[f] then idx[#idx + 1] = { file = f, time = '', driver = '?', final = nil } end
  end
  table.sort(idx, function(a, b) return (a.file or '') > (b.file or '') end)
  return idx
end

function M.addToIndex(entry)
  local dir = storage.runsDir()
  local idx = storage.readJSON(dir .. '/index.json')
  if type(idx) ~= 'table' then idx = {} end
  idx[#idx + 1] = entry
  storage.writeJSON(dir .. '/index.json', idx)
  runsCache = nil
end

local function entryText(e)
  return table.concat({ tostring(e.driver or ''), tostring(e.time or ''), tostring(e.file or ''), tostring(e.layout or ''), tostring(e.car or ''),
    e.tag == 'szabad' and 'szabad felvétel' or '', e.zero and 'nullás' or '' }, ' ')
end

function M.entries()
  if not runsCache or now() - runsCacheT > 10 then
    runsCache, runsCacheT = loadIndex(), now()
  end
  return runsCache
end

-- For the global search: list of { index, entry }.
function M.search(query)
  local schema = require('src/schema')
  local r = {}
  for i, e in ipairs(M.entries()) do
    if schema.textMatches(entryText(e), query) then r[#r + 1] = { index = i, entry = e } end
  end
  return r
end

-- Score text of a saved run, with the judge's deduction (A16) if there is one.
local function scoreText(app, e)
  if e.final == nil then return '–' end
  if e.zero then return 'NULLÁS' end
  local d = app and app.getDeduction and app.getDeduction(e.file)
  if d and (d.amount or 0) > 0 then
    return string.format('%s (−%s)', U.t1(math.max(0, e.final - d.amount)), U.t1(d.amount))
  end
  return U.t1(e.final)
end
M.scoreText = scoreText

local function faultsText(e)
  return string.format('1k %d · 2k %d · korr. %d · fal %d · túld. %d', e.oneWheel or 0, e.twoWheel or 0, e.corrections or 0, e.wallSaves or 0, e.overRot or 0)
end

-- Results sent by the pilots' PCs on the server (netsync). Judges use this list; "Másolás" puts it on the
-- clipboard as a table (tab separated) for Challonge / Discord / a spreadsheet.
local function serverRuns(app)
  local N = app.netsync
  if not N then return end
  local list = N.runs or {}
  local scores = platform.canSeeScores()
  local status
  if N.available() then
    status = string.format('kapcsolat rendben · %d futás érkezett ebben a menetben', N.receivedCount or 0)
  else
    status = 'ezen a szerveren nem érhető el (csak AssettoServerrel működik), vagy offline vagy'
  end
  U.collapsible('runs_server', string.format('Szerverről érkezett futások (%d)', #list), {
    sub = status, defaultOpen = #list > 0,
    tip = 'Ha egy pilótánál véget ér egy futás, a program elküldi az eredményét mindenkinek a szerveren. A pilóta gépe teljes képkockaszámmal mér, ezért ez pontosabb, mint egy távoli autó pontozása.',
  }, function()
    if #list == 0 then
      U.text('Még nem érkezett futás. A pilóták gépén is futnia kell a programnak (a szerverről automatikusan megkapják).', 12, U.col.dim)
      return
    end
    if U.button('Másolás táblázatként##srvCopy', 0, false, 'A lista a vágólapra kerül (tabulátorral elválasztva): beilleszthető táblázatba, Challonge-ba, Discordra.') then
      local lines = { 'Idő\tPilóta\tAutó\tPont\tLine\tAngle\tStílus\tNullás\tHibák\tPályaterv' }
      for _, e in ipairs(list) do
        lines[#lines + 1] = table.concat({ e.time or '', e.driver or '', e.car or '',
          scores and string.format('%.1f', e.final or 0) or '', scores and string.format('%.1f', e.line or 0) or '',
          scores and string.format('%.1f', e.angle or 0) or '', scores and string.format('%.1f', e.style or 0) or '',
          e.zero and ('igen: ' .. (e.zeroReason or '')) or '', faultsText(e), e.layout or '' }, '\t')
      end
      local text = table.concat(lines, '\n')
      if callable(ac.setClipboardText) then pcall(ac.setClipboardText, text) end
      if app.status then app.status(string.format('%d futás a vágólapon.', #list), U.col.green) end
    end
    for i, e in ipairs(list) do
      if i > 60 then U.text(string.format('… és még %d', #list - 60), 12, U.col.dim) break end
      ui.textColored(string.format('%-19s', e.time or ''), U.col.dim)
      ui.sameLine(170)
      ui.text(tostring(e.driver or '?') .. (e.own and ' (te)' or ''))
      ui.sameLine(330)
      if not scores then ui.textColored(e.zero and 'NULLÁS' or 'kész', e.zero and U.col.red or U.col.dim)
      elseif e.zero then ui.textColored('NULLÁS', U.col.red)
      else ui.textColored(U.t1(e.final), U.col.green) end
      U.tip(e.zero and ('Nullás kör: ' .. (e.zeroReason or '')) or (scores and string.format('Line %s · Angle %s · Stílus %s', U.t1(e.line), U.t1(e.angle), U.t1(e.style)) or nil))
      ui.sameLine(400)
      ui.textColored(faultsText(e), U.col.dim)
      ui.sameLine(640)
      ui.textColored(e.layout or '', U.col.dim)
    end
  end)
end

function M.drawRunsTab(app)
  local schema = require('src/schema')
  local entries = M.entries()
  serverRuns(app)
  if platform.online then
    U.sectionTitle('Futások ebben a menetben – ' .. storage.trackKey(), string.format('%d db', #entries))
    U.text('Az online (szerverről kapott) változat nem ment fájlt: a futások a játék bezárásáig maradnak meg, a telemetria az utolsó 15-höz. Hangoláshoz a telepített változat kell.', 12, U.col.dim)
  else
    U.sectionTitle('Mentett futások – ' .. storage.trackKey(), string.format('%d db', #entries))
    U.text('Minden futás teljes telemetriával és a pályatervvel együtt mentődik. Ezeket a fájlokat kell elküldeni hangoláshoz.', 12, U.col.dim)
  end
  if U.button('Frissítés', 80, false, 'Újraolvassa a futások listáját.') then runsCache = nil; entries = M.entries() end
  if not platform.online then
    ui.sameLine()
    require('src/ui_settings').foldersRow(app, true)
  end
  filter = U.searchBox('flt', 'Szűrés: név, idő, pályaterv, „nullás”, „szabad”…', filter, 340)
  ui.separator()
  if not entries then return end
  U.text('Megnyitás = a mentett eredmény. Újrapontozás = a felvett telemetriát a MOSTANI pályatervvel és beállításokkal számolja újra.', 12, U.col.dim)
  ui.childWindow('##runs', vec2(ui.availableSpaceX(), ui.availableSpaceY()), false, ui.WindowFlags.None, function()
    local shown = 0
    for i, e in ipairs(entries) do
      if schema.textMatches(entryText(e), filter) then
        shown = shown + 1
        local name = tostring(e.driver or '?')
        local scoreTxt = scoreText(app, e)
        if not platform.canSeeScores() and e.final ~= nil and not e.zero then scoreTxt = 'kész' end
        local col = e.final == nil and U.col.dim or (e.zero and U.col.red or U.col.green)
        ui.textColored(string.format('%-19s', e.time ~= '' and e.time or e.file), U.col.dim)
        ui.sameLine(170)
        ui.text(name)
        ui.sameLine(330)
        ui.textColored(scoreTxt, col)
        ui.sameLine(430)
        ui.textColored(e.tag == 'szabad' and 'szabad felvétel' or (e.tag == 'megszakitott' and 'megszakított' or (e.layout or '')), U.col.dim)
        ui.sameLine(590)
        if U.button('Megnyitás##o' .. i, 90, false, 'A futás mentett eredményének megnyitása az Eredmény fülön.') then app.openRun(e.file, false) end
        ui.sameLine()
        if U.button('Újrapontozás##r' .. i, 110, false, 'A felvett telemetriát a JELENLEGI pályatervvel és beállításokkal pontozza újra (a fájl nem változik).') then app.openRun(e.file, true) end
      end
    end
    if shown == 0 then
      U.text(#entries == 0 and 'Még nincs mentett futás ezen a pályán.' or 'Nincs a szűrésnek megfelelő futás.', 13, U.col.dim)
    end
  end)
end

return M
