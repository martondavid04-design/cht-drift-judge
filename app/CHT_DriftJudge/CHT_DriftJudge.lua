-- CHT Drift Judge – CornerHuntersTeam drift judging app for Assetto Corsa (CSP Lua)
-- Phase 1: solo (qualifying) judging, in-game layout editor, telemetry recording.
-- The same code runs as an installed Lua app (apps/lua/CHT_DriftJudge) and as an online script that the
-- server sends to every player (one bundled file from GitHub, see tools/build.py and src/platform.lua).

local APP_VERSION = '0.3.8'

local config = require('src/config')
local layoutMod = require('src/layout')
local scoring = require('src/scoring')
local storage = require('src/storage')
local telemetry = require('src/telemetry')
local draw3d = require('src/draw3d')
local editor = require('src/editor')
local U = require('src/ui_common')
local Live = require('src/ui_live')
local Result = require('src/ui_result')
local Runs = require('src/ui_runs')
local Settings = require('src/ui_settings')
local schema = require('src/schema')
local todo = require('src/todo')
local help = require('src/help')
local visibility = require('src/visibility')
local platform = require('src/platform')
local controls = require('src/controls')
local netsync = require('src/netsync')

local app = {
  version = APP_VERSION,
  settings = storage.loadSettings(),
  dirty = false,
  t = 0,
  online = platform.online,
  passive = false,        -- online script on a PC where the installed app runs: stays silent
  serverLayouts = {},     -- online: layout names that came from the server (GitHub)
  remote = { state = 'none' },
}
app.platform = platform
app.netsync = netsync
app.cfg = config.merge(app.settings.scoring)
if visibility.migrate(app.settings) then storage.saveSettings(app.settings) end

local recorder = telemetry.newRecorder(3, 600)
app.freeRecorder = telemetry.newRecorder(0, 600)
local freeStartT = 0
local runHeader = nil
local pendingRebuild = false
local partialTimer = 0
local statusUntil = 0
local selectTab = nil

local function now() return ac.getSim().time / 1000 end

local function status(msg, color, seconds)
  app.statusMessage, app.statusColor = msg, color
  statusUntil = now() + (seconds or 6)
end
app.status = status

-- Hotkeys and the main switch of the track drawings (E01) ------------------------------------------
controls.init(platform.online)
function app.hotkeyText(id)
  local b = controls.boundTo(id)
  if b and b ~= '' then return b end
  for _, d in ipairs(controls.defs) do if d.id == id then return d.defaultText end end
  return ''
end

function app.toggleTrackDraw()
  local on = visibility.toggleMaster(app.settings)
  app.saveSoon()
  status(on and 'Pályarajz BE: a zónák és a többi rajz újra látszik.' or ('Pályarajz KI: a program most semmit nem rajzol a pályára. Visszakapcsolás: ' .. app.hotkeyText('zones') .. ' vagy a fő ablak felső sora.'),
    on and U.col.green or U.col.dim, 6)
end

-- Judges' deductions (A12, A16): per saved run, typed in by the judge on the Eredmény tab.
app.deductions = storage.loadDeductions()
function app.getDeduction(file)
  local d = file and app.deductions[file]
  if type(d) ~= 'table' then return nil end
  return d
end
function app.setDeduction(file, amount, note)
  if not file then return end
  amount = tonumber(amount) or 0
  note = tostring(note or '')
  if amount <= 0 and note == '' then app.deductions[file] = nil
  else app.deductions[file] = { amount = math.max(0, amount), note = note } end
  storage.saveDeductions(app.deductions)
  Runs.invalidate()
end

-- Settings are saved shortly after a change (sliders change every frame while dragged).
local saveAt = nil
function app.saveSoon() saveAt = now() + 1.0 end
local function flushSave()
  if saveAt and now() > saveAt then
    saveAt = nil
    storage.saveSettings(app.settings)
  end
end

-- Collapsible sections remember their state in settings.ui.open.
if type(app.settings.ui) ~= 'table' then app.settings.ui = {} end
if type(app.settings.ui.open) ~= 'table' then app.settings.ui.open = {} end
U.openStore = app.settings.ui.open
U.onOpenChange = function() app.saveSoon() end

-- Car being judged ---------------------------------------------------------------------------------

function app.car()
  local sim = ac.getSim()
  local idx = 0
  if app.settings.ui.carMode == 'focused' and sim.focusedCar >= 0 then idx = sim.focusedCar end
  return ac.getCar(idx)
end

-- Layout handling ----------------------------------------------------------------------------------

local function rebuildJudge()
  local car = app.car()
  app.judge = scoring.newJudge(app.compiled, app.cfg, { steerLock = car and car.steerLock or 450 })
  pendingRebuild = false
end

function app.recompile()
  app.compiled = layoutMod.compile(app.layout, app.cfg)
  app.compiledByIndex = {}
  for _, cz in ipairs(app.compiled.zones) do app.compiledByIndex[cz.index] = cz end
  app.layoutIssues = layoutMod.validate(app.layout)
  if not app.judge or app.judge.state == 'idle' then rebuildJudge() else pendingRebuild = true end
end

function app.loadLayout(name)
  local data = storage.loadLayout(name)
  local l, warnings = layoutMod.sanitize(data)
  if not data then l = layoutMod.new(storage.trackKey(), name) end
  l.name = name
  app.layout = l
  app.dirty = false
  app.settings.activeLayouts[storage.trackKey()] = name
  storage.saveSettings(app.settings)
  app.recompile()
  if warnings and #warnings > 0 then status(table.concat(warnings, ' '), U.col.orange) end
end

function app.newLayout(name)
  app.layout = layoutMod.new(ac.getTrackFullID('/'), name)
  app.dirty = true
  app.recompile()
end

function app.saveLayout()
  app.layout.track = ac.getTrackFullID('/')
  if platform.online and app.serverLayouts[app.layout.name] then
    -- the server's copy stays as it is: an online edit is saved on this PC under another name
    app.layout.name = app.layout.name .. ' (helyi)'
    status('A szerver pályatervét nem írom felül: a módosítás „' .. app.layout.name .. '” néven ezen a gépen marad. Véglegesítéshez a Pálya fülön a „Másolás” gombbal küldd el.', U.col.orange, 12)
  end
  if storage.saveLayout(app.layout) then
    app.dirty = false
    app.settings.activeLayouts[storage.trackKey()] = app.layout.name
    storage.saveSettings(app.settings)
    status('Pályaterv elmentve: ' .. app.layout.name, U.col.green)
  else
    status('Nem sikerült menteni a pályatervet!', U.col.red)
  end
end

function app.saveSettings() storage.saveSettings(app.settings) end

function app.applySettings()
  app.cfg = config.merge(app.settings.scoring)
  app.recompile()
end

-- Teendők (things to fix / check) ----------------------------------------------------------------

app.todoDismissed = {} -- itemId -> signature, hidden for this session ("Rendben, így jó" on non-zone items)

local function todoCtx()
  local car = app.car()
  return {
    layout = app.layout, dirty = app.dirty,
    result = app.lastResult, resultIsCurrent = app.lastResult ~= nil and app.resultLayout == app.layout,
    settings = app.settings, remoteCar = car and car.isRemote or false,
    freeRecording = app.freeRecorder:active(),
    changedSettings = #schema.changedList(app.settings),
    dismissed = app.todoDismissed,
  }
end

function app.zoneIssues() return todo.zoneIssues(todoCtx()) end
function app.todoItems() return todo.collect(todoCtx()) end

-- Approves a zone problem ("Rendben, így jó"). The approval is stored in the layout, so it travels with
-- the layout file; if the layout had no other unsaved change, it is saved right away.
function app.ackZoneIssue(zi, kind, approve)
  local z = app.layout.zones[zi]
  if not z then return end
  local wasClean = not app.dirty
  if approve == false then
    if z.ack then z.ack[kind] = nil end
  else
    z.ack = z.ack or {}
    z.ack[kind] = todo.zoneSig(z)
  end
  app.dirty = true
  if wasClean then app.saveLayout() end
  local what = todo.zoneShort[kind] or kind
  if approve == false then
    status(z.name .. ': a jóváhagyás visszavonva (' .. what .. ') – újra a Teendők között.', U.col.orange)
  else
    status(z.name .. ': jóváhagyva (' .. what .. '). Ha a zóna vonala megváltozik, újra szólok.', U.col.green)
  end
end

function app.ackTodoItem(it)
  if it.ack == 'zone' and it.zone then
    app.ackZoneIssue(it.zone, it.kind, true)
  elseif it.ack == 'session' and it.id then
    app.todoDismissed[it.id] = it.sig
    status('Elrejtve a Teendők közül (a játék újraindításáig, vagy amíg nem változik).', U.col.dim)
  end
end

function app.restoreTodoItem(it)
  if it.approved and it.zone then app.ackZoneIssue(it.zone, it.kind, false)
  elseif it.id then app.todoDismissed[it.id] = nil end
end

-- Layout tempo from a result (Eredmény tab button): the run's average speed = full tempo, 90% = minimum.
function app.setTempoFromResult(res)
  if editor.setTempoFromResult(res) then
    status(string.format('Minimális tempó: %.0f km/h, teljes pont: %.0f km/h – mentsd el a pályatervet.', app.layout.tempoMin, app.layout.tempoFull), U.col.purple, 8)
  end
end

function app.openZone(i)
  editor.selectZone(i)
  selectTab = 'editor'
end

local function runTodoAction(a)
  if not a then return end
  if a.kind == 'zone' and a.zone then app.openZone(a.zone)
  elseif a.kind == 'tab' then selectTab = a.tab
  elseif a.kind == 'save' then app.saveLayout()
  elseif a.kind == 'settingsChanged' then Settings.focus('', true); selectTab = 'settings' end
end

-- Runs ---------------------------------------------------------------------------------------------

local function copyLayout()
  local ok, text = pcall(JSON.stringify, app.layout)
  if ok then return JSON.parse(text), text end
  return nil, ''
end

local function saveRecord(rows, result, tag)
  local layoutCopy, layoutText = copyLayout()
  local header = runHeader or telemetry.header(app.car(), { appVersion = APP_VERSION, time = storage.timestampHuman() })
  local record = {
    format = 'cht-drift-run', version = 1, tag = tag,
    header = header,
    layoutName = app.layout.name, layoutHash = layoutMod.hash(app.layout, layoutText), layout = layoutCopy,
    scoring = app.cfg, fields = telemetry.fields, samples = rows, result = result,
  }
  storage.saveRun(record, function(err, path)
    if err then
      status('Mentési hiba: ' .. tostring(err), U.col.red)
      return
    end
    local file = path:match('[^/\\]+$')
    if record.result and app.lastResult == record.result and app.resultMeta then app.resultMeta.file = file end
    Runs.addToIndex({
      file = file, time = header.time, driver = header.driver, car = header.car,
      final = result and result.final or nil, zero = result and result.zeroRun or false,
      layout = app.layout.name, tag = tag,
    })
  end)
end

local function onEvent(ev, s)
  if ev.type == 'runStarted' then
    recorder:start(s.t)
    local car = app.car()
    runHeader = telemetry.header(car, { appVersion = APP_VERSION, time = storage.timestampHuman() })
    if ev.restarted then status('Futás újraindult (START újra átlépve).', U.col.yellow) end
  elseif ev.type == 'runFinished' then
    local rows = recorder:stop()
    local res = ev.result
    app.lastResult = res
    app.resultMeta = { header = runHeader, time = runHeader and runHeader.time, layoutName = app.layout.name }
    app.resultLayout = app.layout
    app.resultCompiled = app.compiled
    app.livePartial = nil
    saveRecord(rows, res, nil)
    app.sendRunResult(res)
    if app.settings.ui.autoOpenResult ~= false then selectTab = 'result' end
    status(res.zeroRun and ('Nullás kör: ' .. table.concat(res.zeroReasons, ', ')) or ('Futás kész: ' .. U.t1(res.final) .. ' pont'),
      res.zeroRun and U.col.red or U.col.green, 10)
    if pendingRebuild then rebuildJudge() end
  elseif ev.type == 'runAborted' then
    local rows = recorder:stop()
    if app.settings.ui.saveAborted and rows and #rows > 0 then saveRecord(rows, nil, 'megszakitott') end
    app.livePartial = nil
    status('Futás megszakítva: ' .. (ev.reason or ''), U.col.orange)
    if pendingRebuild then rebuildJudge() end
  end
end

-- Finished runs go to everyone on the server (judges collect them): online script – unless the server
-- switched it off (sendResults = 0); installed app – unless switched off in Beállítások.
function app.sendRunResult(res)
  if app.passive then return end
  local allowed
  if platform.online then allowed = platform.flag('sendResults') else allowed = app.settings.ui.sendResults ~= false end
  if allowed then netsync.sendRun(res, app.layout and app.layout.name, APP_VERSION) end
end

function app.finishNow()
  local res = app.judge:finishNow()
  if res then onEvent({ type = 'runFinished', result = res }, app.lastSample) end
end

function app.discardRun()
  app.judge:reset()
  recorder:stop()
  app.livePartial = nil
  status('Futás elvetve.', U.col.dim)
  if pendingRebuild then rebuildJudge() end
end

function app.toggleFreeRecording()
  if app.freeRecorder:active() then
    local rows = app.freeRecorder:stop()
    runHeader = telemetry.header(app.car(), { appVersion = APP_VERSION, time = storage.timestampHuman() })
    saveRecord(rows, nil, 'szabad')
    status(string.format('Szabad felvétel elmentve (%d minta).', #rows), U.col.green)
  else
    app.freeRecorder:start(app.t)
    freeStartT = app.t
  end
end

function app.freeRecordTime() return app.t - freeStartT end

-- Open / re-score a saved run.
function app.openRun(file, rescore)
  local path = storage.runsDir() .. '/' .. file
  local rec = storage.readJSON(path)
  if type(rec) ~= 'table' then status('Nem sikerült beolvasni: ' .. file, U.col.red) return end
  local recLayout = layoutMod.sanitize(rec.layout)
  if not rescore and rec.result then
    app.lastResult = rec.result
    app.resultMeta = { header = rec.header, time = rec.header and rec.header.time, layoutName = rec.layoutName, file = file }
    app.resultLayout = recLayout
    app.resultCompiled = layoutMod.compile(recLayout, config.merge(rec.scoring))
    selectTab = 'result'
    return
  end
  -- re-score with the current layout (or the embedded one if the current has no zones) and current settings
  local useLayout = (#app.layout.zones > 0) and app.layout or recLayout
  local compiled = layoutMod.compile(useLayout, app.cfg)
  local judge = scoring.newJudge(compiled, app.cfg, rec.header or {})
  local fields = rec.fields or telemetry.fields
  local rows = rec.samples or {}
  local result = nil
  for _, row in ipairs(rows) do
    local ev = judge:feed(telemetry.unpack(row, fields))
    if ev and ev.type == 'runFinished' then result = ev.result break end
  end
  if not result and judge.state == 'judging' then result = judge:finishNow() end
  if not result and #rows > 1 then
    -- recording never crossed the gates: judge the whole recording
    judge = scoring.newJudge(compiled, app.cfg, rec.header or {})
    judge:forceStart(telemetry.unpack(rows[1], fields).t, true)
    for i = 1, #rows do judge:feed(telemetry.unpack(rows[i], fields)) end
    result = judge:finishNow()
  end
  if not result then status('Ebből a felvételből nem lett eredmény.', U.col.orange) return end
  app.lastResult = result
  app.resultMeta = { header = rec.header, time = (rec.header and rec.header.time or '') .. ' (újrapontozva)', layoutName = useLayout.name }
  app.resultLayout = useLayout
  app.resultCompiled = compiled
  selectTab = 'result'
  status('Újrapontozva: ' .. (result.zeroRun and 'nullás kör' or U.t1(result.final)), U.col.green)
end

-- Init ---------------------------------------------------------------------------------------------

do
  local key = storage.trackKey()
  local name = app.settings.activeLayouts[key]
  local names = storage.listLayouts()
  if not name and #names > 0 then name = names[1] end
  if name then
    app.loadLayout(name)
  else
    app.layout = layoutMod.new(ac.getTrackFullID('/'), 'Alap')
    app.recompile()
  end
end
editor.init(app)
telemetry.watchJumps(0)
netsync.init(app)
if rawget(_G, '__STUB') then _G.__CHT_APP = app end -- offline smoke tests only

-- Online: layouts come from the server's GitHub folder ------------------------------------------------
-- layouts/<track>/index.json (optional list of names) and layouts/<track>/<name>.json. A downloaded
-- layout is kept on the PC (CSP storage), so the next join works even before the download finishes.
function app.loadServerLayouts(force)
  if not platform.online then return end
  app.remote = { state = 'loading', names = {}, started = os.clock() }
  local wanted = tostring(platform.server.layout or '')
  local function fetchOne(name, makeActive)
    storage.fetchJSON(storage.remoteLayoutURL(name), function(err, data)
      if err or type(data) ~= 'table' then
        if makeActive then
          app.remote.state = 'error'
          app.remote.error = string.format('„%s”: %s', name, tostring(err))
        end
        return
      end
      local l = layoutMod.sanitize(data)
      l.name = name
      storage.writeJSON(storage.layoutPath(name), l)
      app.serverLayouts[name] = true
      app.remote.names[#app.remote.names + 1] = name
      if makeActive then
        app.remote.state = 'ok'
        app.remote.active = name
        local cur = app.layout
        local curIsServer = cur and app.serverLayouts[cur.name]
        if force or not cur or #cur.zones == 0 or curIsServer or cur.name == name then
          if not app.judge or app.judge.state == 'idle' then
            app.loadLayout(name)
            status('Pályaterv a szerverről: ' .. name, U.col.green, 6)
          end
        end
      end
    end)
  end
  storage.fetchJSON(storage.remoteIndexURL(), function(err, idx)
    local names = {}
    if not err and type(idx) == 'table' then
      for _, n in ipairs(idx) do if type(n) == 'string' and n ~= '' then names[#names + 1] = n end end
    end
    if wanted == '' then wanted = names[1] or 'Alap' end
    app.remote.wanted = wanted
    fetchOne(wanted, true)
    for _, n in ipairs(names) do if n ~= wanted then fetchOne(n, false) end end
  end)
end
if platform.online then app.loadServerLayouts(false) end

-- Main loop ----------------------------------------------------------------------------------------

-- Online windows state (the installed app has real app windows from manifest.ini)
local onlineUI = { main = false, hud = false, welcomed = false }
app.onlineUI = onlineUI

local function hotkeys()
  if controls.pressed('zones') then app.toggleTrackDraw() end
  if platform.online then
    if controls.pressed('main') then onlineUI.main = not onlineUI.main end
    if controls.pressed('hud') then
      onlineUI.hud = not onlineUI.hud
      app.settings.ui.onlineHud = onlineUI.hud
      app.saveSoon()
    end
  end
end

local passiveCheckAt = 0
local function updatePassive()
  if not platform.online then
    netsync.beat(APP_VERSION)
    return
  end
  if os.clock() < passiveCheckAt then return end
  passiveCheckAt = os.clock() + 1
  local was = app.passive
  app.passive = netsync.installedAppRunning()
  if app.passive ~= was and app.judge and app.judge.state ~= 'idle' then app.judge:reset(); recorder:stop() end
end

local function updateFrame(dt)
  local sim = ac.getSim()
  updatePassive()
  if app.passive then return end
  hotkeys()
  if statusUntil > 0 and now() > statusUntil then app.statusMessage, statusUntil = nil, 0 end
  if sim.isReplayActive or sim.isPaused or sim.dt <= 0 then return end
  local car = app.car()
  if not car then return end
  if app.watchedCar ~= car.index then
    telemetry.watchJumps(car.index)
    if app.watchedCar ~= nil and app.judge.state ~= 'idle' then
      app.judge:reset()
      recorder:stop()
      status('Másik autó lett kiválasztva – a futás megszakadt.', U.col.orange)
    end
    app.watchedCar = car.index
    rebuildJudge()
  end
  app.t = app.t + sim.dt
  local raw = telemetry.sample(car, app.t)
  app.lastSample = raw
  -- the judge gets exactly the (rounded) values that go into the recording, so re-scoring a saved
  -- run reproduces the live result exactly
  local row = telemetry.pack(raw)
  local s = telemetry.unpack(row)
  recorder:pushRow(row)
  if app.freeRecorder:active() then
    app.freeRecorder:pushRow(row)
    if app.freeRecorder.overflow then app.toggleFreeRecording() end
  end
  local ok, ev = pcall(app.judge.feed, app.judge, s)
  if not ok then
    ac.error('CHT Drift Judge hiba:', ev)
    status('Belső hiba a pontozásban: ' .. tostring(ev), U.col.red, 15)
    app.judge:reset()
    recorder:stop()
  elseif ev then
    onEvent(ev, s)
  end
  partialTimer = partialTimer + sim.dt
  if partialTimer > 0.25 then
    partialTimer = 0
    local zones, sum = app.judge:partial()
    app.livePartial = zones and { zones = zones, sum = sum } or nil
  end
  editor.update(car)
  flushSave()
end

-- Installed app: errors show up in CSP's Lua debug app as usual. Online script: an error must not stop
-- the script for the rest of the session, so it is caught, logged and shown in the status line.
if platform.online then
  local updateErrors = 0
  function script.update(dt)
    if updateErrors > 50 then return end
    local ok, err = pcall(updateFrame, dt)
    if not ok then
      updateErrors = updateErrors + 1
      ac.error('CHT Drift Judge (frissítés):', err)
      status('Belső hiba: ' .. tostring(err), U.col.red, 15)
    end
  end
else
  script.update = updateFrame
end

-- 3D -------------------------------------------------------------------------------------------------

-- Editor mode = the Pálya tab is open (drawn in the last half second) or a point is being placed.
app.editorSeenAt = -100
function app.editorActive()
  return editor.isPlacing() or (os.clock() - app.editorSeenAt) < 0.5
end

local function drawTrack()
  if app.passive then return end
  -- a screen capture for the paint detector is being made: the app's own drawings must not be on it
  if editor.overlaysHidden() then return end
  local ui_ = app.settings.ui
  local placing = editor.isPlacing()
  local ed = app.editorActive()
  local function vis(key) return placing or visibility.visible(app.settings, key, ed) end
  local opts = editor.drawOptions()
  opts.depthOff = ui_.depthOff == true or placing
  opts.showBands = ui_.showBands ~= false
  opts.labels = vis('names')
  opts.zoneLines = vis('zones')
  opts.gates = vis('gates')
  opts.settings = app.settings
  opts.cfg = app.cfg
  opts.fill = vis('fills')
  opts.fillOff = vis('offtrack')
  opts.fillAlpha = type(ui_.fillAlpha) == 'number' and ui_.fillAlpha or 0.25
  if vis('bins') and app.lastResult and app.resultLayout == app.layout then
    opts.bins = {}
    for _, z in ipairs(app.lastResult.zones or {}) do if z.index then opts.bins[z.index] = z.bins end end
  end
  if opts.labels or opts.zoneLines or opts.gates or opts.fill or opts.fillOff or opts.bins then
    draw3d.drawLayout(app.layout, app.compiled, opts)
  end
  if vis('trace') and app.lastResult and app.resultLayout == app.layout then
    draw3d.drawTrace(app.lastResult.trace)
  end
  editor.render3D()
end

-- Installed app: CSP's render event. Online script: script.draw3D (called with the transparent objects).
if platform.online then
  local drawErrors = 0
  function script.draw3D()
    if drawErrors > 20 then return end
    local ok, err = pcall(drawTrack)
    if not ok then
      drawErrors = drawErrors + 1
      ac.error('CHT Drift Judge (rajz):', err)
    end
  end
else
  render.on('main.track.transparent', drawTrack)
end

-- Windows ------------------------------------------------------------------------------------------

local function tabFlags(id)
  if selectTab == id then
    selectTab = nil
    return ui.TabItemFlags.SetSelected
  end
  return ui.TabItemFlags.None
end

local globalQuery = ''
local showAllTodo = false

local function topBar()
  U.text('CHT Drift Judge', 18, U.col.text, true)
  ui.sameLine(0, 12)
  U.pill('Pályaterv: ' .. (app.layout.name or '?'), U.col.purple)
  U.tip('A pályán most használt pályaterv. Váltani a Pálya fül 1. lépésénél lehet.')
  if app.dirty then
    ui.sameLine(0, 6)
    U.pill('Nem mentett változás', U.col.orange)
    U.tip('A pályatervben mentés nélküli változás van – a Teendők között egy kattintással elmentheted.')
  end
  ui.sameLine(0, 6)
  U.pill('v' .. APP_VERSION .. (platform.online and ' · online' or ''), U.col.dim)
  U.tip(platform.online and 'A szerverről kapott (online) változat: mindig a legfrissebb, de fájlt nem ment. A futások csak erre a menetre maradnak meg.'
    or 'A telepített változat (apps/lua/CHT_DriftJudge).')
  ui.sameLine(0, 6)
  local drawOn = visibility.masterOn(app.settings)
  if U.button((drawOn and 'Pályarajz: BE' or 'Pályarajz: KI') .. '##trackDraw', 0, false,
    'Egy kattintással elrejti / megmutatja mindazt, amit a program a pályára rajzol (zónák, színek, kapuk, feliratok, nyomvonal). Gyorsbillentyű: ' .. app.hotkeyText('zones') .. '. Hogy bekapcsolva mi látszódjon: Beállítások → Mi látszódjon a pályán.') then
    app.toggleTrackDraw()
  end
  ui.sameLine(math.max(560, ui.windowWidth() - 350))
  globalQuery = U.searchBox('global', 'Keresés mindenben: beállítás, zóna, futás, súgó…', globalQuery, 330)
end

-- Teendők panel display mode: 'panel' (always) | 'errors' (only while there is a HIBA) | 'hidden'
local function todoMode()
  local m = app.settings.ui.todoMode
  if m == 'errors' or m == 'hidden' then return m end
  return 'panel'
end

local function todoSummary(items)
  local c = todo.counts(items)
  local parts = {}
  if c.error > 0 then parts[#parts + 1] = string.format('%d hiba', c.error) end
  if c.warn > 0 then parts[#parts + 1] = string.format('%d figyelmeztetés', c.warn) end
  if c.info > 0 then parts[#parts + 1] = string.format('%d infó', c.info) end
  local level = c.error > 0 and 'error' or (c.warn > 0 and 'warn' or (c.info > 0 and 'info' or 'ok'))
  return (#parts > 0 and table.concat(parts, ' · ') or 'RENDBEN'), level, c
end

-- Small line under the top bar when the panel is hidden: summary + "Megjelenítés" button.
local function todoCompact(items, visible)
  local text, level = todoSummary(items)
  U.text('Teendők:', 13, U.col.dim)
  ui.sameLine(0, 6)
  U.pill(text, U.levelColors[level])
  ui.sameLine(0, 8)
  if visible then
    if U.button('Teendők elrejtése##todoHide', 0, false, 'Elrejti a panelt. A felső sorban továbbra is látszik, hány teendő van.') then
      app.settings.ui.todoMode = 'hidden'; app.saveSoon()
    end
  else
    if U.button('Teendők megjelenítése##todoShow', 0, false, 'Megnyitja a Teendők panelt.') then
      app.settings.ui.todoMode = 'panel'; app.saveSoon()
    end
  end
end

local function todoPanel(items, hidden)
  local badge, level = todoSummary(items)
  U.collapsible('todo', 'Teendők', {
    sub = #items == 0 and 'minden rendben, nincs teendő' or 'ami javításra vagy ellenőrzésre vár',
    badge = badge, badgeColor = U.levelColors[level], level = level, defaultOpen = true,
    tip = 'HIBA = javítani kell, FIGYELEM = érdemes ellenőrizni, INFÓ = tudnivaló. Amit rendben lévőnek tartasz, azt a „Rendben, így jó” gombbal jóváhagyhatod.',
  }, function()
    U.text('Megjelenés:', 12, U.col.dim)
    local modes = { { 'panel', 'Mindig látszik' }, { 'errors', 'Csak ha HIBA van' }, { 'hidden', 'Elrejtve' } }
    for _, m in ipairs(modes) do
      ui.sameLine(0, 6)
      if U.button(m[2] .. (todoMode() == m[1] and ' (aktív)' or '') .. '##todoMode' .. m[1], 0, false,
        ({ panel = 'A panel mindig látszik.', errors = 'A panel csak akkor jelenik meg, ha HIBA van; különben csak a felső sor mutatja a számot.', hidden = 'A panel rejtve; a felső sorban látszik, hány teendő van, és onnan megnyitható.' })[m[1]]) then
        app.settings.ui.todoMode = m[1]; app.saveSoon()
      end
    end
    if #items == 0 then
      U.text('A pályaterv rendben van, és a legutóbbi futásban sem volt gyanús adat.', 13, U.col.green)
    end
    local limit = showAllTodo and #items or math.min(#items, 3)
    for i = 1, limit do
      local it = items[i]
      local buttons = {}
      if it.action then buttons[#buttons + 1] = { it.action.label, it.fix } end
      if it.ack then
        buttons[#buttons + 1] = { 'Rendben, így jó', it.ack == 'zone'
          and 'Jóváhagyod, hogy ez így rendben van: a pályatervbe mentődik, és amíg a zóna vonala nem változik, nem szól érte.'
          or 'Elrejti ezt a tételt (a játék újraindításáig, vagy amíg nem változik).' }
      end
      local b = U.notice('todo' .. i, it.level, it.title, it.fix, buttons)
      if b then
        local which = buttons[b][1]
        if which == 'Rendben, így jó' then app.ackTodoItem(it) else runTodoAction(it.action) end
      end
    end
    if #items > 3 then
      if U.button(showAllTodo and 'Kevesebb mutatása##todo' or string.format('Mind a %d teendő mutatása##todo', #items), 0) then showAllTodo = not showAllTodo end
    end
    if hidden and #hidden > 0 then
      U.collapsible('todoHidden', string.format('Jóváhagyva / elrejtve (%d)', #hidden), { defaultOpen = false,
        sub = 'innen visszaállíthatod őket', tip = 'Amit a „Rendben, így jó” gombbal jóváhagytál vagy elrejtettél.' }, function()
        for k, it in ipairs(hidden) do
          U.text((it.approved and 'Jóváhagyva: ' or 'Elrejtve: ') .. it.title, 12, U.col.dim)
          ui.sameLine(0, 8)
          if U.button('Visszaállítás##todoRestore' .. k, 0, false, 'Újra megjelenik a Teendők között.') then app.restoreTodoItem(it) end
        end
      end)
    end
  end)
end

local function searchResults()
  local q = globalQuery
  local any = false
  U.collapsible('gsearch', 'Keresés: „' .. q .. '”', { sub = 'kattints egy találatra', forceOpen = true, level = 'info' }, function()
    -- settings
    local hits = {}
    for _, it in ipairs(schema.items) do if schema.matches(it, q) then hits[#hits + 1] = it end end
    if #hits > 0 then
      any = true
      U.text(string.format('Beállítások (%d)', #hits), 14, U.col.text, true)
      for i = 1, math.min(#hits, 6) do
        local it = hits[i]
        local g = schema.groupById[it.group]
        if U.button(string.format('%s – %s: %s##gs_set%d', g and g.title or '', it.label, schema.format(it, schema.get(app.settings, it)), i), 0, false, it.desc) then
          Settings.focus(it.label, false); selectTab = 'settings'; globalQuery = ''
        end
        if schema.isChanged(app.settings, it) then ui.sameLine(0, 6); U.pill('MÓDOSÍTVA', U.col.purple) end
      end
      if #hits > 6 and U.button(string.format('Mind a %d beállítás a Beállítások fülön##gs_setall', #hits), 0) then
        Settings.focus(q, false); selectTab = 'settings'; globalQuery = ''
      end
    end
    -- zones
    local zi = app.zoneIssues()
    local zhits = {}
    for i, z in ipairs(app.layout.zones) do
      local hay = z.name .. ' ' .. (layoutMod.zoneTypeShort[z.type] or '') .. ' ' .. (layoutMod.zoneTypeNames[z.type] or '') .. ' zóna'
      for _, iss in ipairs(zi[i] or {}) do hay = hay .. ' ' .. iss.short .. ' hiba' end
      if schema.textMatches(hay, q) then zhits[#zhits + 1] = i end
    end
    if #zhits > 0 then
      any = true
      U.text(string.format('Zónák (%d)', #zhits), 14, U.col.text, true)
      for _, i in ipairs(zhits) do
        local z = app.layout.zones[i]
        local w = todo.worst(zi[i])
        if U.button(string.format('%d. %s [%s]##gs_z%d', i, z.name, layoutMod.zoneTypeShort[z.type] or z.type, i), 0, false, 'Megnyitás a Pálya fülön') then
          app.openZone(i); globalQuery = ''
        end
        if w then ui.sameLine(0, 6); U.pill(U.levelNames[w], U.levelColors[w]) end
      end
    end
    -- runs
    local rhits = Runs.search(q)
    if #rhits > 0 then
      any = true
      U.text(string.format('Futások (%d)', #rhits), 14, U.col.text, true)
      for k = 1, math.min(#rhits, 5) do
        local e = rhits[k].entry
        local sc = e.final == nil and '–' or (e.zero and 'NULLÁS' or U.t1(e.final))
        if U.button(string.format('%s · %s · %s##gs_r%d', e.time ~= '' and e.time or e.file, tostring(e.driver or '?'), sc, k), 0, false, 'A futás megnyitása az Eredmény fülön') then
          app.openRun(e.file, false); globalQuery = ''
        end
      end
    end
    -- help
    local hh = help.search(q, schema.textMatches)
    if #hh > 0 then
      any = true
      U.text(string.format('Súgó (%d)', #hh), 14, U.col.text, true)
      for k, t in ipairs(hh) do
        if k > 4 then break end
        U.text(t.title, 13, U.col.purple, true)
        U.wrapped(t.text, 12, U.col.text)
        if t.tab and U.button('Odaugrás##gs_h' .. k, 0, false, 'Átvált a megfelelő fülre') then
          if t.tab == 'settings' then Settings.focus(t.query or '', false) end
          selectTab = t.tab; globalQuery = ''
        end
      end
    end
    if not any then
      U.text('Nincs találat. Próbáld egy rövidebb szóval – ékezet nélkül is működik (pl. „korrekcio”).', 13, U.col.dim)
    end
  end)
end

function script.windowMain(dt)
  topBar()
  local items, hiddenItems = app.todoItems()
  if globalQuery ~= '' then searchResults() end
  local tm = todoMode()
  local nErr = todo.counts(items).error
  local showPanel = tm == 'panel' or (tm == 'errors' and nErr > 0)
  if showPanel then
    todoPanel(items, hiddenItems)
  else
    todoCompact(items, false)
  end

  local nZoneErr = 0
  for _, it in ipairs(items) do
    if it.level == 'error' and (it.area == 'layout' or (it.action and it.action.kind == 'zone')) then nZoneErr = nZoneErr + 1 end
  end
  local resWarn = app.lastResult and #(app.lastResult.warningItems or app.lastResult.warnings or {}) or 0
  local nChanged = #schema.changedList(app.settings)

  ui.tabBar('chtTabs', ui.TabBarFlags.None, function()
    ui.tabItem('Élő###liveTab', tabFlags('live'), function()
      ui.childWindow('##live', vec2(ui.availableSpaceX(), ui.availableSpaceY() - 22), false, ui.WindowFlags.None, function()
        Live.drawTab(app)
      end)
    end)
    ui.tabItem('Eredmény' .. (resWarn > 0 and ' (!)' or '') .. '###resTab', tabFlags('result'), function()
      ui.childWindow('##res', vec2(ui.availableSpaceX(), ui.availableSpaceY() - 22), false, ui.WindowFlags.None, function()
        if platform.canSeeScores() then
          Result.draw(app.lastResult, app.resultMeta, app.resultLayout, app.resultCompiled, app)
        else
          U.notice('noScores', 'info', 'A pontszámot a bírók látják', 'Ezen a szerveren a pontokat csak a bírók és a közvetítő látják. A futásod adatai a bírókhoz mennek.')
        end
      end)
    end)
    ui.tabItem('Futások###runsTab', tabFlags('runs'), function() Runs.drawRunsTab(app) end)
    ui.tabItem('Pálya' .. (app.dirty and ' *' or '') .. (nZoneErr > 0 and string.format(' (%d hiba)', nZoneErr) or '') .. '###palyaTab', tabFlags('editor'), function()
      app.editorSeenAt = os.clock()
      ui.childWindow('##ed', vec2(ui.availableSpaceX(), ui.availableSpaceY() - 22), false, ui.WindowFlags.None, function()
        editor.drawTab()
      end)
    end)
    ui.tabItem('Beállítások' .. (nChanged > 0 and string.format(' (%d mód.)', nChanged) or '') .. '###setTab', tabFlags('settings'), function()
      ui.childWindow('##set', vec2(ui.availableSpaceX(), ui.availableSpaceY() - 22), false, ui.WindowFlags.None, function()
        Settings.drawTab(app)
      end)
    end)
  end)
  if app.statusMessage then
    ui.setCursorY(ui.windowHeight() - 26)
    ui.textColored(app.statusMessage, app.statusColor or U.col.dim)
  end
  flushSave()
end

function script.windowHud(dt)
  Live.drawHud(app)
end

function script.windowHudSettings(dt)
  Live.drawHudSettings(app)
  flushSave()
end

-- Online windows (the server sends the program as an online script: there are no app windows) ---------
-- Main window: Ctrl+Shift+D (or the chat app's menu); HUD: Ctrl+Shift+H. Both can be moved by their top
-- bar; the main window can be resized by its bottom right corner. Positions are saved in the settings.
local function screenSize()
  local okU, uiState = pcall(ac.getUI)
  local sz = okU and uiState and uiState.windowSize
  if sz and sz.x and sz.x > 100 then return sz.x, sz.y end
  return 1920, 1080
end

local function storedVec(key, dx, dy)
  local t = app.settings.ui[key]
  if type(t) == 'table' and type(t[1]) == 'number' and type(t[2]) == 'number' then return t[1], t[2] end
  return dx, dy
end

local function clampWindow(x, y, w, h)
  local sw, sh = screenSize()
  w = math.max(320, math.min(w, sw))
  h = math.max(200, math.min(h, sh))
  x = math.max(0, math.min(x, sw - 60))
  y = math.max(0, math.min(y, sh - 40))
  return x, y, w, h
end

local function mouseDelta()
  if type(ui.mouseDelta) ~= 'function' then return 0, 0 end
  local ok, d = pcall(ui.mouseDelta)
  if ok and d then return d.x or 0, d.y or 0 end
  return 0, 0
end

-- A movable window. opts: { id, title, posKey, sizeKey, defPos = {x,y}, defSize = {w,h}, resizable, closable,
-- inputs (default true), bar (default true), transparent }
local function onlineWindow(opts, content)
  local sw, sh = screenSize()
  local x, y = storedVec(opts.posKey, opts.defPos[1], opts.defPos[2])
  local w, h = storedVec(opts.sizeKey, opts.defSize[1], opts.defSize[2])
  x, y, w, h = clampWindow(x, y, w, h)
  local closed = false
  local moved = false
  local fn = opts.transparent and ui.transparentWindow or ui.toolWindow
  fn(opts.id, vec2(x, y), vec2(w, h), false, opts.inputs ~= false, function()
    if opts.bar ~= false then
      local barW = ui.availableSpaceX() - (opts.closable and 30 or 0)
      local c = ui.getCursor()
      ui.invisibleButton('##bar_' .. opts.id, vec2(math.max(40, barW), 22))
      if ui.itemActive() then
        local dx, dy = mouseDelta()
        if dx ~= 0 or dy ~= 0 then x, y = x + dx, y + dy; moved = true end
      end
      U.tip('Húzd ide kattintva az ablak mozgatásához.')
      ui.setCursorX(c.x)
      ui.setCursorY(c.y)
      U.text(opts.title, 14, U.col.text, true)
      if opts.closable then
        ui.sameLine(math.max(60, ui.windowWidth() - 36))
        if U.button('×##close_' .. opts.id, 24, false, 'Bezárás (' .. (opts.hotkey or '') .. ')') then closed = true end
      end
      ui.separator()
    end
    content()
    if opts.resizable then
      local ws = ui.windowSize()
      ui.setCursorX(ws.x - 18)
      ui.setCursorY(ws.y - 18)
      ui.invisibleButton('##grip_' .. opts.id, vec2(16, 16))
      if ui.itemActive() then
        local dx, dy = mouseDelta()
        if dx ~= 0 or dy ~= 0 then w, h = w + dx, h + dy; moved = true end
      end
      U.tip('Húzd az ablak átméretezéséhez.')
      ui.drawRectFilled(vec2(ws.x - 12, ws.y - 12), vec2(ws.x - 4, ws.y - 4), rgbm(0.6, 0.6, 0.7, 0.6), 2)
    end
  end)
  if moved then
    x, y, w, h = clampWindow(x, y, w, h)
    app.settings.ui[opts.posKey] = { x, y }
    if opts.sizeKey then app.settings.ui[opts.sizeKey] = { w, h } end
    app.saveSoon()
  end
  return closed
end

local function welcome()
  if onlineUI.welcomed then return end
  onlineUI.welcomed = true
  onlineUI.hud = app.settings.ui.onlineHud == true
  if not platform.flag('showWelcome') then return end
  local text = string.format('CHT Drift Judge %s betöltve a szerverről. Fő ablak: %s, HUD: %s, pályarajz ki-be: %s.',
    APP_VERSION, app.hotkeyText('main'), app.hotkeyText('hud'), app.hotkeyText('zones'))
  local ok = false
  if type(ui.toast) == 'function' then
    ok = pcall(ui.toast, ui.Icons and (ui.Icons.Info or ui.Icons.Settings) or nil, text)
  end
  if not ok then status(text, U.col.green, 12) end
end

-- Chat app menu entry (CSP's online extras), when this CSP version has it.
local function registerExtras()
  if type(ui.registerOnlineExtra) ~= 'function' then return end
  pcall(ui.registerOnlineExtra, ui.Icons and (ui.Icons.Settings or ui.Icons.Info) or nil, 'CHT Drift Judge', function() return not app.passive end, function()
    U.text('CHT Drift Judge ' .. APP_VERSION, 15, U.col.text, true)
    if U.button(onlineUI.main and 'Fő ablak bezárása' or 'Fő ablak megnyitása', 180) then onlineUI.main = not onlineUI.main end
    if U.button(onlineUI.hud and 'HUD elrejtése' or 'HUD megjelenítése', 180) then
      onlineUI.hud = not onlineUI.hud; app.settings.ui.onlineHud = onlineUI.hud; app.saveSoon()
    end
    if U.button(visibility.masterOn(app.settings) and 'Pályarajz kikapcsolása' or 'Pályarajz bekapcsolása', 180) then app.toggleTrackDraw() end
    U.text(string.format('Gyorsbillentyűk: fő ablak %s · HUD %s · pályarajz %s', app.hotkeyText('main'), app.hotkeyText('hud'), app.hotkeyText('zones')), 12, U.col.dim)
  end, nil, ui.OnlineExtraFlags and ui.OnlineExtraFlags.Tool or nil)
end

if platform.online then
  registerExtras()
  local uiErrors = 0
  function script.drawUI()
    if app.passive or uiErrors > 20 then return end
    local ok, err = pcall(function()
      welcome()
      if onlineUI.hud then
        onlineWindow({ id = 'chtOnlineHud', title = 'CHT Drift HUD', posKey = 'onlineHudPos', sizeKey = 'onlineHudSize',
          defPos = { 30, 220 }, defSize = { 260, 420 }, transparent = true,
          -- the HUD can be moved only while the main window is open (otherwise clicks go to the game)
          inputs = onlineUI.main, bar = onlineUI.main }, function() Live.drawHud(app) end)
      end
      if onlineUI.main then
        local sw, sh = screenSize()
        local closed = onlineWindow({ id = 'chtOnlineMain', title = 'CHT Drift Judge – szerverről (online)', posKey = 'onlineMainPos',
          sizeKey = 'onlineMainSize', defPos = { math.max(0, sw / 2 - 490), 80 }, defSize = { 980, 760 },
          resizable = true, closable = true, hotkey = app.hotkeyText('main') }, function()
          ui.childWindow('##onlineMainBody', vec2(ui.availableSpaceX(), ui.availableSpaceY()), false, ui.WindowFlags.None, function()
            script.windowMain(0)
          end)
        end)
        if closed then onlineUI.main = false end
      end
    end)
    if not ok then
      uiErrors = uiErrors + 1
      ac.error('CHT Drift Judge (ablak):', err)
      status('Hiba az ablak rajzolásában: ' .. tostring(err), U.col.red, 15)
    end
  end
end
