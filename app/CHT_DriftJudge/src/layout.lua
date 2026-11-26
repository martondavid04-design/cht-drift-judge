-- CHT Drift Judge – track layout model (gates + zones). Pure Lua.
-- A layout is stored as JSON. Coordinates are world coordinates of the track (meters).
--
-- layout = {
--   format = 'cht-drift-layout', version = 1,
--   track = 'track_id/layout', name = 'Comp layout',
--   gates = { start = {a={x,y,z}, b={x,y,z}}, judging = {...}, finish = {...} },
--   zones = { { id, name, type = 'OZ'|'IZ'|'WALL'|'TNG', maxPoints, side = 1|-1,
--               points = { {x,y,z}, ... },           -- reference line (outer line, inner line, wall, TnG line)
--               fullDist?, zeroDist?, angleTarget?, angleMin?, tiers? = {t1,t2,t3}, tngMode?,
--               nogo = { { {x,y,z}, ... }, ... } }, -- optional no-go polygons belonging to this zone
--             ... },
--   decelMap? = { path, segments },  -- accel / decel map for the tandem lead (src/decelmap.lua, 0.4.0)
-- }

local geom = require('src/geom')
local config = require('src/config')
local decelmap = require('src/decelmap')

local layout = {}

layout.zoneTypes = { 'OZ', 'IZ', 'WALL', 'TNG', 'IC', 'LIMIT' }
layout.zoneTypeNames = {
  OZ = 'Outer zone (hátsó lökhárító a külső vonalhoz)',
  IZ = 'Inner zone (első lökhárító a belső vonalhoz)',
  WALL = 'Falas zóna (hátulja a falhoz, minél hosszabban)',
  TNG = 'Touch and go (első kerék a vonalhoz)',
  IC = 'Belső érintési pont – IC (első lökhárító a ponthoz)',
  LIMIT = 'Pályahatár (kerék a vonalon túl = pályaelhagyás, nem pontoz)',
}
layout.zoneTypeShort = { OZ = 'OZ', IZ = 'IZ', WALL = 'FAL', TNG = 'TNG', IC = 'IC', LIMIT = 'HATÁR' }
layout.gateNames = { start = 'START', judging = 'JUDGING', finish = 'FINISH' }

-- An IC zone is a single point (more points = a short clip line); every other zone needs a line.
function layout.minPoints(z) return (z and z.type == 'IC') and 1 or 2 end
layout.gateOrder = { 'start', 'judging', 'finish' }

-- weighting: 'auto' = zone weights from length, curve and type (a zone can still have its own fixed
-- weight: zone.weightLock + zone.maxPoints); 'manual' = zone.maxPoints for every zone (older layouts).
function layout.new(trackID, name)
  return {
    format = 'cht-drift-layout', version = 1,
    track = trackID or '', name = name or 'Új pályaterv',
    gates = {}, zones = {}, weighting = 'auto',
  }
end

local function num(v, def)
  if type(v) == 'number' and v == v then return v end
  return def
end

local function point(p)
  if type(p) ~= 'table' then return nil end
  local x, z = num(p.x), num(p.z)
  if not x or not z then return nil end
  return { x = x, y = num(p.y, 0), z = z }
end

-- Cleans up a parsed JSON layout (drops broken items, fills defaults). Returns layout, warnings.
function layout.sanitize(l)
  local warnings = {}
  if type(l) ~= 'table' then return layout.new(), { 'Hibás pályaterv fájl.' } end
  local r = layout.new(l.track, type(l.name) == 'string' and l.name or nil)
  r.created, r.modified = l.created, l.modified
  -- older layouts have no weighting field: they keep their manual weights
  r.weighting = (l.weighting == 'auto') and 'auto' or 'manual'
  -- minimum tempo (km/h) of the layout: below it the run is flagged, and between the minimum and the
  -- full tempo it counts in Style / Commitment (nil = not set)
  local tmin, tfull = num(l.tempoMin), num(l.tempoFull)
  if tmin and tmin > 0 then
    r.tempoMin = math.min(300, tmin)
    if tfull and tfull > r.tempoMin then r.tempoFull = math.min(320, tfull) end
  end
  r.decelMap = decelmap.sanitize(l.decelMap)
  if type(l.gates) == 'table' then
    for _, key in ipairs(layout.gateOrder) do
      local g = l.gates[key]
      if type(g) == 'table' then
        local a, b = point(g.a), point(g.b)
        if a and b then r.gates[key] = { a = a, b = b } else warnings[#warnings + 1] = 'Hiányos kapu: ' .. key end
      end
    end
  end
  if type(l.zones) == 'table' then
    for i, z in ipairs(l.zones) do
      if type(z) == 'table' then
        local zone = {
          id = type(z.id) == 'string' and z.id or ('z' .. i),
          name = type(z.name) == 'string' and z.name or ('Z' .. i),
          type = (z.type == 'OZ' or z.type == 'IZ' or z.type == 'WALL' or z.type == 'TNG' or z.type == 'IC' or z.type == 'LIMIT') and z.type or 'OZ',
          maxPoints = num(z.maxPoints, 20),
          side = (z.side == -1) and -1 or 1,
          sideSet = z.sideSet == true,
          points = {},
          fullDist = num(z.fullDist), zeroDist = num(z.zeroDist),
          angleTarget = num(z.angleTarget), angleMin = num(z.angleMin),
          tngMode = (z.tngMode == 'linear' or z.tngMode == 'step') and z.tngMode or nil,
          nogo = {},
        }
        -- per-zone off-track: limit = this line is / is not a track limit (nil = by type), offTol = where
        -- off-track begins, metres beyond the line (nil = Beállítások → zone line tolerance; HATÁR: 0)
        if type(z.limit) == 'boolean' then zone.limit = z.limit end
        if z.weightLock == true then zone.weightLock = true end
        if type(z.offTol) == 'number' then zone.offTol = math.max(-1, math.min(4, z.offTol)) end
        -- issues the user approved ("Rendben, így jó"): kind -> signature of the zone when approved
        if type(z.ack) == 'table' then
          for k, v in pairs(z.ack) do
            if type(k) == 'string' and type(v) == 'string' then
              zone.ack = zone.ack or {}
              zone.ack[k] = v
            end
          end
        end
        if type(z.tiers) == 'table' then
          local t1, t2, t3 = num(z.tiers[1]), num(z.tiers[2]), num(z.tiers[3])
          if t1 and t2 and t3 then zone.tiers = { t1, t2, t3 } end
        end
        if type(z.points) == 'table' then
          for _, p in ipairs(z.points) do
            local pp = point(p)
            if pp then zone.points[#zone.points + 1] = pp end
          end
        end
        if type(z.nogo) == 'table' then
          for _, poly in ipairs(z.nogo) do
            if type(poly) == 'table' then
              local pts = {}
              for _, p in ipairs(poly) do
                local pp = point(p)
                if pp then pts[#pts + 1] = pp end
              end
              if #pts >= 3 then zone.nogo[#zone.nogo + 1] = pts end
            end
          end
        end
        if #zone.points < layout.minPoints(zone) then
          warnings[#warnings + 1] = zone.name .. (zone.type == 'IC' and ': nincs pontja, a zóna nem pontoz.' or ': kevesebb mint 2 pont, a zóna nem pontoz.')
        end
        r.zones[#r.zones + 1] = zone
      end
    end
  end
  return r, warnings
end

-- Geometry of a zone line used by the automatic weights: length (m) and how much it turns (degrees).
-- The line is first resampled every 0.5 m and smoothed over ±2 m, so the zig-zag of hand-placed or
-- traced points (e.g. the trace jumping between the car's two corners) neither adds length nor turn.
-- The turn is the spread of the heading along the smoothed line: a corner of 90° gives about 90°.
function layout.zoneShape(z)
  local pts = z.points or {}
  if #pts < 2 then return 0, 0 end
  local pl = geom.polyline(pts)
  local raw = pl.length
  if raw < 1e-3 then return 0, 0 end
  local n = math.max(2, math.floor(raw / 0.5) + 1)
  local xs, zs = {}, {}
  for i = 1, n do xs[i], zs[i] = geom.pointAt(pl, raw * (i - 1) / (n - 1)) end
  local w = 4
  local sx, sz = {}, {}
  for i = 1, n do
    local ax, az, c = 0, 0, 0
    for j = math.max(1, i - w), math.min(n, i + w) do ax, az, c = ax + xs[j], az + zs[j], c + 1 end
    sx[i], sz[i] = ax / c, az / c
  end
  -- the ends keep their real position (the average would pull them inwards)
  sx[1], sz[1], sx[n], sz[n] = xs[1], zs[1], xs[n], zs[n]
  local len = 0
  for i = 2, n do len = len + geom.dist(sx[i - 1], sz[i - 1], sx[i], sz[i]) end
  local stepIdx = 4 -- 2 m
  local prev, cum, lo, hi = nil, 0, 0, 0
  local i = 1
  while i < n do
    local j = math.min(n, i + stepIdx)
    local dx, dz = sx[j] - sx[i], sz[j] - sz[i]
    if dx * dx + dz * dz > 0.25 then
      local hdg = math.deg(math.atan2(dx, dz))
      if prev then
        local d = (hdg - prev + 540) % 360 - 180
        -- a reversal is a drawing error, not a corner; a real corner turns < 45° per 2 m
        if math.abs(d) > 120 then d = 0 end
        d = math.max(-45, math.min(45, d))
        cum = cum + d
        if cum < lo then lo = cum end
        if cum > hi then hi = cum end
      end
      prev = hdg
    end
    i = j
  end
  return len, math.min(180, hi - lo)
end

-- Number of places where the line turns back (> 120° between neighbouring segments longer than 0.3 m).
function layout.reversals(points)
  local cnt, prev = 0, nil
  for k = 1, #points - 1 do
    local a, b = points[k], points[k + 1]
    local dx, dz = b.x - a.x, b.z - a.z
    if dx * dx + dz * dz > 0.09 then
      local hdg = math.deg(math.atan2(dx, dz))
      if prev then
        local d = math.abs((hdg - prev + 540) % 360 - 180)
        if d > 120 then cnt = cnt + 1 end
      end
      prev = hdg
    end
  end
  return cnt
end

local typeKey = { OZ = 'autoTypeOZ', IZ = 'autoTypeIZ', WALL = 'autoTypeWALL', TNG = 'autoTypeTNG', IC = 'autoTypeIC' }

-- Automatic weight of a zone and its parts (for the explanation in the editor).
function layout.autoWeight(z, cfg)
  cfg = cfg or config.defaults
  local len, turn = layout.zoneShape(z)
  local lenUsed = math.max(len, cfg.autoMinLength or 4)
  local lenPart = lenUsed ^ (cfg.autoLengthExp or 0.5)
  local curvePart = 1 + (cfg.autoCurveFactor or 0) * math.min(turn, 180) / 90
  local typePart = cfg[typeKey[z.type] or ''] or 1
  local w = lenPart * curvePart * typePart
  return w, { length = len, lengthUsed = lenUsed, turn = turn, lenPart = lenPart, curvePart = curvePart, typePart = typePart }
end

function layout.isAutoWeighted(l, z)
  return l.weighting == 'auto' and not z.weightLock and z.type ~= 'LIMIT'
end

-- Weight of a zone as the scoring uses it.
function layout.zoneWeight(l, z, cfg)
  if z.type == 'LIMIT' then return 0 end
  if layout.isAutoWeighted(l, z) then
    if #(z.points or {}) < layout.minPoints(z) then return 0 end
    return (layout.autoWeight(z, cfg))
  end
  return z.maxPoints or 0
end

-- Points a zone is worth out of 100 after normalisation (its weight / sum of weights × 100).
-- Points of the zones out of 100: with the style weight (DM: 0.2) the zones share 80.
function layout.zonePoints(cfg)
  local sw = math.max(0, math.min(0.9, (cfg and cfg.styleWeight) or 0))
  return 100 * (1 - sw)
end

function layout.effectivePoints(l, zone, cfg)
  local total = layout.totalMaxPoints(l, cfg)
  if total <= 0 then return 0 end
  return layout.zoneWeight(l, zone, cfg) / total * layout.zonePoints(cfg)
end

function layout.isScoring(z) return z.type ~= 'LIMIT' end

function layout.totalMaxPoints(l, cfg)
  local s = 0
  for _, z in ipairs(l.zones) do if z.type ~= 'LIMIT' then s = s + layout.zoneWeight(l, z, cfg) end end
  return s
end

-- Switching to manual weights: every automatic zone keeps its current share (points out of 100,
-- rounded), so the scores do not jump; from then on they can be changed one by one.
function layout.freezeAutoWeights(l, cfg)
  local total = layout.totalMaxPoints(l, cfg)
  for _, z in ipairs(l.zones) do
    if layout.isAutoWeighted(l, z) then
      z.maxPoints = total > 0 and math.floor(layout.zoneWeight(l, z, cfg) / total * 100 + 0.5) or (z.maxPoints or 20)
    end
  end
end

-- Problems that stop a layout from being judged (shown in the editor).
-- Structured layout check for the UI. Returns a list of
--   { level = 'error'|'warn', kind, text, fix, zone = layout zone index (optional), gate = key (optional) }
-- error = the layout cannot be judged correctly until fixed; warn = it works, but the result may be off.
function layout.validateDetailed(l)
  local issues = {}
  local function add(level, kind, text, fix, extra)
    local it = { level = level, kind = kind, text = text, fix = fix }
    if extra then for k, v in pairs(extra) do it[k] = v end end
    issues[#issues + 1] = it
  end
  if not l.gates.judging then
    add('error', 'gate', 'Nincs JUDGING vonal.', 'Pálya fül → 2. Kapuk → JUDGING: „Az autó helyére” vagy „Egérrel”.', { gate = 'judging' })
  end
  if not l.gates.finish then
    add('error', 'gate', 'Nincs FINISH vonal.', 'Pálya fül → 2. Kapuk → FINISH: „Az autó helyére” vagy „Egérrel”.', { gate = 'finish' })
  end
  local valid = 0
  for i, z in ipairs(l.zones) do
    local n = #z.points
    local need = layout.minPoints(z)
    if z.type ~= 'LIMIT' and n >= need then valid = valid + 1 end
    if n < need then
      if z.type == 'IC' then
        add('warn', 'noLine', z.name .. ': még nincs pontja – így nem számít.',
          'Jelöld ki a zónát, és tedd le az érintési pontot (kattintással, az autóhoz vagy a festésből).', { zone = i })
      else
        add('warn', 'noLine', z.name .. ': még nincs vonala (legalább 2 pont kell) – így nem számít.',
          'Jelöld ki a zónát, és adj hozzá pontokat (kattintással, az autóhoz vagy nyomkövetéssel).', { zone = i })
      end
    elseif n == 2 and z.type ~= 'TNG' and z.type ~= 'IC' then
      local a, b = z.points[1], z.points[2]
      if geom.dist(a.x, a.z, b.x, b.z) > 6 then
        add('warn', 'twoPoints', z.name .. ': csak 2 pont egy hosszú szakaszon.',
          'Ha a vonal ÍVES, adj hozzá pontokat 2–3 méterenként (pl. nyomkövetéssel). Ha a vonal EGYENES, ez rendben van – nyomd meg a „Rendben, így jó” gombot.', { zone = i })
      end
    end
    if n >= 3 and z.type ~= 'IC' then
      local rev = layout.reversals(z.points)
      if rev > 0 then
        add('warn', 'zigzag', string.format('%s: a vonal %d helyen visszafordul / cikcakkos (oda-vissza ugráló pontok).', z.name, rev),
          'Ez általában hibás nyomkövetés (a pontok a két autósarok között ugráltak). Torzítja a pontozást, a pályaelhagyást és a súlyt is: rajzold újra (pl. „Pontok törlése és újrarajzolás”).', { zone = i })
      end
    end
    if z.type ~= 'LIMIT' and n >= need and not layout.isAutoWeighted(l, z) and (z.maxPoints or 0) <= 0 then
      add('warn', 'zeroWeight', z.name .. ': a súlya 0, ezért nem ér pontot.', 'Állíts be súlyt a zóna Alapadatainál.', { zone = i })
    end
  end
  if valid == 0 then
    add('error', 'noZone', 'Nincs pontozható zóna (legalább 2 pont kell, IC-nél 1).', 'Pálya fül → 3. Zónák: adj hozzá egy OZ / IZ / FAL / TNG / IC zónát, és rajzold meg a vonalát (IC: a pontját).')
  end
  local total = layout.totalMaxPoints(l)
  if valid > 0 and total <= 0 then
    add('error', 'allZero', 'Minden zóna súlya 0 – így egyik sem ér pontot.', 'Adj súlyt legalább egy zónának.')
  end
  return issues
end

-- Simple list of issue texts (kept for older callers).
function layout.validate(l)
  local r = {}
  for _, it in ipairs(layout.validateDetailed(l)) do r[#r + 1] = it.text end
  return r
end

-- Builds runtime geometry for scoring.
function layout.compile(l, cfg)
  local c = { gates = {}, zones = {}, limits = {} }
  if l.tempoMin then c.tempo = { min = l.tempoMin, full = l.tempoFull } end
  c.decel = decelmap.compile(l.decelMap)
  for key, g in pairs(l.gates) do
    c.gates[key] = { ax = g.a.x, az = g.a.z, bx = g.b.x, bz = g.b.z }
  end
  for i, z in ipairs(l.zones) do
    if z.type == 'LIMIT' and #z.points >= 2 then
      local pl = geom.polyline(z.points)
      if pl.length > 0.5 then
        local x0, z0, x1, z1 = math.huge, math.huge, -math.huge, -math.huge
        for _, p in ipairs(pl.pts) do x0, z0, x1, z1 = math.min(x0, p.x), math.min(z0, p.z), math.max(x1, p.x), math.max(z1, p.z) end
        c.limits[#c.limits + 1] = { index = i, def = z, pl = pl, side = z.side or 1, bx0 = x0 - 8, bz0 = z0 - 8, bx1 = x1 + 8, bz1 = z1 + 8 }
      end
    elseif z.type == 'IC' and #z.points >= 1 then
      -- inner clipping point (or a short clip line): the front bumper's closest approach counts
      local pl = geom.polyline(z.points)
      local full, zero = z.fullDist or cfg.icFullDist, z.zeroDist or cfg.icZeroDist
      if zero <= full then zero = full + 0.01 end
      c.zones[#c.zones + 1] = {
        index = i, def = z, pl = pl, length = pl.length, nb = 1, binSize = math.max(pl.length, 0.01),
        weight = layout.zoneWeight(l, z, cfg), type = 'IC', side = z.side or 1,
        fullDist = full, zeroDist = zero, capture = zero + cfg.captureMargin,
        angleTarget = z.angleTarget or cfg.angleTarget, angleMin = z.angleMin or cfg.angleMin,
        tiers = { full, (full + zero) / 2, zero }, tngMode = 'linear', nogo = {},
      }
    elseif #z.points >= 2 then
      local pl = geom.polyline(z.points)
      if pl.length > 0.5 then
        local full, zero
        if z.type == 'OZ' then full, zero = cfg.ozFullDist, cfg.ozZeroDist
        elseif z.type == 'IZ' then full, zero = cfg.izFullDist, cfg.izZeroDist
        elseif z.type == 'WALL' then full, zero = cfg.wallFullDist, cfg.wallZeroDist
        else full, zero = cfg.tngTier1, cfg.tngTier3 end
        if z.fullDist then full = z.fullDist end
        if z.zeroDist then zero = z.zeroDist end
        local tiers = z.tiers or { cfg.tngTier1, cfg.tngTier2, cfg.tngTier3 }
        if z.type == 'TNG' then full, zero = tiers[1], tiers[3] end
        if zero <= full then zero = full + 0.01 end
        local binSize = math.max(0.05, cfg.binSize)
        local nb = math.max(1, math.ceil(pl.length / binSize))
        local polys = {}
        for _, poly in ipairs(z.nogo or {}) do polys[#polys + 1] = poly end
        c.zones[#c.zones + 1] = {
          index = i, def = z, pl = pl, length = pl.length, nb = nb, binSize = pl.length / nb,
          weight = layout.zoneWeight(l, z, cfg),
          type = z.type, side = z.side or 1,
          fullDist = full, zeroDist = zero, capture = zero + cfg.captureMargin,
          angleTarget = z.angleTarget or cfg.angleTarget, angleMin = z.angleMin or cfg.angleMin,
          tiers = tiers, tngMode = z.tngMode or cfg.tngMode,
          nogo = polys,
        }
      end
    end
  end
  return c
end

-- Stable short hash of a layout (to link recordings with the layout version they were judged with).
function layout.hash(l, jsonText)
  local s = jsonText or ''
  local h = 5381
  for i = 1, #s do h = (h * 33 + s:byte(i)) % 4294967296 end
  return string.format('%08x', h)
end

return layout
