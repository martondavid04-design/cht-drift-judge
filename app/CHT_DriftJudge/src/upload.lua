-- CHT Drift Judge – test data to the Google Sheet („CHT Drift Judge – tesztadatok”).
--
-- Every PC that runs the program (the online script from the server, or the installed app) sends its
-- data straight to the sheet over the internet (HTTPS, web.post) – nothing goes through the game server.
-- The receiving end is a Google Apps Script web app in the owner's Google account
-- (tools/gsheet_collector.gs), which writes the rows into the sheet.
--   session  once after the game started: version, CSP, mode, role, what this CSP version supports
--   run      every saved run (finished, aborted, free recording): summary + the full recording
--   debug    errors caught by the program, paint detection results (rate limited)
-- Online: the server can switch it off ([SCRIPT_…] upload = 0) or send it elsewhere (uploadUrl = …).
-- Installed app: Beállítások → „Tesztadatok küldése” (on by default while testing).
--
-- Requests go one at a time (CSP allows two at once, and layouts are downloaded too); a failed send is
-- retried 3 times (5 s, 20 s, 60 s later). The queue keeps at most 40 items / 8 MB, debug items go first.

local platform = require('src/platform')

local M = {}

-- Where the data goes (Apps Script web app „CHT Drift Judge – gyűjtő”) and the write key. The key is in
-- the public program, so it only lets someone add rows; reading the data needs another key.
M.url = 'https://script.google.com/macros/s/AKfycbx6H9E260jLGFlsHgxQuXOaNtfdQwWnAeWquPwv07lk8VayG8zfsf7z1PmXXhuOFWmM/exec'
M.key = 'Kwu8voShi5BWY71UMngoc6l39j3u'

M.maxQueue = 40
M.maxQueueBytes = 8 * 1024 * 1024
M.maxRunBytes = 6 * 1024 * 1024    -- a bigger run goes without its samples (the summary still arrives)
M.sessionDelay = 8                 -- s after start: layouts are downloaded first, driver and car are known
M.maxDebug = 40                    -- debug items per game start
M.debugRepeat = 60                 -- the same debug message at most once a minute
M.timeout = 90                     -- s without an answer = failed

M.stats = { sent = 0, failed = 0, dropped = 0, queued = 0, bytes = 0, lastError = nil, lastOkText = nil, lastOkAt = nil }

local app = nil
local queue, queueBytes = {}, 0
local inFlight = nil               -- { item, token, since }
local token = 0
local startedAt = nil
local sessionSent = false
local debugSeen, debugCount = {}, 0
local backoff = { 5, 20, 60 }
local maxTries = 4

M.clockFn = nil                    -- offline tests: a fake clock
local function clock() return (M.clockFn or os.clock)() end

local function newSessionId()
  local okT, t = pcall(os.time)
  local base = okT and t or math.floor(clock() * 1000)
  return string.format('%x-%04x', base, math.random(0, 0xffff))
end
M.sessionId = newSessionId()

local function configured()
  return M.target():find('^https://') ~= nil
end

function M.target()
  local u = platform.online and tostring(platform.server.uploadUrl or '') or ''
  if u == '' then u = M.url end
  return u
end

-- Is sending on? Online: the server decides (upload = 1 by default). Installed app: Beállítások.
-- While the installed app runs on the same PC, the online copy stays silent (the app sends).
function M.enabled()
  if not app or app.passive then return false end
  if type(web) ~= 'table' or type(web.post) ~= 'function' then return false end
  if platform.online then return platform.flag('upload') end
  return app.settings.ui.uploadData ~= false
end

function M.stateText()
  if not app then return 'nincs elindítva' end
  if not configured() then return 'nincs beállítva (hiányzik a táblázat címe)' end
  if type(web) ~= 'table' or type(web.post) ~= 'function' then return 'ez a CSP nem tud adatot küldeni (nincs web.post)' end
  if app.passive then return 'a telepített app küld ezen a gépen' end
  if platform.online and not platform.flag('upload') then return 'a szerver kikapcsolta (upload = 0)' end
  if not platform.online and app.settings.ui.uploadData == false then return 'kikapcsolva' end
  return 'bekapcsolva'
end

local function driverName()
  local ok, n = pcall(ac.getDriverName, 0)
  return ok and n or ''
end

local function clip(s, n)
  s = tostring(s or '')
  if #s > n then return s:sub(1, n) end
  return s
end

local function removeItem(item)
  for i, it in ipairs(queue) do
    if it == item then
      table.remove(queue, i)
      queueBytes = queueBytes - #item.body
      break
    end
  end
  M.stats.queued, M.stats.bytes = #queue, queueBytes
end

-- Makes room for `size` more bytes: oldest debug items first, then the oldest of anything – never the
-- one being sent.
local function makeRoom(size)
  local function full() return #queue >= M.maxQueue or queueBytes + size > M.maxQueueBytes end
  for _, kind in ipairs({ 'debug', 'session', 'run' }) do
    local i = 1
    while full() and i <= #queue do
      local it = queue[i]
      if it.kind == kind and not (inFlight and inFlight.item == it) then
        removeItem(it)
        M.stats.dropped = M.stats.dropped + 1
      else
        i = i + 1
      end
    end
    if not full() then return true end
  end
  return not full()
end

local function push(kind, msg, what)
  if not M.enabled() or not configured() then return false end
  msg.key = M.key
  msg.session = M.sessionId
  msg.version = app.version
  msg.mode = platform.online and 'online' or 'app'
  msg.driver = msg.driver or driverName()
  local ok, body = pcall(JSON.stringify, msg)
  if not ok or type(body) ~= 'string' then
    M.stats.lastError = 'JSON hiba: ' .. tostring(body)
    return false
  end
  if not makeRoom(#body) then
    M.stats.dropped = M.stats.dropped + 1
    return false
  end
  queue[#queue + 1] = { kind = kind, body = body, tries = 0, nextAt = 0, what = what or kind }
  queueBytes = queueBytes + #body
  M.stats.queued, M.stats.bytes = #queue, queueBytes
  return true
end

-- Session --------------------------------------------------------------------------------------------
local function screen()
  local ok, u = pcall(ac.getUI)
  local sz = ok and u and u.windowSize
  if sz and sz.x then return { math.floor(sz.x), math.floor(sz.y) } end
  return nil
end

local function caps()
  local okS, sim = pcall(ac.getSim)
  sim = okS and sim or {}
  local okC, code = pcall(ac.getPatchVersionCode)
  return {
    cspCode = okC and code or nil,
    steamIDfn = type(ac.getUserSteamID) == 'function',
    steamID = platform.steamID(),
    checkAdmin = type(ac.checkAdminPrivileges) == 'function',
    registerOnlineExtra = type(ui.registerOnlineExtra) == 'function',
    mouseDelta = type(ui.mouseDelta) == 'function',
    toast = type(ui.toast) == 'function',
    controlButton = ac.ControlButton ~= nil,
    onlineEvent = type(ac.OnlineEvent) == 'function',
    directMessaging = sim.directMessagingAvailable == true,
    connect = type(ac.connect) == 'function',
    onCarJumped = type(ac.onCarJumped) == 'function',
    storage = ac.storage ~= nil,
    io = type(io) == 'table' and type(io.save) == 'function',
    onlineRace = sim.isOnlineRace == true,
    screen = screen(),
    fps = sim.fps and math.floor(sim.fps) or nil,
    server = platform.online and {
      layout = platform.server.layout, pilotScores = platform.server.pilotScores,
      sendResults = platform.server.sendResults, judges = platform.server.judges ~= '' and 'van' or 'nincs',
    } or nil,
    remoteLayout = app.remote and { state = app.remote.state, active = app.remote.active, error = app.remote.error } or nil,
    installedApp = platform.online and platform.installedAppVersion() or nil,
  }
end

local function sendSession()
  sessionSent = true
  local car = app.car and app.car()
  local okN, carName = pcall(ac.getCarName, car and car.index or 0)
  local okV, csp = pcall(ac.getPatchVersion)
  local okA, sim = pcall(ac.getSim)
  push('session', {
    type = 'session',
    car = okN and carName or '', track = ac.getTrackFullID('/'), layout = app.layout and app.layout.name or '',
    csp = okV and csp or '', role = platform.serverRole() or (not platform.online and app.settings.ui.role) or 'pilóta',
    admin = okA and sim and sim.isAdmin == true,
    caps = caps(),
  }, 'belépés')
end

-- Runs -----------------------------------------------------------------------------------------------
local tagNames = { megszakitott = 'megszakított', szabad = 'szabad felvétel' }

local function compactResult(res)
  if type(res) ~= 'table' then return nil end
  local zones = {}
  for _, z in ipairs(res.zones or {}) do
    zones[#zones + 1] = {
      i = z.index, name = z.name, type = z.type, points = z.points, max = z.maxPoints, line = z.line, angle = z.angle,
      coverage = z.coverage, depth = z.depth, nogo = z.nogo, avgSpeed = z.avgSpeed,
    }
  end
  local warnings = {}
  for _, w in ipairs(res.warnings or {}) do warnings[#warnings + 1] = tostring(w) end
  return {
    final = res.final, before = res.beforeDeductions, deductions = res.deductions, deductionTotal = res.deductionTotal,
    split = res.split, style = res.style, zones = zones, faults = res.faults, zeroReasons = res.zeroReasons,
    warnings = warnings, distance = res.distance, entrySpeed = res.entrySpeed, entryAngle = res.entryAngle,
    avgAngle = res.avgAngle, minSpeed = res.minSpeed, finished = res.finished,
  }
end

local runCounter = 0
function M.run(record)
  if not M.enabled() or type(record) ~= 'table' then return false end
  runCounter = runCounter + 1
  local res = record.result
  local h = record.header or {}
  local f = res and res.faults or {}
  local sp = res and res.split or {}
  local runId = M.sessionId .. '-' .. runCounter
  local msg = {
    type = 'run', runId = runId, tag = tagNames[record.tag] or record.tag or 'futás',
    driver = h.driver, car = h.car, track = h.track, layout = record.layoutName,
    summary = {
      time = h.time,
      final = res and res.final, line = sp.line, angle = sp.angle, style = sp.style,
      zero = res and res.zeroRun == true, zeroReason = res and clip(table.concat(res.zeroReasons or {}, ', '), 290) or nil,
      oneWheel = f.oneWheel, twoWheel = f.twoWheel, corrections = f.corrections, wallSaves = f.wallSaves,
      overRot = f.overRotations, duration = res and res.duration, avgSpeed = res and res.avgSpeed, maxAngle = res and res.maxAngle,
    },
    result = compactResult(res),
    record = record,
  }
  -- very long recordings: the samples stay on the PC (installed app) / are left out
  local n = type(record.samples) == 'table' and #record.samples or 0
  if n * 240 > M.maxRunBytes then
    local slim = {}
    for k, v in pairs(record) do if k ~= 'samples' then slim[k] = v end end
    slim.samplesLeftOut = n
    msg.record = slim
  end
  local what = (msg.tag == 'futás' and res) and ('futás, ' .. (res.zeroRun and 'nullás' or string.format('%.1f pont', res.final or 0))) or msg.tag
  return push('run', msg, what)
end

-- Debug ----------------------------------------------------------------------------------------------
-- level: 'error' | 'warn' | 'info'; where: short place name; details: any table (JSON)
function M.debug(level, where, message, details)
  if not M.enabled() then return false end
  if debugCount >= M.maxDebug then return false end
  local sig = tostring(where) .. '|' .. clip(message, 200)
  local t = clock()
  if debugSeen[sig] and t - debugSeen[sig] < M.debugRepeat then return false end
  debugSeen[sig] = t
  debugCount = debugCount + 1
  return push('debug', { type = 'debug', level = level or 'error', where = clip(where, 60), message = clip(message, 2000), details = details }, 'debug: ' .. clip(where, 30))
end

-- Sending --------------------------------------------------------------------------------------------
local function finish(item, ok, err)
  if ok then
    removeItem(item)
    M.stats.sent = M.stats.sent + 1
    M.stats.lastOkText, M.stats.lastOkAt = item.what, clock()
    return
  end
  M.stats.lastError = err
  if item.tries >= maxTries or item.permanent then
    removeItem(item)
    M.stats.failed = M.stats.failed + 1
  else
    item.nextAt = clock() + (backoff[item.tries] or 60)
  end
end

local function onAnswer(myToken, item, err, response)
  if not inFlight or inFlight.token ~= myToken then return end -- late answer after a timeout
  inFlight = nil
  if err then finish(item, false, tostring(err)) return end
  local status = response and response.status or 0
  -- Apps Script answers with a redirect (302) to the result page; the row is already written by then.
  if status == 301 or status == 302 or status == 303 then finish(item, true) return end
  if status ~= 200 then finish(item, false, 'HTTP ' .. tostring(status)) return end
  local okP, data = pcall(JSON.parse, response.body or '')
  if not okP or type(data) ~= 'table' then finish(item, false, 'nem JSON válasz') return end
  if data.ok == false then
    -- a wrong key / type / size will not get better by retrying
    if data.error == 'key' or data.error == 'type' or data.error == 'size' then item.permanent = true end
    finish(item, false, 'a táblázat elutasította: ' .. tostring(data.error))
    return
  end
  finish(item, true)
end

local function sendNext()
  local t = clock()
  if inFlight then
    if t - inFlight.since > M.timeout then
      local item = inFlight.item
      inFlight = nil
      finish(item, false, 'nincs válasz ' .. M.timeout .. ' mp alatt')
    end
    return
  end
  local item = nil
  for _, it in ipairs(queue) do
    if t >= it.nextAt then item = it break end
  end
  if not item then return end
  item.tries = item.tries + 1
  token = token + 1
  local myToken = token
  inFlight = { item = item, token = myToken, since = t }
  local ok, e = pcall(web.post, M.target(), { ['Content-Type'] = 'application/json' }, item.body, function(err, response)
    onAnswer(myToken, item, err, response)
  end)
  if not ok then
    if inFlight and inFlight.token == myToken then inFlight = nil end
    finish(item, false, tostring(e))
  end
end

-- Called every frame (also while paused).
function M.update()
  if not app then return end
  if not startedAt then startedAt = clock() end
  if not sessionSent and clock() - startedAt > M.sessionDelay and M.enabled() then sendSession() end
  if #queue > 0 and M.enabled() then sendNext() end
end

function M.init(a)
  app = a
  startedAt = clock()
end

-- offline tests
function M._reset()
  queue, queueBytes, inFlight, sessionSent, debugSeen, debugCount, runCounter = {}, 0, nil, false, {}, 0, 0
  M.stats = { sent = 0, failed = 0, dropped = 0, queued = 0, bytes = 0 }
end
function M._queue() return queue end

return M
