-- CHT Drift Judge – 2D geometry helpers (pure Lua, no CSP dependency)
-- All scoring geometry runs in the horizontal X/Z plane. Points are plain tables {x=, z=}.

local geom = {}

local sqrt, abs, min, max, floor = math.sqrt, math.abs, math.min, math.max, math.floor

geom.atan2 = math.atan2 or function(y, x) return math.atan(y, x) end

function geom.clamp(v, a, b)
  if v < a then return a elseif v > b then return b end
  return v
end

function geom.lerp(a, b, t) return a + (b - a) * t end

function geom.dist(ax, az, bx, bz)
  local dx, dz = bx - ax, bz - az
  return sqrt(dx * dx + dz * dz)
end

-- Does segment p1->p2 cross segment q1->q2? Returns the parameter t on p (0..1) or nil.
function geom.segmentIntersect(p1x, p1z, p2x, p2z, q1x, q1z, q2x, q2z)
  local rx, rz = p2x - p1x, p2z - p1z
  local sx, sz = q2x - q1x, q2z - q1z
  local den = rx * sz - rz * sx
  if abs(den) < 1e-12 then return nil end
  local qpx, qpz = q1x - p1x, q1z - p1z
  local t = (qpx * sz - qpz * sx) / den
  local u = (qpx * rz - qpz * rx) / den
  if t >= 0 and t <= 1 and u >= 0 and u <= 1 then return t, u end
  return nil
end

-- Which side of directed line a->b is point p on? >0 left, <0 right (with x right, z forward).
function geom.sideOf(ax, az, bx, bz, px, pz)
  return (bx - ax) * (pz - az) - (bz - az) * (px - ax)
end

-- Ray-casting point-in-polygon test. poly = { {x=,z=}, ... }
function geom.pointInPolygon(px, pz, poly)
  local inside = false
  local n = #poly
  if n < 3 then return false end
  local j = n
  for i = 1, n do
    local xi, zi = poly[i].x, poly[i].z
    local xj, zj = poly[j].x, poly[j].z
    if ((zi > pz) ~= (zj > pz)) and (px < (xj - xi) * (pz - zi) / (zj - zi + 1e-12) + xi) then
      inside = not inside
    end
    j = i
  end
  return inside
end

-- Polyline with cumulative lengths for fast projection.
-- pts = { {x=,z=}, ... } (at least 2 points)
function geom.polyline(pts)
  local pl = { pts = {}, cum = { 0 }, length = 0, segs = {} }
  for i = 1, #pts do pl.pts[i] = { x = pts[i].x, z = pts[i].z } end
  local total = 0
  for i = 1, #pl.pts - 1 do
    local a, b = pl.pts[i], pl.pts[i + 1]
    local dx, dz = b.x - a.x, b.z - a.z
    local len = sqrt(dx * dx + dz * dz)
    local inv = len > 1e-9 and 1 / len or 0
    -- left normal of the direction (dx, dz) is (-dz, dx)
    pl.segs[i] = { ax = a.x, az = a.z, dx = dx * inv, dz = dz * inv, len = len, nx = -dz * inv, nz = dx * inv }
    total = total + len
    pl.cum[i + 1] = total
  end
  pl.length = total
  return pl
end

-- Projects point onto polyline.
-- Returns s (arc length from start), signed lateral distance (positive on the left side of travel
-- direction), and `inside` = projection falls within the polyline span (not before start / after end).
function geom.project(pl, px, pz)
  local bestD2, bestS, bestLat, bestInside = math.huge, 0, 0, false
  local nseg = #pl.segs
  for i = 1, nseg do
    local sg = pl.segs[i]
    local vx, vz = px - sg.ax, pz - sg.az
    local t = vx * sg.dx + vz * sg.dz
    local inside = true
    if t < 0 then
      if i == 1 then inside = false end
      t = 0
    elseif t > sg.len then
      if i == nseg then inside = false end
      t = sg.len
    end
    local cx, cz = sg.ax + sg.dx * t, sg.az + sg.dz * t
    local ex, ez = px - cx, pz - cz
    local d2 = ex * ex + ez * ez
    if d2 < bestD2 then
      bestD2 = d2
      bestS = pl.cum[i] + t
      -- signed lateral distance relative to this segment's left normal
      local lat = ex * sg.nx + ez * sg.nz
      if abs(lat) < 1e-9 then lat = 0 end
      -- at a vertex the closest point may be off-normal; keep sign from normal, magnitude from true distance
      local d = sqrt(d2)
      bestLat = (lat >= 0) and d or -d
      bestInside = inside
    end
  end
  return bestS, bestLat, bestInside
end

-- Point along polyline at arc length s.
function geom.pointAt(pl, s)
  s = geom.clamp(s, 0, pl.length)
  for i = 1, #pl.segs do
    if s <= pl.cum[i + 1] or i == #pl.segs then
      local sg = pl.segs[i]
      local t = s - pl.cum[i]
      return sg.ax + sg.dx * t, sg.az + sg.dz * t, sg.nx, sg.nz
    end
  end
  return pl.pts[1].x, pl.pts[1].z, 0, 0
end

-- Offsets a polyline sideways (for drawing zone bands). side = +1 left, -1 right.
function geom.offsetPoints(pl, dist)
  local out = {}
  for i = 1, #pl.pts do
    local nx, nz
    if i == 1 then
      nx, nz = pl.segs[1].nx, pl.segs[1].nz
    elseif i == #pl.pts then
      nx, nz = pl.segs[#pl.segs].nx, pl.segs[#pl.segs].nz
    else
      local a, b = pl.segs[i - 1], pl.segs[i]
      nx, nz = a.nx + b.nx, a.nz + b.nz
      local l = sqrt(nx * nx + nz * nz)
      if l > 1e-6 then nx, nz = nx / l, nz / l else nx, nz = b.nx, b.nz end
    end
    out[i] = { x = pl.pts[i].x + nx * dist, z = pl.pts[i].z + nz * dist }
  end
  return out
end

-- Drift angle from local velocity (x sideways, z forward): 0..180 degrees and direction sign.
function geom.driftAngle(lvx, lvz)
  local a = geom.atan2(abs(lvx), lvz) * 57.29577951308232
  local dir = 0
  if lvx > 0 then dir = 1 elseif lvx < 0 then dir = -1 end
  return a, dir
end

function geom.round(v, digits)
  local m = 10 ^ (digits or 0)
  return floor(v * m + 0.5) / m
end

function geom.truncate1(v)
  -- FullSend-style display: truncate to tenths (not round)
  if v >= 0 then return floor(v * 10 + 1e-9) / 10 end
  return -floor(-v * 10 + 1e-9) / 10
end

return geom
