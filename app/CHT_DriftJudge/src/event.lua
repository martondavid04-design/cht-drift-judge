-- CHT Drift Judge – a competition: qualifying table, Top 32 bracket, tandem battles, judges' votes (0.4.0).
--
-- One PC directs the competition (the race director: a server admin or a judge – Verseny tab). Its PC
-- keeps the competition, measures the tandem runs and collects the votes; everything is saved on the PC
-- (versenyek/<id>.json, kept online too) and sent to the Google script (Versenyek sheet + a Drive file),
-- from where the other judges', the broadcaster's PCs read it. Live state goes over the server:
--   cht.driftjudge.evt.v1   director → everyone: which battle, who leads, run n, phase, the saved version
--   cht.driftjudge.vote.v1  judge → director: A / B / One More Time for a battle (and for its OMT)
--   cht.driftjudge.tded.v1  judge → director: a deduction / note on one driver of one tandem run (A16)
--   cht.driftjudge.tmes.v1  pilot → director (0.4.1): the run as the lead's / chase's own PC measured it
-- Every PC with a role measures the armed tandem run too (src/tandem.lua), so the judges and the
-- broadcaster see proximity, angles and contacts at once; the director's measurement is the one saved.
-- 0.4.1: the two pilots' PCs measure it as well and send a summary: on the chase's PC its own car is
-- exact, so its proximity is the better one; on the lead's PC the pedals are its own (accel / decel map).
-- Cars go in the messages by their server slot (session ID): the local index differs between the PCs
-- (index 0 is always the PC's own car).
--
-- Rules: see src/bracket.lua and src/tandem.lua (A02–A06, A11, A13–A17, B01, B06, DM 2025 1.8–1.16).

local callable = require('src/fn').callable
local storage = require('src/storage')
local platform = require('src/platform')
local bracket = require('src/bracket')
local tandem = require('src/tandem')

local E = {}

E.ev = nil                 -- the competition being shown (directed here or read from the director)
E.tracker = nil            -- tandem tracker of the armed run on this PC
E.trackKey = nil           -- '<battle>#<run>' the tracker belongs to
E.live = nil               -- last live message from the director (other PCs)
E.localRuns = {}           -- ['<battle>#<run>'] = summary measured on this PC (for the judges until the saved one arrives)
E.myVotes = {}             -- ['<battle>#p<pair>'] = 'a' | 'b' | 'omt' sent from this PC
E.trackMine = nil          -- 'lead' | 'chase' when this PC's own car is in the measured run (0.4.1)
E.pending = {}             -- director: pilots' measurements that came before the run was recorded
E.decidedAt = {}           -- [battle] = clock() when its decision was seen here (broadcaster HUD)
E.screens = { 'auto', 'battle', 'bracket', 'quali' }
E.messages = {}            -- short log of what happened (UI)
E.fetch = { state = 'none' }
E.saveDelay = 2            -- s: changes are sent together
E.refreshEvery = 60        -- s: other PCs re-read the competition at least this often
E.autoNext = true          -- after run 1 of a pair, the 2nd run (lead swapped) is armed by itself
E.clockFn = nil
local function clock() return (E.clockFn or os.clock)() end

local app = nil
local liveFn, voteFn, dedFn, measFn = nil, nil, nil, nil
local saveAt, savingRev, savedRev = nil, nil, 0
local nextFetchAt, nextListAt = math.huge, math.huge
local wantFetch = nil

local function now() return storage.timestampHuman() end
local function ownName()
  local ok, n = pcall(ac.getDriverName, 0)
  return ok and n and tostring(n) or '?'
end
local function namespace()
  return (ac.SharedNamespace and ac.SharedNamespace.Shared) or 'shared'
end
-- Can messages go between the PCs? (custom server with direct messaging, like netsync)
local function available()
  local okS, sim = pcall(ac.getSim)
  return okS and sim and sim.directMessagingAvailable == true
end

local function note(text, level)
  table.insert(E.messages, 1, { t = now(), text = text, level = level or 'info' })
  while #E.messages > 40 do table.remove(E.messages) end
end
E.note = note

-- Roles --------------------------------------------------------------------------------------------------
-- 'admin' | 'judge' | 'streamer' | nil. The installed app has no Steam ID: there the PC's own choice counts
-- (Beállítások → Szerep), and it can always direct (it sees the points too).
function E.myRole()
  if platform.online then return platform.serverRole() end
  local r = app and app.settings and app.settings.ui and app.settings.ui.role
  if r == 'judge' or r == 'streamer' then return r end
  return 'admin'
end
function E.canDirect()
  local r = E.myRole()
  return r == 'admin' or r == 'judge'
end
function E.isJudge()
  local r = E.myRole()
  return r == 'admin' or r == 'judge'
end
function E.involved() return E.myRole() ~= nil end
function E.isDirector()
  return E.ev ~= nil and E.ev.director ~= nil and E.ev.director.name == ownName() and E.canDirect()
end

-- Cars -----------------------------------------------------------------------------------------------------
function E.carOf(name)
  if not name then return nil end
  if callable(ac.getCarByDriverName) then
    local ok, i = pcall(ac.getCarByDriverName, name)
    if ok and type(i) == 'number' and i >= 0 then return i end
  end
  local okS, sim = pcall(ac.getSim)
  local n = okS and sim and sim.carsCount or 1
  for i = 0, n - 1 do
    local okN, d = pcall(ac.getDriverName, i)
    if okN and d == name then
      local okC, c = pcall(ac.getCar, i)
      if okC and c and c.isConnected ~= false then return i end
    end
  end
  return nil
end

-- Car of this PC (local index) → server slot, and back. ac.getCar(0) is always the PC's own car, so the
-- local index of a car differs from PC to PC; the session ID is the same everywhere.
function E.sessionOf(idx)
  if idx == nil then return nil end
  local ok, c = pcall(ac.getCar, idx)
  local sid = ok and c and c.sessionID
  if type(sid) == 'number' and sid >= 0 then return sid end
  return idx
end

function E.localOf(sid)
  sid = tonumber(sid)
  if not sid or sid < 0 or sid == 255 then return nil end
  local okF, f = pcall(function() return ac.getCar.serverSlot end)
  if okF and callable(f) then
    local ok, c = pcall(f, sid)
    if ok and c and type(c.index) == 'number' and c.index >= 0 then return c.index end
  end
  local okS, sim = pcall(ac.getSim)
  local n = okS and sim and sim.carsCount or 0
  local known = false
  for i = 0, n - 1 do
    local ok, c = pcall(ac.getCar, i)
    if ok and c and type(c.sessionID) == 'number' and c.sessionID >= 0 then
      known = true
      if c.sessionID == sid then return i end
    end
  end
  if known then return nil end -- session IDs are known, none matches: not on the server (any more)
  return sid                   -- no session IDs (single player, tests): the same index
end

-- Saving ---------------------------------------------------------------------------------------------------
local function path(id) return storage.eventsDir() .. '/' .. tostring(id) .. '.json' end

function E.list()
  local out = {}
  local okD, files = pcall(function() return io.scanDir(storage.eventsDir(), '*.json') end)
  for _, f in ipairs(okD and files or {}) do
    local ev = storage.readJSON(storage.eventsDir() .. '/' .. f)
    if type(ev) == 'table' and ev.format == 'cht-drift-event' then out[#out + 1] = ev end
  end
  table.sort(out, function(a, b) return tostring(a.updated or '') > tostring(b.updated or '') end)
  return out
end

-- A copy for the store: without the measured series (a battle keeps its stats only).
local function compactForStore(ev)
  return ev
end

-- After every change on the director's PC: new version, saved here at once, sent in a moment.
function E.touch(why)
  local ev = E.ev
  if not ev or not E.isDirector() then return end
  ev.rev = (ev.rev or 0) + 1
  ev.updated = now()
  if why then
    ev.log = ev.log or {}
    table.insert(ev.log, 1, { t = ev.updated, text = why, by = ownName() })
    while #ev.log > 150 do table.remove(ev.log) end
  end
  pcall(storage.writeJSON, path(ev.id), ev)
  saveAt = clock() + E.saveDelay
  E.sendLive()
end

local function post()
  local ev = E.ev
  if not ev or not app or not app.upload or not app.upload.event then return end
  local ok, text = pcall(JSON.stringify, compactForStore(ev))
  if not ok then note('A verseny nem menthető: ' .. tostring(text), 'error') return end
  local rev = ev.rev
  savingRev = rev
  local queued = app.upload.event({ id = ev.id, name = ev.name, rev = rev, track = ev.track, layout = ev.layout,
    director = ev.director and ev.director.name, phase = ev.phase, text = text }, function(done, err)
    savingRev = nil
    if done then
      if E.ev and E.ev.id == ev.id and rev > savedRev then savedRev = rev end
      E.saveState = 'ok'
      E.sendLive()
    else
      E.saveState = 'error'
      E.saveError = tostring(err)
      saveAt = clock() + 15
    end
  end)
  if not queued then E.saveState, E.saveError = 'error', 'nem fért a küldési sorba'; saveAt = clock() + 15; savingRev = nil end
  if queued then E.saveState = 'sending' end
end

-- New competition (this PC directs it).
function E.create(name)
  local okT, t = pcall(os.date, '%Y%m%d-%H%M%S')
  local id = 'v' .. ((okT and t) or tostring(math.floor(clock())))
  E.ev = {
    format = 'cht-drift-event', version = 1, id = id, name = (name and name ~= '') and name or 'CHT verseny',
    created = now(), updated = now(), rev = 0,
    track = storage.trackKey(), layout = app and app.layout and app.layout.name or '',
    director = { name = ownName(), steamId = platform.steamID() },
    judgeCount = 2, judges = {}, phase = 'quali',
    quali = { from = now(), manual = {}, table = {} },
    current = nil, log = {},
  }
  savedRev = 0
  E.touch('verseny létrehozva: ' .. E.ev.name)
  return E.ev
end

function E.open(ev)
  E.ev = ev
  savedRev = ev and ev.rev or 0
  E.tracker, E.trackKey = nil, nil
end

-- Another admin / judge takes over directing (e.g. the director's PC dropped out).
function E.takeOver()
  if not E.ev or not E.canDirect() then return false end
  local prev = E.ev.director and E.ev.director.name or '?'
  E.ev.director = { name = ownName(), steamId = platform.steamID() }
  E.touch(string.format('a vezetést átvette: %s (előtte: %s)', ownName(), prev))
  return true
end

-- Qualifying ------------------------------------------------------------------------------------------------
-- Drivers with the qualifying runs (the competition's layout, from the start of the qualifying).
function E.qualiDrivers()
  local ev = E.ev
  if not ev or not app or not app.drivers then return {} end
  local list = app.drivers.collect(app, { layout = ev.layout, allLayouts = false })
  local from, to = ev.quali and ev.quali.from or '', ev.quali and ev.quali.to or nil
  local out = {}
  for _, d in ipairs(list) do
    local runs = {}
    local pilot = {}
    for _, r in ipairs(d.runs) do if r.source == 'pilot' then pilot[#pilot + 1] = r end end
    for _, r in ipairs(#pilot > 0 and pilot or d.runs) do
      local t = tostring(r.time or '')
      if (from == '' or t == '' or t >= from) and (not to or t == '' or t <= to) then runs[#runs + 1] = r end
    end
    out[#out + 1] = { name = d.name, runs = runs, connected = d.connected, carIndex = d.carIndex }
  end
  return out
end

local function compactRun(r)
  if not r then return nil end
  return { final = r.zero and 0 or (r.effective or r.final), zero = r.zero == true, line = r.line, angle = r.angle, style = r.style,
    reason = r.zero and r.zeroReason or nil, time = r.time }
end

-- Director: the table from the runs here (worked out at most once a second). Others: the one the
-- director saved (with its runs' points).
local qualiCache = { at = -100, rows = nil, id = nil }
function E.qualiTable(fresh)
  local ev = E.ev
  if not ev then return {} end
  if not E.isDirector() or ev.phase ~= 'quali' then return ev.quali and ev.quali.table or {} end
  if not fresh and qualiCache.rows and qualiCache.id == ev.id and clock() - qualiCache.at < 1 then return qualiCache.rows end
  local rows = bracket.qualiTable(E.qualiDrivers(), ev.quali.manual)
  local out = {}
  for _, e in ipairs(rows) do
    out[#out + 1] = { name = e.name, place = e.place, status = e.status, why = e.why, best = compactRun(e.best), second = compactRun(e.second),
      runs = #e.counted, all = e.all, zeros = e.zeros, third = e.third or nil, connected = e.connected or nil }
  end
  qualiCache.at, qualiCache.rows, qualiCache.id = clock(), out, ev.id
  return out
end

local qualiSig, qualiCheckAt = nil, 0
-- Director: keeps the saved table up to date (checked every 2 s, saved when it changed).
local function updateQuali()
  local ev = E.ev
  if not ev or ev.phase ~= 'quali' or not E.isDirector() then return end
  if clock() < qualiCheckAt then return end
  qualiCheckAt = clock() + 2
  local t = E.qualiTable(true)
  local okJ, sig = pcall(JSON.stringify, t)
  if not okJ then return end
  if sig ~= qualiSig then
    local first = qualiSig == nil
    qualiSig = sig
    ev.quali.table = t
    if not first or #t > 0 then E.touch(nil) end
  end
end

-- manual: 'third' (3rd chance), 'out' (removed), 'back' (counts despite two zero runs), value true / nil
function E.setManual(name, what, value)
  local ev = E.ev
  if not ev or not E.isDirector() then return end
  ev.quali.manual[name] = ev.quali.manual[name] or {}
  ev.quali.manual[name][what] = value or nil
  if next(ev.quali.manual[name]) == nil then ev.quali.manual[name] = nil end
  qualiSig, qualiCache.rows = nil, nil
  local names = { third = '3. esély', out = 'kivéve', back = 'visszavéve' }
  E.touch(string.format('%s: %s %s', name, names[what] or what, value and 'be' or 'ki'))
end

function E.restartQuali()
  local ev = E.ev
  if not ev or not E.isDirector() then return end
  ev.quali.from, ev.quali.to = now(), nil
  qualiSig = nil
  E.touch('a kvalifikáció újraindult (csak az ezután futott körök számítanak)')
end

-- Bracket ---------------------------------------------------------------------------------------------------
-- Allowed sizes for n qualified drivers: at most the size that fits everyone (fewer = only the best).
function E.sizesFor(n)
  local out = {}
  local max = bracket.sizeFor(n)
  for _, s in ipairs({ 4, 8, 16, 32 }) do if s <= max and n >= 2 then out[#out + 1] = s end end
  return out
end

function E.buildBracket(size)
  local ev = E.ev
  if not ev or not E.isDirector() then return false, 'nem te vezeted a versenyt' end
  local t = E.qualiTable(true)
  local seeds = {}
  for _, e in ipairs(t) do if e.status == 'ok' then seeds[#seeds + 1] = e.name end end
  if #seeds < 2 then return false, 'legalább 2 továbbjutó kell' end
  size = size or bracket.sizeFor(#seeds)
  while #seeds > size do table.remove(seeds) end
  ev.quali.table = t
  ev.quali.to = ev.quali.to or now()
  ev.seeds = seeds
  ev.bracket = bracket.build(seeds, size)
  ev.phase = 'bracket'
  ev.current = nil
  local nb = bracket.nextBattle(ev.bracket)
  if nb then E.select(nb.id, true) end
  E.touch(string.format('tábla összeállítva: Top %d, %d pilóta', size, #seeds))
  return true
end

function E.unbuildBracket()
  local ev = E.ev
  if not ev or not E.isDirector() then return end
  ev.bracket, ev.seeds, ev.current, ev.phase = nil, nil, nil, 'quali'
  E.tracker, E.trackKey = nil, nil
  qualiSig = nil
  E.touch('a tábla törölve – vissza a kvalifikációhoz')
end

function E.battle(id)
  return E.ev and E.ev.bracket and bracket.battle(E.ev.bracket, id) or nil
end

-- Which pair of runs a battle is in (1 = main, 2 = One More Time), and the lead of its next run.
function E.pairOf(b) return b.omt and 2 or 1 end
function E.pairRuns(b, pair)
  local out = {}
  for _, r in ipairs(b.runs or {}) do if (r.pair or 1) == pair then out[#out + 1] = r end end
  return out
end
function E.nextLead(b)
  local pair = E.pairOf(b)
  local runs = E.pairRuns(b, pair)
  local first = b.firstLead or 'a'
  if #runs == 0 then return first end
  if #runs == 1 then return runs[1].leadSide == 'a' and 'b' or 'a' end
  return nil -- the pair is complete: vote
end

function E.select(id, quiet)
  local ev = E.ev
  if not ev or not E.isDirector() then return end
  local b = E.battle(id)
  if not b or not b.a or not b.b then return end
  if not b.firstLead then
    -- the better qualifier leads first by default (the director can switch it before the first run)
    b.firstLead = (b.seedA or 99) <= (b.seedB or 99) and 'a' or 'b'
  end
  ev.current = { battle = id, state = 'idle', run = #(b.runs or {}) }
  E.tracker, E.trackKey = nil, nil
  if not quiet then E.touch(string.format('kiválasztva: %s – %s', b.a, b.b)) end
end

function E.current()
  local ev = E.ev
  if not ev or not ev.current then return nil end
  return E.battle(ev.current.battle), ev.current
end

function E.setFirstLead(side)
  local b, cur = E.current()
  if not b or #(b.runs or {}) > 0 then return end
  b.firstLead = side
  E.touch(string.format('%s vezet először', side == 'a' and b.a or b.b))
end

-- Runs -------------------------------------------------------------------------------------------------------
-- b = { a, b } names; cars (optional) = { a = carIndex, b = carIndex } (from the director's live message)
local function newTracker(b, leadSide, cars)
  local lead = leadSide == 'a' and b.a or b.b
  local chase = leadSide == 'a' and b.b or b.a
  local li = cars and cars[leadSide] or E.carOf(lead)
  local ci = cars and cars[leadSide == 'a' and 'b' or 'a'] or E.carOf(chase)
  if not li or not ci then
    return nil, string.format('%s nincs fent a szerveren', not li and tostring(lead) or tostring(chase))
  end
  if not app or not app.compiled then return nil, 'nincs pályaterv' end
  local okL, lc = pcall(ac.getCar, li)
  local okC, cc = pcall(ac.getCar, ci)
  local tr = tandem.new({ lead = li, chase = ci, leadName = lead, chaseName = chase }, app.compiled, app.cfg,
    { steerLead = okL and lc and lc.steerLock or nil, steerChase = okC and cc and cc.steerLock or nil })
  return tr
end

-- Director: get the next run ready – the program waits for the lead to cross the START line.
function E.arm()
  local b, cur = E.current()
  if not b then return false, 'nincs kiválasztott csata' end
  if b.winner then return false, 'ez a csata már eldőlt' end
  local side = E.nextLead(b)
  if not side then return false, 'a két futás megvan: szavazás' end
  local tr, err = newTracker(b, side)
  if not tr then return false, err end
  cur.run = #(b.runs or {}) + 1
  cur.leadSide = side
  cur.state = 'armed'
  cur.armedAt, cur.startedAt = now(), nil
  E.tracker, E.trackKey = tr, b.id .. '#' .. cur.run
  E.touch(string.format('%d. futás élesítve: %s vezet', cur.run, side == 'a' and b.a or b.b))
  return true
end

function E.disarm()
  local b, cur = E.current()
  if not cur then return end
  cur.state = 'idle'
  E.tracker, E.trackKey = nil, nil
  E.touch('élesítés visszavonva')
end

-- Director: end the run now (e.g. the cars stopped before the FINISH line).
function E.finishNow()
  if E.tracker and E.tracker.state ~= 'done' then
    E.tracker:finish(true)
  end
end

-- What the store keeps of a tandem run (no series: small enough for the sheet).
local function storeSummary(s)
  if not s then return nil end
  local p = s.prox or {}
  local contacts = {}
  for i, c in ipairs(s.contacts or {}) do
    if i > 6 then break end
    contacts[#contacts + 1] = { t = c.t, leadFault = c.leadFault, reasons = c.reasons, mapColor = c.mapColor }
  end
  local viol = {}
  for i, v in ipairs(s.map and s.map.violations or {}) do
    if i > 6 then break end
    viol[#viol + 1] = { color = v.color, kind = v.kind, value = v.value, t0 = v.t0, t1 = v.t1 }
  end
  return {
    lead = s.lead, chase = s.chase, leadPts = s.leadPts, chasePts = s.chasePts,
    leadResult = s.leadResult, chaseResult = s.chaseResult,
    prox = { avg = p.avg, min = p.min, near = p.near, weak = p.weak, far = p.far, time = p.time },
    contacts = contacts, contactCount = #(s.contacts or {}), init = s.init, angle = s.angle, line = s.line,
    pass = s.pass and { t = s.pass.t } or nil, incomplete = s.incomplete, warnings = s.warnings, restarts = s.restarts,
    map = { has = s.map and s.map.has, violations = viol, count = #(s.map and s.map.violations or {}) },
    scores = s.scores,
  }
end
E.storeSummary = storeSummary

-- The pilot's own result of the run (its program sends it to everyone when the run ends), if it has
-- arrived: the first one after the run started (`since`), before the next run started (`untilT`).
function E.ownResult(name, since, untilT)
  local found = nil
  for _, e in ipairs(app and app.netsync and app.netsync.runs or {}) do -- newest first
    local t = tostring(e.time or '')
    if e.driver == name and (not since or t >= since) and (not untilT or t < untilT) then
      found = { final = e.final, zero = e.zero, zeroReason = e.zeroReason, line = e.line, angle = e.angle, style = e.style, time = e.time }
    end
  end
  return found
end

-- Director: the pilots' own results usually arrive a moment after the run was recorded – add them then.
local ownCheckAt = 0
local function updateOwnResults()
  if clock() < ownCheckAt then return end
  ownCheckAt = clock() + 2
  local b = E.current()
  if not b then return end
  local changed = false
  local runs = b.runs or {}
  for i, r in ipairs(runs) do
    local since = r.startedAt or r.armedAt
    local untilT = runs[i + 1] and (runs[i + 1].startedAt or runs[i + 1].armedAt) or nil
    if since and not r.leadOwn then
      r.leadOwn = E.ownResult(r.lead, since, untilT)
      changed = changed or r.leadOwn ~= nil
    end
    if since and not r.chaseOwn then
      r.chaseOwn = E.ownResult(r.chase, since, untilT)
      changed = changed or r.chaseOwn ~= nil
    end
  end
  if changed then E.touch(nil) end
end

local function recordRun(summary)
  local b, cur = E.current()
  if not b or not cur then return end
  b.runs = b.runs or {}
  local run = {
    n = cur.run or (#b.runs + 1), pair = E.pairOf(b), leadSide = cur.leadSide,
    lead = summary.lead, chase = summary.chase, at = now(), armedAt = cur.armedAt, startedAt = cur.startedAt,
    summary = storeSummary(summary), deductions = {}, notes = {},
  }
  run.leadOwn = E.ownResult(run.lead, run.startedAt or run.armedAt)
  run.chaseOwn = E.ownResult(run.chase, run.startedAt or run.armedAt)
  for _, role in ipairs({ 'lead', 'chase' }) do
    local k = b.id .. '#' .. tostring(run.n) .. '#' .. role
    local m = E.pending[k]
    if m and m.by == run[role] then
      run.measured = run.measured or {}
      run.measured[role] = m
    end
    E.pending[k] = nil
  end
  b.runs[#b.runs + 1] = run
  local pairRuns = E.pairRuns(b, run.pair)
  cur.state = #pairRuns >= 2 and 'voting' or 'review'
  E.tracker, E.trackKey = nil, nil
  E.touch(string.format('%d. futás kész (%s vezetett)%s', run.n, run.lead,
    cur.state == 'voting' and ' – szavazás' or ''))
  if cur.state == 'review' and E.autoNext then
    local ok, err = E.arm()
    if not ok then note('A 2. futás nem élesíthető: ' .. tostring(err), 'warn') end
  end
end

-- Director: drop the last run (false start, technical problem: it is run again).
function E.deleteLastRun()
  local b, cur = E.current()
  if not b or not b.runs or #b.runs == 0 or b.winner then return end
  local r = table.remove(b.runs)
  local pairKey = 'p' .. (r.pair or 1)
  if b.votes then b.votes[pairKey] = nil end
  cur.state, cur.run = 'idle', #b.runs
  E.tracker, E.trackKey = nil, nil
  E.touch(string.format('%d. futás törölve (újrafutás)', r.n or 0))
end

-- Votes --------------------------------------------------------------------------------------------------------
function E.judgeNeeded() return math.max(1, tonumber(E.ev and E.ev.judgeCount) or 2) end

function E.votesOf(b, pair)
  b.votes = b.votes or {}
  local k = 'p' .. (pair or E.pairOf(b))
  b.votes[k] = b.votes[k] or {}
  return b.votes[k]
end

local function decideBattle(b)
  local pair = E.pairOf(b)
  if #E.pairRuns(b, pair) < 2 then return end
  local votes = E.votesOf(b, pair)
  local d, why = bracket.decide(votes, E.judgeNeeded(), b.omt)
  if d == 'a' or d == 'b' then
    E.setWinner(b, d, 'szavazás (' .. why .. ')')
  elseif d == 'omt' then
    b.omt = true
    local cur = E.ev.current
    if cur and cur.battle == b.id then cur.state = 'idle' end
    E.touch(string.format('%s – %s: One More Time', b.a, b.b))
  elseif d == 'deadlock' then
    note('Az OMT után sincs többség: a versenyigazgató dönt (Kézi döntés).', 'warn')
  end
end

function E.setWinner(b, side, how)
  local ev = E.ev
  b.winner = side
  b.done = true
  b.decision = { winner = side, how = how, at = now(), by = ownName(), omt = b.omt or nil }
  E.decidedAt[b.id] = clock()
  bracket.propagate(ev.bracket)
  local cur = ev.current
  if cur and cur.battle == b.id then cur.state = 'decided' end
  E.tracker, E.trackKey = nil, nil
  local champ = bracket.champion(ev.bracket)
  if champ then ev.phase = 'done' end
  E.touch(string.format('%s nyert (%s ellen) – %s', bracket.winnerName(b), bracket.loserName(b) or '?', how)
    .. (champ and (' · GYŐZTES: ' .. champ) or ''))
end

-- Director: record a vote (own, received, or typed in for a judge who said it on Discord).
function E.addVote(battleId, pair, judge, vote)
  local ev = E.ev
  if not ev or not E.isDirector() then return false end
  local b = E.battle(battleId)
  if not b or b.winner then return false end
  if (pair or 1) ~= E.pairOf(b) then return false end
  if vote ~= 'a' and vote ~= 'b' and vote ~= 'omt' then return false end
  if vote == 'omt' and b.omt then return false end -- after an OMT a winner must be named
  E.votesOf(b, pair)[judge] = vote
  E.touch(string.format('szavazat: %s (%s)', judge, #E.pairRuns(b, pair) >= 2 and 'beérkezett' or 'előre'))
  decideBattle(b)
  return true
end

function E.clearVote(battleId, pair, judge)
  local b = E.battle(battleId)
  if not b or b.winner or not E.isDirector() then return end
  E.votesOf(b, pair)[judge] = nil
  E.touch('szavazat törölve: ' .. judge)
end

-- Judge (this PC): vote. On the director's PC it counts at once, else it goes to the director.
function E.vote(vote)
  if vote ~= 'a' and vote ~= 'b' and vote ~= 'omt' then return false, 'rossz szavazat' end
  if E.isDirector() then
    local b = E.current()
    if not b then return false, 'nincs kiválasztott csata' end
    local pair = E.pairOf(b)
    local ok = E.addVote(b.id, pair, ownName(), vote)
    if ok then E.myVotes[b.id .. '#p' .. pair] = vote end
    return ok
  end
  local live = E.live
  if not live or live.battle == '' then return false, 'nincs folyamatban csata' end
  if not voteFn or not available() then return false, 'az üzenetküldés nem elérhető ezen a szerveren' end
  local code = vote == 'a' and 1 or (vote == 'b' and 2 or 3)
  local ok, r = pcall(voteFn, { eventId = live.eventId, battle = live.battle, pair = live.pair or 1, vote = code })
  if ok and r ~= false then E.myVotes[live.battle .. '#p' .. (live.pair or 1)] = vote return true end
  return false, 'nem ment el'
end

-- Undo a decision (only while the next battle of the winner has not started).
function E.undoDecision(battleId)
  local ev = E.ev
  local b = E.battle(battleId)
  if not b or not b.winner or not E.isDirector() then return false end
  local r = b.round
  local nxt = ev.bracket.rounds[r + 1] and ev.bracket.rounds[r + 1].battles[math.ceil(b.slot / 2)]
  if nxt and (#(nxt.runs or {}) > 0 or nxt.winner) then return false, 'a következő csata már elkezdődött' end
  b.winner, b.done, b.decision = nil, nil, nil
  bracket.propagate(ev.bracket)
  if ev.phase == 'done' then ev.phase = 'bracket' end
  ev.current = { battle = b.id, state = 'voting', run = #(b.runs or {}) }
  if #E.pairRuns(b, E.pairOf(b)) < 2 then ev.current.state = 'idle' end
  E.touch(string.format('döntés visszavonva: %s – %s', b.a or '?', b.b or '?'))
  return true
end

-- Deductions / notes on one driver of a tandem run (A16): { judge, target = 'lead' | 'chase', amount, note }
function E.setDeduction(battleId, runN, target, judge, amount, noteText)
  local b = E.battle(battleId)
  if not b or not E.isDirector() then return false end
  for _, r in ipairs(b.runs or {}) do
    if r.n == runN then
      r.deductions = r.deductions or {}
      local key = judge .. '|' .. target
      if (tonumber(amount) or 0) == 0 and (noteText or '') == '' then r.deductions[key] = nil
      else r.deductions[key] = { judge = judge, target = target, amount = tonumber(amount) or 0, note = noteText or '' } end
      E.touch(string.format('levonás / megjegyzés: %d. futás, %s (%s)', runN, target == 'lead' and 'lead' or 'chase', judge))
      return true
    end
  end
  return false
end

function E.sendDeduction(battleId, runN, target, amount, noteText)
  if E.isDirector() then return E.setDeduction(battleId, runN, target, ownName(), amount, noteText) end
  if not dedFn or not available() then return false end
  local ok, r = pcall(dedFn, { eventId = E.ev and E.ev.id or (E.live and E.live.eventId) or '', battle = battleId, run = runN, target = target == 'lead' and 1 or 2,
    amount = tonumber(amount) or 0, note = tostring(noteText or ''):sub(1, 47) })
  return ok and r ~= false
end

-- Total deductions of a run per target.
function E.deductionTotal(run, target)
  local s = 0
  for _, d in pairs(run.deductions or {}) do if d.target == target then s = s + (tonumber(d.amount) or 0) end end
  return s
end

-- Suggested chase points of a run: with the chase's own PC's proximity when it came (0.4.1: more exact,
-- its own car is not an interpolated remote one), else the director's measurement.
function E.chasePoints(r)
  local s = r.summary or {}
  local m = r.measured and r.measured.chase
  if not m or not s.scores or (s.chasePts or 0) <= 0 or not m.near then return s.chasePts or 0 end
  local prox = (m.near or 0) + 0.5 * (m.weak or 0)
  local pts = 40 * (0.5 * prox + 0.25 * (s.scores.angle or 0) + 0.25 * (s.scores.line or 0))
  if s.init and s.init.late then pts = pts * 0.9 end
  return math.floor(pts * 10 + 0.5) / 10
end

-- Suggested battle total per driver (informational, after deductions): lead part + chase part of the pair.
function E.suggestion(b)
  local pair = E.pairOf(b)
  local runs = E.pairRuns(b, pair)
  local out = {}
  for _, r in ipairs(runs) do
    local s = r.summary or {}
    if r.lead then
      out[r.lead] = out[r.lead] or {}
      out[r.lead].lead = math.max(0, (s.leadPts or 0) - E.deductionTotal(r, 'lead'))
    end
    if r.chase then
      out[r.chase] = out[r.chase] or {}
      out[r.chase].chase = math.max(0, E.chasePoints(r) - E.deductionTotal(r, 'chase'))
    end
  end
  for _, v in pairs(out) do v.total = (v.lead or 0) + (v.chase or 0) end
  return out
end

-- Messages ----------------------------------------------------------------------------------------------------
local phases = { idle = 0, armed = 1, running = 2, review = 3, voting = 4, decided = 5 }
local phaseNames = { [0] = 'idle', 'armed', 'running', 'review', 'voting', 'decided' }

-- (names go as server slots – the same on every PC – so a long or accented name is never cut in two;
-- the director as a short fingerprint of the name; screen = what the broadcaster HUD should show)
local screenCodes = { auto = 0, battle = 1, bracket = 2, quali = 3 }
local screenNames = { [0] = 'auto', 'battle', 'bracket', 'quali' }
local function liveLayout()
  local S = ac.StructItem
  return { S.key('cht.driftjudge.evt.v1'), eventId = S.string(24), rev = S.uint32(), director = S.uint32(), battle = S.string(8),
    carA = S.byte(), carB = S.byte(), lead = S.byte(), phase = S.byte(), run = S.byte(), pair = S.byte(), winner = S.byte(),
    screen = S.byte() }
end

-- A pilot's PC → the director: the run as it was measured there (fractions as 0–200, −1 / 255 = none).
local function measLayout()
  local S = ac.StructItem
  return { S.key('cht.driftjudge.tmes.v1'), eventId = S.string(24), battle = S.string(8), run = S.byte(), role = S.byte(),
    proxAvg = S.float(), proxMin = S.float(), near = S.byte(), weak = S.byte(), far = S.byte(),
    contacts = S.byte(), contactT = S.float(), fault = S.byte(), initDiff = S.float(), angleDiff = S.float(), lineDev = S.float(),
    pass = S.byte(), mapCount = S.byte(), mColor = S.byte(), mKind = S.byte(), mFrom = S.float(), mTo = S.float(),
    solo = S.float(), soloZero = S.byte(), zeroReason = S.string(24) }
end

-- Fingerprint of a name (31-multiplier rolling hash, fits a uint32).
function E.nameHash(name)
  local h = 7
  local s = tostring(name or '')
  for i = 1, #s do h = (h * 31 + s:byte(i)) % 2147483647 end
  return h
end
local function voteLayout()
  local S = ac.StructItem
  return { S.key('cht.driftjudge.vote.v1'), eventId = S.string(24), battle = S.string(8), pair = S.byte(), vote = S.byte() }
end
local function dedLayout()
  local S = ac.StructItem
  return { S.key('cht.driftjudge.tded.v1'), eventId = S.string(24), battle = S.string(8), run = S.byte(), target = S.byte(),
    amount = S.float(), note = S.string(48) }
end

local lastLiveSent = -100
function E.sendLive()
  if not liveFn or not E.isDirector() or not available() then return false end
  local ev = E.ev
  local b, cur = E.current()
  local ca, cb = b and E.sessionOf(E.carOf(b.a)), b and E.sessionOf(E.carOf(b.b))
  local msg = { eventId = ev.id, rev = savedRev, director = E.nameHash(ownName()), battle = b and b.id or '',
    carA = ca or 255, carB = cb or 255, screen = screenCodes[ev.screen or 'auto'] or 0,
    lead = cur and cur.leadSide == 'b' and 2 or (cur and cur.leadSide == 'a' and 1 or 0),
    phase = cur and phases[cur.state] or 0, run = cur and cur.run or 0, pair = b and E.pairOf(b) or 1,
    winner = b and (b.winner == 'a' and 1 or (b.winner == 'b' and 2 or 0)) or 0 }
  if E.tracker and E.tracker.state == 'running' then msg.phase = phases.running end
  lastLiveSent = clock()
  local ok, r = pcall(liveFn, msg)
  return ok and r ~= false
end

local function scheduleFetch(id, delay)
  wantFetch = id
  nextFetchAt = math.min(nextFetchAt, clock() + (delay or 0))
end

function E.receiveLive(sender, msg)
  if not msg or not sender or sender.index == 0 then return end
  local id = tostring(msg.eventId or '')
  if id == '' then return end
  local function car(v) return E.localOf(v) end
  local function nameOf(i)
    if not i then return '' end
    local okN, n = pcall(ac.getDriverName, i)
    return okN and n and tostring(n) or ''
  end
  local ca, cb = car(msg.carA), car(msg.carB)
  local okD, dn = pcall(ac.getDriverName, sender.index)
  local live = { eventId = id, rev = tonumber(msg.rev) or 0, battle = tostring(msg.battle or ''), carA = ca, carB = cb,
    a = nameOf(ca), b = nameOf(cb), directorHash = tonumber(msg.director) or 0,
    director = okD and dn and tostring(dn) or '?', leadSide = msg.lead == 2 and 'b' or (msg.lead == 1 and 'a' or nil),
    phase = phaseNames[tonumber(msg.phase) or 0] or 'idle', run = tonumber(msg.run) or 0, pair = tonumber(msg.pair) or 1,
    winner = msg.winner == 1 and 'a' or (msg.winner == 2 and 'b' or nil), at = clock(), from = sender.index,
    screen = screenNames[tonumber(msg.screen) or 0] or 'auto' }
  E.live = live
  if live.winner and live.battle ~= '' and not E.decidedAt[live.battle] then E.decidedAt[live.battle] = clock() end
  -- someone else directs now (took over): this PC follows
  if E.ev and E.ev.id == id and E.isDirector() and live.directorHash ~= E.nameHash(ownName()) then
    note('A versenyt most ' .. live.director .. ' vezeti.', 'warn')
    E.ev.director = { name = live.director }
  end
  if not E.ev or E.ev.id ~= id or (live.rev > (E.ev.rev or 0)) then scheduleFetch(id, 0.5) end
  -- measure the armed run here too (judges, broadcaster – and 0.4.1: the two pilots, on their own PC)
  local mine = nil
  if live.leadSide and (live.carA == 0 or live.carB == 0) then
    local ownSide = live.carA == 0 and 'a' or 'b'
    mine = ownSide == live.leadSide and 'lead' or 'chase'
  end
  if not E.isDirector() and (E.involved() or mine) and (live.phase == 'armed' or live.phase == 'running') and live.leadSide then
    local key = live.battle .. '#' .. live.run
    if E.trackKey ~= key then
      local b = { id = live.battle, a = live.a, b = live.b }
      local tr = (live.carA and live.carB) and newTracker(b, live.leadSide, { a = live.carA, b = live.carB }) or nil
      E.tracker, E.trackKey, E.trackMine = tr, tr and key or nil, tr and mine or nil
    end
  elseif not E.isDirector() and E.tracker and E.tracker.state ~= 'done' and live.phase ~= 'armed' and live.phase ~= 'running' then
    -- the director ended / dropped the run
    if live.phase == 'idle' then E.tracker, E.trackKey, E.trackMine = nil, nil, nil end
  end
end

-- Pilot's PC: the summary of its own measurement to the director.
local kindCodes = { drop = 1, brake = 2, handbrake = 3 }
local kindNames = { 'drop', 'brake', 'handbrake' }
local colorCodes = { green = 1, orange = 2, red = 3 }
local colorNames = { 'green', 'orange', 'red' }
local function frac(v) if v == nil then return 255 end return math.max(0, math.min(200, math.floor(v * 200 + 0.5))) end
local function unfrac(v) v = tonumber(v) if not v or v > 200 then return nil end return v / 200 end
local function opt(v) if v == nil then return -999 end return v end
local function unopt(v) v = tonumber(v) if not v or v <= -998 then return nil end return v end

function E.sendMeasure(key, role, s)
  if not measFn or not available() or not s then return false end
  local battle, run = tostring(key):match('^(.-)#(%d+)$')
  if not battle then return false end
  local p = s.prox or {}
  local c1 = s.contacts and s.contacts[1]
  local v1 = s.map and s.map.violations and s.map.violations[1]
  local res = role == 'lead' and s.leadResult or s.chaseResult
  local msg = {
    eventId = (E.live and E.live.eventId) or (E.ev and E.ev.id) or '', battle = battle, run = tonumber(run), role = role == 'lead' and 1 or 2,
    proxAvg = opt(p.avg), proxMin = opt(p.min), near = frac(p.near), weak = frac(p.weak), far = frac(p.far),
    contacts = math.min(254, #(s.contacts or {})), contactT = opt(c1 and c1.t), fault = c1 and (c1.leadFault and 1 or 2) or 0,
    initDiff = opt(s.init and s.init.diff), angleDiff = opt(s.angle and s.angle.avgDiff), lineDev = opt(s.line and s.line.avgDev),
    pass = s.pass and 1 or 0, mapCount = math.min(254, #(s.map and s.map.violations or {})),
    mColor = v1 and colorCodes[v1.color] or 0, mKind = v1 and kindCodes[v1.kind] or 0, mFrom = opt(v1 and v1.from), mTo = opt(v1 and v1.to),
    solo = opt(res and res.final), soloZero = res and res.zero and 1 or 0,
    zeroReason = tostring(res and res.zeroReasons and res.zeroReasons[1] or ''):sub(1, 23),
  }
  local ok, r = pcall(measFn, msg)
  return ok and r ~= false
end

function E.receiveMeasure(sender, msg)
  if not msg or not sender or sender.index == 0 or not E.isDirector() then return end
  if tostring(msg.eventId or '') ~= E.ev.id then return end
  local b = E.battle(tostring(msg.battle or ''))
  if not b then return end
  local okN, name = pcall(ac.getDriverName, sender.index)
  name = okN and name and tostring(name) or ''
  if name ~= b.a and name ~= b.b then return end -- only the two pilots of the battle
  local role = msg.role == 1 and 'lead' or 'chase'
  local m = {
    by = name, proxAvg = unopt(msg.proxAvg), proxMin = unopt(msg.proxMin), near = unfrac(msg.near), weak = unfrac(msg.weak), far = unfrac(msg.far),
    contacts = tonumber(msg.contacts) or 0, contactT = unopt(msg.contactT), fault = msg.fault == 1 and 'lead' or (msg.fault == 2 and 'chase' or nil),
    initDiff = unopt(msg.initDiff), angleDiff = unopt(msg.angleDiff), lineDev = unopt(msg.lineDev), pass = msg.pass == 1,
    mapCount = tonumber(msg.mapCount) or 0, solo = unopt(msg.solo), soloZero = msg.soloZero == 1,
    zeroReason = tostring(msg.zeroReason or ''), at = now(),
  }
  if m.mapCount > 0 and colorNames[tonumber(msg.mColor) or 0] then
    m.map1 = { color = colorNames[msg.mColor], kind = kindNames[tonumber(msg.mKind) or 0] or 'drop', from = unopt(msg.mFrom), to = unopt(msg.mTo) }
  end
  local n = tonumber(msg.run) or 0
  for _, r in ipairs(b.runs or {}) do
    if r.n == n then
      if r[role] ~= name then return end
      r.measured = r.measured or {}
      r.measured[role] = m
      E.touch(string.format('%d. futás: %s gépének mérése megérkezett (%s)', n, name, role))
      return
    end
  end
  E.pending[b.id .. '#' .. n .. '#' .. role] = m -- the director's run is not recorded yet
end

-- Director: what the broadcaster HUD shows ('auto' | 'battle' | 'bracket' | 'quali').
function E.setScreen(sc)
  if not E.ev or not E.isDirector() or not screenCodes[sc] then return end
  E.ev.screen = sc
  E.touch(nil)
end

-- The screen the director asked for (on any PC that follows the competition).
function E.requestedScreen()
  if E.isDirector() then return E.ev and E.ev.screen or 'auto' end
  if E.live and E.ev and E.live.eventId == E.ev.id then return E.live.screen or 'auto' end
  return E.ev and E.ev.screen or 'auto'
end

function E.receiveVote(sender, msg)
  if not msg or not sender or sender.index == 0 or not E.isDirector() then return end
  if tostring(msg.eventId or '') ~= E.ev.id then return end
  local okN, name = pcall(ac.getDriverName, sender.index)
  name = okN and name and tostring(name) or ('#' .. sender.index)
  if not E.acceptsJudge(sender.index, name) then
    note(string.format('Szavazat elutasítva: %s nem bíró (Versenyzők fül → Bíró).', name), 'warn')
    return
  end
  local v = msg.vote == 1 and 'a' or (msg.vote == 2 and 'b' or (msg.vote == 3 and 'omt' or nil))
  if not v then return end
  if not E.addVote(tostring(msg.battle or ''), tonumber(msg.pair) or 1, name, v) then
    note(string.format('Szavazat nem számít: %s (%s)', name, tostring(msg.battle)), 'warn')
  end
end

function E.receiveDeduction(sender, msg)
  if not msg or not sender or sender.index == 0 or not E.isDirector() then return end
  if tostring(msg.eventId or '') ~= E.ev.id then return end
  local okN, name = pcall(ac.getDriverName, sender.index)
  name = okN and name and tostring(name) or ('#' .. sender.index)
  if not E.acceptsJudge(sender.index, name) then return end
  E.setDeduction(tostring(msg.battle or ''), tonumber(msg.run) or 0, msg.target == 1 and 'lead' or 'chase', name,
    tonumber(msg.amount) or 0, tostring(msg.note or ''))
end

-- Is the driver of car `idx` a judge? (named in the competition, or judge / admin by role)
function E.acceptsJudge(idx, name)
  local ev = E.ev
  for _, j in ipairs(ev and ev.judges or {}) do if j == name then return true end end
  local peer = app and app.netsync and app.netsync.peers and app.netsync.peers[idx]
  if peer then
    local r = app.roles and app.roles.roleOf and app.roles.roleOf(peer.steamId)
    if r == 'judge' then return true end
    if peer.role == 'judge' or peer.role == 'admin' then return true end
  end
  return false
end

-- Reading (other PCs) -------------------------------------------------------------------------------------------
function E.url(action, params)
  local base = app and app.upload and app.upload.target() or ''
  local u = base .. '?action=' .. action
  for k, v in pairs(params or {}) do
    u = u .. '&' .. k .. '=' .. tostring(v):gsub('[^%w%-_%.~]', function(c) return string.format('%%%02X', c:byte()) end)
  end
  return u
end

function E.fetchEvent(id, cb)
  if E.fetch.state == 'loading' then return end
  if not (app and app.upload and app.upload.target():find('^https://')) then return end
  E.fetch.state = 'loading'
  storage.fetchJSON(E.url('event', { id = id }), function(err, data)
    if err or type(data) ~= 'table' or data.ok ~= true or type(data.event) ~= 'table' then
      E.fetch.state, E.fetch.error = 'error', tostring(err or (type(data) == 'table' and data.error) or 'rossz válasz')
    else
      local ev = data.event
      E.fetch.state, E.fetch.error, E.fetch.at = 'ok', nil, clock()
      -- a newer copy than what this PC has (or another competition) – not over the director's own
      if not (E.ev and E.ev.id == ev.id and E.isDirector() and (E.ev.rev or 0) >= (ev.rev or 0)) then
        if not E.ev or E.ev.id ~= ev.id or (ev.rev or 0) >= (E.ev.rev or 0) then
          E.ev = ev
          savedRev = ev.rev or 0
        end
      end
    end
    if cb then cb(E.fetch.state == 'ok') end
  end)
end

-- The newest competition on this track (a PC with a role that joined later).
function E.fetchLatest(cb)
  if not (app and app.upload and app.upload.target():find('^https://')) then return end
  storage.fetchJSON(E.url('events', { track = storage.trackKey() }), function(err, data)
    if err or type(data) ~= 'table' or data.ok ~= true or type(data.events) ~= 'table' then if cb then cb(false) end return end
    E.remoteList = data.events
    local best = nil
    for _, e in ipairs(data.events) do
      if e.phase ~= 'done' and (not best or tostring(e.updated or '') > tostring(best.updated or '')) then best = e end
    end
    if best and not E.ev then E.fetchEvent(best.id, cb) elseif cb then cb(best ~= nil) end
  end)
end

-- Every frame ---------------------------------------------------------------------------------------------------
function E.update(dt)
  local t = clock()
  -- the tandem run being measured here
  if E.tracker and dt and dt > 0 then
    local ok, err = pcall(E.tracker.update, E.tracker, dt)
    if not ok then
      note('Hiba a tandem mérésben: ' .. tostring(err), 'error')
      E.tracker, E.trackKey = nil, nil
    elseif E.tracker.state == 'done' then
      local s = E.tracker.summary
      if E.isDirector() then
        recordRun(s)
      else
        E.localRuns[E.trackKey] = storeSummary(s)
        if E.trackMine then E.sendMeasure(E.trackKey, E.trackMine, s) end
        E.tracker, E.trackMine = nil, nil
      end
    elseif E.isDirector() and E.tracker.state == 'running' then
      local _, cur = E.current()
      if cur and cur.state == 'armed' then cur.state = 'running'; cur.startedAt = now(); E.touch(nil) end
    end
  end
  if E.isDirector() then
    updateQuali()
    updateOwnResults()
    if saveAt and t >= saveAt and not savingRev then saveAt = nil; post() end
    -- the live state every 5 s (a PC that joined meanwhile gets it too)
    if t - lastLiveSent > 5 then E.sendLive() end
  elseif E.involved() then
    if wantFetch and t >= nextFetchAt then
      local id = wantFetch
      wantFetch, nextFetchAt = nil, math.huge
      E.fetchEvent(id)
    end
    if E.ev and E.fetch.at and t - E.fetch.at > E.refreshEvery and E.fetch.state ~= 'loading' then
      E.fetch.at = t
      E.fetchEvent(E.ev.id)
    end
    if not E.ev and t >= nextListAt then
      nextListAt = t + 120
      E.fetchLatest()
    end
  end
end

function E.init(a)
  app = a
  nextListAt = clock() + 12
  -- the competition directed on this PC last time (a reconnect does not lose it)
  local list = E.list()
  for _, ev in ipairs(list) do
    if ev.phase ~= 'done' and ev.director and ev.director.name == ownName() then E.open(ev) break end
  end
  if not callable(ac.OnlineEvent) or not ac.StructItem then return end
  local function wrap(fn)
    return function(sender, msg)
      if app and app.passive then return end
      local ok, err = pcall(fn, sender, msg)
      if not ok then note('Üzenet hiba: ' .. tostring(err), 'error') end
    end
  end
  local okL, l = pcall(ac.OnlineEvent, liveLayout(), wrap(E.receiveLive), namespace())
  if okL then liveFn = l end
  local okV, v = pcall(ac.OnlineEvent, voteLayout(), wrap(E.receiveVote), namespace())
  if okV then voteFn = v end
  local okD, d = pcall(ac.OnlineEvent, dedLayout(), wrap(E.receiveDeduction), namespace())
  if okD then dedFn = d end
  local okM, m = pcall(ac.OnlineEvent, measLayout(), wrap(E.receiveMeasure), namespace())
  if okM then measFn = m end
end

-- Text exports --------------------------------------------------------------------------------------------------
function E.qualiText()
  local lines = { 'Hely\tPilóta\tLegjobb\tMásodik\tLine\tAngle\tStílus\tFutás\tÁllapot' }
  for _, e in ipairs(E.qualiTable()) do
    local b = e.best or {}
    local function sc(r) if not r then return '' end if r.zero then return '0' end return string.format('%.1f', tonumber(r.final) or 0) end
    lines[#lines + 1] = table.concat({ e.place and tostring(e.place) or '', e.name, sc(e.best), sc(e.second),
      b.line and string.format('%.1f', b.line) or '', b.angle and string.format('%.1f', b.angle) or '', b.style and string.format('%.1f', b.style) or '',
      tostring(e.runs or 0), e.status == 'ok' and '' or (e.why or e.status) }, '\t')
  end
  return table.concat(lines, '\n')
end

function E.challongeText()
  local seeds = E.ev and E.ev.seeds
  if not seeds then
    seeds = {}
    for _, e in ipairs(E.qualiTable()) do if e.status == 'ok' then seeds[#seeds + 1] = e.name end end
  end
  return bracket.challongeText(seeds)
end

function E.resultsText()
  return bracket.resultsText(E.ev and E.ev.bracket)
end

function E._reset()
  E.ev, E.tracker, E.trackKey, E.live = nil, nil, nil, nil
  E.localRuns, E.myVotes, E.messages = {}, {}, {}
  E.pending, E.decidedAt, E.trackMine = {}, {}, nil
  E.fetch = { state = 'none' }
  saveAt, savingRev, savedRev = nil, nil, 0
  nextFetchAt, nextListAt, wantFetch = math.huge, math.huge, nil
  qualiSig, qualiCheckAt = nil, 0
  qualiCache.rows = nil
end
E._phases = phases

return E
