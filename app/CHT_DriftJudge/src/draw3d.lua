-- CHT Drift Judge – 3D drawing of gates, zones and no-go areas on the track (CSP only).

local geom = require('src/geom')
local colors = require('src/colors')

local draw3d = {}

draw3d.zoneColors = {
  OZ = rgbm(1.6, 0.5, 3.0, 1),
  IZ = rgbm(0.4, 1.2, 3.0, 1),
  WALL = rgbm(3.0, 1.2, 0.2, 1),
  TNG = rgbm(3.0, 2.6, 0.3, 1),
  IC = rgbm(0.3, 2.8, 2.8, 1),
  LIMIT = rgbm(3.0, 0.25, 0.25, 1),
}
draw3d.gateColors = {
  start = rgbm(0.3, 3.0, 0.5, 1),
  judging = rgbm(3, 3, 3, 1),
  finish = rgbm(3.0, 0.4, 0.4, 1),
}
local colNogo = rgbm(3.0, 0.15, 0.15, 1)
local colDim = rgbm(1, 1, 1, 0.35)
local colSel = rgbm(4, 4, 4, 1)
local colGood = rgbm(0.2, 3.0, 0.4, 1)
local colBad = rgbm(3.0, 0.3, 0.2, 1)

local lift = 0.06
local v1, v2 = vec3(), vec3()
local v3, vUp = vec3(), vec3(0, 1, 0)
local callable = require('src/fn').callable

-- Editor point markers (0.3.14, client request: bigger, higher contrast). Not the zone colour: white /
-- green (first) / purple (last) on a black ring stands out on every zone colour and on the asphalt.
draw3d.pointColors = {
  mid = rgbm(4, 4, 4, 1),
  first = rgbm(0.2, 4, 0.5, 1),
  last = rgbm(3.6, 0.3, 4, 1),
  hot = rgbm(4, 3.4, 0, 1),     -- the point under the mouse / picked for moving
  del = rgbm(4, 0.2, 0.2, 1),
  ring = rgbm(0, 0, 0, 1),
}
draw3d.pointScale = 1
local pointLabelCol = rgbm(4, 4, 4, 1)

local function drawDisc(x, y, z, r, col)
  v3:set(x, y, z)
  if callable(render.circle) then
    local ok = pcall(render.circle, v3, vUp, r, col)
    if ok then return end
  end
  render.debugPoint(v3, r * 1.6, col)
end

-- kind: 'mid' | 'first' | 'last' | 'hot' | 'del' (or an rgbm); label: number / text above the pole
function draw3d.pointMarker(p, kind, label, scale)
  local k = (scale or draw3d.pointScale or 1)
  local col = type(kind) == 'string' and (draw3d.pointColors[kind] or draw3d.pointColors.mid) or (kind or draw3d.pointColors.mid)
  local x, y, z = p.x, (p.y or 0), p.z
  local r = 0.42 * k
  -- black ring, then the coloured disc on it
  drawDisc(x, y + lift + 0.01, z, r * 1.35, draw3d.pointColors.ring)
  drawDisc(x, y + lift + 0.02, z, r, col)
  -- pole with a point on top: visible from the far side of the track as well
  local top = y + 1.1 * k
  v1:set(x, y + lift, z)
  v2:set(x, top, z)
  render.debugLine(v1, v2, col, col)
  render.debugPoint(v2, 0.45 * k, col)
  if label then
    v2:set(x, top + 0.35 * k, z)
    render.debugText(v2, tostring(label), pointLabelCol, 0.9 * math.max(1, k))
  end
end

-- Markers for every point of a zone line: first / last coloured, number above each (selected zone).
function draw3d.zonePoints(pts, numbered)
  local n = #pts
  for k = 1, n do
    local kind = (n > 1 and k == 1) and 'first' or ((n > 1 and k == n) and 'last' or 'mid')
    draw3d.pointMarker(pts[k], kind, numbered and tostring(k) or nil)
  end
end

local function yAt(points, pl, s)
  -- interpolate height along the reference polyline
  local n = #points
  if n == 0 then return 0 end
  if n == 1 then return points[1].y or 0 end
  for i = 1, n - 1 do
    if s <= pl.cum[i + 1] or i == n - 1 then
      local len = pl.cum[i + 1] - pl.cum[i]
      local t = len > 1e-6 and geom.clamp((s - pl.cum[i]) / len, 0, 1) or 0
      return geom.lerp(points[i].y or 0, points[i + 1].y or 0, t)
    end
  end
  return points[n].y or 0
end
draw3d.yAt = yAt

local function line(ax, ay, az, bx, by, bz, c1, c2)
  v1:set(ax, ay + lift, az)
  v2:set(bx, by + lift, bz)
  render.debugLine(v1, v2, c1, c2)
end

-- red → green palette, cached (avoids creating colour objects every frame)
local palette = {}
for i = 0, 20 do
  local t = i / 20
  palette[i] = rgbm(geom.lerp(colBad.r, colGood.r, t), geom.lerp(colBad.g, colGood.g, t), geom.lerp(colBad.b, colGood.b, t), 1)
end
local colMissed = rgbm(0.6, 0.1, 0.1, 0.8)
local function mixColor(t)
  return palette[math.floor(geom.clamp(t, 0, 1) * 20 + 0.5)]
end

local function drawGate(key, g, selected, showLabel)
  local c = draw3d.gateColors[key] or colSel
  if selected then c = colSel end
  line(g.a.x, g.a.y, g.a.z, g.b.x, g.b.y, g.b.z, c)
  -- small posts
  line(g.a.x, g.a.y, g.a.z, g.a.x, g.a.y + 1.2, g.a.z, c)
  line(g.b.x, g.b.y, g.b.z, g.b.x, g.b.y + 1.2, g.b.z, c)
  v1:set((g.a.x + g.b.x) / 2, (g.a.y + g.b.y) / 2 + 1.5, (g.a.z + g.b.z) / 2)
  if showLabel ~= false then render.debugText(v1, ({ start = 'START', judging = 'JUDGING', finish = 'FINISH' })[key] or key, c, 1.2) end
end


-- Translucent fills ---------------------------------------------------------------------------------
-- For each zone: the whole zone band (line → 0% distance) and the full-score band (line → 100%
-- distance) on the track side, and a red strip beyond the line where a wheel already counts as off
-- track. Geometry is cached per zone and rebuilt only when the zone or the settings change.

local fillCache = setmetatable({}, { __mode = 'k' })

local function surfaceY(x, y, z)
  local hit = vec3()
  local d = physics.raycastTrack(vec3(x, y + 2, z), vec3(0, -1, 0), 6, hit)
  if d >= 0 then return hit.y end
  return y
end

local function stationsOf(pl)
  local list, seen = {}, {}
  local function add(v)
    local k = math.floor(v * 100 + 0.5)
    if not seen[k] then seen[k] = true; list[#list + 1] = v end
  end
  local step = 2.0
  local d = 0
  while d < pl.length do add(d); d = d + step end
  for i = 1, #pl.cum do add(pl.cum[i]) end
  add(pl.length)
  table.sort(list)
  return list
end

-- smoothed left normal at arc length s
local function normalAt(pl, s)
  local _, _, n1x, n1z = geom.pointAt(pl, math.max(0, s - 0.3))
  local _, _, n2x, n2z = geom.pointAt(pl, math.min(pl.length, s + 0.3))
  local nx, nz = n1x + n2x, n1z + n2z
  local l = math.sqrt(nx * nx + nz * nz)
  if l < 1e-6 then return n2x, n2z end
  return nx / l, nz / l
end

-- offsets: list of signed lateral distances (+ = left of travel direction)
local function buildRows(cz, pts, offsets)
  local pl = cz.pl
  local rows = {}
  for _, st in ipairs(stationsOf(pl)) do
    local x, z = geom.pointAt(pl, st)
    local nx, nz = normalAt(pl, st)
    local y0 = yAt(pts, pl, st)
    local row = {}
    for k, d in ipairs(offsets) do
      local px, pz = x + nx * d, z + nz * d
      row[k] = vec3(px, surfaceY(px, y0, pz) + 0.045, pz)
    end
    rows[#rows + 1] = row
  end
  return rows
end

local function fillKey(z, cz, o)
  local p1, pn = z.points[1], z.points[#z.points]
  return table.concat({ #z.points, p1 and p1.x or 0, p1 and p1.z or 0, pn and pn.x or 0, pn and pn.z or 0,
    cz.length or 0, cz.side or 1, cz.fullDist or 0, cz.zeroDist or 0, cz.tiers and table.concat(cz.tiers, '/') or '',
    o.offTol or 0, o.off and 1 or 0 }, '|')
end

-- Returns cached { rows, bands = { { a, b, colorKey, strength } } }.
local function fillGeometry(z, cz, o)
  local key = fillKey(z, cz, o)
  local c = fillCache[z]
  if c and c.key == key then return c end
  local sd = cz.side or 1
  local offsets, bands = {}, {}
  local function idx(d)
    for k, v in ipairs(offsets) do if math.abs(v - d) < 1e-4 then return k end end
    offsets[#offsets + 1] = d
    return #offsets
  end
  if cz.type == 'TNG' then
    local t = cz.tiers or { 0.3, 0.8, 1.5 }
    bands[#bands + 1] = { idx(0), idx(t[1] * sd), 'TNG', 1.0 }
    bands[#bands + 1] = { idx(t[1] * sd), idx(t[2] * sd), 'TNG', 0.6 }
    bands[#bands + 1] = { idx(t[2] * sd), idx(t[3] * sd), 'TNG', 0.35 }
  elseif cz.type ~= 'LIMIT' then
    local full, zero = cz.fullDist or 0, cz.zeroDist or 0
    if full > 0.02 then bands[#bands + 1] = { idx(0), idx(full * sd), cz.type, 1.0 } end
    bands[#bands + 1] = { idx(full * sd), idx(zero * sd), cz.type, 0.45 }
  end
  if o.off then
    local tol = o.offTol or 0
    bands[#bands + 1] = { idx(-tol * sd), idx(-(tol + 1.5) * sd), 'OFF', 1.0 }
    bands[#bands + 1] = { idx(-(tol + 1.5) * sd), idx(-(tol + 4) * sd), 'OFF', 0.4 }
  end
  c = { key = key, rows = buildRows(cz, z.points, offsets), bands = bands }
  fillCache[z] = c
  return c
end

-- IMPORTANT: AC's immediate-mode renderer (render.glBegin … render.glEnd) holds at most 36 vertices
-- per batch; more than that overwrites memory and crashes the game ("GLRenderer::vertex3f
-- currentIndex > 36" in log.txt). Quads are therefore sent in small batches: 4 quads = 16 vertices
-- (still under the limit even if the renderer turns every quad into 6 triangle indices).
draw3d.glMaxQuadsPerBatch = 4

local fillColor = rgbm()
local function drawFills(geo, settings, alpha)
  render.setBlendMode(render.BlendMode.AlphaBlend)
  render.setCullMode(render.CullMode.None)
  local rows = geo.rows
  local perBatch = draw3d.glMaxQuadsPerBatch
  for _, b in ipairs(geo.bands) do
    local col = colors.get(settings, b[3])
    fillColor.r, fillColor.g, fillColor.b = col[1] * 1.6, col[2] * 1.6, col[3] * 1.6
    fillColor.mult = geom.clamp(alpha * b[4], 0, 1)
    local i = 1
    local n = #rows - 1
    while i <= n do
      local last = math.min(n, i + perBatch - 1)
      render.glSetColor(fillColor)
      render.glBegin(render.GLPrimitiveType.Quads)
      for k = i, last do
        local r1, r2 = rows[k], rows[k + 1]
        render.glVertex(r1[b[1]]); render.glVertex(r2[b[1]]); render.glVertex(r2[b[2]]); render.glVertex(r1[b[2]])
      end
      render.glEnd()
      i = last + 1
    end
  end
  render.setCullMode(render.CullMode.Back)
end

-- IC (inner clipping point): filled discs on the track (full-score radius strong, zero radius light),
-- a short post, rings and a cross. Geometry cached like the band fills.
local icCache = setmetatable({}, { __mode = 'k' })
local function icGeometry(z, cz)
  local p = z.points[1]
  local key = table.concat({ #z.points, p.x, p.z, cz.fullDist, cz.zeroDist }, '|')
  local c = icCache[z]
  if c and c.key == key then return c end
  local N = 24
  local radii = { 0, cz.fullDist, cz.zeroDist }
  local rings = {}
  for ri, r in ipairs(radii) do
    local ring = {}
    for k = 0, N do
      local a = k / N * 2 * math.pi
      local x, zz = p.x + math.cos(a) * r, p.z + math.sin(a) * r
      ring[k] = vec3(x, surfaceY(x, p.y or 0, zz) + 0.05, zz)
    end
    rings[ri] = ring
  end
  c = { key = key, rings = rings, N = N }
  icCache[z] = c
  return c
end

local icFill = rgbm()
local function drawICFill(geo, settings, alpha)
  local col = colors.get(settings, 'IC')
  render.setBlendMode(render.BlendMode.AlphaBlend)
  render.setCullMode(render.CullMode.None)
  local perBatch = draw3d.glMaxQuadsPerBatch
  for ri = 1, 2 do
    icFill.r, icFill.g, icFill.b = col[1] * 1.6, col[2] * 1.6, col[3] * 1.6
    icFill.mult = geom.clamp(alpha * (ri == 1 and 1.0 or 0.45), 0, 1)
    local inner, outer = geo.rings[ri], geo.rings[ri + 1]
    local k = 0
    while k < geo.N do
      local last = math.min(geo.N - 1, k + perBatch - 1)
      render.glSetColor(icFill)
      render.glBegin(render.GLPrimitiveType.Quads)
      for j = k, last do
        render.glVertex(inner[j]); render.glVertex(inner[j + 1]); render.glVertex(outer[j + 1]); render.glVertex(outer[j])
      end
      render.glEnd()
      k = last + 1
    end
  end
  render.setCullMode(render.CullMode.Back)
end

local function drawICLines(z, cz, c, sel, showRings)
  local pts = z.points
  local p = pts[1]
  local y = p.y or 0
  line(p.x, y, p.z, p.x, y + 1.0, p.z, c)
  line(p.x - 0.35, y, p.z, p.x + 0.35, y, p.z, c)
  line(p.x, y, p.z - 0.35, p.x, y, p.z + 0.35, c)
  for k = 1, #pts - 1 do line(pts[k].x, pts[k].y, pts[k].z, pts[k + 1].x, pts[k + 1].y, pts[k + 1].z, c) end
  if showRings and cz then
    local N = 24
    for _, r in ipairs({ cz.fullDist, cz.zeroDist }) do
      for k = 0, N - 1 do
        local a0, a1 = k / N * 2 * math.pi, (k + 1) / N * 2 * math.pi
        line(p.x + math.cos(a0) * r, y, p.z + math.sin(a0) * r, p.x + math.cos(a1) * r, y, p.z + math.sin(a1) * r,
          r == cz.fullDist and rgbm(c.r * 0.6, c.g * 0.6, c.b * 0.6, 0.8) or colDim)
      end
    end
  end
  if sel then
    draw3d.pointMarker({ x = p.x, y = y, z = p.z }, 'mid', 'IC')
  end
end

-- Is a zone line also a track limit with the current settings? (zone.limit overrides the type setting)
function draw3d.isLimitLine(ztype, cfg, zone)
  if ztype == 'IC' then return false end
  if zone and zone.limit ~= nil and ztype ~= 'LIMIT' and ztype ~= 'WALL' then return zone.limit == true end
  if not cfg then return ztype == 'LIMIT' end
  if ztype == 'LIMIT' then return cfg.offTrackLimits ~= false end
  if cfg.offTrackZones == false then return false end
  if ztype == 'OZ' then return cfg.limitOZ ~= false end
  if ztype == 'IZ' then return cfg.limitIZ ~= false end
  if ztype == 'TNG' then return cfg.limitTNG == true end
  return false
end

-- opts: { selectedZone, selectedGate, bins = {zoneIndex = binsArray}, showBands, labels, gates, zoneLines,
--         settings (colours), cfg, fill (zone fill), fillOff (off-track strip), fillAlpha }
function draw3d.drawLayout(l, compiled, opts)
  opts = opts or {}
  draw3d.pointScale = tonumber(opts.pointSize) or 1
  if opts.depthOff then render.setDepthMode(render.DepthMode.Off) else render.setDepthMode(render.DepthMode.ReadOnlyLessEqual) end

  for _, key in ipairs({ 'start', 'judging', 'finish' }) do
    local g = l.gates[key]
    if g and (opts.gates ~= false or opts.selectedGate == key) then drawGate(key, g, opts.selectedGate == key, opts.labels ~= false) end
  end

  local byIndex = {}
  if compiled then
    for _, cz in ipairs(compiled.zones) do byIndex[cz.index] = cz end
    for _, lim in ipairs(compiled.limits or {}) do byIndex[lim.index] = { type = 'LIMIT', pl = lim.pl, side = lim.side, length = lim.pl.length } end
  end

  -- translucent fills first (lines and labels are drawn over them)
  if opts.fill ~= false or opts.fillOff ~= false then
    local alpha = type(opts.fillAlpha) == 'number' and opts.fillAlpha or 0.25
    for i, z in ipairs(l.zones) do
      local cz = byIndex[i]
      if cz and z.type == 'IC' and #z.points >= 1 then
        if opts.fill ~= false then drawICFill(icGeometry(z, cz), opts.settings, alpha * (opts.selectedZone == i and 1.4 or 1)) end
      elseif cz and #z.points >= 2 then
        local off = opts.fillOff ~= false and draw3d.isLimitLine(z.type, opts.cfg, z)
        if opts.fill ~= false or off then
          local tol = tonumber(z.offTol) or (z.type == 'LIMIT' and 0 or (opts.cfg and opts.cfg.zoneLimitTolerance or 0.15))
          local o = { off = off, offTol = tol }
          local geo = fillGeometry(z, cz, o)
          if opts.fill == false then
            local only = {}
            for _, b in ipairs(geo.bands) do if b[3] == 'OFF' then only[#only + 1] = b end end
            geo = { rows = geo.rows, bands = only }
          end
          drawFills(geo, opts.settings, alpha * (opts.selectedZone == i and 1.4 or 1))
        end
      end
    end
    if opts.depthOff then render.setDepthMode(render.DepthMode.Off) else render.setDepthMode(render.DepthMode.ReadOnlyLessEqual) end
  end

  for i, z in ipairs(l.zones) do
    local sel = opts.selectedZone == i
    local zc = colors.get(opts.settings, z.type)
    local c = sel and colSel or rgbm(zc[1] * 3, zc[2] * 3, zc[3] * 3, 1)
    local pts = z.points
    local drawLines = opts.zoneLines ~= false or sel
    if z.type == 'IC' then
      if drawLines and #pts >= 1 then drawICLines(z, byIndex[i], c, sel, opts.showBands ~= false) end
      if opts.labels ~= false and #pts >= 1 then
        local cz = byIndex[i]
        local tw = 0
        if compiled then for _, c2 in ipairs(compiled.zones) do tw = tw + (c2.weight or 0) end end
        v1:set(pts[1].x, (pts[1].y or 0) + 1.3, pts[1].z)
        render.debugText(v1, (cz and cz.weight and tw > 0) and (z.name .. string.format(' (%.1f p)', cz.weight / tw * 100)) or z.name, c, sel and 1.3 or 1.0)
      end
      goto continue
    end
    for k = 1, drawLines and (#pts - 1) or 0 do
      line(pts[k].x, pts[k].y, pts[k].z, pts[k + 1].x, pts[k + 1].y, pts[k + 1].z, c)
    end
    if drawLines and (sel or opts.showPoints) then
      -- selected zone: full markers with numbers; others while editing: smaller markers
      draw3d.pointScale = (tonumber(opts.pointSize) or 1) * (sel and 1 or 0.6)
      draw3d.zonePoints(pts, sel)
      draw3d.pointScale = tonumber(opts.pointSize) or 1
    elseif drawLines and #pts == 1 then
      draw3d.pointMarker(pts[1], 'mid')
    end

    -- track limit: short ticks every 2 m pointing to the track side (inside)
    if drawLines and z.type == 'LIMIT' and #pts >= 2 then
      local pl = geom.polyline(pts)
      local sd = z.side or 1
      local d = 0
      while d <= pl.length do
        local x, zz, nx, nz = geom.pointAt(pl, d)
        local y = yAt(pts, pl, d)
        line(x, y, zz, x + nx * sd * 0.6, y, zz + nz * sd * 0.6, c)
        d = d + 2
      end
    end

    local cz = byIndex[i]
    if cz and cz.type ~= 'LIMIT' then
      -- band edges: full-score distance and zero-score distance from the reference line
      if drawLines and opts.showBands ~= false then
        local full = geom.offsetPoints(cz.pl, cz.fullDist * cz.side)
        local zero = geom.offsetPoints(cz.pl, cz.zeroDist * cz.side)
        for k = 1, #zero - 1 do
          local ya, yb = pts[k] and pts[k].y or 0, pts[k + 1] and pts[k + 1].y or 0
          line(zero[k].x, ya, zero[k].z, zero[k + 1].x, yb, zero[k + 1].z, colDim)
          if cz.fullDist > 0.05 then
            line(full[k].x, ya, full[k].z, full[k + 1].x, yb, full[k + 1].z, rgbm(c.r * 0.5, c.g * 0.5, c.b * 0.5, 0.6))
          end
        end
        -- end caps
        local n = #zero
        if n >= 2 then
          line(pts[1].x, pts[1].y, pts[1].z, zero[1].x, pts[1].y, zero[1].z, colDim)
          line(pts[n].x, pts[n].y, pts[n].z, zero[n].x, pts[n].y, zero[n].z, colDim)
        end
        if cz.type == 'TNG' then
          local t2 = geom.offsetPoints(cz.pl, cz.tiers[2] * cz.side)
          for k = 1, #t2 - 1 do
            local ya, yb = pts[k] and pts[k].y or 0, pts[k + 1] and pts[k + 1].y or 0
            line(t2[k].x, ya, t2[k].z, t2[k + 1].x, yb, t2[k + 1].z, rgbm(c.r * 0.6, c.g * 0.6, c.b * 0.6, 0.7))
          end
        end
      end

      -- last run coverage along the reference line
      local bins = opts.bins and opts.bins[i]
      if bins and #bins > 0 then
        local step = cz.length / #bins
        for b = 1, #bins do
          local s0, s1 = (b - 1) * step, b * step
          local ax, az = geom.pointAt(cz.pl, s0)
          local bx, bz = geom.pointAt(cz.pl, s1)
          local ox, oz = 0, 0
          local _, _, nx, nz = geom.pointAt(cz.pl, (s0 + s1) / 2)
          ox, oz = nx * 0.25 * cz.side, nz * 0.25 * cz.side
          local col = bins[b] > 0 and mixColor(bins[b]) or colMissed
          line(ax + ox, yAt(pts, cz.pl, s0) + 0.03, az + oz, bx + ox, yAt(pts, cz.pl, s1) + 0.03, bz + oz, col)
        end
      end
    end

    -- no-go polygons
    for _, poly in ipairs(z.nogo or {}) do
      for k = 1, #poly do
        local a, b = poly[k], poly[k % #poly + 1]
        line(a.x, a.y, a.z, b.x, b.y, b.z, colNogo)
      end
    end

    if opts.labels ~= false and #pts > 0 then
      local mid = pts[math.max(1, math.floor((#pts + 1) / 2))]
      v1:set(mid.x, (mid.y or 0) + 1.2, mid.z)
      local label
      if z.type == 'LIMIT' then label = z.name .. ' (határ)'
      else
        local cz = byIndex[i]
        local tw = 0
        if compiled then for _, c2 in ipairs(compiled.zones) do tw = tw + (c2.weight or 0) end end
        if cz and cz.weight and tw > 0 then label = z.name .. string.format(' (%.1f p)', cz.weight / tw * 100)
        else label = z.name .. string.format(' (%g)', z.maxPoints or 0) end
      end
      render.debugText(v1, label, c, sel and 1.3 or 1.0)
    end
    ::continue::
  end
  render.setDepthMode(render.DepthMode.Normal)
end

-- Draft polygon / helper markers from the editor.
function draw3d.drawDraft(points, closed, color)
  color = color or colNogo
  for k = 1, #points - 1 do
    line(points[k].x, points[k].y, points[k].z, points[k + 1].x, points[k + 1].y, points[k + 1].z, color)
  end
  if closed and #points > 2 then
    local a, b = points[#points], points[1]
    line(a.x, a.y, a.z, b.x, b.y, b.z, color)
  end
  for k = 1, #points do
    draw3d.pointMarker(points[k], k == 1 and 'first' or 'mid', tostring(k))
  end
end

function draw3d.marker(p, color, text)
  local k = draw3d.pointScale or 1
  v1:set(p.x, (p.y or 0) + lift, p.z)
  render.setDepthMode(render.DepthMode.Off)
  render.debugCross(v1, 0.9 * k, color or colSel)
  drawDisc(p.x, (p.y or 0) + lift + 0.01, p.z, 0.3 * k, draw3d.pointColors.ring)
  drawDisc(p.x, (p.y or 0) + lift + 0.02, p.z, 0.2 * k, color or colSel)
  if text then
    v2:set(p.x, (p.y or 0) + 1.3 * k, p.z)
    render.debugText(v2, text, color or colSel, 1.0 * math.max(1, k))
  end
  render.setDepthMode(render.DepthMode.Normal)
end

-- Accel / decel map (A15): the reference line, coloured where the map has a segment (green / orange /
-- red), grey elsewhere; metre marks every 25 m. cm = compiled map (src/decelmap.lua), path with y.
draw3d.decelColors = { green = rgbm(0.2, 3, 0.4, 1), orange = rgbm(3, 1.4, 0.1, 1), red = rgbm(3, 0.2, 0.2, 1), none = rgbm(0.6, 0.6, 0.7, 0.6) }
function draw3d.drawDecelMap(path, cm, labels)
  if not path or #path < 2 then return end
  render.setDepthMode(render.DepthMode.ReadOnlyLessEqual)
  local s0 = 0
  local nextMark = 0
  for i = 1, #path - 1 do
    local a, b = path[i], path[i + 1]
    local seg = geom.dist(a.x, a.z, b.x, b.z)
    local mid = s0 + seg / 2
    local col = draw3d.decelColors.none
    if cm then
      for _, sg in ipairs(cm.segments) do
        if mid >= sg.from and mid <= sg.to then col = draw3d.decelColors[sg.color] or col break end
      end
    end
    local ya, yb = (a.y or 0) + 0.05, (b.y or 0) + 0.05
    line(a.x, ya, a.z, b.x, yb, b.z, col)
    line(a.x, ya + 0.04, a.z, b.x, yb + 0.04, b.z, col)
    if labels and s0 >= nextMark then
      v1:set(a.x, (a.y or 0) + 0.9, a.z)
      render.debugText(v1, string.format('%.0f m', s0), col, 0.9)
      nextMark = nextMark + 25
    end
    s0 = s0 + seg
  end
  render.setDepthMode(render.DepthMode.Normal)
end

-- Run trace (rear midpoints), coloured by angle.
function draw3d.drawTrace(trace, y)
  if not trace or #trace < 2 then return end
  render.setDepthMode(render.DepthMode.ReadOnlyLessEqual)
  for i = 1, #trace - 1 do
    local a, b = trace[i], trace[i + 1]
    local t = geom.clamp((a[3] or 0) / 75, 0, 1)
    line(a[5] or a[1], a[7] or y or 0, a[6] or a[2], b[5] or b[1], b[7] or y or 0, b[6] or b[2], mixColor(t))
  end
  render.setDepthMode(render.DepthMode.Normal)
end

return draw3d
