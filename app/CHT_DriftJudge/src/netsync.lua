-- CHT Drift Judge – messages between the PCs on the server (ac.OnlineEvent) and between the installed
-- app and the online script on the same PC (ac.connect).
--
-- Run results: when a run is finished on a pilot's PC, a short summary is sent to everyone on the server
-- (the judges collect them in Futások → Szerverről érkezett futások). The pilot's own PC measures at full
-- frame rate, so this is more exact than judging a remote car from 18 Hz position updates.
-- Only on custom servers (AssettoServer: direct messaging); on the original Kunos server the messages
-- would go through the chat, so nothing is sent there.
--
-- Presence: the installed app writes a heartbeat into a shared structure; if the online script (sent by
-- the server) sees a fresh heartbeat on the same PC, it stays passive – no double HUD, drawing or sending.

local platform = require('src/platform')
local storage = require('src/storage')

local N = {}
N.runs = {}          -- received results, newest first
N.maxRuns = 300
N.sendOk = nil       -- nil = not tried, true / false = last send
N.lastError = nil
N.receivedCount = 0

local function buildLayout()
  local S = ac.StructItem
  return {
    S.key('cht.driftjudge.run.v1'),
    runId = S.uint32(),
    final = S.float(), line = S.float(), angle = S.float(), style = S.float(),
    zero = S.boolean(), zeroReason = S.string(40),
    layout = S.string(32),
    corrections = S.byte(), wallSaves = S.byte(), oneWheel = S.byte(), twoWheel = S.byte(), overRot = S.byte(),
    duration = S.float(), avgSpeed = S.float(), maxAngle = S.float(),
    appVersion = S.string(12),
  }
end

local sendFn = nil
local app = nil

local function namespace()
  return (ac.SharedNamespace and ac.SharedNamespace.Shared) or 'shared'
end

-- Copies a received message into a plain Lua table (the message object is reused by CSP).
local function str(v) if v == nil then return '' end return tostring(v) end
local function num(v) return tonumber(v) or 0 end

function N.receive(sender, msg)
  if not msg then return end
  local idx = sender and sender.index or -1
  local runId = num(msg.runId)
  for _, e in ipairs(N.runs) do
    if e.carIndex == idx and e.runId == runId then return end
  end
  local driver, car = '?', ''
  if idx >= 0 then
    local okD, d = pcall(ac.getDriverName, idx)
    if okD and d then driver = tostring(d) end
    local okC, c = pcall(ac.getCarName, idx)
    if okC and c then car = tostring(c) end
  end
  local e = {
    carIndex = idx, runId = runId, own = idx == 0,
    time = storage.timestampHuman(), driver = driver, car = car,
    final = num(msg.final), line = num(msg.line), angle = num(msg.angle), style = num(msg.style),
    zero = msg.zero == true, zeroReason = str(msg.zeroReason), layout = str(msg.layout),
    corrections = num(msg.corrections), wallSaves = num(msg.wallSaves), oneWheel = num(msg.oneWheel),
    twoWheel = num(msg.twoWheel), overRot = num(msg.overRot),
    duration = num(msg.duration), avgSpeed = num(msg.avgSpeed), maxAngle = num(msg.maxAngle),
    appVersion = str(msg.appVersion),
  }
  table.insert(N.runs, 1, e)
  while #N.runs > N.maxRuns do table.remove(N.runs) end
  N.receivedCount = N.receivedCount + 1
  N.save()
  if app and app.onServerRun then pcall(app.onServerRun, e) end
end

-- Received results are kept next to the runs (installed app: a file; online: for the session).
function N.path() return storage.runsDir() .. '/szerver_futasok.json' end
function N.save() pcall(storage.writeJSON, N.path(), N.runs) end
function N.load()
  local t = storage.readJSON(N.path())
  if type(t) == 'table' then N.runs = t end
end

function N.available()
  local sim = ac.getSim()
  return sendFn ~= nil and sim ~= nil and sim.directMessagingAvailable == true
end

function N.init(appRef)
  app = appRef
  N.load()
  if type(ac.OnlineEvent) ~= 'function' or not ac.StructItem then return end
  local ok, fn = pcall(ac.OnlineEvent, buildLayout(), function(sender, msg)
    local okR, err = pcall(N.receive, sender, msg)
    if not okR then N.lastError = tostring(err) end
  end, namespace())
  if ok then sendFn = fn else N.lastError = tostring(fn) end
end

local function clip(s, n)
  s = tostring(s or '')
  if #s <= n then return s end
  return s:sub(1, n)
end

-- Sends a finished run (result table of the judge). Returns true if it went out.
function N.sendRun(res, layoutName, appVersion)
  if not res or not N.available() then return false end
  local f = res.faults or {}
  local sp = res.split or {}
  local msg = {
    runId = math.floor((os.clock() * 1000 + math.random() * 1e6) % 4294967295),
    final = res.final or 0, line = sp.line or 0, angle = sp.angle or 0, style = sp.style or 0,
    zero = res.zeroRun == true, zeroReason = clip(table.concat(res.zeroReasons or {}, ', '), 39),
    layout = clip(layoutName or '', 31),
    corrections = math.min(255, f.corrections or 0), wallSaves = math.min(255, f.wallSaves or 0),
    oneWheel = math.min(255, f.oneWheel or 0), twoWheel = math.min(255, f.twoWheel or 0),
    overRot = math.min(255, f.overRotations or 0),
    duration = res.duration or 0, avgSpeed = res.avgSpeed or 0, maxAngle = res.maxAngle or 0,
    appVersion = clip(appVersion or '', 11),
  }
  local ok, r = pcall(sendFn, msg)
  N.sendOk = ok and r ~= false
  if not ok then N.lastError = tostring(r) end
  return N.sendOk
end

-- Presence ------------------------------------------------------------------------------------------
local presence = nil
local function presenceStruct()
  if presence ~= nil then return presence or nil end
  presence = false
  if type(ac.connect) ~= 'function' or not ac.StructItem then return nil end
  local ok, p = pcall(ac.connect, {
    ac.StructItem.key('cht.driftjudge.presence.v1'),
    appBeat = ac.StructItem.double(),
    appVersion = ac.StructItem.string(12),
  }, false, namespace())
  if ok and p then presence = p end
  return presence or nil
end

-- Installed app: call every frame.
function N.beat(version)
  local p = presenceStruct()
  if not p then return end
  pcall(function()
    p.appBeat = os.clock()
    p.appVersion = version or ''
  end)
end

-- Online script: is the installed app running on this PC (heartbeat in the last 3 seconds)?
function N.installedAppRunning()
  local p = presenceStruct()
  if not p then return false end
  local ok, t = pcall(function() return tonumber(p.appBeat) or 0 end)
  if not ok or t <= 0 then return false end
  return math.abs(os.clock() - t) < 3
end

function N.installedAppVersion()
  local p = presenceStruct()
  if not p then return nil end
  local ok, v = pcall(function() return tostring(p.appVersion or '') end)
  return ok and v or nil
end

return N
