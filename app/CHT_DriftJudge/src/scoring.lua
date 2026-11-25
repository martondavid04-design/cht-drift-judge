-- CHT Drift Judge – solo run judging core. Pure Lua (LuaJIT / Lua 5.1+), no CSP dependency,
-- so the exact same code scores live runs in game and recorded runs offline.
--
-- Usage:
--   local judge = scoring.newJudge(compiledLayout, cfg, header)
--   local ev = judge:feed(sample)   -- once per frame; returns nil or an event table:
--        { type = 'runStarted' } | { type = 'judgingStarted' } |
--        { type = 'runFinished', result = <result> } | { type = 'runAborted', reason = '...' }
--   judge:live()                    -- live values for HUDs
--
-- Sample (plain table, one per frame):
--   t        time in seconds (monotonic)
--   px,py,pz car position (world)
--   lvx,lvz  local velocity (m/s, x sideways, z forward)
--   spd      speed km/h
--   steer    steering wheel angle, degrees
--   gas,brake,hb  0..1
--   wo       number of wheels outside of track limits (AC: car.wheelsOutside)
--   col      -1 no collision, 0 track/wall, >0 car
--   cd       collision depth (m)
--   flx,flz, frx,frz, rlx,rlz, rrx,rrz   bumper corners (front-left, front-right, rear-left, rear-right)
--   w0x,w0z .. w3x,w3z                   wheel contact points (0 FL, 1 FR, 2 RL, 3 RR)
--   jump     true if the car was teleported / reset this frame

local geom = require('src/geom')

local scoring = {}

local abs, max, min, floor = math.abs, math.max, math.min, math.floor
local clamp, lerp = geom.clamp, geom.lerp

local function round(v, d) return geom.round(v, d or 1) end

-- Share of the 100 points that comes from the style (DM: 0.2); the zones give the rest.
function scoring.styleShare(cfg)
  return clamp((cfg and cfg.styleWeight) or 0, 0, 0.9)
end

---------------------------------------------------------------------------------------------------
-- Zone runtime
---------------------------------------------------------------------------------------------------

local function zoneBBox(z)
  local x0, z0, x1, z1 = math.huge, math.huge, -math.huge, -math.huge
  for _, p in ipairs(z.pl.pts) do
    x0, z0, x1, z1 = min(x0, p.x), min(z0, p.z), max(x1, p.x), max(z1, p.z)
  end
  local m = z.capture + 6
  return x0 - m, z0 - m, x1 + m, z1 + m
end

local function newZoneState(z)
  local st = {
    z = z, line = {}, aSum = {}, aCnt = {}, nogo = {},
    prevValid = false, prevS = 0, prevL = 0, prevA = 0,
    minE = math.huge, minT = nil, minX = nil, minZ = nil,
    nearASum = 0, nearACnt = 0, nogoInside = false, nogoEvents = 0,
    spdSum = 0, spdCnt = 0, entrySpd = nil, exitSpd = nil,
  }
  for j = 1, z.nb do st.line[j] = 0; st.aSum[j] = 0; st.aCnt[j] = 0; st.nogo[j] = false end
  st.bx0, st.bz0, st.bx1, st.bz1 = zoneBBox(z)
  return st
end

local function lineMap(e, full, zero)
  if e <= full then return 1 end
  if e >= zero then return 0 end
  return 1 - (e - full) / (zero - full)
end

-- Angle score 0..1: 0 at/below `amin`, 1 at/above `atarget`, linear between.
local function angleMap(a, atarget, amin)
  if atarget <= amin then return a >= atarget and 1 or 0 end
  return clamp((a - amin) / (atarget - amin), 0, 1)
end

local function binIndex(z, s)
  local k = floor(s / z.binSize) + 1
  if k < 1 then k = 1 elseif k > z.nb then k = z.nb end
  return k
end

-- Points of the car that a zone looks at.
local function zonePoints(ztype, s)
  if ztype == 'OZ' or ztype == 'WALL' then
    return s.rlx, s.rlz, s.rrx, s.rrz
  elseif ztype == 'IZ' then
    return s.flx, s.flz, s.frx, s.frz
  else -- TNG: front wheels
    return s.w0x, s.w0z, s.w1x, s.w1z
  end
end

-- Effective distance of a point to the zone's reference line (meters), or nil if not alongside the zone.
local function effDist(z, px, pz)
  if not px then return nil end
  local s, lat, inside = geom.project(z.pl, px, pz)
  if not inside then return nil end
  -- distance to the reference line, whichever side the car is on (a wrongly set band side in the
  -- editor can not break scoring; going over a painted line is judged as off-track / no-go)
  return abs(lat), s
end

local function fillBins(st, s0, l0, a0, s1, l1, a1)
  local z = st.z
  local k0, k1 = binIndex(z, s0), binIndex(z, s1)
  local step = k1 >= k0 and 1 or -1
  local span = s1 - s0
  for j = k0, k1, step do
    local t
    if abs(span) < 1e-6 then t = 1 else t = clamp(((j - 0.5) * z.binSize - s0) / span, 0, 1) end
    local l = lerp(l0, l1, t)
    local a = lerp(a0, a1, t)
    if l > st.line[j] then st.line[j] = l end
    if l > 0 then
      st.aSum[j] = st.aSum[j] + a
      st.aCnt[j] = st.aCnt[j] + 1
    end
  end
end

local function markNogo(st, s0, s1)
  local z = st.z
  local k0, k1 = binIndex(z, s0), binIndex(z, s1)
  local step = k1 >= k0 and 1 or -1
  for j = k0, k1, step do st.nogo[j] = true end
end

local function anyPointInPolys(polys, s)
  for _, poly in ipairs(polys) do
    if geom.pointInPolygon(s.flx, s.flz, poly) or geom.pointInPolygon(s.frx, s.frz, poly)
      or geom.pointInPolygon(s.rlx, s.rlz, poly) or geom.pointInPolygon(s.rrx, s.rrz, poly)
      or geom.pointInPolygon(s.w0x, s.w0z, poly) or geom.pointInPolygon(s.w1x, s.w1z, poly)
      or geom.pointInPolygon(s.w2x, s.w2z, poly) or geom.pointInPolygon(s.w3x, s.w3z, poly) then
      return true
    end
  end
  return false
end

-- distance between segments a–b and c–d (2D)
local function segDist(ax, az, bx, bz, cx, cz, dx, dz)
  local function ps(px, pz, x0, z0, x1, z1)
    local vx, vz = x1 - x0, z1 - z0
    local l2 = vx * vx + vz * vz
    local t = l2 > 1e-12 and clamp(((px - x0) * vx + (pz - z0) * vz) / l2, 0, 1) or 0
    local qx, qz = x0 + vx * t - px, z0 + vz * t - pz
    return math.sqrt(qx * qx + qz * qz)
  end
  -- crossing segments touch
  local function orient(px, pz, qx, qz, rx, rz) return (qx - px) * (rz - pz) - (qz - pz) * (rx - px) end
  local o1, o2 = orient(ax, az, bx, bz, cx, cz), orient(ax, az, bx, bz, dx, dz)
  local o3, o4 = orient(cx, cz, dx, dz, ax, az), orient(cx, cz, dx, dz, bx, bz)
  if o1 * o2 < 0 and o3 * o4 < 0 then return 0 end
  return min(ps(ax, az, cx, cz, dx, dz), ps(bx, bz, cx, cz, dx, dz), ps(cx, cz, ax, az, bx, bz), ps(dx, dz, ax, az, bx, bz))
end

-- IC: distance of the front bumper (front-left → front-right corner) to the clipping point / clip line
local function icDist(z, s)
  local pts = z.pl.pts
  if #pts == 1 then
    return segDist(s.flx, s.flz, s.frx, s.frz, pts[1].x, pts[1].z, pts[1].x, pts[1].z)
  end
  local best = math.huge
  for i = 1, #pts - 1 do
    local d = segDist(s.flx, s.flz, s.frx, s.frz, pts[i].x, pts[i].z, pts[i + 1].x, pts[i + 1].z)
    if d < best then best = d end
  end
  return best
end

local function updateIC(st, s, angle, run)
  local z = st.z
  local e = icDist(z, s)
  if e > z.capture then return false end
  st.spdSum, st.spdCnt = st.spdSum + s.spd, st.spdCnt + 1
  st.entrySpd = st.entrySpd or s.spd
  st.exitSpd = s.spd
  local drifting = angle >= run.cfg.driftMinAngle
  if drifting or not run.cfg.lineNeedsDrift then
    if e < st.minE then st.minE, st.minT, st.minX, st.minZ = e, s.t, s.px, s.pz end
    if e <= z.zeroDist then
      st.nearASum = st.nearASum + angleMap(angle, z.angleTarget, z.angleMin)
      st.nearACnt = st.nearACnt + 1
    end
  end
  return e <= z.zeroDist
end

local function updateZone(st, s, angle, run)
  local z = st.z
  if s.px < st.bx0 or s.px > st.bx1 or s.pz < st.bz0 or s.pz > st.bz1 then
    st.prevValid = false
    return false
  end
  if z.type == 'IC' then return updateIC(st, s, angle, run) end

  -- no-go areas (any corner or wheel inside), marked along the zone by the car centre projection
  if #z.nogo > 0 then
    local inside = anyPointInPolys(z.nogo, s)
    if inside then
      local sc, _, insideSpan = geom.project(z.pl, s.px, s.pz)
      if insideSpan then
        markNogo(st, st.nogoLastS or sc, sc)
        st.nogoLastS = sc
      end
      if not st.nogoInside then
        st.nogoEvents = st.nogoEvents + 1
        run:addEvent('nogo', 'No-go: ' .. z.def.name, s, nil)
      end
    else
      st.nogoLastS = nil
    end
    st.nogoInside = inside
  end

  local ax, az, bx, bz = zonePoints(z.type, s)
  local e1, s1 = effDist(z, ax, az)
  local e2, s2 = effDist(z, bx, bz)
  local e, sp
  if e1 and (not e2 or e1 <= e2) then e, sp = e1, s1 elseif e2 then e, sp = e2, s2 end
  if not e or e > z.capture then
    st.prevValid = false
    return false
  end

  -- the rear touching the wall / line inside an OZ or wall zone counts as 0 cm (the bumper box
  -- corner is never exactly at the body surface, so a real contact is the most precise evidence)
  if (z.type == 'WALL' or z.type == 'OZ') and run.cfg.contactCountsAsLine and s.col == 0 and (s.cd or 0) > 0 and s.cpx then
    local fx, fz = (s.flx + s.frx) / 2, (s.flz + s.frz) / 2
    local rx, rz = (s.rlx + s.rrx) / 2, (s.rlz + s.rrz) / 2
    local rear = (s.cpx - s.px) * (fx - rx) + (s.cpz - s.pz) * (fz - rz) < 0
    if rear then
      local _, clat, cin = geom.project(z.pl, s.cpx, s.cpz)
      if cin and abs(clat) <= 0.6 then e = 0 end
    end
  end

  st.spdSum, st.spdCnt = st.spdSum + s.spd, st.spdCnt + 1
  st.entrySpd = st.entrySpd or s.spd
  st.exitSpd = s.spd

  local drifting = angle >= run.cfg.driftMinAngle
  local l = lineMap(e, z.fullDist, z.zeroDist)
  if run.cfg.lineNeedsDrift and not drifting then l = 0 end
  local a = l > 0 and angleMap(angle, z.angleTarget, z.angleMin) or 0
  if st.prevValid and abs(sp - st.prevS) < 8 then
    fillBins(st, st.prevS, st.prevL, st.prevA, sp, l, a)
  else
    fillBins(st, sp, l, a, sp, l, a)
  end
  st.prevValid, st.prevS, st.prevL, st.prevA = true, sp, l, a

  if z.type == 'TNG' and (drifting or not run.cfg.lineNeedsDrift) then
    if e < st.minE then
      st.minE, st.minT, st.minX, st.minZ = e, s.t, s.px, s.pz
    end
    if e <= z.zeroDist then
      st.nearASum = st.nearASum + angleMap(angle, z.angleTarget, z.angleMin)
      st.nearACnt = st.nearACnt + 1
    end
  end
  return l > 0
end

local function zoneResult(st, cfg, scale)
  local z = st.z
  local nb = z.nb
  local covered, lineSum, depthSum, nogoCnt, angleAll, angleCov = 0, 0, 0, 0, 0, 0
  for j = 1, nb do
    local l = st.line[j]
    lineSum = lineSum + l
    if l > 0 then
      covered = covered + 1
      depthSum = depthSum + l
      local aa = st.aCnt[j] > 0 and st.aSum[j] / st.aCnt[j] or 0
      angleAll = angleAll + aa
      angleCov = angleCov + aa
    end
    if st.nogo[j] then nogoCnt = nogoCnt + 1 end
  end
  local r = {
    name = z.def.name, type = z.type, maxPoints = z.weight or z.def.maxPoints or 0, index = z.index,
    coverage = covered / nb * 100,
    depth = covered > 0 and depthSum / covered * 100 or 0,
    nogo = nogoCnt / nb * 100,
    length = z.length,
  }
  if z.type == 'IC' then
    local e = st.minE
    r.minDist = e < math.huge and e or nil
    r.lineGross = e < math.huge and lineMap(e, z.fullDist, z.zeroDist) * 100 or 0
    r.angle = st.nearACnt > 0 and st.nearASum / st.nearACnt * 100 or 0
    r.entered = e <= z.zeroDist
    r.coverage = r.entered and 100 or 0
    r.depth = r.lineGross
  elseif z.type == 'TNG' then
    local t1, t2, t3 = z.tiers[1], z.tiers[2], z.tiers[3]
    local e = st.minE
    local prox = 0
    if e < math.huge then
      if z.tngMode == 'linear' then
        prox = lineMap(e, t1, t3) * 100
      else
        if e <= t1 then prox = 100 elseif e <= t2 then prox = 200 / 3 elseif e <= t3 then prox = 100 / 3 else prox = 0 end
      end
    end
    r.minDist = e < math.huge and e or nil
    r.lineGross = prox
    r.angle = st.nearACnt > 0 and st.nearASum / st.nearACnt * 100 or 0
    r.entered = e <= t3
  else
    r.lineGross = lineSum / nb * 100
    if cfg.angleGating == 'covered' then
      r.angle = covered > 0 and angleCov / covered * 100 or 0
    else
      r.angle = angleAll / nb * 100
    end
    r.entered = covered > 0
  end
  r.line = max(0, r.lineGross - r.nogo)
  local wl, wa = cfg.lineWeight, cfg.angleWeight
  local ws = wl + wa
  if ws <= 0 then wl, wa, ws = 1, 0, 1 end
  r.score = (wl * r.line + wa * r.angle) / ws
  -- maxPoints act as weights; with normalisation the zones of a layout always add up to 100
  scale = scale or 1
  r.weight = r.maxPoints
  r.maxPoints = r.maxPoints * scale
  r.points = r.score / 100 * r.maxPoints
  r.linePoints = r.maxPoints * (wl / ws) * r.line / 100
  r.anglePoints = r.maxPoints * (wa / ws) * r.angle / 100
  r.avgSpeed = st.spdCnt > 0 and st.spdSum / st.spdCnt or nil
  r.entrySpeed, r.exitSpeed = st.entrySpd, st.exitSpd
  -- compact per-bin line values for map colouring (max 120 values)
  local bins = {}
  local stride = math.max(1, math.ceil(nb / 120))
  for j = 1, nb, stride do
    local m = 0
    for k = j, min(nb, j + stride - 1) do if st.line[k] > m then m = st.line[k] end end
    bins[#bins + 1] = round(m, 2)
  end
  r.bins = bins
  return r
end

---------------------------------------------------------------------------------------------------
-- Run state (one judged run)
---------------------------------------------------------------------------------------------------

local Run = {}
Run.__index = Run

local function newRun(judge, t)
  local r = setmetatable({
    judge = judge, cfg = judge.cfg, startT = t, judgeT = nil,
    zones = {}, events = {}, trace = {}, lastTraceT = -1,
    faults = { oneWheel = 0, twoWheel = 0, corrections = 0, overRotations = 0, spins = 0,
      wallFlow = 0, wallSaves = 0, straight = 0, carContacts = 0, nogo = 0 },
    off = { active = false }, over = { active = false }, spin = {}, stall = {}, straight = {},
    hist = {}, fan = { trend = 0, ext = 0, rev = {} }, lastCorrT = -math.huge,
    wall = { active = false, lastEnd = -math.huge, ev = nil },
    carCol = { active = false },
    zeroReasons = {},
    stats = { maxAngle = 0, angleDist = 0, dist = 0, entrySpeed = nil, minSpeed = math.huge, spdSum = 0, n = 0 },
    driftDir = 0, prevPx = nil, prevPz = nil,
    style = { ema = nil, devSum = 0, devDist = 0, trDir = 0, trLastT = nil, trPending = nil, trTimes = {}, sinceTr = math.huge,
      entryDrop = 0, recent = {}, lockScores = {}, lockAngles = {}, lockPending = nil,
      driftDist = 0, liftDist = 0, spdHist = {}, spdHistDist = 0, spdDistSum = 0 },
    preDriftT = nil,
  }, Run)
  for i, z in ipairs(judge.layout.zones) do
    r.zones[i] = newZoneState(z)
    if z.def and z.def.limit == true then r.anyZoneLimit = true end
  end
  return r
end

function Run:jt(s) return s.t - (self.judgeT or self.startT) end

function Run:addEvent(kind, label, s, detail)
  local ev = { t = round(self:jt(s), 2), type = kind, label = label, x = round(s.px, 2), z = round(s.pz, 2), detail = detail }
  self.events[#self.events + 1] = ev
  return ev
end

function Run:zero(reason)
  for _, r in ipairs(self.zeroReasons) do if r == reason then return end end
  self.zeroReasons[#self.zeroReasons + 1] = reason
end

function Run:correction(s, kind, detail)
  local cfg = self.cfg
  if s.t - self.lastCorrT < cfg.correctionCooldown then return end
  self.lastCorrT = s.t
  if s.t - self.wall.lastEnd <= cfg.wallSaveWindow or self.wall.active then
    -- a correction right after touching the wall is its own category ("Fal utáni mentés")
    self.faults.wallSaves = self.faults.wallSaves + 1
    local ev = self:addEvent('wallSave', 'Fal utáni mentés', s, detail)
    ev.kind = kind
    if self.wall.ev and not self.wall.ev.saved then
      self.wall.ev.saved = true
      self.wall.ev.label = 'Falérintés – mentés kellett'
      if self.faults.wallFlow > 0 and self.wall.ev.countedFlow then
        self.faults.wallFlow = self.faults.wallFlow - 1
        self.wall.ev.countedFlow = false
      end
    end
    return
  end
  self.faults.corrections = self.faults.corrections + 1
  local label = kind == 'fan' and 'Korrekció (legyezés)' or 'Korrekció (szögesés)'
  self:addEvent('correction', label, s, detail)
end

-- Wheels beyond a "Pályahatár" line (returns bitmask of wheels 0..3 and the limit's name).
local wheelKeys = { { 'w0x', 'w0z' }, { 'w1x', 'w1z' }, { 'w2x', 'w2z' }, { 'w3x', 'w3z' } }
local function limitWheels(limits, s)
  local mask, name = 0, nil
  for _, lim in ipairs(limits) do
    if s.px >= lim.bx0 and s.px <= lim.bx1 and s.pz >= lim.bz0 and s.pz <= lim.bz1 then
      for i = 1, 4 do
        local wx, wz = s[wheelKeys[i][1]], s[wheelKeys[i][2]]
        if wx then
          local _, lat, inside = geom.project(lim.pl, wx, wz)
          -- beyond the line (+ the zone's own off-track offset, if set), but only close to it (another
          -- part of the track may lie further behind it)
          local tol = tonumber(lim.def.offTol) or 0
          local beyond = -lat * lim.side
          if inside and beyond > tol and beyond <= tol + 4 then
            local bitv = 2 ^ (i - 1)
            if mask % (bitv * 2) < bitv then mask = mask + bitv end
            name = lim.def.name
          end
        end
      end
    end
  end
  return mask, name
end

local function popcount4(m)
  local n = 0
  for i = 0, 3 do if math.floor(m / 2 ^ i) % 2 == 1 then n = n + 1 end end
  return n
end

local function orMask(a, b)
  for i = 0, 3 do
    local bitv = 2 ^ i
    if math.floor(b / bitv) % 2 == 1 and math.floor(a / bitv) % 2 == 0 then a = a + bitv end
  end
  return a
end

-- Zone lines as track limits: the outer line of an OZ, the inner line of an IZ and the TnG line
-- run along the edge of the track, so a wheel clearly beyond them is off-track. The track side is
-- learned from the car itself: when the car first comes alongside a zone, its centre is on the
-- track side, and a wheel on the other side of the line (by more than the tolerance) is off.
function Run:zoneLimitWheels(s)
  local cfg = self.cfg
  local mask, name = 0, nil
  for _, zs in ipairs(self.zones) do
    local z = zs.z
    -- per zone: z.def.limit (true / false) overrides the type setting; z.def.offTol overrides the tolerance
    local use
    if z.type == 'IC' then use = false
    elseif z.def.limit ~= nil then use = z.def.limit == true
    else use = (cfg.offTrackZones and ((z.type == 'OZ' and cfg.limitOZ) or (z.type == 'IZ' and cfg.limitIZ) or (z.type == 'TNG' and cfg.limitTNG))) end
    local tol = tonumber(z.def.offTol) or cfg.zoneLimitTolerance
    if use and s.px >= zs.bx0 and s.px <= zs.bx1 and s.pz >= zs.bz0 and s.pz <= zs.bz1 then
      local _, latC, insideC = geom.project(z.pl, s.px, s.pz)
      -- plausibility: a real track edge is never crossed by the car's centre; if it is, this line
      -- is not an edge and its off-track hits are dropped at the end of the run
      if insideC and abs(latC) > 1.0 and abs(latC) <= z.capture + 2 then
        if latC > 0 then zs.cPos = (zs.cPos or 0) + 1 else zs.cNeg = (zs.cNeg or 0) + 1 end
      end
      if insideC and abs(latC) <= z.capture + 2 then
        if not zs.trackSide then
          if z.def.sideSet then
            zs.trackSide = z.side
          elseif abs(latC) > 0.5 then
            zs.trackSide = latC > 0 and 1 or -1
          end
        end
        if zs.trackSide then
          for i = 1, 4 do
            local wx, wz = s[wheelKeys[i][1]], s[wheelKeys[i][2]]
            if wx then
              local _, lat, inside = geom.project(z.pl, wx, wz)
              local beyond = -lat * zs.trackSide
              if inside and beyond > tol and beyond <= tol + 4 then
                mask = orMask(mask, 2 ^ (i - 1))
                name = z.def.name
              end
            end
          end
        end
      end
    end
  end
  return mask, name
end

-- Off-track events: AC limits, wheel surface (grass/dirt/gravel/sand), zone lines, editor limit lines.
function Run:updateOffTrack(s, dt)
  local cfg, o = self.cfg, self.off
  local ac = cfg.offTrackAC and (s.wo or 0) or 0
  local mask = 0
  if cfg.offTrackSurface and (s.sg or 0) > 0 then mask = s.sg end
  local limName = nil
  if cfg.offTrackLimits and #self.judge.layout.limits > 0 then
    local lm
    lm, limName = limitWheels(self.judge.layout.limits, s)
    mask = orMask(mask, lm)
  end
  local zoneName = nil
  if cfg.offTrackZones or self.anyZoneLimit then
    local zm
    zm, zoneName = self:zoneLimitWheels(s)
    mask = orMask(mask, zm)
  end
  local wo = max(ac, popcount4(mask))
  if wo > 0 then
    self.offTimeTotal = (self.offTimeTotal or 0) + dt
    if not o.active then
      o.active, o.startT, o.maxWo, o.time, o.x, o.z = true, s.t, wo, 0, s.px, s.pz
      o.src = {}
    end
    if ac > 0 then o.src.ac = true end
    if (s.sg or 0) > 0 and cfg.offTrackSurface then o.src.surface = true end
    if limName then o.src.limit = limName end
    if zoneName then o.src.zone = zoneName end
    o.maxWo = max(o.maxWo, wo)
    o.time = o.time + dt
    o.lastOut = s.t
  elseif o.active and s.t - o.lastOut >= cfg.offTrackEndHold then
    self:closeOffTrack(s)
  end
end

function Run:closeOffTrack(s)
  local o = self.off
  if not o.active then return end
  o.active = false
  if o.time + 1e-6 < self.cfg.offTrackMinTime then return end
  local fake = { t = o.startT, px = o.x, pz = o.z }
  local srcTxt = {}
  if o.src then
    if o.src.zone then srcTxt[#srcTxt + 1] = o.src.zone .. ' vonalán túl' end
    if o.src.limit then srcTxt[#srcTxt + 1] = 'határ: ' .. o.src.limit end
    if o.src.surface then srcTxt[#srcTxt + 1] = 'fű/murva' end
    if o.src.ac then srcTxt[#srcTxt + 1] = 'AC pályahatár' end
  end
  local suffix = #srcTxt > 0 and (' (' .. table.concat(srcTxt, ', ') .. ')') or ''
  local zoneOnly = nil
  if o.src and o.src.zone and not o.src.ac and not o.src.surface and not o.src.limit then zoneOnly = o.src.zone end
  if o.maxWo >= 2 then
    self.faults.twoWheel = self.faults.twoWheel + 1
    self:addEvent('twoWheel', string.format('Pályaelhagyás – %d kerék', o.maxWo) .. suffix, fake, { wheels = o.maxWo, time = round(o.time, 2), zoneOnly = zoneOnly })
  else
    self.faults.oneWheel = self.faults.oneWheel + 1
    self:addEvent('oneWheel', 'Pályaelhagyás – 1 kerék' .. suffix, fake, { wheels = 1, time = round(o.time, 2), zoneOnly = zoneOnly })
  end
end

function Run:updateAngles(s, a, rawA, dir)
  local cfg = self.cfg

  -- spin: very high angle for a while
  if rawA >= cfg.spinAngle and s.spd > 3 then
    self.spin.since = self.spin.since or s.t
    if not self.spin.done and s.t - self.spin.since >= cfg.spinTime then
      self.spin.done = true
      self.faults.spins = self.faults.spins + 1
      self:addEvent('spin', string.format('Beforgás (%.0f°)', rawA), s, { angle = round(rawA, 1) })
      if cfg.spinZero then self:zero('Beforgás') end
    end
  else
    self.spin.since = nil
  end
  -- stall: (almost) stopped inside judging
  if s.spd < cfg.stallSpeed then
    self.stall.since = self.stall.since or s.t
    if not self.stall.done and s.t - self.stall.since >= cfg.stallTime then
      self.stall.done = true
      self.faults.spins = self.faults.spins + 1
      self:addEvent('spin', 'Megállás / beforgás', s, { speed = round(s.spd, 1) })
      if cfg.spinZero then self:zero('Megállás / beforgás') end
    end
  else
    self.stall.since = nil
  end

  -- over-rotation
  local ov = self.over
  if a >= cfg.overAngle then
    if not ov.active then ov.active, ov.max, ov.t0, ov.x, ov.z = true, a, s.t, s.px, s.pz end
    ov.max = max(ov.max, a)
  elseif ov.active and a < cfg.overAngle - 3 then
    ov.active = false
    self.faults.overRotations = self.faults.overRotations + 1
    self:addEvent('overRotation', string.format('Túldobás (%.0f°)', ov.max), { t = ov.t0, px = ov.x, pz = ov.z },
      { maxAngle = round(ov.max, 1), time = round(s.t - ov.t0, 2) })
  end

  -- straightening (info)
  local st = self.straight
  if a >= cfg.driftMinAngle + 3 then st.everDrifted = true end
  if not st.everDrifted then
    -- before the first initiation a straight car is expected (judging line before the entry)
  elseif a < cfg.driftMinAngle then
    st.since = st.since or s.t
    if not st.flagged and s.t - st.since >= cfg.straightTime then
      st.flagged = true
      self.faults.straight = self.faults.straight + 1
      self:addEvent('straight', 'Kiegyenesedés', s, nil)
    end
  elseif a > cfg.driftMinAngle + 3 then
    st.since, st.flagged = nil, false
  end
end

-- Correction detection: fast angle dip with recovery, or steering fanning, within one drift direction.
function Run:updateCorrections(s, a, dir)
  local cfg = self.cfg
  local drifting = a >= cfg.driftMinAngle and dir ~= 0
  if not drifting then
    self.hist = {}
    self.dip = nil
    self.fan.rev = {}
    self.driftDir = 0
    return
  end
  if dir ~= self.driftDir then
    -- transition: a new drift direction starts, previous history is irrelevant
    self.driftDir = dir
    self.hist = {}
    self.dip = nil
    self.fan.rev = {}
    self.fan.trend = 0
  end

  -- angle history in the last dipTime seconds
  local h = self.hist
  h[#h + 1] = { t = s.t, a = a }
  while #h > 0 and s.t - h[1].t > cfg.dipTime do table.remove(h, 1) end
  local wmax = a
  for i = 1, #h do if h[i].a > wmax then wmax = h[i].a end end

  if not self.dip then
    if wmax - a >= cfg.dipDegrees then
      self.dip = { low = a, t0 = s.t, peak = wmax }
    end
  else
    local dp = self.dip
    if a < dp.low then dp.low = a end
    if a - dp.low >= cfg.dipRecover then
      self:correction(s, 'dip', { drop = round(dp.peak - dp.low, 1), peak = round(dp.peak, 1), low = round(dp.low, 1) })
      self.dip = nil
      self.hist = { { t = s.t, a = a } }
    elseif s.t - dp.t0 > 1.5 then
      self.dip = nil -- slow, intended angle reduction
    end
  end

  -- steering fanning
  local lock = self.judge.steerLock
  local u = (s.steer or 0) / lock
  local f = self.fan
  if f.trend == 0 then
    f.trend, f.ext = 1, u
  elseif f.trend > 0 then
    if u > f.ext then f.ext = u
    elseif f.ext - u >= cfg.fanAmplitude then f.trend, f.ext = -1, u; f.rev[#f.rev + 1] = s.t end
  else
    if u < f.ext then f.ext = u
    elseif u - f.ext >= cfg.fanAmplitude then f.trend, f.ext = 1, u; f.rev[#f.rev + 1] = s.t end
  end
  while #f.rev > 0 and s.t - f.rev[1] > cfg.fanWindow do table.remove(f.rev, 1) end
  if #f.rev >= cfg.fanReversals then
    self:correction(s, 'fan', { reversals = #f.rev })
    f.rev = {}
  end
end

function Run:updateContacts(s)
  local cfg = self.cfg
  local w = self.wall
  local wallNow = s.col == 0 and (s.cd or 0) > 0
  if wallNow then
    if not w.active then
      w.active = true
      w.ev = self:addEvent('wall', 'Falérintés (flow)', s, { speed = round(s.spd, 1) })
      w.ev.countedFlow = true
      self.faults.wallFlow = self.faults.wallFlow + 1
    end
    w.lastSeen = s.t
  elseif w.active and s.t - (w.lastSeen or s.t) > 0.15 then
    w.active = false
    w.lastEnd = w.lastSeen
  end
  local carNow = (s.col or -1) > 0 and (s.cd or 0) > 0
  if carNow and not self.carCol.active then
    self.faults.carContacts = self.faults.carContacts + 1
    self:addEvent('carContact', 'Autóval érintkezés', s, { car = s.col })
  end
  self.carCol.active = carNow
end

-- Before the JUDGING line: remember since when the car has been drifting, so an initiation that
-- starts before the line ("early") is timed from its real start.
function Run:feedPre(s)
  local cfg = self.cfg
  local a, dir = geom.driftAngle(s.lvx or 0, s.lvz or 0)
  if s.spd >= cfg.minSpeed and a >= cfg.driftMinAngle and dir ~= 0 then
    if not self.preDriftT or self.preDriftDir ~= dir then self.preDriftT, self.preDriftDir = s.t, dir end
  else
    self.preDriftT, self.preDriftDir = nil, nil
  end
end

-- Measurable proxies of the Drift Masters style criteria (judging rules 2025, 1.6):
--   Initiation (5): early (vs the JUDGING line), rate to angle, smooth entry (no angle lost)
--   Fluidity (10):  rotation (transition time), lock to lock (high angle before and after a transition),
--                   flow (angle wobble)
--   Commitment (5): throttle (no lifting while drifting), pace (no bogging down; the layout's minimum tempo)
-- Confidence near walls and edges is already in the Line points, so it is not measured again here.
local ENTRY_WINDOW, LOCK_PRE, LOCK_POST = 1.5, 1.0, 1.5

function Run:updateStyle(s, a, dir, dt)
  local cfg, st = self.cfg, self.style
  local drifting = a >= cfg.driftMinAngle and dir ~= 0
  local d = self.prevStepDist or 0
  -- initiation: the drift's start (before the JUDGING line, if it was already drifting there)
  if drifting and not st.initT then
    local early = self.preDriftT and self.preDriftDir == dir and self.stats.dist < 0.5
    st.initT = early and self.preDriftT or s.t
    st.initDist = self.stats.dist
    st.initSpeed, st.initAngle, st.entryDir, st.entryMax = s.spd, a, dir, a
  end
  if st.initT then
    if not st.rateT and drifting and a >= 0.8 * cfg.angleTarget then st.rateT = s.t - st.initT end
    if s.t - st.initT <= 1.0 and a > (st.initAngle or 0) then st.initAngle = a end
    -- smooth entry: angle lost during the first 2.5 s and then taken back in the same direction (the
    -- angle dropped and had to be built up again – a correction or, if the drift was lost, a double
    -- initiation). An angle that falls and swings to the other side is a feint or a transition, and a
    -- small settle after the initial flick is not counted.
    local since = s.t - st.initT
    if since <= ENTRY_WINDOW + 1 then
      local inWin = since <= ENTRY_WINDOW
      if drifting and dir ~= st.entryDir then
        st.entryDir, st.entryMax, st.entryLow = dir, inWin and a or nil, nil
      elseif st.entryMax then
        if drifting and a > st.entryMax then
          if inWin then st.entryMax, st.entryLow = a, nil end
        else
          if not st.entryLow or a < st.entryLow then st.entryLow = a end
          if drifting and a >= st.entryLow + cfg.dipRecover then
            st.entryDrop = max(st.entryDrop, st.entryMax - st.entryLow)
          end
        end
      end
    end
  end
  if drifting then
    -- recent drifting samples (for the angle before a transition)
    local rc = st.recent
    rc[#rc + 1] = { s.t, a, dir }
    while #rc > 0 and s.t - rc[1][1] > LOCK_PRE + 3 do table.remove(rc, 1) end
    if st.trDir ~= 0 and dir ~= st.trDir and st.trLastT then
      st.trPending = { t0 = st.trLastT }
      st.sinceTr = 0
      local pre = 0
      for _, r in ipairs(rc) do if r[3] == st.trDir and st.trLastT - r[1] <= LOCK_PRE then pre = max(pre, r[2]) end end
      st.lockPending = { pre = pre, t0 = s.t, post = a }
    end
    st.trDir, st.trLastT = dir, s.t
    if st.trPending then
      if s.t - st.trPending.t0 > 3 then
        st.trPending = nil
      elseif a >= 0.5 * cfg.angleTarget then
        st.trTimes[#st.trTimes + 1] = s.t - st.trPending.t0
        st.trPending = nil
      end
    end
    if st.lockPending then st.lockPending.post = max(st.lockPending.post, a) end
    -- flow: deviation from an exponentially smoothed angle, weighted by distance,
    -- skipping the first 0.8 s after a transition (big intended changes)
    st.sinceTr = st.sinceTr + dt
    if not st.ema then st.ema = a end
    st.ema = st.ema + (a - st.ema) * math.min(1, dt / 0.5)
    if st.sinceTr > 0.8 and self.prevStepDist then
      st.devSum = st.devSum + abs(a - st.ema) * self.prevStepDist
      st.devDist = st.devDist + self.prevStepDist
    end
    -- throttle: share of the drifting distance with the throttle below 30%
    st.driftDist = st.driftDist + d
    if (s.gas or 1) < 0.3 then st.liftDist = st.liftDist + d end
  else
    st.ema = nil
  end
  local lp = st.lockPending
  if lp and s.t - lp.t0 >= LOCK_POST then
    -- a direction change with small angle on both sides is a wobble on a straight, not a transition
    if max(lp.pre, lp.post) >= 0.5 * cfg.angleTarget then
      local lower = min(lp.pre, lp.post)
      st.lockScores[#st.lockScores + 1] = angleMap(lower, cfg.angleTarget, cfg.angleMin)
      st.lockAngles[#st.lockAngles + 1] = lower
    end
    st.lockPending = nil
  end
  -- pace: speed distribution over the distance (after the first 3 s of judging)
  if self.judgeT and s.t - self.judgeT >= 3 and d > 0 then
    local b = floor(s.spd)
    st.spdHist[b] = (st.spdHist[b] or 0) + d
    st.spdHistDist = st.spdHistDist + d
  end
  st.spdDistSum = st.spdDistSum + s.spd * d
end

local function avgOf(list)
  if #list == 0 then return nil end
  local sum = 0
  for _, v in ipairs(list) do sum = sum + v end
  return sum / #list
end

-- speed (km/h) below which `q` of the distance was driven
local function histQuantile(hist, total, q)
  local keys = {}
  for k in pairs(hist) do keys[#keys + 1] = k end
  table.sort(keys)
  local acc = 0
  for _, k in ipairs(keys) do
    acc = acc + hist[k]
    if acc >= q * total then return k + 0.5 end
  end
  return keys[#keys] and keys[#keys] + 0.5 or 0
end

-- Style result: three parts, each 0..100 from its available sub-scores (a sub-score that could not be
-- measured, e.g. no transition on a one-way course, is left out of the average).
function Run:styleResult(avgSpeed, entrySpeed)
  local cfg, st = self.cfg, self.style
  local function part(subs)
    local sum, n = 0, 0
    for _, sb in ipairs(subs) do
      if sb.score then sum, n = sum + sb.score, n + 1 end
    end
    return n > 0 and sum / n or 0
  end
  local function pct(v) return v and round(v * 100, 2) or nil end

  -- Initiation
  local early, rate, entry
  if st.initT then
    early = clamp(1 - (st.initDist or 0) / math.max(0.5, cfg.styleInitLate), 0, 1)
    if st.rateT then
      rate = clamp(1 - (st.rateT - cfg.styleRateGood) / math.max(0.05, cfg.styleRateBad - cfg.styleRateGood), 0, 1)
    else
      rate = 0
    end
    entry = clamp(1 - (st.entryDrop - 3) / math.max(0.5, cfg.styleEntryDropBad - 3), 0, 1)
  end
  local ini = {
    early = { score = pct(early or 0), dist = round(st.initDist or 0, 1) },
    rate = { score = pct(rate or 0), time = st.rateT and round(st.rateT, 2) or nil },
    entry = { score = pct(entry or 0), drop = round(st.entryDrop or 0, 1) },
    angle = round(st.initAngle or 0, 1), speed = round(st.initSpeed or entrySpeed or 0, 1),
    drifted = st.initT ~= nil,
  }
  ini.score = round(part({ ini.early, ini.rate, ini.entry }), 2)

  -- Fluidity
  local rot, lock, flow = { count = #st.trTimes }, { count = #st.lockScores }, { measured = st.devDist > 5 }
  local trAvg = avgOf(st.trTimes)
  if trAvg then
    rot.avgTime = round(trAvg, 2)
    rot.score = pct(clamp(1 - (trAvg - cfg.styleTransGood) / math.max(0.05, cfg.styleTransBad - cfg.styleTransGood), 0, 1))
  end
  local lk = avgOf(st.lockScores)
  if lk then lock.score, lock.avgAngle = pct(lk), round(avgOf(st.lockAngles), 1) end
  if st.devDist > 5 then
    local dev = st.devSum / st.devDist
    flow.wobble = round(dev, 2)
    flow.score = pct(clamp(1 - dev / cfg.styleSmoothBad, 0, 1))
  end
  local flu = { rotation = rot, lock = lock, flow = flow }
  flu.score = round(part({ flow, rot, lock }), 2)

  -- Commitment
  local thr, pace = { measured = st.driftDist > 5 }, { measured = st.spdHistDist > 10 }
  if st.driftDist > 5 then
    local share = st.liftDist / st.driftDist
    thr.liftShare = round(share, 3)
    thr.score = pct(clamp(1 - (share - cfg.styleLiftGood) / math.max(0.01, cfg.styleLiftBad - cfg.styleLiftGood), 0, 1))
  end
  local tempo = self.judge.layout.tempo
  if st.spdHistDist > 10 then
    local p10 = histQuantile(st.spdHist, st.spdHistDist, 0.10)
    local med = histQuantile(st.spdHist, st.spdHistDist, 0.50)
    local ratio = med > 1 and p10 / med or 0
    pace.ratio, pace.p10, pace.median = round(ratio, 3), round(p10, 1), round(med, 1)
    local cons = clamp((ratio - cfg.stylePaceLow) / math.max(0.01, cfg.stylePaceHigh - cfg.stylePaceLow), 0, 1)
    pace.consistency = pct(cons)
    local sc = cons
    if tempo and tempo.min then
      local full = (tempo.full and tempo.full > tempo.min) and tempo.full or (tempo.min + 10)
      local ts = clamp((avgSpeed - tempo.min) / (full - tempo.min), 0, 1)
      pace.tempo = { score = pct(ts), avg = round(avgSpeed, 1), min = tempo.min, full = full }
      sc = (cons + ts) / 2
    end
    pace.score = pct(sc)
  end
  if entrySpeed and entrySpeed > 5 then pace.retention = round(avgSpeed / entrySpeed, 3) end
  local com = { throttle = thr, pace = pace }
  com.score = round(part({ thr, pace }), 2)

  local wI, wF, wC = max(0, cfg.styleInitPts or 5), max(0, cfg.styleFlowPts or 10), max(0, cfg.styleCommitPts or 5)
  local wSum = wI + wF + wC
  if wSum <= 0 then wI, wF, wC, wSum = 1, 1, 1, 3 end
  ini.weight, flu.weight, com.weight = wI / wSum, wF / wSum, wC / wSum
  -- 0.3.8: no drift at all (less than 5 m drifted) = no style points, like Line (a slow roll at an even
  -- speed used to get the 5 Commitment points for its "steady tempo").
  local noDrift = (st.driftDist or 0) <= 5
  return {
    version = 2,
    initiation = ini, fluidity = flu, commitment = com, noDrift = noDrift or nil,
    score = noDrift and 0 or round((wI * ini.score + wF * flu.score + wC * com.score) / wSum, 3),
  }
end

function Run:feedJudging(s, dt)
  local cfg = self.cfg
  local rawA, dir = geom.driftAngle(s.lvx or 0, s.lvz or 0)
  local a = rawA
  if s.spd < cfg.minSpeed then a, dir = 0, 0 end

  -- stats
  local st = self.stats
  if self.prevPx then
    local d = geom.dist(self.prevPx, self.prevPz, s.px, s.pz)
    if d < 10 then
      st.dist = st.dist + d
      st.angleDist = st.angleDist + a * d
      self.prevStepDist = d
    else
      self.prevStepDist = nil
    end
  end
  self.prevPx, self.prevPz = s.px, s.pz
  st.maxAngle = max(st.maxAngle, a)
  st.minSpeed = min(st.minSpeed, s.spd)
  st.spdSum, st.n = st.spdSum + s.spd, st.n + 1
  if not st.entrySpeed then st.entrySpeed, st.entryAngle = s.spd, a end

  self:updateStyle(s, a, dir, dt)
  self:updateOffTrack(s, dt)
  self:updateAngles(s, a, rawA, dir)
  self:updateCorrections(s, a, dir)
  self:updateContacts(s)

  local activeZone, activeZoneIdx = nil, nil
  for i, zs in ipairs(self.zones) do
    if updateZone(zs, s, a, self) then activeZone, activeZoneIdx = zs, i end
  end
  self.activeZone = activeZoneIdx

  if s.t - self.lastTraceT >= 0.1 then
    self.lastTraceT = s.t
    local rx, rz = (s.rlx + s.rrx) / 2, (s.rlz + s.rrz) / 2
    self.trace[#self.trace + 1] = { round(s.px, 2), round(s.pz, 2), round(a, 1), round(s.spd, 1), round(rx, 2), round(rz, 2), round(s.py or 0, 2) }
  end
  self.lastAngle, self.lastDir = a, dir
end

-- Factor that maps the sum of the zones' max points (weights) to 100.
-- With the style weight w (DM: 0.2) the zones add up to (1 - w) × 100 and the style gives the rest.
function Run:pointScale()
  if self.cfg.normalizeTotal == false then return 1 end
  local w = 0
  for _, zs in ipairs(self.zones) do w = w + (zs.z.weight or zs.z.def.maxPoints or 0) end
  if w <= 0 then return 1 end
  return 100 * (1 - scoring.styleShare(self.cfg)) / w
end

function Run:result(s, finished)
  self:closeOffTrack(s)
  if self.over.active then
    self.over.active = false
    self.faults.overRotations = self.faults.overRotations + 1
    self:addEvent('overRotation', string.format('Túldobás (%.0f°)', self.over.max), s, { maxAngle = round(self.over.max, 1) })
  end
  local cfg = self.cfg
  local zones, before = {}, 0
  local scale = self:pointScale()
  for i, zs in ipairs(self.zones) do
    local zr = zoneResult(zs, cfg, scale)
    zones[i] = zr
    before = before + zr.points
  end

  local f = self.faults
  local warnings = {}
  local warningItems = {} -- same warnings, structured for the UI: { kind, text, zones = { layout zone index, ... } }

  -- drop off-track hits that came only from zone lines which turned out not to be track edges
  local invalid, names, idxs = {}, {}, {}
  for _, zs in ipairs(self.zones) do
    if (zs.cPos or 0) >= 3 and (zs.cNeg or 0) >= 3 then
      invalid[zs.z.def.name] = true
      names[#names + 1] = zs.z.def.name
      idxs[#idxs + 1] = zs.z.index
    end
  end
  if #names > 0 then
    local kept = {}
    for _, e in ipairs(self.events) do
      local drop = (e.type == 'oneWheel' or e.type == 'twoWheel') and e.detail and e.detail.zoneOnly and invalid[e.detail.zoneOnly]
      if not drop then kept[#kept + 1] = e end
    end
    self.events = kept
    f.oneWheel, f.twoWheel = 0, 0
    for _, e in ipairs(kept) do
      if e.type == 'oneWheel' then f.oneWheel = f.oneWheel + 1 elseif e.type == 'twoWheel' then f.twoWheel = f.twoWheel + 1 end
    end
    warnings[#warnings + 1] = string.format('%s: a vonalon az autó közepe is áthaladt, tehát nem a pálya szélén van – itt nem figyeltem a pályaelhagyást. Rajzold a vonalat pontosan a pálya szélére.', table.concat(names, ', '))
    warningItems[#warningItems + 1] = { kind = 'zoneLine', text = warnings[#warnings], zones = idxs, names = names }
  end

  if cfg.twoWheelZero and f.twoWheel > 0 then self:zero('Kétkerekes pályaelhagyás') end
  if f.oneWheel >= cfg.oneWheelZeroAt then self:zero(string.format('%d egykerekes pályaelhagyás', f.oneWheel)) end

  local deductions, dsum = {}, 0
  local function ded(label, amount)
    if amount > 0 then deductions[#deductions + 1] = { label = label, amount = amount }; dsum = dsum + amount end
  end
  ded(string.format('Egykerekes pályaelhagyás × %d', f.oneWheel), f.oneWheel * cfg.oneWheelPenalty)
  ded(string.format('Korrekció × %d', f.corrections), f.corrections * cfg.correctionPenalty)
  ded(string.format('Túldobás × %d', f.overRotations), f.overRotations * cfg.overRotationPenalty)
  ded(string.format('Fal utáni mentés × %d', f.wallSaves), f.wallSaves * cfg.wallSavePenalty)

  local judgedTime = s.t - (self.judgeT or self.startT)
  if judgedTime > 2 and (self.offTimeTotal or 0) / judgedTime > 0.3 then
    warnings[#warnings + 1] = string.format('Gyanús pályaelhagyás-adat: a futás %.0f%%-ában jelzett kint lévő kereket. Ellenőrizd a pályahatár vonalak oldalát!', (self.offTimeTotal or 0) / judgedTime * 100)
    warningItems[#warningItems + 1] = { kind = 'offTrackSuspicious', text = warnings[#warnings], zones = {} }
  end

  local st = self.stats
  local zoneMax, lineSum, angleSum = 0, 0, 0
  for _, z in ipairs(zones) do
    zoneMax = zoneMax + z.maxPoints
    lineSum, angleSum = lineSum + (z.linePoints or 0), angleSum + (z.anglePoints or 0)
  end
  local avgSpeed = st.n > 0 and st.spdSum / st.n or 0
  local avgSpeedDist = st.dist > 1 and self.style.spdDistSum / st.dist or avgSpeed
  local style = self:styleResult(avgSpeedDist, st.entrySpeed)
  local zoneSum = before
  local sw = scoring.styleShare(cfg)
  local styleMax = (sw > 0 and zoneMax > 0) and zoneMax * sw / (1 - sw) or 0
  local stylePoints = style.score / 100 * styleMax
  for _, key in ipairs({ 'initiation', 'fluidity', 'commitment' }) do
    local p = style[key]
    p.max = styleMax * p.weight
    p.points = round(p.score / 100 * p.max, 3)
    p.max = round(p.max, 3)
  end
  before = zoneSum + stylePoints
  local total = zoneMax + styleMax
  local wl, wa = cfg.lineWeight, cfg.angleWeight
  local ws = wl + wa
  if ws <= 0 then wl, wa, ws = 1, 0, 1 end
  -- the run's points by criterion (DM: Line 60, Angle 20, Style 20)
  local split = {
    line = round(lineSum, 3), lineMax = round(zoneMax * wl / ws, 3),
    angle = round(angleSum, 3), angleMax = round(zoneMax * wa / ws, 3),
    style = round(stylePoints, 3), styleMax = round(styleMax, 3),
  }

  -- minimum tempo of the layout (flag; it also counts in Style / Commitment)
  local tempo = self.judge.layout.tempo
  if tempo and tempo.min and st.dist > 20 and avgSpeedDist < tempo.min then
    f.slow = (f.slow or 0) + 1
    local txt = string.format('Minimális tempó alatt: átlag %.0f km/h, a pályaterv minimuma %.0f km/h.', avgSpeedDist, tempo.min)
    self:addEvent('slow', string.format('Minimális tempó alatt (%.0f / %.0f km/h)', avgSpeedDist, tempo.min), s, { avg = round(avgSpeedDist, 1), min = tempo.min })
    warnings[#warnings + 1] = txt
    warningItems[#warningItems + 1] = { kind = 'slow', text = txt, zones = {} }
    ded('Minimális tempó alatt', cfg.tempoPenalty or 0)
  end
  table.sort(self.events, function(a, b) return a.t < b.t end)
  local zero = #self.zeroReasons > 0
  local res = {
    format = 'cht-drift-result', version = 1,
    finished = finished,
    duration = round(s.t - (self.judgeT or self.startT), 2),
    entrySpeed = round(st.entrySpeed or 0, 1), entryAngle = round(st.entryAngle or 0, 1),
    avgSpeed = round(avgSpeedDist, 1),
    minSpeed = round(st.minSpeed < math.huge and st.minSpeed or 0, 1),
    maxAngle = round(st.maxAngle, 1),
    avgAngle = round(st.dist > 0 and st.angleDist / st.dist or 0, 1),
    distance = round(st.dist, 1),
    zones = zones, maxTotal = total,
    zoneSum = round(zoneSum, 3), style = style, styleWeight = sw, split = split,
    tempo = tempo and { min = tempo.min, full = tempo.full } or nil,
    beforeDeductions = before,
    deductions = deductions, deductionTotal = dsum,
    faults = f, events = self.events,
    zeroRun = zero, zeroReasons = self.zeroReasons, warnings = warnings, warningItems = warningItems,
    final = zero and 0 or max(0, before - dsum),
    trace = self.trace,
  }
  for _, z in ipairs(zones) do
    z.coverage, z.depth, z.nogo = round(z.coverage, 3), round(z.depth, 3), round(z.nogo, 3)
    z.lineGross, z.line, z.angle = round(z.lineGross, 3), round(z.line, 3), round(z.angle, 3)
    z.score, z.points = round(z.score, 3), round(z.points, 3)
    z.linePoints, z.anglePoints = round(z.linePoints or 0, 3), round(z.anglePoints or 0, 3)
    z.maxPoints = round(z.maxPoints, 3)
    if z.minDist then z.minDist = round(z.minDist, 3) end
    if z.avgSpeed then z.avgSpeed = round(z.avgSpeed, 1) end
    if z.entrySpeed then z.entrySpeed = round(z.entrySpeed, 1) end
    if z.exitSpeed then z.exitSpeed = round(z.exitSpeed, 1) end
  end
  res.beforeDeductions, res.final = round(res.beforeDeductions, 3), round(res.final, 3)
  return res
end

-- Partial zone scores during a run (for live view).
function Run:partial()
  local cfg = self.cfg
  local out, sum = {}, 0
  local scale = self:pointScale()
  for i, zs in ipairs(self.zones) do
    local zr = zoneResult(zs, cfg, scale)
    out[i] = zr
    sum = sum + zr.points
  end
  return out, sum
end

---------------------------------------------------------------------------------------------------
-- Judge: gates + run lifecycle
---------------------------------------------------------------------------------------------------

local Judge = {}
Judge.__index = Judge

function scoring.newJudge(compiled, cfg, header)
  header = header or {}
  local lock = header.steerLock
  if type(lock) ~= 'number' or lock <= 1 then lock = 450 end
  return setmetatable({
    layout = compiled, cfg = cfg, header = header, steerLock = lock,
    state = 'idle', run = nil, prev = nil, lastT = nil,
  }, Judge)
end

local function crosses(g, ax, az, bx, bz)
  if not g then return false end
  return geom.segmentIntersect(ax, az, bx, bz, g.ax, g.az, g.bx, g.bz) ~= nil
end

function Judge:reset()
  self.state, self.run = 'idle', nil
end

-- For recordings that begin exactly at the start of a run. With `judging = true` judging starts
-- immediately (used to score free recordings that never crossed the gates).
function Judge:forceStart(t, judging)
  self.run = newRun(self, t)
  if judging then
    self.run.judgeT = t
    self.state = 'judging'
  else
    self.state = 'started'
  end
end

function Judge:feed(s)
  local prev = self.prev
  local dt = (self.lastT and s.t - self.lastT) or 0
  if dt < 0 or dt > 0.5 then dt = 0 end
  self.prev, self.lastT = s, s.t
  local g = self.layout.gates
  local event = nil

  -- reset / teleport: while judging a zero run (CHT, 2026-11-14), before the JUDGING line only an abort
  local jumped = s.jump
  if not jumped and prev and geom.dist(prev.px, prev.pz, s.px, s.pz) > 30 then jumped = 'far' end
  if jumped then
    if self.run then
      if self.state == 'judging' and self.cfg.resetZero ~= false and prev then
        local run = self.run
        run:zero('Visszarakás a bírálat alatt')
        run:addEvent('reset', jumped == 'far' and 'Visszarakás / teleport (nagy ugrás a pozícióban)' or 'Visszarakás (reset, box, teleport)', prev)
        local res = run:result(prev, false)
        self.state, self.run = 'idle', nil
        self.lastResult = res
        return { type = 'runFinished', result = res, reset = true }
      end
      self.run, self.state = nil, 'idle'
      return { type = 'runAborted', reason = jumped == 'far' and 'Nagy ugrás a pozícióban (teleport?).' or 'Az autó vissza lett rakva / teleportált.' }
    end
    return nil
  end
  if not prev then return nil end

  local crossStart = crosses(g.start, prev.px, prev.pz, s.px, s.pz)
  local crossJudging = crosses(g.judging, prev.px, prev.pz, s.px, s.pz)
  local crossFinish = crosses(g.finish, prev.px, prev.pz, s.px, s.pz)

  if self.state == 'idle' then
    if crossStart then
      self.run = newRun(self, s.t)
      self.state = 'started'
      event = { type = 'runStarted' }
    elseif not g.start and crossJudging then
      self.run = newRun(self, s.t)
      self.run.judgeT = s.t
      self.state = 'judging'
      return { type = 'runStarted', judging = true }
    end
    return event
  end

  local run = self.run
  if s.t - run.startT > self.cfg.maxRunTime then
    self.run, self.state = nil, 'idle'
    return { type = 'runAborted', reason = 'Túl hosszú futás (időtúllépés).' }
  end

  if self.state == 'started' then
    run:feedPre(s)
    if crossStart and s.t - run.startT > 2 then
      self.run = newRun(self, s.t)
      return { type = 'runStarted', restarted = true }
    end
    if crossJudging then
      run.judgeT = s.t
      self.state = 'judging'
      run:feedJudging(s, dt)
      return { type = 'judgingStarted' }
    end
    return nil
  end

  if self.state == 'judging' then
    run:feedJudging(s, dt)
    if crossFinish then
      local res = run:result(s, true)
      self.state, self.run = 'idle', nil
      self.lastResult = res
      return { type = 'runFinished', result = res }
    end
    if crossStart and s.t - run.startT > 2 then
      self.run = newRun(self, s.t)
      self.state = 'started'
      return { type = 'runStarted', restarted = true }
    end
  end
  return nil
end

-- Ends the current run early (e.g. judge presses "Futás lezárása").
function Judge:finishNow()
  if self.run and self.prev and self.state == 'judging' then
    local res = self.run:result(self.prev, false)
    self.state, self.run = 'idle', nil
    self.lastResult = res
    return res
  end
  return nil
end

function Judge:live()
  local s = self.prev
  local out = { state = self.state }
  if not s then return out end
  local a, dir = geom.driftAngle(s.lvx or 0, s.lvz or 0)
  if s.spd < self.cfg.minSpeed then a, dir = 0, 0 end
  out.angle, out.dir, out.speed, out.steer = a, dir, s.spd, s.steer
  local run = self.run
  if run then
    out.runTime = s.t - run.startT
    out.judgeTime = run.judgeT and (s.t - run.judgeT) or nil
    out.faults = run.faults
    out.activeZone = run.activeZone and run.zones[run.activeZone].z.def.name or nil
    out.zeroReasons = run.zeroReasons
  end
  return out
end

function Judge:partial()
  if self.run and self.state == 'judging' then return self.run:partial() end
  return nil
end

scoring.zoneResult = zoneResult
scoring.lineMap = lineMap

return scoring
