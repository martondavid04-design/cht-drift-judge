-- CHT Drift Judge – finds a painted zone marking on the track from its colour (pure Lua, testable).
--
-- How it works:
--  1. The user clicks on the paint. The colour there is the reference colour.
--  2. Region growing on a world-aligned pixel grid (h metres per pixel): every connected pixel with a
--     similar colour belongs to the marking (small gaps of `bridge` pixels are jumped over).
--  3. The region is reduced to 0.5 m cells; the two cells farthest apart along the region (geodesic
--     distance, so curved bands work) are its ends, the path between them is a rough spine.
--  4. At stations every metre along the spine the band is scanned across: both edges, middle, width.
--     This is repeated once on the middle line for better normals, and the ends are extended to the
--     real end of the paint.
-- Result: length, width, middle line and both edges. A thin result (< thinWidth) is a painted line,
-- otherwise a painted area (box); for an area the zone line is one of its edges.
--
-- colorAt(x, z) must return r, g, b (0..1) or nil if that part of the track is not loaded yet; the
-- detector then yields ('need', x, z) and expects to be resumed when it is available. Every `budget`
-- pixel tests it yields ('busy', pixels) so the game keeps running smoothly.

local geom = require('src/geom')

local PD = {}

PD.defaults = {
  h = 0.04,            -- metres per pixel (must match the captured images)
  tol = 0.12,          -- colour tolerance: average |difference| per channel
  bridge = 3,          -- gaps up to this many pixels minus one are bridged (worn paint, cracks)
  maxPixels = 350000,  -- safety: more than this = the colour matches the asphalt too
  maxRadius = 160,     -- metres from the click
  budget = 4000,       -- pixel tests per resume
  cell = 0.5,          -- metres, coarse grid for the spine
  station = 1.0,       -- metres between cross-sections
  maxHalfWidth = 6,    -- metres scanned to each side
  thinWidth = 0.6,     -- narrower than this = a painted line
}

local floor, abs, sqrt, huge = math.floor, math.abs, math.sqrt, math.huge

local function yieldMaybe(...)
  local co, isMain = coroutine.running()
  if co and not isMain then coroutine.yield(...) end
end

local function key(gx, gz) return gx * 4194304 + gz end

local function median(t)
  if #t == 0 then return 0 end
  local c = {}
  for i, v in ipairs(t) do c[i] = v end
  table.sort(c)
  local n = #c
  if n % 2 == 1 then return c[(n + 1) / 2] end
  return (c[n / 2] + c[n / 2 + 1]) / 2
end

-- Runs the detection. Must be called inside a coroutine (yields while waiting for images).
-- Returns result table, or nil + error code ('nocolor' | 'flood' | 'small').
function PD.detect(seedX, seedZ, colorAt, opts)
  local o = {}
  for k, v in pairs(PD.defaults) do o[k] = v end
  for k, v in pairs(opts or {}) do o[k] = v end
  local h = o.h

  local function sample(gx, gz)
    local x, z = (gx + 0.5) * h, (gz + 0.5) * h
    while true do
      local r, g, b = colorAt(x, z)
      if r then return r, g, b end
      coroutine.yield('need', x, z)
    end
  end

  -- reference colour: the clicked pixel, refined with the average of those 3×3 neighbours that are
  -- close to it (so a thin line is not mixed with the asphalt next to it)
  local sgx, sgz = floor(seedX / h), floor(seedZ / h)
  local tol3 = o.tol * 3
  local cr, cg, cb = sample(sgx, sgz)
  local sr, sgc, sb, nn = 0, 0, 0, 0
  for dx = -1, 1 do
    for dz = -1, 1 do
      local r, g, b = sample(sgx + dx, sgz + dz)
      if abs(r - cr) + abs(g - cg) + abs(b - cb) <= tol3 then
        sr, sgc, sb, nn = sr + r, sgc + g, sb + b, nn + 1
      end
    end
  end
  sr, sgc, sb = sr / nn, sgc / nn, sb / nn
  local function matches(r, g, b) return abs(r - sr) + abs(g - sgc) + abs(b - sb) <= tol3 end

  -- similarity to the reference colour, cached per pixel
  local simCache = {}
  local function similar(gx, gz)
    local k = key(gx, gz)
    local v = simCache[k]
    if v == nil then
      local r, g, b = sample(gx, gz)
      v = matches(r, g, b)
      simCache[k] = v
    end
    return v
  end

  -- raw and 3×3-smoothed colours, cached (asphalt is grainy pixel by pixel; painted lines are 10–20 cm
  -- wide, so a 12 cm average keeps the lines and removes the grain)
  local cR, cG, cB = {}, {}, {}
  local function raw(gx, gz)
    local k = key(gx, gz)
    local r = cR[k]
    if r == nil then
      local rr, gg, bb = sample(gx, gz)
      cR[k], cG[k], cB[k] = rr, gg, bb
      return rr, gg, bb
    end
    return r, cG[k], cB[k]
  end
  local mR, mG, mB = {}, {}, {}
  local function smooth(gx, gz)
    local k = key(gx, gz)
    local r = mR[k]
    if r ~= nil then return r, mG[k], mB[k] end
    local ar, ag, ab = 0, 0, 0
    for dx = -1, 1 do
      for dz = -1, 1 do
        local a, b, c = raw(gx + dx, gz + dz)
        ar, ag, ab = ar + a, ag + b, ab + c
      end
    end
    ar, ag, ab = ar / 9, ag / 9, ab / 9
    mR[k], mG[k], mB[k] = ar, ag, ab
    return ar, ag, ab
  end
  local function maxDiff(r1, g1, b1, r2, g2, b2)
    return math.max(abs(r1 - r2), abs(g1 - g2), abs(b1 - b2))
  end

  -- What was clicked? Two rings around the click: if most of them has the same (smoothed) colour, the
  -- click is inside a larger area – the inside of a painted frame (asphalt) or a filled painted area
  -- ('area'); otherwise it is on a painted line ('line').
  local areaT = o.tol * 2          -- inside an area: max difference from the area's typical colour
  local areaStep = o.tol * 0.6     -- inside an area: max difference between neighbouring pixels
  local mode = o.mode
  if not mode then
    local same, total = 0, 0
    for _, rad in ipairs({ 0.35, 0.7 }) do
      for i = 0, 23 do
        local a = i / 24 * 2 * math.pi
        total = total + 1
        local r, g, b = smooth(floor((seedX + math.cos(a) * rad) / h), floor((seedZ + math.sin(a) * rad) / h))
        if maxDiff(r, g, b, sr, sgc, sb) <= areaT then same = same + 1 end
      end
    end
    mode = (same / total >= 0.55) and 'area' or 'line'
  end

  -- 2. region growing
  local region = {}           -- key -> true (in the region), false (tested, not in it)
  local qx, qz, qh, qt = {}, {}, 1, 0
  local count, ops = 0, 0
  local maxR2 = (o.maxRadius / h) ^ 2
  local erodeR = 2
  -- typical colour of the clicked area: smoothed colours within 0.3 m of the click (only those close to
  -- the clicked colour, so a line next to the click does not spoil it)
  local muR, muG, muB = sr, sgc, sb
  if mode == 'area' then
    local n, ar, ag, ab = 0, 0, 0, 0
    local rr = floor(0.3 / h)
    for dx = -rr, rr, 2 do
      for dz = -rr, rr, 2 do
        if dx * dx + dz * dz <= rr * rr then
          local r, g, b = smooth(sgx + dx, sgz + dz)
          if maxDiff(r, g, b, sr, sgc, sb) <= areaT then n, ar, ag, ab = n + 1, ar + r, ag + g, ab + b end
        end
      end
    end
    if n > 0 then muR, muG, muB = ar / n, ag / n, ab / n end
  end
  local insideCache = {}
  local function insideLike(gx, gz)
    local k = key(gx, gz)
    local v = insideCache[k]
    if v == nil then
      local r, g, b = smooth(gx, gz)
      v = maxDiff(r, g, b, muR, muG, muB) <= areaT
      insideCache[k] = v
    end
    return v
  end
  -- 'area': a pixel belongs to the region if it and its 8 neighbours look like the clicked area, and
  -- its colour is close to the pixel it was reached from (gradual changes – rubber, patches – are
  -- followed, the sharp edge of a painted line is not crossed)
  local function passable(gx, gz, fx, fz)
    for dx = -1, 1 do
      for dz = -1, 1 do
        if not insideLike(gx + dx, gz + dz) then return false end
      end
    end
    if fx then
      local r1, g1, b1 = smooth(gx, gz)
      local r2, g2, b2 = smooth(fx, fz)
      if maxDiff(r1, g1, b1, r2, g2, b2) > areaStep then return false end
    end
    return true
  end
  local function push(nx, nz)
    region[key(nx, nz)] = true
    qt = qt + 1
    qx[qt], qz[qt] = nx, nz
    count = count + 1
  end

  -- Paint-bounded area (the inside of a painted frame): the region is bounded by PAINT, not by
  -- "anything that is not asphalt", so shadows, rubber and patches inside the frame do not stop it.
  -- The paint colour is the most common bright / coloured colour where rays from the click first leave
  -- the clicked area. A frame that is not closed (a side missing, a worn gap) is closed with virtual
  -- walls between the free ends of its painted lines.
  local function luma(r, g, b) return 0.3 * r + 0.59 * g + 0.11 * b end
  local function satur(r, g, b)
    local mx, mn = math.max(r, g, b), math.min(r, g, b)
    return mx > 1e-6 and (mx - mn) / mx or 0
  end
  -- magenta = no image data (clear colour of a shot, or an app window covering a screen image)
  local function noData(r, g, b) return r > 0.92 and g < 0.08 and b > 0.92 end
  local rayHits = {}
  -- Reference brightness of the track around the click: 60th percentile of a 3 m disk (paint is a
  -- small bright minority, shadows and rubber are darker – so this is plain asphalt even if the click
  -- itself is in a shadow).
  local L0, rR, rG, rB = nil, muR, muG, muB
  local function trackReference()
    local ls, cs = {}, {}
    local step = 0.2
    for dx = -3, 3, step do
      for dz = -3, 3, step do
        if dx * dx + dz * dz <= 9 then
          local r, g, b = smooth(floor((seedX + dx) / h), floor((seedZ + dz) / h))
          if not noData(r, g, b) then
            ls[#ls + 1] = luma(r, g, b)
            cs[#cs + 1] = { r, g, b }
          end
        end
      end
    end
    if #ls < 20 then return false end
    local sorted = {}
    for i, v in ipairs(ls) do sorted[i] = v end
    table.sort(sorted)
    local Lmed = sorted[math.max(1, floor(#sorted * 0.5))]
    -- the click itself is on paint (a filled painted area): not a frame
    if satur(muR, muG, muB) > 0.35 or luma(muR, muG, muB) > Lmed + 0.06 + o.tol * 0.65 then return false end
    L0 = math.max(luma(muR, muG, muB), sorted[math.max(1, floor(#sorted * 0.4))])
    local n, ar, ag, ab = 0, 0, 0, 0
    for i, v in ipairs(ls) do
      if abs(v - L0) <= 0.05 then n, ar, ag, ab = n + 1, ar + cs[i][1], ag + cs[i][2], ab + cs[i][3] end
    end
    if n > 0 then rR, rG, rB = ar / n, ag / n, ab / n end
    return true
  end
  -- paint-like = clearly brighter than the track, or clearly coloured (yellow, blue, red paint);
  -- shadows, rubber and patches are darker / grey, so they are not paint. A higher colour tolerance
  -- makes the area swallow more (fewer pixels count as paint).
  local brightT = 0.06 + o.tol * 0.65
  local function paintLike(r, g, b)
    if noData(r, g, b) then return false end
    local l = luma(r, g, b)
    return (l - L0 > brightT) or (satur(r, g, b) > 0.35 and l > 0.12 and maxDiff(r, g, b, rR, rG, rB) > areaT
      and maxDiff(r, g, b, muR, muG, muB) > areaT)
  end
  local plike, pmask = {}, {}
  local function likePx(gx, gz)
    local k = key(gx, gz)
    local v = plike[k]
    if v == nil then
      v = paintLike(smooth(gx, gz))
      plike[k] = v
    end
    return v
  end
  -- a paint pixel needs paint-like neighbours too: single bright grains of the asphalt are not paint
  local function isPaintPx(gx, gz)
    local k = key(gx, gz)
    local v = pmask[k]
    if v == nil then
      v = false
      if likePx(gx, gz) then
        local n = 0
        for dx = -1, 1 do
          for dz = -1, 1 do
            if (dx ~= 0 or dz ~= 0) and likePx(gx + dx, gz + dz) then n = n + 1 end
          end
        end
        v = n >= 3
      end
      pmask[k] = v
    end
    return v
  end
  -- rays from the click to the first paint-like pixel (12 m); enough of them = a painted frame around
  -- the click (several paint colours are fine: white edge line + yellow frame, worn + fresh paint)
  local function findPaintColor()
    if not trackReference() then return false end
    if isPaintPx(sgx, sgz) then return false end
    local hits = {}
    local nDir = 48
    local maxSteps = floor(12 / h)
    for i = 0, nDir - 1 do
      local a = i / nDir * 2 * math.pi
      local dx, dz = math.cos(a), math.sin(a)
      for st = 1, maxSteps do
        local gx, gz = floor((seedX + dx * st * h) / h), floor((seedZ + dz * st * h) / h)
        if isPaintPx(gx, gz) then
          hits[#hits + 1] = { gx = gx, gz = gz }
          break
        end
        local r, g, b = raw(gx, gz)
        if noData(r, g, b) then break end
      end
      ops = ops + maxSteps
      if ops % o.budget < maxSteps then yieldMaybe('busy', count) end
    end
    if o.debug then o.debug.L0, o.debug.hits, o.debug.ref = L0, #hits, { rR, rG, rB } end
    if #hits < 4 then return false end
    rayHits = hits
    return true
  end
  local vwall = {}
  -- Free ends of the painted lines around the click, and the virtual walls that close the frame:
  --  'gap'  – two ends facing each other (a worn / interrupted line), up to 3 m apart;
  --  'side' – two ends side by side, pointing the same way, the click behind both (a side of the frame
  --           is missing: "]" or "=" shapes), up to 45 m on the same painted line, 9 m between two lines.
  local endpoints = {}
  local function virtualWalls()
    local walls = {}
    local pk, pqx, pqz, ph, pt = {}, {}, {}, 1, 0
    local R2 = (45 / h) ^ 2
    for _, c in ipairs(rayHits) do
      local k = key(c.gx, c.gz)
      if pk[k] == nil and isPaintPx(c.gx, c.gz) then
        pk[k] = true
        pt = pt + 1
        pqx[pt], pqz[pt] = c.gx, c.gz
      end
    end
    while ph <= pt do
      local gx, gz = pqx[ph], pqz[ph]
      ph = ph + 1
      for dx = -2, 2 do
        for dz = -2, 2 do
          if dx ~= 0 or dz ~= 0 then
            local nx, nz = gx + dx, gz + dz
            local k = key(nx, nz)
            if pk[k] == nil then
              local ddx, ddz = nx - sgx, nz - sgz
              if ddx * ddx + ddz * ddz <= R2 and isPaintPx(nx, nz) then
                pk[k] = true
                pt = pt + 1
                pqx[pt], pqz[pt] = nx, nz
                if pt > 250000 then return walls end   -- a large filled painted area: nothing to close
              else
                pk[k] = false
              end
              ops = ops + 1
              if ops % o.budget == 0 then yieldMaybe('busy', count) end
            end
          end
        end
      end
    end
    if o.debug then o.debug.paintN, o.debug.paintX, o.debug.paintZ = pt, pqx, pqz end
    -- 0.2 m cells of the paint
    local kc2 = math.max(1, floor(0.2 / h + 0.5))
    local cm = kc2 * h
    local cmap, clist = {}, {}
    for i = 1, pt do
      local cx, cz = floor(pqx[i] / kc2), floor(pqz[i] / kc2)
      local ck = key(cx, cz)
      local c = cmap[ck]
      if not c then
        c = { cx = cx, cz = cz, n = 0, sx = 0, sz = 0 }
        cmap[ck] = c
        clist[#clist + 1] = c
      end
      c.n = c.n + 1
      c.sx, c.sz = c.sx + (pqx[i] + 0.5) * h, c.sz + (pqz[i] + 0.5) * h
    end
    local cells = {}
    local kept2 = {}
    for _, c in ipairs(clist) do
      if c.n >= 2 then
        c.x, c.z = c.sx / c.n, c.sz / c.n
        kept2[key(c.cx, c.cz)] = c
        cells[#cells + 1] = c
      end
    end
    local function nb8(c, fn)
      for dx = -1, 1 do
        for dz = -1, 1 do
          if dx ~= 0 or dz ~= 0 then
            local n = kept2[key(c.cx + dx, c.cz + dz)]
            if n then fn(n, (dx ~= 0 and dz ~= 0) and 1.4142 * cm or cm) end
          end
        end
      end
    end
    -- connected components (8-neighbours)
    local comp = 0
    for _, c in ipairs(cells) do
      if not c.comp then
        comp = comp + 1
        c.comp = comp
        local q, qh2 = { c }, 1
        while qh2 <= #q do
          local u = q[qh2]
          qh2 = qh2 + 1
          nb8(u, function(n) if not n.comp then n.comp = comp; q[#q + 1] = n end end)
        end
      end
    end
    -- free ends: walking R1 metres from the cell along the paint leaves ONE frontier (a line passing
    -- through or a corner leaves two, a junction three)
    local R1, band = 1.2, 0.4
    local cand = {}
    for ci, c in ipairs(cells) do
      local dist = { [c] = 0 }
      local q, qh2 = { c }, 1
      while qh2 <= #q do
        local u = q[qh2]
        qh2 = qh2 + 1
        local du = dist[u]
        nb8(u, function(n, w)
          local nd = du + w
          if nd <= R1 and (dist[n] == nil or nd < dist[n] - 1e-6) then
            dist[n] = nd
            q[#q + 1] = n
          end
        end)
      end
      local front = {}
      for n, d in pairs(dist) do if d >= R1 - band then front[#front + 1] = n end end
      if #front > 0 then
        local inF = {}
        for _, n in ipairs(front) do inF[n] = true end
        local seen, clusters = {}, 0
        for _, n in ipairs(front) do
          if not seen[n] then
            clusters = clusters + 1
            local q2, h2 = { n }, 1
            seen[n] = true
            while h2 <= #q2 do
              local u = q2[h2]
              h2 = h2 + 1
              nb8(u, function(m) if inF[m] and not seen[m] then seen[m] = true; q2[#q2 + 1] = m end end)
            end
          end
        end
        if clusters == 1 then
          local fx, fz = 0, 0
          for _, n in ipairs(front) do fx, fz = fx + n.x, fz + n.z end
          fx, fz = fx / #front, fz / #front
          local tx, tz = c.x - fx, c.z - fz
          local l = sqrt(tx * tx + tz * tz)
          if l > 1e-6 then
            c.tx, c.tz = tx / l, tz / l
            cand[#cand + 1] = c
            c.isCand = true
          end
        end
      end
      ops = ops + 20
      if ci % 50 == 0 then yieldMaybe('busy', count) end
    end
    -- one end per group of neighbouring candidate cells: the one farthest out
    local done = {}
    for _, c in ipairs(cand) do
      if not done[c] then
        local group, q, qh2 = {}, { c }, 1
        done[c] = true
        while qh2 <= #q do
          local u = q[qh2]
          qh2 = qh2 + 1
          group[#group + 1] = u
          nb8(u, function(n) if n.isCand and not done[n] then done[n] = true; q[#q + 1] = n end end)
        end
        local tx, tz = 0, 0
        for _, u in ipairs(group) do tx, tz = tx + u.tx, tz + u.tz end
        local l = sqrt(tx * tx + tz * tz)
        if l > 1e-6 then
          tx, tz = tx / l, tz / l
          local tip, best = nil, -huge
          for _, u in ipairs(group) do
            local d = u.x * tx + u.z * tz
            if d > best then best, tip = d, u end
          end
          -- the very end of the paint along the tangent
          -- the very end of the paint along the tangent (the smoothed mask is one pixel wider than the
          -- paint, so the last pixel is not counted)
          local ex, ez = tip.x, tip.z
          local last = 0
          for st = 1, floor(0.5 / h) do
            local x, z = tip.x + tx * st * h, tip.z + tz * st * h
            if isPaintPx(floor(x / h), floor(z / h)) then last = st else break end
          end
          if last > 0 then
            local st = math.max(0, last - 1)
            ex, ez = tip.x + tx * st * h, tip.z + tz * st * h
          end
          endpoints[#endpoints + 1] = { x = ex, z = ez, tx = tx, tz = tz, comp = tip.comp }
        end
      end
    end
    if o.debug then o.debug.endpoints = endpoints end
    -- pairs of ends to close
    local E = endpoints
    local pairsList = {}
    for i = 1, #E do
      for j = i + 1, #E do
        local a, b = E[i], E[j]
        local dx, dz = b.x - a.x, b.z - a.z
        local L = sqrt(dx * dx + dz * dz)
        if L > 0.05 then
          local ux, uz = dx / L, dz / L
          local ai = a.tx * ux + a.tz * uz
          local bj = -(b.tx * ux + b.tz * uz)
          local par = a.tx * b.tx + a.tz * b.tz
          local kind
          if ai > 0.8 and bj > 0.8 and L <= 3.0 then
            kind = 'gap'
          elseif par > 0.7 and abs(ai) < 0.45 and abs(bj) < 0.45 and L >= 0.8 and L <= (a.comp == b.comp and 45 or 9) then
            local sa = (seedX - a.x) * a.tx + (seedZ - a.z) * a.tz
            local sb = (seedX - b.x) * b.tx + (seedZ - b.z) * b.tz
            if sa < 0 and sb < 0 then kind = 'side' end
          end
          if kind then pairsList[#pairsList + 1] = { i = i, j = j, L = L, kind = kind } end
        end
      end
    end
    table.sort(pairsList, function(p, q)
      if p.kind ~= q.kind then return p.kind == 'gap' end
      return p.L < q.L
    end)
    local used = {}
    for _, pr in ipairs(pairsList) do
      if not used[pr.i] and not used[pr.j] then
        local a, b = E[pr.i], E[pr.j]
        local clear = true
        local n = math.max(2, floor(pr.L / h))
        for st = 1, n - 1 do
          local t = st / n
          local d = t * pr.L
          if d > 0.3 and pr.L - d > 0.3
            and isPaintPx(floor((a.x + (b.x - a.x) * t) / h), floor((a.z + (b.z - a.z) * t) / h)) then
            clear = false
            break
          end
        end
        if clear then
          used[pr.i], used[pr.j] = true, true
          walls[#walls + 1] = { a = { x = a.x, z = a.z }, b = { x = b.x, z = b.z }, kind = pr.kind, length = pr.L }
        end
      end
    end
    return walls
  end

  local walls = {}
  local paintBounded = false
  local touchedNoData = false
  if mode == 'area' and o.paintBounded ~= false then
    paintBounded = findPaintColor()
  end
  local function rasterise(w)
    local a, b = w.a, w.b
    local m = math.max(2, floor(w.length / (h * 0.5)))
    for st = 0, m do
      local t = st / m
      local gx, gz = floor((a.x + (b.x - a.x) * t) / h), floor((a.z + (b.z - a.z) * t) / h)
      for ox = -1, 1 do for oz = -1, 1 do vwall[key(gx + ox, gz + oz)] = true end end
    end
    walls[#walls + 1] = w
  end

  if mode == 'area' then
    local function pass(gx, gz, fx, fz)
      if not paintBounded then return passable(gx, gz, fx, fz) end
      if vwall[key(gx, gz)] then return false end
      -- 2 pixels away from paint: worn holes in a line and thin dark strips between two painted lines
      -- (e.g. the frame and the white track-edge line) do not let the area through
      for dx = -2, 2 do
        for dz = -2, 2 do
          if isPaintPx(gx + dx, gz + dz) then return false end
        end
      end
      local r, g, b = raw(gx, gz)
      if noData(r, g, b) then
        -- an unknown part (outside the image, an app window over it): the area is not proven closed
        touchedNoData = true
        return false
      end
      return true
    end
    local nb = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }
    -- one flood of the area; false = it leaked out (not closed)
    local function flood(cap)
      region, qx, qz, qh, qt, count = {}, {}, {}, 1, 0, 0
      touchedNoData = false
      local sx0, sz0 = nil, nil
      for rr = 0, 6 do
        for dx = -rr, rr do
          for dz = -rr, rr do
            if not sx0 and pass(sgx + dx, sgz + dz) then sx0, sz0 = sgx + dx, sgz + dz end
          end
        end
        if sx0 then break end
      end
      if not sx0 then return nil end
      push(sx0, sz0)
      while qh <= qt do
        local gx, gz = qx[qh], qz[qh]
        qh = qh + 1
        for _, d in ipairs(nb) do
          local nx, nz = gx + d[1], gz + d[2]
          local k = key(nx, nz)
          if region[k] == nil then
            if pass(nx, nz, gx, gz) then
              push(nx, nz)
              if count > cap then return false end
              local ddx, ddz = nx - sgx, nz - sgz
              if ddx * ddx + ddz * ddz > maxR2 then return false end
            else
              region[k] = false
            end
            ops = ops + 1
            if ops % o.budget == 0 then yieldMaybe('busy', count) end
          end
        end
      end
      return not touchedNoData
    end
    local function openErr()
      return nil, 'open', { freeEnds = #endpoints, walls = #walls, paintBounded = paintBounded, unknown = touchedNoData }
    end
    -- a closed frame needs no virtual walls; only when the area leaks out are the free ends of the
    -- paint closed: first the gaps of interrupted lines, then the missing sides
    local ok = flood(paintBounded and math.min(o.maxPixels, 200000) or o.maxPixels)
    if ok == nil then return nil, 'nocolor' end
    if not ok and paintBounded then
      local cand = virtualWalls()
      local any = false
      for _, w in ipairs(cand) do if w.kind == 'gap' then rasterise(w); any = true end end
      if any then ok = flood(o.maxPixels) end
      if not ok then
        any = false
        for _, w in ipairs(cand) do if w.kind == 'side' then rasterise(w); any = true end end
        if any then ok = flood(o.maxPixels) end
      end
    end
    if not ok then return openErr() end
    if o.debug then o.debug.regionN, o.debug.regionX, o.debug.regionZ = qt, qx, qz end
    if count * h * h < 0.3 then return nil, 'small' end
  else
    if not similar(sgx, sgz) then return nil, 'nocolor' end
    -- IC mark (o.markOnly): the click must be ON paint – most of a ring around it is another colour
    local function markResult(kind)
      local sx, sz, n, near = 0, 0, 0, 0.3 / h
      for i = 1, qt do
        local dx, dz = qx[i] - sgx, qz[i] - sgz
        if kind == 'mark' or dx * dx + dz * dz <= near * near then
          sx, sz, n = sx + (qx[i] + 0.5) * h, sz + (qz[i] + 0.5) * h, n + 1
        end
      end
      if n == 0 then return nil, 'nocolor' end
      local cx, cz = sx / n, sz / n
      local ext = 0
      if kind == 'mark' then
        for i = 1, qt do ext = math.max(ext, geom.dist((qx[i] + 0.5) * h, (qz[i] + 0.5) * h, cx, cz)) end
      end
      return { kind = kind, x = cx, z = cz, extent = ext * 2, pixels = qt, color = { sr, sgc, sb } }
    end
    if o.markOnly then
      local same = 0
      for i = 0, 31 do
        local a = i / 32 * 2 * math.pi
        if similar(floor((seedX + math.cos(a) * 1.2) / h), floor((seedZ + math.sin(a) * 1.2) / h)) then same = same + 1 end
      end
      if same > 16 then return nil, 'icarea' end
    end
    push(sgx, sgz)
    local bridge = o.bridge
    while qh <= qt do
      local gx, gz = qx[qh], qz[qh]
      qh = qh + 1
      for dx = -bridge, bridge do
        for dz = -bridge, bridge do
          if dx ~= 0 or dz ~= 0 then
            local nx, nz = gx + dx, gz + dz
            local k = key(nx, nz)
            if region[k] == nil then
              if similar(nx, nz) then
                push(nx, nz)
                if count > o.maxPixels then
                  if o.markOnly then return markResult('onLine') end
                  return nil, 'flood'
                end
                local ddx, ddz = nx - sgx, nz - sgz
                if ddx * ddx + ddz * ddz > maxR2 then
                  if o.markOnly then return markResult('onLine') end
                  return nil, 'flood'
                end
              else
                region[k] = false
              end
              ops = ops + 1
              if ops % o.budget == 0 then yieldMaybe('busy', count) end
            end
          end
        end
      end
    end
  end
  if o.markOnly then
    if mode == 'area' then return nil, 'icarea' end
    -- the whole paint blob fitted within the radius: a painted dot / small box, its centre is the point
    local sx, sz = 0, 0
    for i = 1, qt do sx, sz = sx + (qx[i] + 0.5) * h, sz + (qz[i] + 0.5) * h end
    local cx, cz = sx / qt, sz / qt
    local ext = 0
    for i = 1, qt do ext = math.max(ext, geom.dist((qx[i] + 0.5) * h, (qz[i] + 0.5) * h, cx, cz)) end
    return { kind = 'mark', x = cx, z = cz, extent = ext * 2, pixels = qt, color = { sr, sgc, sb } }
  end
  local bridge = mode == 'area' and erodeR or o.bridge
  local function isPaint(x, z) return region[key(floor(x / h), floor(z / h))] == true end

  -- 3. coarse cells and the geodesic spine
  local kc = math.max(1, floor(o.cell / h + 0.5))
  local cells, cellList = {}, {}
  for i = 1, qt do
    local cx, cz = floor(qx[i] / kc), floor(qz[i] / kc)
    local ck = key(cx, cz)
    local c = cells[ck]
    if not c then
      c = { cx = cx, cz = cz, n = 0, sx = 0, sz = 0 }
      cells[ck] = c
      cellList[#cellList + 1] = c
    end
    c.n = c.n + 1
    c.sx = c.sx + (qx[i] + 0.5) * h
    c.sz = c.sz + (qz[i] + 0.5) * h
  end
  local minFill = math.max(2, floor(kc * kc * 0.04))
  local kept = {}
  for _, c in ipairs(cellList) do
    if c.n >= minFill then
      c.x, c.z = c.sx / c.n, c.sz / c.n
      kept[key(c.cx, c.cz)] = c
    end
  end
  local function bfs(start)
    local dist, parent = { [start] = 0 }, {}
    local q, head = { start }, 1
    local far = start
    while head <= #q do
      local c = q[head]
      head = head + 1
      for dx = -1, 1 do
        for dz = -1, 1 do
          if dx ~= 0 or dz ~= 0 then
            local n = kept[key(c.cx + dx, c.cz + dz)]
            if n and dist[n] == nil then
              dist[n] = dist[c] + ((dx ~= 0 and dz ~= 0) and 1.414 or 1)
              parent[n] = c
              q[#q + 1] = n
              if dist[n] > dist[far] then far = n end
            end
          end
        end
      end
    end
    return far, parent, dist
  end
  local seedCell = kept[key(floor(sgx / kc), floor(sgz / kc))]
  if not seedCell then
    local bd = huge
    for _, c in pairs(kept) do
      local d = geom.dist(c.x, c.z, seedX, seedZ)
      if d < bd then bd, seedCell = d, c end
    end
  end
  if not seedCell then return nil, 'small' end
  local a = bfs(seedCell)
  local b, parent = bfs(a)
  local path = {}
  local c = b
  while c do
    path[#path + 1] = { x = c.x, z = c.z }
    c = parent[c]
  end
  if #path < 3 then return nil, 'small' end

  -- smooth the rough spine (moving average)
  local function smoothLine(pts, w)
    local out = {}
    for i = 1, #pts do
      local sx, sz, n = 0, 0, 0
      for j = math.max(1, i - w), math.min(#pts, i + w) do sx, sz, n = sx + pts[j].x, sz + pts[j].z, n + 1 end
      out[i] = { x = sx / n, z = sz / n }
    end
    out[1], out[#out] = { x = pts[1].x, z = pts[1].z }, { x = pts[#pts].x, z = pts[#pts].z }
    return out
  end
  local function resample(pts, step)
    local pl = geom.polyline(pts)
    local out = {}
    local n = math.max(1, floor(pl.length / step + 0.5))
    for i = 0, n do
      local x, z = geom.pointAt(pl, pl.length * i / n)
      out[#out + 1] = { x = x, z = z }
    end
    return out, pl.length
  end

  -- 4. cross-sections
  local maxSteps = floor(o.maxHalfWidth / h)
  local gapSteps = bridge + 1
  local function scan(x, z, nx, nz)
    -- start on paint: nearest paint along the normal within 1.5 m
    local s0 = nil
    for i = 0, floor(1.5 / h) do
      if isPaint(x + nx * i * h, z + nz * i * h) then s0 = i break end
      if isPaint(x - nx * i * h, z - nz * i * h) then s0 = -i break end
    end
    if not s0 then return nil end
    local function walk(dir)
      local last, miss, i = s0, 0, s0
      while abs(i - s0) < maxSteps do
        i = i + dir
        if isPaint(x + nx * i * h, z + nz * i * h) then last, miss = i, 0
        else
          miss = miss + 1
          if miss > gapSteps then break end
        end
      end
      return last
    end
    local plus, minus = walk(1), walk(-1)
    return plus * h + h / 2, minus * h - h / 2
  end
  -- 'area' mode: from the edge of the region (inside a painted frame) go on through the remaining
  -- margin of the clicked colour, then through the painted line itself; the edge is the MIDDLE of the
  -- painted line. If there is no narrow line (a filled painted area), the edge stays at the region edge.
  local maxLine = floor(0.6 / h)
  local function refine(px, pz, nx, nz, e, dir)
    local function at(t) return floor((px + nx * t) / h), floor((pz + nz * t) / h) end
    local t = e
    for _ = 1, erodeR + 3 do
      local gx, gz = at(t + dir * h * 0.5)
      if vwall[key(gx, gz)] then
        -- a virtual wall (missing side of an open frame): the edge is the middle of the wall
        return t + dir * h * 1.5, nil, true
      end
      if insideLike(gx, gz) then t = t + dir * h else break end
    end
    -- colour of the line: average of its first 3 (smoothed) pixels
    local pr, pg, pb = 0, 0, 0
    for i = 0, 2 do
      local gx, gz = at(t + dir * h * (i + 0.5))
      local r, g, b = smooth(gx, gz)
      pr, pg, pb = pr + r / 3, pg + g / 3, pb + b / 3
    end
    local n, miss, last = 0, 0, 0
    while n < maxLine do
      n = n + 1
      local gx, gz = at(t + dir * h * (n - 0.5))
      local r, g, b = smooth(gx, gz)
      if maxDiff(r, g, b, pr, pg, pb) <= o.tol * 1.5 and not insideLike(gx, gz) then
        last, miss = n, 0
      else
        miss = miss + 1
        if miss > 2 then break end
      end
    end
    if last >= 1 and last < maxLine - 2 then return t, last * h end
    return t, nil
  end
  -- widths of the painted line measured at the cross-sections; their median is used everywhere, so a
  -- worn piece of the line does not bend the zone edge
  local lineWs = {}
  local lineW = nil
  local function placeEdges(sct)
    if not sct.pb then return sct end
    local wp = lineW or sct.pw or 0
    local wm = lineW or sct.mw or 0
    local plus = sct.pb + (sct.pwall and 0 or (sct.pw and wp / 2 or (lineW and lineW / 2 or 0)))
    local minus = sct.mb - (sct.mwall and 0 or (sct.mw and wm / 2 or (lineW and lineW / 2 or 0)))
    local nx, nz = sct.nx, sct.nz
    sct.left = { x = sct.px + nx * plus, z = sct.pz + nz * plus }
    sct.right = { x = sct.px + nx * minus, z = sct.pz + nz * minus }
    sct.mid = { x = sct.px + nx * (plus + minus) / 2, z = sct.pz + nz * (plus + minus) / 2 }
    sct.width = plus - minus
    return sct
  end

  local function makeSection(p, tx, tz)
    local nx, nz = -tz, tx
    local plus, minus = scan(p.x, p.z, nx, nz)
    if not plus then return nil end
    if mode == 'area' then
      local pb, pw, pwall = refine(p.x, p.z, nx, nz, plus, 1)
      local mb, mw, mwall = refine(p.x, p.z, nx, nz, minus, -1)
      if pw then lineWs[#lineWs + 1] = pw end
      if mw then lineWs[#lineWs + 1] = mw end
      return placeEdges({ pb = pb, mb = mb, pw = pw, mw = mw, pwall = pwall, mwall = mwall, px = p.x, pz = p.z, nx = nx, nz = nz, tx = tx, tz = tz })
    end
    return {
      left = { x = p.x + nx * plus, z = p.z + nz * plus },
      right = { x = p.x + nx * minus, z = p.z + nz * minus },
      mid = { x = p.x + nx * (plus + minus) / 2, z = p.z + nz * (plus + minus) / 2 },
      width = plus - minus, tx = tx, tz = tz,
    }
  end
  local function sections(spine)
    local out = {}
    for i = 1, #spine do
      local p0, p1 = spine[math.max(1, i - 1)], spine[math.min(#spine, i + 1)]
      local tx, tz = p1.x - p0.x, p1.z - p0.z
      local l = sqrt(tx * tx + tz * tz)
      if l > 1e-6 then
        local sct = makeSection(spine[i], tx / l, tz / l)
        if sct then out[#out + 1] = sct end
      end
    end
    return out
  end

  local spine = resample(smoothLine(path, 2), o.station)
  local secs = sections(spine)
  if #secs < 2 then return nil, 'small' end
  local mids = {}
  for i, s in ipairs(secs) do mids[i] = s.mid end
  spine = resample(smoothLine(mids, 1), o.station)
  lineWs = {}
  secs = sections(spine)
  if #secs < 2 then return nil, 'small' end
  if mode == 'area' and #lineWs >= 6 and #lineWs >= #secs * 0.5 then
    lineW = median(lineWs)
    for _, sc in ipairs(secs) do placeEdges(sc) end
  end
  if o.debug then
    o.debug.path = path
    o.debug.secs1 = {}
    for i, sc in ipairs(secs) do o.debug.secs1[i] = { x = sc.mid.x, z = sc.mid.z, w = sc.width } end
  end

  -- The spine runs between the two farthest cells, which for a painted area are opposite corners, so
  -- the cross-sections near the ends are skewed. Drop the end sections within about one band width
  -- (and any section whose width is far from the typical one); the ends are rebuilt by the extension
  -- below along a tangent measured over a longer baseline.
  do
    local ws = {}
    for i, sct in ipairs(secs) do ws[i] = sct.width end
    local med = median(ws)
    if med >= o.thinWidth then
      local trim = math.min(med, 3) * 0.8
      local function bad(sct) return abs(sct.width - med) > 0.2 * med end
      local function arcFromStart(k)
        local d = 0
        for j = 2, k do d = d + geom.dist(secs[j - 1].mid.x, secs[j - 1].mid.z, secs[j].mid.x, secs[j].mid.z) end
        return d
      end
      while #secs > 3 and (bad(secs[1]) or arcFromStart(2) < trim) do
        table.remove(secs, 1)
        trim = trim - o.station
      end
      trim = math.min(med, 3) * 0.8
      while #secs > 3 and (bad(secs[#secs]) or geom.dist(secs[#secs].mid.x, secs[#secs].mid.z, secs[#secs - 1].mid.x, secs[#secs - 1].mid.z) < 0 or trim > 0) do
        table.remove(secs)
        trim = trim - o.station
      end
    end
  end
  -- robust end tangents (baseline of up to 3 sections)
  local function baseTangent(i, j)
    local a, b = secs[i].mid, secs[j].mid
    local tx, tz = b.x - a.x, b.z - a.z
    local l = sqrt(tx * tx + tz * tz)
    if l < 1e-6 then return secs[i].tx, secs[i].tz end
    return tx / l, tz / l
  end
  do
    local n = #secs
    local k = math.min(n, 4)
    local t1x, t1z = baseTangent(1, k)
    local tnx, tnz = baseTangent(math.max(1, n - k + 1), n)
    -- re-cut the end sections square to the robust tangent
    secs[1] = makeSection(secs[1].mid, t1x, t1z) or secs[1]
    secs[n] = makeSection(secs[n].mid, tnx, tnz) or secs[n]
  end

  -- extend both ends to the real end of the paint
  local function extend(sec, sign)
    local ext, miss, i, last = 0, 0, 0, 0
    local maxI = floor(3 / h)
    while i < maxI do
      i = i + 1
      local x, z = sec.mid.x + sec.tx * sign * i * h, sec.mid.z + sec.tz * sign * i * h
      if isPaint(x, z) then last, miss = i, 0 else miss = miss + 1; if miss > gapSteps then break end end
    end
    ext = last * h + h / 2
    if mode == 'area' then
      local t, w, wall = refine(sec.mid.x, sec.mid.z, sec.tx * sign, sec.tz * sign, ext, 1)
      ext = t + ((not wall and (lineW or w)) and (lineW or w) / 2 or 0)
    end
    if ext < 0.05 then return nil end
    local dx, dz = sec.tx * sign * ext, sec.tz * sign * ext
    return {
      left = { x = sec.left.x + dx, z = sec.left.z + dz }, right = { x = sec.right.x + dx, z = sec.right.z + dz },
      mid = { x = sec.mid.x + dx, z = sec.mid.z + dz }, width = sec.width, tx = sec.tx, tz = sec.tz,
    }
  end
  local head = extend(secs[1], -1)
  local tail = extend(secs[#secs], 1)
  if head then table.insert(secs, 1, head) end
  if tail then secs[#secs + 1] = tail end

  -- remove single-section kinks in the edges (worn paint): median of 5 of the edge offsets measured
  -- from the middle line, then rebuild the edges
  do
    local n = #secs
    if n >= 5 then
      local function offs(which)
        local t = {}
        for i, sc in ipairs(secs) do
          local nx, nz = -sc.tz, sc.tx
          t[i] = (sc[which].x - sc.mid.x) * nx + (sc[which].z - sc.mid.z) * nz
        end
        return t
      end
      local lo, ro = offs('left'), offs('right')
      local function med5(t, i)
        local w = {}
        for j = math.max(1, i - 2), math.min(#t, i + 2) do w[#w + 1] = t[j] end
        return median(w)
      end
      for i, sc in ipairs(secs) do
        local nx, nz = -sc.tz, sc.tx
        local l, r = lo[i], ro[i]
        local ml, mr = med5(lo, i), med5(ro, i)
        if abs(l - ml) > 0.05 then l = ml end
        if abs(r - mr) > 0.05 then r = mr end
        sc.left = { x = sc.mid.x + nx * l, z = sc.mid.z + nz * l }
        sc.right = { x = sc.mid.x + nx * r, z = sc.mid.z + nz * r }
        sc.width = l - r
      end
    end
  end

  local res = { mid = {}, left = {}, right = {}, widths = {}, pixels = count, color = { sr, sgc, sb } }
  for i, s in ipairs(secs) do
    res.mid[i], res.left[i], res.right[i] = s.mid, s.left, s.right
    res.widths[i] = s.width
  end
  local inner = {}
  for i = 3, #res.widths - 2 do inner[#inner + 1] = res.widths[i] end
  res.width = median(#inner > 0 and inner or res.widths)
  res.length = geom.polyline(res.mid).length
  res.mode = mode
  res.thin = mode ~= 'area' and res.width < o.thinWidth
  res.walls = walls or {}
  res.paintBounded = paintBounded
  res.freeEnds = #endpoints
  -- a line that is part of a network (e.g. one side of a painted frame with more lines attached):
  -- far more paint than one line of this length and width
  if mode == 'line' then
    if count * h * h > 2.0 * res.length * math.max(res.width, 2 * h) + 0.5 then return nil, 'network' end
    -- branches / closed frame: paint cells far from the found line
    local pl = geom.polyline(res.mid)
    local off, all = 0, 0
    local lim = math.max(1.0, res.width)
    for _, cc in pairs(kept) do
      all = all + 1
      local _, lat, inside = geom.project(pl, cc.x, cc.z)
      if abs(lat) > lim or not inside then
        local d1 = geom.dist(cc.x, cc.z, res.mid[1].x, res.mid[1].z)
        local d2 = geom.dist(cc.x, cc.z, res.mid[#res.mid].x, res.mid[#res.mid].z)
        if abs(lat) > lim or math.min(d1, d2) > lim then off = off + 1 end
      end
    end
    if all > 0 and off / all > 0.12 then return nil, 'network' end
  end
  return res
end

-- IC (inner clipping point) from paint: the user clicks ON the painted mark.
--   a small painted dot / box  -> its centre   ({ kind = 'mark', x, z, extent })
--   a long painted line        -> the middle of the line next to the click ({ kind = 'onLine', x, z })
-- Errors: 'icarea' (the click is not on paint), 'nocolor'.
function PD.detectMark(seedX, seedZ, colorAt, opts)
  local o = {}
  for k, v in pairs(opts or {}) do o[k] = v end
  o.mode, o.markOnly = 'line', true
  o.maxRadius = o.markRadius or 2.0
  o.maxPixels = math.min(o.maxPixels or PD.defaults.maxPixels, 60000)
  return PD.detect(seedX, seedZ, colorAt, o)
end

-- Douglas–Peucker simplification (tolerance in metres), then no segment longer than maxSeg.
function PD.simplify(pts, tolerance, maxSeg)
  if #pts <= 2 then return pts end
  local keep = { [1] = true, [#pts] = true }
  local function dp(i, j)
    if j <= i + 1 then return end
    local a, b = pts[i], pts[j]
    local dx, dz = b.x - a.x, b.z - a.z
    local l = sqrt(dx * dx + dz * dz)
    local best, bi = -1, nil
    for k = i + 1, j - 1 do
      local p = pts[k]
      local d
      if l < 1e-9 then d = geom.dist(p.x, p.z, a.x, a.z) else d = abs((p.x - a.x) * dz - (p.z - a.z) * dx) / l end
      if d > best then best, bi = d, k end
    end
    if best > tolerance then
      keep[bi] = true
      dp(i, bi)
      dp(bi, j)
    end
  end
  dp(1, #pts)
  local out = {}
  for i = 1, #pts do
    if keep[i] then
      local p = pts[i]
      local q = out[#out]
      if q and maxSeg then
        local d = geom.dist(q.x, q.z, p.x, p.z)
        local n = math.ceil(d / maxSeg)
        for s = 1, n - 1 do
          out[#out + 1] = { x = q.x + (p.x - q.x) * s / n, z = q.z + (p.z - q.z) * s / n }
        end
      end
      out[#out + 1] = { x = p.x, z = p.z }
    end
  end
  return out
end

local function reversed(t)
  local r = {}
  for i = #t, 1, -1 do r[#r + 1] = t[i] end
  return r
end

-- Picks the zone line from a detection result.
--   dirX, dirZ: driving direction (the line is returned in this direction)
--   carX, carZ: a point on the track (the car), to tell the track side from the outside
--   edge: 'auto' (area: edge farther from the car, line: middle), 'far', 'near', 'mid'
-- Returns { points, side, zeroDist (area only), edge = 'far'|'near'|'mid' }
function PD.choose(res, dirX, dirZ, carX, carZ, edge)
  local mid, left, right = res.mid, res.left, res.right
  local a, b = mid[1], mid[#mid]
  if (b.x - a.x) * dirX + (b.z - a.z) * dirZ < 0 then
    -- reversing the direction swaps left and right
    mid, left, right = reversed(mid), reversed(right), reversed(left)
  end
  edge = edge or 'auto'
  if edge == 'auto' then edge = res.thin and 'mid' or 'far' end
  local function minDist(pts)
    local d = huge
    for _, p in ipairs(pts) do d = math.min(d, geom.dist(p.x, p.z, carX, carZ)) end
    return d
  end
  local pts, side
  if edge == 'mid' then
    pts = mid
    local pa, pb = mid[1], mid[#mid]
    local sd = geom.sideOf(pa.x, pa.z, pb.x, pb.z, carX, carZ)
    -- for long curved lines use the nearest segment instead of the chord
    local bestD, bi = huge, 1
    for i = 1, #mid - 1 do
      local d = geom.dist((mid[i].x + mid[i + 1].x) / 2, (mid[i].z + mid[i + 1].z) / 2, carX, carZ)
      if d < bestD then bestD, bi = d, i end
    end
    sd = geom.sideOf(mid[bi].x, mid[bi].z, mid[bi + 1].x, mid[bi + 1].z, carX, carZ)
    side = sd >= 0 and 1 or -1
  else
    local leftFar = minDist(left) > minDist(right)
    local useLeft = (edge == 'far') == leftFar
    pts = useLeft and left or right
    -- the zone band lies towards the other edge
    side = useLeft and -1 or 1
  end
  return { points = pts, side = side, zeroDist = (not res.thin) and res.width or nil, edge = edge }
end

return PD
