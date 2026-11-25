-- CHT Drift Judge – geometry edits on a zone line after it has been placed: lengthen / shorten either
-- end, shift sideways, move / insert / delete points. Pure Lua (testable offline).
-- `snap(x, y, z)` (optional) puts a point back onto the track surface and returns {x,y,z}.

local geom = require('src/geom')

local E = {}

local sqrt = math.sqrt

local function copy(p) return { x = p.x, y = p.y or 0, z = p.z } end
local function place(snap, x, y, z)
  if snap then return snap(x, y, z) end
  return { x = x, y = y, z = z }
end

function E.length(points)
  if #points < 2 then return 0 end
  return geom.polyline(points).length
end

-- Moves the end of the line by d metres: d > 0 lengthens (along the last segment), d < 0 shortens.
-- Never shortens below 0.5 m. Returns true if something changed.
function E.extendEnd(points, d, snap)
  local n = #points
  if n < 2 or d == 0 then return false end
  if d > 0 then
    local a, b = points[n - 1], points[n]
    local dx, dz = b.x - a.x, b.z - a.z
    local l = sqrt(dx * dx + dz * dz)
    if l < 1e-6 then return false end
    points[n] = place(snap, b.x + dx / l * d, b.y or 0, b.z + dz / l * d)
    return true
  end
  local rem = -d
  if E.length(points) - rem < 0.5 then return false end
  while rem > 1e-6 and #points >= 2 do
    n = #points
    local a, b = points[n - 1], points[n]
    local dx, dz = b.x - a.x, b.z - a.z
    local l = sqrt(dx * dx + dz * dz)
    if l > rem + 0.05 or n == 2 then
      local t = (l - rem) / l
      points[n] = place(snap, a.x + dx * t, geom.lerp(a.y or 0, b.y or 0, t), a.z + dz * t)
      rem = 0
    else
      table.remove(points, n)
      rem = rem - l
    end
  end
  return true
end

local function reverse(points)
  local r = {}
  for i = #points, 1, -1 do r[#r + 1] = points[i] end
  for i = 1, #r do points[i] = r[i] end
end

function E.extendStart(points, d, snap)
  reverse(points)
  local ok = E.extendEnd(points, d, snap)
  reverse(points)
  return ok
end

-- Shifts the whole line sideways by `dist` metres; positive = to the left of the travel direction.
function E.offset(points, dist, snap)
  if #points < 2 or dist == 0 then return false end
  local pl = geom.polyline(points)
  local out = geom.offsetPoints(pl, dist)
  for i = 1, #points do
    points[i] = place(snap, out[i].x, points[i].y or 0, out[i].z)
  end
  return true
end

-- Index of the point nearest to (x, z) within maxDist (or nil).
function E.nearestPoint(points, x, z, maxDist)
  local best, bestD = nil, maxDist or math.huge
  for i, p in ipairs(points) do
    local d = geom.dist(p.x, p.z, x, z)
    if d < bestD then best, bestD = i, d end
  end
  return best, bestD
end

-- Index at which a new point (x, z) should be inserted so the line stays in order.
function E.insertIndex(points, x, z)
  local n = #points
  if n < 2 then return n + 1 end
  local pl = geom.polyline(points)
  local s, _, inside = geom.project(pl, x, z)
  if not inside then
    if s <= 1e-6 then return 1 end
    return n + 1
  end
  for i = 1, n - 1 do
    if s <= pl.cum[i + 1] then return i + 1 end
  end
  return n
end

function E.insertPoint(points, p)
  local i = E.insertIndex(points, p.x, p.z)
  table.insert(points, i, copy(p))
  return i
end

return E
