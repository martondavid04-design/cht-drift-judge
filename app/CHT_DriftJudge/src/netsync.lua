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
--
-- Hello (0.3.15): every PC with the online script tells the others its own Steam ID (and version, role);
-- an admin's PC uses it to hand out judge / broadcaster roles in the Versenyzők tab (src/roles.lua), so
-- nobody has to collect Steam IDs. Sent a few seconds after joining, when someone joins, as an answer to
-- an unknown PC's hello (at most every 10 s) and every 2 minutes. Role ping: after an admin changed a
-- role, the PC concerned re-reads the role list at once.

local callable = require('src/fn').callable
local platform = require('src/platform')
local storage = require('src/storage')

local N = {}
N.runs = {}          -- received results, newest first
N.maxRuns = 300
N.sendOk = nil       -- nil = not tried, true / false = last send
N.lastError = nil
N.receivedCount = 0
N.peers = {}         -- [carIndex] = { steamId, role, appVersion, name, at } from the hello messages
N.helloSent = 0
N.helloEvery = 120
N.onRolePing = nil   -- set by src/roles.lua

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
local helloFn, pingFn = nil, nil
local app = nil
local helloAt = math.huge        -- clock() of the next hello (set by N.init)
local lastAnswer = -100
N.clockFn = nil
local function clock() return (N.clockFn or os.clock)() end

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

-- Hello and role ping ------------------------------------------------------------------------------
local function helloLayout()
  local S = ac.StructItem
  return { S.key('cht.driftjudge.hello.v1'), steamId = S.string(20), role = S.string(10), appVersion = S.string(12) }
end
local function pingLayout()
  local S = ac.StructItem
  return { S.key('cht.driftjudge.role.v1'), steamId = S.string(20) }
end

function N.receiveHello(sender, msg)
  if not msg then return end
  local idx = sender and sender.index or -1
  if idx <= 0 then return end -- own message (if the server echoes it) or unknown sender
  local id = tostring(msg.steamId or ''):match('^%d+$')
  local known = N.peers[idx] ~= nil and N.peers[idx].steamId == id
  local okD, d = pcall(ac.getDriverName, idx)
  N.peers[idx] = { steamId = id, role = tostring(msg.role or ''), appVersion = tostring(msg.appVersion or ''),
    name = okD and d and tostring(d) or '?', at = clock() }
  -- someone new: answer soon, so a PC that just joined learns everyone (at most every 10 s)
  if not known and clock() - lastAnswer > 10 then
    lastAnswer = clock()
    helloAt = math.min(helloAt, clock() + 1 + math.random() * 2)
  end
end

function N.sendHello()
  local me = platform.steamID()
  if not helloFn or not me or not N.available() then return false end
  local role = platform.serverRole() or ''
  local ok, r = pcall(helloFn, { steamId = me, role = role, appVersion = app and app.version or '' })
  if ok and r ~= false then N.helloSent = N.helloSent + 1 return true end
  if not ok then N.lastError = tostring(r) end
  return false
end

function N.sendRolePing(steamId)
  if not pingFn or not N.available() then return false end
  local ok, r = pcall(pingFn, { steamId = tostring(steamId or '') })
  return ok and r ~= false
end

-- Peer of a car (only if it is still on the server).
function N.peer(carIndex)
  local p = N.peers[carIndex]
  if not p then return nil end
  local okC, c = pcall(ac.getCar, carIndex)
  if not okC or not c or c.isConnected == false then return nil end
  return p
end

-- Every frame (also while the online script stays passive: only it knows this PC's Steam ID).
function N.update()
  if not helloFn then return end
  local t = clock()
  if t >= helloAt then
    -- not sent (messages not ready yet, no Steam ID): try again in 10 s
    helloAt = t + (N.sendHello() and N.helloEvery or 10)
  end
end

function N.init(appRef)
  app = appRef
  N.load()
  if not callable(ac.OnlineEvent) or not ac.StructItem then return end
  local ok, fn = pcall(ac.OnlineEvent, buildLayout(), function(sender, msg)
    local okR, err = pcall(N.receive, sender, msg)
    if not okR then N.lastError = tostring(err) end
  end, namespace())
  if ok then sendFn = fn else N.lastError = tostring(fn) end
  local okH, h = pcall(ac.OnlineEvent, helloLayout(), function(sender, msg)
    local okR, err = pcall(N.receiveHello, sender, msg)
    if not okR then N.lastError = tostring(err) end
  end, namespace())
  if okH then helloFn = h; helloAt = clock() + 5 end
  local okP, pf = pcall(ac.OnlineEvent, pingLayout(), function(sender, msg)
    if msg and N.onRolePing then pcall(N.onRolePing, tostring(msg.steamId or '')) end
  end, namespace())
  if okP then pingFn = pf end
  -- someone joined: say hello a few seconds later (their program has started by then)
  if callable(ac.onClientConnected) then
    pcall(ac.onClientConnected, function(carIndex)
      N.peers[carIndex] = nil
      helloAt = math.min(helloAt, clock() + 4)
    end)
  end
  if callable(ac.onClientDisconnected) then
    pcall(ac.onClientDisconnected, function(carIndex) N.peers[carIndex] = nil end)
  end
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
  if not callable(ac.connect) or not ac.StructItem then return nil end
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
