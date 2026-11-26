-- CHT Drift Judge – car state → plain sample tables + recorder (CSP only).

local callable = require('src/fn').callable
local telemetry = {}

-- Order of values in recorded sample rows (keeps files compact: one array per frame).
telemetry.fields = {
  't', 'px', 'py', 'pz', 'lvx', 'lvz', 'spd', 'steer', 'gas', 'brake', 'hb', 'wo', 'col', 'cd',
  'flx', 'flz', 'frx', 'frz', 'rlx', 'rlz', 'rrx', 'rrz',
  'w0x', 'w0z', 'w1x', 'w1z', 'w2x', 'w2z', 'w3x', 'w3z', 'jump', 'gear', 'rpm',
  'cpx', 'cpz', -- collision point (world), when colliding
  'sg',          -- bitmask: wheels on grass / dirt / gravel / sand
  'sv',          -- bitmask: wheels on a surface AC marks as not valid track
  'se',          -- packed surfaceExtendedType of the 4 wheels (4 bits each), for analysis
  'clutch', 'dslip', -- clutch value as AC gives it, driven wheels spin (tyre surface speed / wheel ground speed - 1)
  'wfb',         -- 0.3.14: bitmask of wheels whose contact point was missing (remote car) and was estimated
}
local precision = {
  t = 3, px = 3, py = 2, pz = 3, lvx = 3, lvz = 3, spd = 2, steer = 1, gas = 2, brake = 2, hb = 2,
  cd = 3, rpm = 0, clutch = 2, dslip = 2,
}

local tmpLocal = { vec3(), vec3(), vec3(), vec3() }
local corners = { vec3(), vec3(), vec3(), vec3() }
local collisionWorld = vec3()

local jumpFlags = {}
local jumpSubscriptions = {}

function telemetry.watchJumps(carIndex)
  if jumpSubscriptions[carIndex] then return end
  -- (the reset counter below catches resets too, if this CSP version has no ac.onCarJumped)
  if not callable(ac.onCarJumped) then jumpSubscriptions[carIndex] = true return end
  local ok, sub = pcall(ac.onCarJumped, carIndex, function(idx) jumpFlags[idx] = true end)
  jumpSubscriptions[carIndex] = ok and sub or true
end

local lastReset = {}

-- Builds a sample for car `car` (ac.StateCar) at time `t` (seconds).
function telemetry.sample(car, t)
  local s = { t = t }
  local p = car.position
  s.px, s.py, s.pz = p.x, p.y, p.z
  local lv = car.localVelocity
  s.lvx, s.lvz = lv.x, lv.z
  s.spd = car.speedKmh
  s.steer = car.steer
  s.gas, s.brake, s.hb = car.gas, car.brake, car.handbrake
  s.wo = car.wheelsOutside or 0
  if car.collisionDepth > 0 then
    s.col, s.cd = car.collidedWith, car.collisionDepth
    car.bodyTransform:transformPointTo(collisionWorld, car.collisionPosition)
    s.cpx, s.cpz = collisionWorld.x, collisionWorld.z
  else
    s.col, s.cd = -1, 0
  end
  s.gear, s.rpm = car.gear, car.rpm

  -- bumper corners from the AABB of the car model, classified into front / rear using the look vector
  local c, z = car.aabbCenter, car.aabbSize
  local hx, hz = z.x / 2, z.z / 2
  local y = c.y - z.y / 2 + 0.15
  tmpLocal[1]:set(c.x - hx, y, c.z + hz)
  tmpLocal[2]:set(c.x + hx, y, c.z + hz)
  tmpLocal[3]:set(c.x - hx, y, c.z - hz)
  tmpLocal[4]:set(c.x + hx, y, c.z - hz)
  local tr = car.bodyTransform
  local look = car.look
  local front, rear = {}, {}
  for i = 1, 4 do
    tr:transformPointTo(corners[i], tmpLocal[i])
    local w = corners[i]
    local d = (w.x - p.x) * look.x + (w.z - p.z) * look.z
    if d >= 0 then front[#front + 1] = w else rear[#rear + 1] = w end
  end
  if #front ~= 2 or #rear ~= 2 then
    -- degenerate AABB: fall back to a 4.4 × 1.8 m box around the car position
    local side = car.side
    local function pt(f, sd) return p.x + look.x * f + side.x * sd, p.z + look.z * f + side.z * sd end
    s.flx, s.flz = pt(2.2, -0.9); s.frx, s.frz = pt(2.2, 0.9)
    s.rlx, s.rlz = pt(-2.2, -0.9); s.rrx, s.rrz = pt(-2.2, 0.9)
  else
    s.flx, s.flz, s.frx, s.frz = front[1].x, front[1].z, front[2].x, front[2].z
    s.rlx, s.rlz, s.rrx, s.rrz = rear[1].x, rear[1].z, rear[2].x, rear[2].z
  end

  -- Wheels. A car driven on another PC (spectator / judge following it with the camera) may come without
  -- physics contact data: then the contact point is empty or far from the car and the surface reads as
  -- „grass” (0). Such a wheel is placed from its visual position (or the car's outline) and its surface
  -- flags are not used, so a spectated run is not zeroed by missing data (0.3.14).
  local sg, sv, se, fb = 0, 0, 0, 0
  for i = 0, 3 do
    local wh = car.wheels[i]
    local wp = wh.contactPoint
    local bitv = 2 ^ i
    local okP = wp ~= nil and (wp.x ~= 0 or wp.z ~= 0) and (wp.x - p.x) ^ 2 + (wp.z - p.z) ^ 2 < 25
    if okP then
      s['w' .. i .. 'x'], s['w' .. i .. 'z'] = wp.x, wp.z
      local st, ext = wh.surfaceType, wh.surfaceExtendedType or 0
      if st == 0 or st == 1 or ext == 2 or ext == 3 or ext == 6 then sg = sg + bitv end -- grass, dirt, gravel, sand
      if wh.surfaceValidTrack == false then sv = sv + bitv end
      se = se + (ext % 16) * 16 ^ i
    else
      fb = fb + bitv
      local q = wh.position
      if q ~= nil and (q.x ~= 0 or q.z ~= 0) and (q.x - p.x) ^ 2 + (q.z - p.z) ^ 2 < 25 then
        s['w' .. i .. 'x'], s['w' .. i .. 'z'] = q.x, q.z
      else
        -- wheel order: 0 front left, 1 front right, 2 rear left, 3 rear right
        local f = i < 2 and 1.3 or -1.3
        local sd = (i % 2 == 0) and -0.75 or 0.75
        local look, side = car.look, car.side
        s['w' .. i .. 'x'] = p.x + look.x * f + side.x * sd
        s['w' .. i .. 'z'] = p.z + look.z * f + side.z * sd
      end
    end
  end
  s.sg, s.sv, s.se, s.wfb = sg, sv, se, fb
  s.clutch = car.clutch
  s.dslip = telemetry.drivenSlip(car)

  local idx = car.index
  if jumpFlags[idx] then
    s.jump = true
    jumpFlags[idx] = false
  end
  if lastReset[idx] and lastReset[idx] ~= car.resetCounter then s.jump = true end
  lastReset[idx] = car.resetCounter
  return s
end

-- Driven wheels: how much faster the tyre surface turns than the wheel actually moves over the ground
-- (0 = no wheelspin, 0.5 = the tyres turn 50 % faster than the car moves). The ground speed is the
-- wheel's full speed over the ground – in a drift most of it is sideways, so taking only the part along
-- the wheel (as 0.3.0–0.3.3 did) showed far too high values; below 3 m/s the ground speed is treated as
-- 3 m/s so a slow roll does not show huge percentages.
local function wheelSpeeds(wh)
  local v = wh.velocity
  local ground = math.sqrt(v.x * v.x + v.z * v.z)
  local surface = math.abs((wh.angularSpeed or 0) * (wh.tyreRadius or 0.3))
  return surface, ground
end

local function drivenIdx(car)
  local t = car.tractionType
  if t == 1 then return { 0, 1 } end
  if t == 2 or t == 3 then return { 0, 1, 2, 3 } end
  return { 2, 3 }
end

-- average tyre surface speed and ground speed of the driven wheels, m/s
function telemetry.drivenSpeeds(car)
  local idx = drivenIdx(car)
  local ss, gs = 0, 0
  for _, i in ipairs(idx) do
    local s, g = wheelSpeeds(car.wheels[i])
    ss, gs = ss + s, gs + g
  end
  return ss / #idx, gs / #idx
end

function telemetry.drivenSlip(car)
  local surface, ground = telemetry.drivenSpeeds(car)
  local slip = (surface - ground) / math.max(ground, 3)
  if slip ~= slip then return 0 end
  return math.max(-1, math.min(5, slip))
end

function telemetry.header(car, extra)
  local h = {
    driver = ac.getDriverName(car.index) or '',
    car = ac.getCarName(car.index) or '',
    carID = ac.getCarID(car.index) or '',
    track = ac.getTrackFullID('/'),
    trackName = ac.getTrackName and ac.getTrackName() or '',
    steerLock = car.steerLock,
    tractionType = car.tractionType,
    aabbCenter = { car.aabbCenter.x, car.aabbCenter.y, car.aabbCenter.z },
    aabbSize = { car.aabbSize.x, car.aabbSize.y, car.aabbSize.z },
    remote = car.isRemote,
    csp = ac.getPatchVersion and ac.getPatchVersion() or '',
    cspCode = ac.getPatchVersionCode and ac.getPatchVersionCode() or 0,
    appVersion = extra and extra.appVersion or '',
    time = extra and extra.time or '',
    carIndex = car.index,
  }
  -- 0.3.14: judged on someone else's PC (spectator / judge following the car with the camera)
  if (car.index or 0) ~= 0 then
    h.spectated = true
    local okN, me = pcall(ac.getDriverName, 0)
    h.judgedBy = okN and me or ''
  end
  return h
end

-- Converts a sample to a compact row.
function telemetry.pack(s)
  local row = {}
  for i, k in ipairs(telemetry.fields) do
    local v = s[k]
    if k == 'jump' then v = v and 1 or 0
    elseif v == nil or v ~= v or v == math.huge or v == -math.huge then v = 0 end
    local pr = precision[k]
    if pr and type(v) == 'number' then
      local m = 10 ^ pr
      v = math.floor(v * m + 0.5) / m
    elseif type(v) == 'number' and k ~= 'wo' and k ~= 'col' and k ~= 'gear' then
      v = math.floor(v * 1000 + 0.5) / 1000
    end
    row[i] = v
  end
  return row
end

function telemetry.unpack(row, fields)
  fields = fields or telemetry.fields
  local s = {}
  for i, k in ipairs(fields) do s[k] = row[i] end
  s.jump = s.jump == 1 or s.jump == true
  return s
end

---------------------------------------------------------------------------------------------------
-- Recorder: keeps a short pre-buffer so recordings always include the START crossing.
---------------------------------------------------------------------------------------------------

local Recorder = {}
Recorder.__index = Recorder

function telemetry.newRecorder(preSeconds, maxSeconds)
  return setmetatable({ pre = {}, rows = nil, preSeconds = preSeconds or 3, maxSeconds = maxSeconds or 600 }, Recorder)
end

function Recorder:push(s) return self:pushRow(telemetry.pack(s)) end

-- Adds an already packed row (row[1] is the time).
function Recorder:pushRow(row)
  local t = row[1]
  if self.rows then
    self.rows[#self.rows + 1] = row
    if t - self.startT > self.maxSeconds then self.overflow = true end
  else
    local pre = self.pre
    pre[#pre + 1] = row
    local t0 = t - self.preSeconds
    local cut = 0
    for i = 1, #pre do if pre[i][1] < t0 then cut = i else break end end
    if cut > 0 then
      local n = #pre
      for i = 1, n - cut do pre[i] = pre[i + cut] end
      for i = n - cut + 1, n do pre[i] = nil end
    end
  end
end

function Recorder:start(t)
  self.rows = {}
  for i = 1, #self.pre do self.rows[i] = self.pre[i] end
  self.startT = t
  self.overflow = false
end

function Recorder:active() return self.rows ~= nil end

function Recorder:stop()
  local rows = self.rows
  self.rows = nil
  self.pre = {}
  return rows
end

function Recorder:cancel()
  self.rows = nil
end

return telemetry
