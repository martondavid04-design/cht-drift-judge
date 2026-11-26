-- CHT Drift Judge – accel / decel map of a layout (A15, DM 1.11 „Accel/Decel map”). Pure Lua.
--
-- Where the lead driver of a tandem run must keep speed (green), may change it a little (orange) or may
-- slow down with handbrake / footbrake (red). Lead runs that do not follow it get a deduction from the
-- judges – the program only flags the places (A16: no fixed deductions).
--
-- layout.decelMap = {
--   path = { {x=, y=, z=}, ... },    -- reference line along the course (from a run, a point every ~2 m; y only for drawing)
--   segments = { { color = 'green' | 'orange' | 'red', from = m, to = m }, ... },  -- metres along `path`
-- }
-- Where the map has no segment, nothing is checked.

local geom = require('src/geom')

local M = {}

M.colors = { 'green', 'orange', 'red' }
M.names = {
  green = 'Zöld – gyorsítás vagy tempótartás',
  orange = 'Narancs – kis tempóváltás, fék és kézifék nélkül',
  red = 'Piros – lassíthat (kézifék, fék, gázelvétel)',
}
M.short = { green = 'ZÖLD', orange = 'NARANCS', red = 'PIROS' }

-- Thresholds of the check (the lead's PC or the judge's PC measures them).
M.limits = {
  greenDrop = 6,      -- km/h: in green the speed may drop at most this much below the segment's best so far
  orangeDrop = 14,    -- km/h: in orange
  brake = 0.35,       -- pedal 0..1: a brake / handbrake above this counts as using it
  minTime = 0.25,     -- s: shorter touches are not flagged
}

local function num(v) if type(v) == 'number' and v == v then return v end return nil end

-- Cleans up the map read from a layout file (nil = no map).
function M.sanitize(d)
  if type(d) ~= 'table' then return nil end
  local r = { path = {}, segments = {} }
  if type(d.path) == 'table' then
    for _, p in ipairs(d.path) do
      if type(p) == 'table' and num(p.x) and num(p.z) then r.path[#r.path + 1] = { x = p.x, y = num(p.y), z = p.z } end
    end
  end
  if type(d.segments) == 'table' then
    for _, s in ipairs(d.segments) do
      if type(s) == 'table' and M.names[s.color] and num(s.from) and num(s.to) then
        local a, b = math.min(s.from, s.to), math.max(s.from, s.to)
        if b - a >= 0.5 then r.segments[#r.segments + 1] = { color = s.color, from = a, to = b } end
      end
    end
  end
  table.sort(r.segments, function(a, b) return a.from < b.from end)
  if #r.path < 2 and #r.segments == 0 then return nil end
  return r
end

-- Reference line from the samples of a run (positions px / pz, or a result's trace rows {x, z, angle,
-- speed, rear x, rear z, y}): a point every `step` metres, rounded to cm.
function M.pathFromSamples(samples, step)
  step = step or 2
  local out, last = {}, nil
  local function r2(v) return v and math.floor(v * 100 + 0.5) / 100 or nil end
  for _, s in ipairs(samples or {}) do
    local x, z, y = s.px, s.pz, s.py
    if not x and type(s[1]) == 'number' then x, z, y = s[1], s[2], s[7] end
    if x and z then
      if not last or geom.dist(last.x, last.z, x, z) >= step then
        last = { x = r2(x), y = r2(y), z = r2(z) }
        out[#out + 1] = last
      end
    end
  end
  return out
end

-- Length of a path (m).
function M.pathLength(path)
  local len = 0
  for i = 2, #(path or {}) do len = len + geom.dist(path[i - 1].x, path[i - 1].z, path[i].x, path[i].z) end
  return len
end

-- Adds a segment (overlapping parts of the others are cut away, so a place has one colour).
function M.addSegment(d, color, from, to)
  if not M.names[color] then return false end
  local a, b = math.min(from, to), math.max(from, to)
  if b - a < 0.5 then return false end
  local out = {}
  for _, sg in ipairs(d.segments or {}) do
    if sg.to <= a or sg.from >= b then out[#out + 1] = sg
    else
      if sg.from < a and a - sg.from >= 0.5 then out[#out + 1] = { color = sg.color, from = sg.from, to = a } end
      if sg.to > b and sg.to - b >= 0.5 then out[#out + 1] = { color = sg.color, from = b, to = sg.to } end
    end
  end
  out[#out + 1] = { color = color, from = math.floor(a * 10 + 0.5) / 10, to = math.floor(b * 10 + 0.5) / 10 }
  table.sort(out, function(x, y) return x.from < y.from end)
  d.segments = out
  return true
end

-- Compiled form for judging (nil if the layout has no usable map).
function M.compile(d)
  if type(d) ~= 'table' or type(d.path) ~= 'table' or #d.path < 2 then return nil end
  local pl = geom.polyline(d.path)
  if pl.length < 5 then return nil end
  local segs = {}
  for _, s in ipairs(d.segments or {}) do segs[#segs + 1] = { color = s.color, from = s.from, to = s.to } end
  table.sort(segs, function(a, b) return a.from < b.from end)
  return { pl = pl, segments = segs, length = pl.length }
end

-- Projection onto the reference line around the last known place (so a hairpin where the line comes
-- back near itself does not make the progress jump). Returns s (m), lateral distance (m).
function M.project(cm, x, z, lastS)
  local pl = cm.pl
  if not lastS then
    local s, lat = geom.project(pl, x, z)
    return s, math.abs(lat)
  end
  local bestD2, bestS = math.huge, lastS
  for i = 1, #pl.segs do
    local c0, c1 = pl.cum[i], pl.cum[i + 1]
    if c1 >= lastS - 25 and c0 <= lastS + 60 then
      local sg = pl.segs[i]
      local vx, vz = x - sg.ax, z - sg.az
      local t = geom.clamp(vx * sg.dx + vz * sg.dz, 0, sg.len)
      local ex, ez = x - (sg.ax + sg.dx * t), z - (sg.az + sg.dz * t)
      local d2 = ex * ex + ez * ez
      if d2 < bestD2 then bestD2, bestS = d2, c0 + t end
    end
  end
  if bestD2 == math.huge then
    local s, lat = geom.project(pl, x, z)
    return s, math.abs(lat)
  end
  return bestS, math.sqrt(bestD2)
end

function M.segmentAt(cm, s)
  if not cm then return nil end
  for i, sg in ipairs(cm.segments) do
    if s >= sg.from and s <= sg.to then return sg, i end
  end
  return nil
end

-- Checker for one car (the lead): feed it the samples of the judged part of the run.
-- Result: list of violations { color, from, to (m), t0, t1, kind = 'drop' | 'brake' | 'handbrake', value }.
function M.newChecker(cm)
  local self = { cm = cm, lastS = nil, segIndex = nil, best = 0, open = nil, list = {}, offLine = 0 }
  local L = M.limits
  local function close(t)
    local o = self.open
    if o then
      o.t1 = t
      if o.t1 - o.t0 >= L.minTime then self.list[#self.list + 1] = o end
      self.open = nil
    end
  end
  function self.feed(s)
    if not cm then return end
    local sp, lat = M.project(cm, s.px, s.pz, self.lastS)
    self.lastS = sp
    if lat > 25 then self.offLine = self.offLine + 1 close(s.t) return end
    local seg, idx = M.segmentAt(cm, sp)
    if idx ~= self.segIndex then
      close(s.t)
      self.segIndex, self.best = idx, s.spd or 0
    end
    if not seg then return end
    self.best = math.max(self.best, s.spd or 0)
    local kind, value = nil, nil
    if seg.color == 'green' then
      if (s.hb or 0) > L.brake then kind, value = 'handbrake', s.hb
      elseif (s.brake or 0) > L.brake then kind, value = 'brake', s.brake
      elseif self.best - (s.spd or 0) > L.greenDrop then kind, value = 'drop', self.best - s.spd end
    elseif seg.color == 'orange' then
      if (s.hb or 0) > L.brake then kind, value = 'handbrake', s.hb
      elseif (s.brake or 0) > L.brake then kind, value = 'brake', s.brake
      elseif self.best - (s.spd or 0) > L.orangeDrop then kind, value = 'drop', self.best - s.spd end
    end
    if kind then
      if self.open and self.open.kind == kind then
        self.open.to = sp
        if (value or 0) > (self.open.value or 0) then self.open.value = value end
      else
        close(s.t)
        self.open = { color = seg.color, kind = kind, from = sp, to = sp, t0 = s.t, value = value }
      end
    else
      close(s.t)
    end
  end
  function self.result(t)
    close(t or 0)
    return self.list
  end
  return self
end

local kindText = { drop = 'tempóvesztés', brake = 'fék', handbrake = 'kézifék' }
function M.violationText(v)
  local what = kindText[v.kind] or v.kind
  if v.kind == 'drop' then what = string.format('tempóvesztés %.0f km/h', v.value or 0) end
  return string.format('%s szakasz %.0f–%.0f m: %s', M.short[v.color] or v.color, v.from or 0, v.to or 0, what)
end

return M
