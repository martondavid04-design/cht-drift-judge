-- CHT Drift Judge – one tandem run of a battle (phase 2, A05 / A06 / A14 / A15 / A17, DM 1.11–1.16).
--
-- Both cars are judged at once on this PC (a solo judge each, fed with their samples), and the two are
-- compared every frame:
--   proximity: chase front bumper → the lead car's outline; 0.2–4 m is tandem, above 3 m „gyenge”
--              (A14 / A17: no automatic invalidation – the judges decide), measured over the whole run;
--   initiation: the chase may not initiate later than the lead (DM 1.11);
--   angle:      the chase should match or beat the lead's angle;
--   line:       how far the chase is from the lead's path (mimic the line);
--   contact:    when the outlines touch, with a suggestion who is at fault (DM 1.16: the lead if it lost
--               drift, went off line or slowed down too sharply – else the chase); the judges decide (A06);
--   passing:    the chase got ahead of the lead (DM 1.13);
--   decel map:  the lead's green / orange / red sections (src/decelmap.lua);
--   incompletes: spin (over-rotation), two wheels off, reset, stop drifting, leaving the run (DM 1.12).
-- The points shown (lead max 60, chase max 40) are only a suggestion: the judges vote (A03, A13).

local geom = require('src/geom')
local scoring = require('src/scoring')
local telemetry = require('src/telemetry')
local decelmap = require('src/decelmap')

local T = {}

T.near, T.weak = 3, 4          -- m: up to 3 m good, 3–4 m weak („gyenge”), above 4 m far (A14 / A17)
T.stopDriftAngle = 8           -- °: below this (at speed) for stopDriftTime = stopped drifting
T.stopDriftTime = 1.0
T.passAhead = 1.0              -- m: the chase's front is this far ahead of the lead's front (along its direction)
T.passTime = 0.5
T.endWait = 8                  -- s: after the first car finished, wait at most this for the other

local function clamp(v, a, b) return math.max(a, math.min(b, v)) end

-- Outline of a car from its four bumper corners (front left, front right, rear right, rear left).
local function outline(s)
  return { { x = s.flx, z = s.flz }, { x = s.frx, z = s.frz }, { x = s.rrx, z = s.rrz }, { x = s.rlx, z = s.rlz } }
end
local function hasOutline(s) return s.flx and s.frx and s.rrx and s.rlx end

local function segDist(px, pz, ax, az, bx, bz)
  local dx, dz = bx - ax, bz - az
  local l2 = dx * dx + dz * dz
  local t = l2 > 1e-9 and clamp(((px - ax) * dx + (pz - az) * dz) / l2, 0, 1) or 0
  return geom.dist(px, pz, ax + dx * t, az + dz * t)
end

-- Distance of point p from polygon poly (0 if inside).
local function pointPolyDist(px, pz, poly)
  if geom.pointInPolygon(px, pz, poly) then return 0 end
  local best = math.huge
  for i = 1, #poly do
    local a, b = poly[i], poly[i % #poly + 1]
    best = math.min(best, segDist(px, pz, a.x, a.z, b.x, b.z))
  end
  return best
end

local function overlap(p1, p2)
  for _, p in ipairs(p1) do if geom.pointInPolygon(p.x, p.z, p2) then return true end end
  for _, p in ipairs(p2) do if geom.pointInPolygon(p.x, p.z, p1) then return true end end
  for i = 1, #p1 do
    local a, b = p1[i], p1[i % #p1 + 1]
    for j = 1, #p2 do
      local c, d = p2[j], p2[j % #p2 + 1]
      if geom.segmentIntersect(a.x, a.z, b.x, b.z, c.x, c.z, d.x, d.z) then return true end
    end
  end
  return false
end

-- Proximity: from the chase's front bumper (both corners and the middle) to the lead's outline.
function T.proximity(lead, chase)
  if not hasOutline(lead) or not hasOutline(chase) then
    return geom.dist(lead.px, lead.pz, chase.px, chase.pz)
  end
  local poly = outline(lead)
  local mx, mz = (chase.flx + chase.frx) / 2, (chase.flz + chase.frz) / 2
  return math.min(pointPolyDist(chase.flx, chase.flz, poly), pointPolyDist(chase.frx, chase.frz, poly), pointPolyDist(mx, mz, poly))
end

function T.touching(a, b)
  if not hasOutline(a) or not hasOutline(b) then return false end
  return overlap(outline(a), outline(b))
end

local function angleOf(s, cfg)
  if (s.spd or 0) < cfg.minSpeed then return 0, 0 end
  local a, dir = geom.driftAngle(s.lvx or 0, s.lvz or 0)
  return a, dir or 0
end

local function faultCount(judge)
  local f = judge.run and judge.run.faults
  if not f then return 0 end
  return (f.oneWheel or 0) + (f.twoWheel or 0)
end

-- A short summary of a solo result (what the battle keeps of it).
function T.compactResult(res)
  if not res then return nil end
  local sp = res.split or {}
  local f = res.faults or {}
  return {
    final = res.final, zero = res.zeroRun == true, zeroReasons = res.zeroReasons or {},
    line = sp.line, angle = sp.angle, style = sp.style, finished = res.finished,
    avgAngle = res.avgAngle, maxAngle = res.maxAngle, avgSpeed = res.avgSpeed,
    faults = { oneWheel = f.oneWheel, twoWheel = f.twoWheel, corrections = f.corrections, wallSaves = f.wallSaves, overRot = f.overRotations },
  }
end

-- cars: { lead = carIndex, chase = carIndex, leadName, chaseName }, compiled layout, cfg (judge config)
function T.new(cars, compiled, cfg, opts)
  opts = opts or {}
  local self = setmetatable({
    cars = cars, compiled = compiled, cfg = cfg, opts = opts,
    state = 'armed', t = 0,
    own = { lead = {}, chase = {} },
  }, { __index = T })
  self.judges = {
    lead = scoring.newJudge(compiled, cfg, { steerLock = opts.steerLead or 450 }),
    chase = scoring.newJudge(compiled, cfg, { steerLock = opts.steerChase or 450 }),
  }
  self.restarts = 0
  self:resetStats()
  return self
end

-- Clears what was measured (a restart of the lead starts the comparison again; the judges restart on their own).
function T:resetStats()
  self.results = {}
  self.ended = {}
  self.firstEndT = nil
  self.prox = { sum = 0, time = 0, near = 0, weak = 0, far = 0, min = math.huge, max = 0, series = {}, nextSeries = 0, now = nil }
  self.contacts = {}
  self.inContact, self.contactLastT = false, -100
  self.init = {}
  self.angle = { diffSum = 0, time = 0, within = 0 }
  self.line = { sum = 0, time = 0 }
  self.path = {}
  self.pass = nil
  self.passTime = 0
  self.stop = { lead = 0, chase = 0 }
  self.opp = { time = 0, noted = false }
  self.incomplete = { lead = {}, chase = {} }
  self.warnings = { lead = {}, chase = {} }
  self.hist = {}
  self.mapCheck = decelmap.newChecker(self.compiled and self.compiled.decel)
  self.started = false
end

local function addReason(list, text)
  for _, r in ipairs(list) do if r == text then return end end
  list[#list + 1] = text
end

-- One frame. getCar(i) → ac.StateCar (default ac.getCar). dt in seconds.
function T:update(dt, getCar)
  if self.state == 'done' or self.state == 'aborted' then return end
  getCar = getCar or ac.getCar
  self.t = self.t + (dt or 0)
  local okL, lc = pcall(getCar, self.cars.lead)
  local okC, cc = pcall(getCar, self.cars.chase)
  if not okL or not okC or not lc or not cc then return end
  local L = telemetry.sample(lc, self.t, self.own.lead)
  local C = telemetry.sample(cc, self.t, self.own.chase)
  self.last = { lead = L, chase = C }
  local cfg = self.cfg
  -- the two solo judges
  for role, s in pairs({ lead = L, chase = C }) do
    local j = self.judges[role]
    local ok, ev = pcall(j.feed, j, s)
    if ok and ev then
      if ev.type == 'runStarted' then
        if role == 'lead' then
          if ev.restarted or self.started then
            self.restarts = self.restarts + 1
            local keepChase = self.judges.chase
            self:resetStats()
            self.judges.chase = keepChase
          end
          self.started, self.state = true, 'running'
        end
      elseif ev.type == 'runFinished' then
        self.results[role] = ev.result
        self.ended[role] = 'finished'
        self.firstEndT = self.firstEndT or self.t
      elseif ev.type == 'runAborted' then
        self.ended[role] = 'aborted'
        addReason(self.incomplete[role], 'a futás megszakadt: ' .. tostring(ev.reason or ''))
        self.firstEndT = self.firstEndT or self.t
      end
    end
  end
  if not self.started then
    self.prox.now = T.proximity(L, C)
    return
  end
  local jl, jc = self.judges.lead, self.judges.chase
  local judgingL = jl.state == 'judging'
  local judgingC = jc.state == 'judging'
  local al, dl = angleOf(L, cfg)
  local ac_, dc = angleOf(C, cfg)

  -- lead's path (for the chase's line) and a short history of the lead (for contacts)
  local lp = self.path[#self.path]
  if not lp or geom.dist(lp.x, lp.z, L.px, L.pz) >= 0.5 then
    self.path[#self.path + 1] = { x = L.px, z = L.pz, t = self.t }
    if #self.path > 4000 then table.remove(self.path, 1) end
  end
  self.hist[#self.hist + 1] = { t = self.t, spd = L.spd or 0, angle = al, faults = faultCount(jl), brake = L.brake or 0, hb = L.hb or 0 }
  while #self.hist > 0 and self.t - self.hist[1].t > 1.5 do table.remove(self.hist, 1) end

  -- initiation (first time the angle reaches the minimum after the start line)
  if not self.init.lead and al >= cfg.angleMin then self.init.lead = { t = self.t, x = L.px, z = L.pz } end
  if not self.init.chase and ac_ >= cfg.angleMin then self.init.chase = { t = self.t, x = C.px, z = C.pz } end

  -- proximity, angle, line: while the lead is being judged and the chase is on course
  local d = T.proximity(L, C)
  self.prox.now = d
  if judgingL and not self.ended.chase then
    local p = self.prox
    p.sum, p.time = p.sum + d * dt, p.time + dt
    p.min, p.max = math.min(p.min, d), math.max(p.max, d)
    if d <= T.near then p.near = p.near + dt elseif d <= T.weak then p.weak = p.weak + dt else p.far = p.far + dt end
    if self.t >= p.nextSeries and #p.series < 600 then
      p.series[#p.series + 1] = { math.floor((self.t) * 10 + 0.5) / 10, math.floor(d * 100 + 0.5) / 100 }
      p.nextSeries = self.t + 0.25
    end
    if al >= cfg.angleMin and ac_ >= cfg.angleMin then
      local diff = ac_ - al
      self.angle.diffSum, self.angle.time = self.angle.diffSum + diff * dt, self.angle.time + dt
      if diff >= -5 then self.angle.within = self.angle.within + dt end
    end
    -- line: distance of the chase from the lead's path (the last 60 m of it)
    local best = math.huge
    for i = #self.path, math.max(1, #self.path - 120), -1 do
      local q = self.path[i]
      local dd = geom.dist(q.x, q.z, C.px, C.pz)
      if dd < best then best = dd end
    end
    if best < math.huge then self.line.sum, self.line.time = self.line.sum + best * dt, self.line.time + dt end
    -- passing: the chase's front ahead of the lead's front, along the lead's direction
    local fx, fz = (L.flx and (L.flx + L.frx) / 2 or L.px), (L.flz and (L.flz + L.frz) / 2 or L.pz)
    local cx, cz = (C.flx and (C.flx + C.frx) / 2 or C.px), (C.flz and (C.flz + C.frz) / 2 or C.pz)
    local hx, hz = fx - (L.rlx and (L.rlx + L.rrx) / 2 or L.px), fz - (L.rlz and (L.rlz + L.rrz) / 2 or L.pz)
    local hl = math.sqrt(hx * hx + hz * hz)
    if hl > 0.5 then
      local ahead = ((cx - fx) * hx + (cz - fz) * hz) / hl
      if ahead > T.passAhead then self.passTime = self.passTime + dt else self.passTime = 0 end
      if not self.pass and self.passTime >= T.passTime then
        self.pass = { t = self.t, x = C.px, z = C.pz }
      end
    end
  end
  if judgingL then self.mapCheck.feed(L) end

  -- drifting in the opposite direction (DM 1.12): both sideways, the other way, for a second
  if judgingL and al >= 15 and ac_ >= 15 and dl ~= 0 and dc ~= 0 and dl ~= dc then
    self.opp.time = self.opp.time + dt
    if not self.opp.noted and self.opp.time >= 1.0 then
      self.opp.noted = true
      addReason(self.warnings.chase, string.format('ellenkező irányban driftelt, mint a lead (%.0f s)', self.t))
    end
  else
    self.opp.time = 0
  end

  -- stopped drifting (DM 1.12): at speed, under the stop angle for a second, while judged
  for role, info in pairs({ lead = { s = L, a = al, judging = judgingL }, chase = { s = C, a = ac_, judging = judgingC } }) do
    if info.judging and (info.s.spd or 0) > 20 and info.a < T.stopDriftAngle and self.init[role] then
      self.stop[role] = self.stop[role] + dt
      if self.stop[role] >= T.stopDriftTime then addReason(self.incomplete[role], 'abbahagyta a driftet') end
    else
      self.stop[role] = 0
    end
  end

  -- contact
  local touch = T.touching(L, C) or ((L.col or -1) > 0 and (L.cd or 0) > 0 and (C.col or -1) > 0)
  if touch then
    if not self.inContact and self.t - self.contactLastT > 0.5 then self:addContact(L, C, al, ac_) end
    self.inContact, self.contactLastT = true, self.t
  elseif self.t - self.contactLastT > 0.3 then
    self.inContact = false
  end

  -- end of the run
  if (self.ended.lead and self.ended.chase) or (self.firstEndT and self.t - self.firstEndT > T.endWait) then
    self:finish()
  end
end

function T:addContact(L, C, al, ac_)
  local reasons = {}
  local maxSpd, lowAngle, faults0 = 0, false, nil
  for _, h in ipairs(self.hist) do
    if self.t - h.t <= 0.8 then maxSpd = math.max(maxSpd, h.spd) end
    if self.t - h.t <= 1.0 then
      if h.angle < self.cfg.angleMin then lowAngle = true end
      faults0 = faults0 or h.faults
    end
  end
  local drop = maxSpd - (L.spd or 0)
  local seg = nil
  local cm = self.compiled and self.compiled.decel
  if cm then seg = decelmap.segmentAt(cm, (decelmap.project(cm, L.px, L.pz))) end
  if lowAngle then reasons[#reasons + 1] = 'a lead elvesztette a driftet' end
  if drop > 10 and not (seg and seg.color == 'red') then
    reasons[#reasons + 1] = string.format('a lead hirtelen lassított (−%.0f km/h)', drop)
  end
  if faults0 and faultCount(self.judges.lead) > faults0 then reasons[#reasons + 1] = 'a lead elhagyta a pályát' end
  local leadFault = #reasons > 0
  if not leadFault then reasons[#reasons + 1] = 'a lead tartotta a driftet és a tempót: a chase ment neki' end
  self.contacts[#self.contacts + 1] = {
    t = math.floor(self.t * 10 + 0.5) / 10, x = (L.px + C.px) / 2, z = (L.pz + C.pz) / 2,
    leadFault = leadFault, reasons = reasons, leadAngle = math.floor(al + 0.5), chaseAngle = math.floor(ac_ + 0.5),
    leadDrop = math.floor(drop + 0.5), mapColor = seg and seg.color or nil,
  }
end

function T:finish(forced)
  if self.state == 'done' then return self.summary end
  for _, role in ipairs({ 'lead', 'chase' }) do
    if not self.results[role] then
      local j = self.judges[role]
      local res = j.finishNow and j:finishNow()
      if res then self.results[role] = res end
      if not self.ended[role] then addReason(self.incomplete[role], forced and 'a futást lezárták' or 'nem ért célba') end
    end
  end
  self.state = 'done'
  self.summary = self:buildSummary()
  return self.summary
end

function T:abort(why)
  self.state = 'aborted'
  self.abortReason = why
end

function T:buildSummary()
  local cfg = self.cfg
  local lr, cr = T.compactResult(self.results.lead), T.compactResult(self.results.chase)
  for role, r in pairs({ lead = lr, chase = cr }) do
    if r and r.zero then
      for _, z in ipairs(r.zeroReasons or {}) do addReason(self.incomplete[role], z) end
    end
    if not r then addReason(self.incomplete[role], 'nincs bírált futás') end
  end
  local p = self.prox
  local total = p.time > 0 and p.time or 1
  local prox = {
    avg = p.time > 0 and p.sum / p.time or nil, min = p.min < math.huge and p.min or nil, max = p.max,
    near = p.near / total, weak = p.weak / total, far = p.far / total, time = p.time, series = p.series,
  }
  local init = { lead = self.init.lead and self.init.lead.t or nil, chase = self.init.chase and self.init.chase.t or nil }
  if init.lead and init.chase then
    init.diff = init.chase - init.lead
    init.late = init.diff > 0.3
  elseif init.lead and not init.chase then
    init.late = true
  end
  -- (a late initiation is a fault for the judges, not an incomplete: it shows in init.late)
  local angle = { avgDiff = self.angle.time > 0 and self.angle.diffSum / self.angle.time or nil,
    within = self.angle.time > 0 and self.angle.within / self.angle.time or nil }
  local line = { avgDev = self.line.time > 0 and self.line.sum / self.line.time or nil }
  if self.pass then
    addReason(self.warnings.lead, 'a chase megelőzte – ha szabályosan (a lead hibája után), a lead futása incomplete')
    addReason(self.warnings.chase, 'megelőzte a leadet – ha szabálytalanul, a chase futása incomplete')
  end
  if self.restarts >= 3 then addReason(self.warnings.lead, string.format('%d újraindítás – a DM szabály szerint a 3. már incomplete', self.restarts)) end
  local map = { has = self.compiled and self.compiled.decel ~= nil and #self.compiled.decel.segments > 0 or false,
    violations = self.mapCheck.result(self.t) }
  -- suggestion (informational): lead 60 % of its solo score, chase 40 % × closeness / angle / line
  local leadInc = #self.incomplete.lead > 0
  local chaseInc = #self.incomplete.chase > 0
  local leadPts = (lr and not leadInc) and 0.6 * (lr.final or 0) or 0
  local proxScore = p.time > 0 and (p.near + 0.5 * p.weak) / p.time or 0
  local angleScore = angle.avgDiff and clamp(1 + angle.avgDiff / 20, 0, 1) or 0
  local lineScore = line.avgDev and clamp(1 - line.avgDev / 4, 0, 1) or 0
  local chasePts = (cr and not chaseInc) and 40 * (0.5 * proxScore + 0.25 * angleScore + 0.25 * lineScore) or 0
  if init.late then chasePts = chasePts * 0.9 end
  return {
    lead = self.cars.leadName, chase = self.cars.chaseName, leadIndex = self.cars.lead, chaseIndex = self.cars.chase,
    leadResult = lr, chaseResult = cr,
    prox = prox, contacts = self.contacts, init = init, angle = angle, line = line, pass = self.pass,
    map = map, incomplete = self.incomplete, warnings = self.warnings, restarts = self.restarts,
    leadPts = math.floor(leadPts * 10 + 0.5) / 10, chasePts = math.floor(chasePts * 10 + 0.5) / 10,
    scores = { prox = proxScore, angle = angleScore, line = lineScore },
  }
end

-- Live numbers for the HUDs (nil before the start).
function T:live()
  local l = self.last
  if not l then return nil end
  return {
    state = self.state, prox = self.prox.now, near = self.prox.now and self.prox.now <= T.near,
    leadAngle = angleOf(l.lead, self.cfg), chaseAngle = angleOf(l.chase, self.cfg),
    leadSpeed = l.lead.spd, chaseSpeed = l.chase.spd,
    contacts = #self.contacts, pass = self.pass ~= nil,
    leadJudge = self.judges.lead.state, chaseJudge = self.judges.chase.state,
  }
end

return T
