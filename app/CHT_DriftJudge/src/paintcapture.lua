-- CHT Drift Judge – colour images of the track for the paint detector (CSP only).
--
-- Two sources:
--  • 'shot'   – 40 × 40 m top-down GeometryShot tiles of the track model. The 0.3.5 test showed a
--               completely empty image on the client's machine, so several shot set-ups are tried in a
--               row (orthographic from high / low, other shader sets, perspective); the first one that
--               draws anything is remembered per track.
--  • 'screen' – a screenshot of what the user sees (F7 free camera from above). The world → screen
--               mapping is measured with render.projectPoint on a 1 m ground grid at capture time, the
--               app windows are masked out, and the app's own 3D drawings are hidden for the shot. This
--               also sees paint that is drawn by a server / track script and is not part of the model.
-- Unknown pixels (nothing drawn, outside the image, under a window) are returned as magenta (1, 0, 1):
-- the detector treats them as "no data".

local PC = {}

PC.size = 40          -- metres per shot tile
PC.res = 1024         -- pixels per shot tile
PC.h = 0.04           -- detector step (metres per detector pixel)

-- shot set-ups, tried in this order
PC.variants = {
  { id = 'ortho_high', label = 'felülnézet magasról (orto)', ortho = true, height = 500, depth = 1000, shaders = 'SampleColor' },
  { id = 'ortho_low', label = 'felülnézet közelről (orto)', ortho = true, height = 30, depth = 300, clip = { 24, 300 }, shaders = 'SampleColor' },
  { id = 'ortho_simple', label = 'felülnézet, egyszerű árnyalók', ortho = true, height = 500, depth = 1000, shaders = 'Simplified' },
  { id = 'persp', label = 'felülnézet perspektívával', ortho = false, height = 400, clip = { 300, 520 }, shaders = 'SampleColor' },
  { id = 'persp_main', label = 'felülnézet, teljes árnyalás', ortho = false, height = 400, clip = { 300, 520 }, shaders = 'Main', best = true },
}

local shot, shotVariant = nil, nil
local tiles = {}
local pending = nil
local tmp = rgbm()
PC.variantIndex = 1
PC.blank = false          -- every shot set-up gave an empty image
PC.guessedMapping = false
PC.lastError = nil
PC.log = {}               -- { id, result = 'ok' | 'blank' | 'error', magenta, spread }
PC.debugDir = nil         -- set by the editor: where test images are saved

local function variantById(id)
  for i, v in ipairs(PC.variants) do if v.id == id then return i end end
  return nil
end

function PC.setVariant(id)
  local i = variantById(id)
  if i then PC.variantIndex = i end
end

function PC.variant() return PC.variants[PC.variantIndex] end

local function groundY(x, z, refY)
  local hit = vec3()
  local d = physics.raycastTrack(vec3(x, refY + 60, z), vec3(0, -1, 0), 200, hit)
  if d >= 0 then return hit.y end
  return refY
end
PC.groundY = groundY

local function disposeShot()
  if shot then pcall(function() shot:dispose() end) end
  shot, shotVariant = nil, nil
end

local function ensureShot()
  local v = PC.variants[PC.variantIndex]
  if shot and shotVariant == v then return shot, v end
  disposeShot()
  local root = ac.findNodes(v.root or 'trackRoot:yes')
  shot = ac.GeometryShot(root, vec2(PC.res, PC.res), 1, false)
  shot:setShadersType(render.ShadersType[v.shaders] or render.ShadersType.SampleColor)
  if v.best and shot.setBestSceneShotQuality then shot:setBestSceneShotQuality() end
  shot:setTransparentPass(true)          -- painted decals are often transparent meshes
  shot:setClearColor(rgbm(1, 0, 1, 0))   -- magenta = nothing drawn there
  if v.ortho then shot:setOrthogonalParams(vec2(PC.size, PC.size), v.depth or 300) end
  if v.clip then shot:setClippingPlanes(v.clip[1], v.clip[2]) end
  shotVariant = v
  return shot, v
end

-- World → pixel mapping of the last shot, from its view and projection matrices. Several matrix
-- conventions are tried; the right one maps the tile centre to the image centre.
local function computeMap(cx, cy, cz)
  local V, P = shot:viewMatrix(), shot:projectionMatrix()
  local function ndcWith(f, x, y, z)
    local ok, a = pcall(f, vec4(x, y, z, 1))
    if not ok or not a or a.w == 0 then return nil end
    return a.x / a.w, a.y / a.w
  end
  local candidates = {
    function(v) return P:transform(V:transform(v)) end,
    function(v) return V:mul(P):transform(v) end,
    function(v) return P:mul(V):transform(v) end,
  }
  local expect = 10 / PC.size -- 5 m = this much in NDC units
  for _, f in ipairs(candidates) do
    local x0, y0 = ndcWith(f, cx, cy, cz)
    local x1, y1 = ndcWith(f, cx + 5, cy, cz)
    local x2, y2 = ndcWith(f, cx, cy, cz + 5)
    if x0 and x1 and x2 and math.abs(x0) < 0.02 and math.abs(y0) < 0.02 then
      local ax, ay = x1 - x0, y1 - y0
      local bx, by = x2 - x0, y2 - y0
      local la, lb = math.sqrt(ax * ax + ay * ay), math.sqrt(bx * bx + by * by)
      if math.abs(la - expect) < expect * 0.2 and math.abs(lb - expect) < expect * 0.2 and math.abs(ax * bx + ay * by) < 0.1 * la * lb then
        local k = PC.res / 2 / 5
        return { cx = cx, cz = cz, pxx = ax * k, pxz = bx * k, pyx = -ay * k, pyz = -by * k, guessed = false }
      end
    end
  end
  local k = PC.res / PC.size
  return { cx = cx, cz = cz, pxx = k, pxz = 0, pyx = 0, pyz = -k, guessed = true }
end

local function toPixel(t, x, z)
  local m = t.map
  local dx, dz = x - m.cx, z - m.cz
  return PC.res / 2 + dx * m.pxx + dz * m.pxz, PC.res / 2 + dx * m.pyx + dz * m.pyz
end

local function isMagenta(c) return c.r > 0.92 and c.g < 0.08 and c.b > 0.92 end

-- share of "nothing drawn" pixels and the brightness spread of a downloaded image (64 × 64 samples)
local function imageStats(data, w, h)
  local probe = rgbm()
  local minS, maxS, mag, n = math.huge, -math.huge, 0, 0
  for i = 0, 63 do
    for j = 0, 63 do
      local c = data:colorTo(probe, math.floor((i + 0.5) * w / 64), math.floor((j + 0.5) * h / 64))
      n = n + 1
      if isMagenta(c) or (c.mult or 1) <= 0.001 and c.r + c.g + c.b <= 0.003 then
        mag = mag + 1
      else
        local v = c.r + c.g * 2 + c.b
        if v < minS then minS = v end
        if v > maxS then maxS = v end
      end
    end
  end
  return mag / n, (maxS > minS) and (maxS - minS) or 0
end

function PC.busy() return pending ~= nil end

-- Starts capturing a shot tile centred at (x, z). The result arrives a few frames later. An empty image
-- moves on to the next shot set-up automatically; when none works, PC.blank is set.
function PC.request(x, z, refY)
  if pending then return true end
  if PC.blank then return false end
  local ok, err = pcall(function()
    local s, v = ensureShot()
    local y = groundY(x, z, refY or 0)
    if v.ortho then
      s:update(vec3(x, y + v.height, z), vec3(0, -1, 0), vec3(0, 0, 1), 0)
    else
      local fov = math.deg(2 * math.atan(PC.size / 2 / v.height))
      s:update(vec3(x, y + v.height, z), vec3(0, -1, 0), vec3(0, 0, 1), fov)
    end
    local t = { map = computeMap(x, y, z), y = y, cx = x, cz = z, variant = v.id }
    local first = #tiles == 0 and not PC.firstTile
    if first and PC.debugDir then
      local file = PC.debugDir .. '/festes_proba_' .. v.id .. '.png'
      pcall(function() s:save(file) end)
      PC.firstTile = { x = x, y = y, z = z, map = t.map, file = file, variant = v.id }
    end
    if t.map.guessed then PC.guessedMapping = true end
    pending = t
    s:accessData(function(e, data)
      pending = nil
      if e or not data then
        PC.lastError = tostring(e or 'no data')
        PC.log[#PC.log + 1] = { id = v.id, result = 'error', error = PC.lastError }
        t.failed = true
        return
      end
      local magShare, spread = imageStats(data, PC.res, PC.res)
      if magShare > 0.97 or spread < 0.004 then
        PC.log[#PC.log + 1] = { id = v.id, result = 'blank', magenta = magShare, spread = spread }
        if data.dispose then data:dispose() end
        PC.firstTile = nil
        if PC.variantIndex < #PC.variants then
          PC.variantIndex = PC.variantIndex + 1
          disposeShot()
          PC.request(x, z, refY)
        else
          PC.blank = true
        end
        return
      end
      if #tiles == 0 then PC.log[#PC.log + 1] = { id = v.id, result = 'ok', magenta = magShare, spread = spread } end
      PC.workingVariant = v.id
      t.data = data
      tiles[#tiles + 1] = t
      while #tiles > 12 do
        local old = table.remove(tiles, 1)
        if old.data and old.data.dispose then old.data:dispose() end
      end
    end)
  end)
  if not ok then
    PC.lastError = tostring(err)
    PC.log[#PC.log + 1] = { id = PC.variants[PC.variantIndex].id, result = 'error', error = PC.lastError }
    pending = nil
    -- a set-up that throws (e.g. a shader set this CSP does not have): try the next one
    if PC.variantIndex < #PC.variants then
      PC.variantIndex = PC.variantIndex + 1
      disposeShot()
      return PC.request(x, z, refY)
    end
    PC.blank = true
    return false
  end
  return true
end

---------------------------------------------------------------------------------------------------
-- Screen source
---------------------------------------------------------------------------------------------------

local scr = nil   -- capture state
PC.screen = nil   -- finished screen image: { data, w, h, x0, z0, step, n, u = {}, v = {}, masks, cam }

function PC.overlaysHidden()
  return scr ~= nil and (scr.state == 'hide' or scr.state == 'shoot' or scr.state == 'wait')
end

function PC.screenState() return scr and scr.state or (PC.screen and 'ready' or 'none'), scr and scr.err end

local function windowMasks()
  local masks = {}
  local ok = pcall(function()
    local uiSize = ac.getUI().windowSize
    local W, H = math.max(1, uiSize.x), math.max(1, uiSize.y)
    for _, w in ipairs(ac.getAppWindows() or {}) do
      if w.visible and w.size and w.position then
        local sy = w.collapsed and math.min(w.size.y, 30) or w.size.y
        masks[#masks + 1] = { (w.position.x - 4) / W, (w.position.y - 4) / H, (w.position.x + w.size.x + 4) / W, (w.position.y + sy + 4) / H }
      end
    end
  end)
  if not ok then masks = {} end
  return masks
end

-- 1 m ground grid around the seed, projected to the screen (0..1, nil = behind / off screen)
local function buildGrid(seed)
  local R, step = 30, 1.0
  local n = math.floor(2 * R / step) + 1
  local g = { x0 = seed.x - R, z0 = seed.z - R, step = step, n = n, u = {}, v = {} }
  local faceScreen = render.ProjectFace and render.ProjectFace.Screen or nil
  local onScreen = 0
  for i = 0, n - 1 do
    for j = 0, n - 1 do
      local x, z = g.x0 + i * step, g.z0 + j * step
      local y = groundY(x, z, seed.y)
      local p = faceScreen and render.projectPoint(vec3(x, y, z), faceScreen) or render.projectPoint(vec3(x, y, z))
      local k = i * n + j
      if p and p.x == p.x and p.y == p.y and math.abs(p.x) < 50 and math.abs(p.y) < 50 then
        g.u[k], g.v[k] = p.x, p.y
        if p.x >= 0 and p.x <= 1 and p.y >= 0 and p.y <= 1 then onScreen = onScreen + 1 end
      end
    end
  end
  g.onScreen = onScreen
  return g
end

-- Starts a screen capture around `seed` ({x, y, z}); poll PC.updateScreen() every frame.
function PC.requestScreen(seed)
  PC.screen = nil
  scr = { state = 'hide', frames = 0, seed = seed, tries = 0, t0 = os.clock() }
end

function PC.cancelScreen() scr = nil end

local function camState()
  local sim = ac.getSim()
  return { pos = vec3(sim.cameraPosition.x, sim.cameraPosition.y, sim.cameraPosition.z),
    look = vec3(sim.cameraLook.x, sim.cameraLook.y, sim.cameraLook.z), fov = sim.cameraFOV }
end

local function camMoved(a, b)
  if not a or not b then return true end
  local dp = (a.pos - b.pos):length()
  local dl = a.look:dot(b.look)
  return dp > 0.03 or dl < 0.99995 or math.abs((a.fov or 0) - (b.fov or 0)) > 0.05
end

function PC.updateScreen()
  if not scr then return end
  scr.frames = scr.frames + 1
  if os.clock() - scr.t0 > 12 then scr.state, scr.err = 'error', 'screenTimeout' return end
  if scr.state == 'hide' then
    -- two frames without the app's own drawings, then the shot
    if scr.frames >= 3 then scr.state = 'shoot' end
  elseif scr.state == 'shoot' then
    scr.cam = camState()
    local okG, g = pcall(buildGrid, scr.seed)
    if not okG then scr.state, scr.err = 'error', 'screenGrid: ' .. tostring(g) return end
    if g.onScreen < 60 then scr.state, scr.err = 'error', 'notVisible' return end
    scr.grid = g
    scr.masks = windowMasks()
    scr.state = 'wait'
    local fmt = ac.ScreenshotFormat and ac.ScreenshotFormat.PNG or nil
    local okS, e = pcall(ac.makeSimpleScreenshot, fmt, function(err, data)
      if not scr then return end
      if err or not data then scr.state, scr.err = 'error', 'screenshot: ' .. tostring(err or 'no data') return end
      if camMoved(scr.cam, camState()) then
        scr.tries = scr.tries + 1
        if scr.tries >= 4 then scr.state, scr.err = 'error', 'cameraMoving' return end
        scr.state, scr.frames = 'hide', 0
        return
      end
      if PC.debugDir then pcall(function() io.save(PC.debugDir .. '/festes_kepernyo.png', data) end) end
      scr.raw = data
      scr.state = 'decode'
      scr.decodeFrames = 0
    end)
    if not okS then scr.state, scr.err = 'error', 'screenshot: ' .. tostring(e) end
  elseif scr.state == 'decode' then
    scr.decodeFrames = scr.decodeFrames + 1
    if not scr.img then
      local okD, img = pcall(ui.decodeImage, scr.raw)
      if not okD or not img then scr.state, scr.err = 'error', 'decode' return end
      scr.img = img
    end
    local size = ui.imageSize(scr.img)
    if size.x < 16 or size.y < 16 then
      if scr.decodeFrames > 120 then scr.state, scr.err = 'error', 'decode' end
      return
    end
    scr.w, scr.h = math.floor(size.x), math.floor(size.y)
    local canvas = ui.ExtraCanvas(vec2(scr.w, scr.h), 1)
    canvas:clear(rgbm(1, 0, 1, 1))
    canvas:update(function() ui.drawImage(scr.img, vec2(0, 0), vec2(scr.w, scr.h)) end)
    scr.canvas = canvas
    scr.state = 'download'
    canvas:accessData(function(err, data)
      if not scr then return end
      if err or not data then scr.state, scr.err = 'error', 'download: ' .. tostring(err or 'no data') return end
      local g = scr.grid
      PC.screen = { data = data, w = scr.w, h = scr.h, x0 = g.x0, z0 = g.z0, step = g.step, n = g.n, u = g.u, v = g.v,
        masks = scr.masks, cam = scr.cam, onScreen = g.onScreen }
      pcall(function() ui.unloadImage(scr.img) end)
      scr.state = 'ready'
    end)
  end
end

local function masked(m, u, v)
  for _, r in ipairs(m) do
    if u >= r[1] and u <= r[3] and v >= r[2] and v <= r[4] then return true end
  end
  return false
end

local function screenColor(x, z)
  local S = PC.screen
  local fx, fz = (x - S.x0) / S.step, (z - S.z0) / S.step
  local i, j = math.floor(fx), math.floor(fz)
  local n = S.n
  if i < 0 or j < 0 or i >= n - 1 or j >= n - 1 then return 1, 0, 1 end
  local k00, k10, k01, k11 = i * n + j, (i + 1) * n + j, i * n + j + 1, (i + 1) * n + j + 1
  local u00, u10, u01, u11 = S.u[k00], S.u[k10], S.u[k01], S.u[k11]
  if not (u00 and u10 and u01 and u11) then return 1, 0, 1 end
  local tx, tz = fx - i, fz - j
  local u = (u00 * (1 - tx) + u10 * tx) * (1 - tz) + (u01 * (1 - tx) + u11 * tx) * tz
  local v = (S.v[k00] * (1 - tx) + S.v[k10] * tx) * (1 - tz) + (S.v[k01] * (1 - tx) + S.v[k11] * tx) * tz
  if u < 0 or v < 0 or u >= 1 or v >= 1 or masked(S.masks, u, v) then return 1, 0, 1 end
  S.data:colorTo(tmp, math.floor(u * S.w), math.floor(v * S.h))
  return tmp.r, tmp.g, tmp.b
end

-- Colour at a world point: r, g, b; nil if no loaded shot tile covers it yet (screen source: never nil,
-- unknown parts are magenta).
function PC.colorAt(x, z)
  if PC.useScreen then
    if PC.screen then return screenColor(x, z) end
    return 1, 0, 1
  end
  for i = #tiles, 1, -1 do
    local t = tiles[i]
    local px, py = toPixel(t, x, z)
    if px >= 2 and py >= 2 and px < PC.res - 2 and py < PC.res - 2 then
      t.data:colorTo(tmp, math.floor(px), math.floor(py))
      return tmp.r, tmp.g, tmp.b
    end
  end
  return nil
end

function PC.tileCount() return PC.useScreen and (PC.screen and 1 or 0) or #tiles end

-- Clears loaded images (keeps the remembered shot set-up and the source choice).
function PC.reset(keepShotLog)
  if keepShotLog then PC.shotLog = PC.log else PC.shotLog = nil end
  for _, t in ipairs(tiles) do if t.data and t.data.dispose then t.data:dispose() end end
  tiles = {}
  pending = nil
  PC.guessedMapping = false
  PC.lastError = nil
  PC.firstTile = nil
  PC.blank = false
  PC.log = {}
  if PC.screen and PC.screen.data and PC.screen.data.dispose then pcall(function() PC.screen.data:dispose() end) end
  PC.screen = nil
  scr = nil
  PC.useScreen = false
end

-- Summary for the debug file.
function PC.debugInfo()
  local S = PC.screen
  return {
    source = PC.useScreen and 'screen' or 'shot', variant = PC.variants[PC.variantIndex] and PC.variants[PC.variantIndex].id,
    workingVariant = PC.workingVariant, attempts = PC.log, shotAttempts = PC.shotLog, blank = PC.blank, guessedMapping = PC.guessedMapping,
    tiles = #tiles, firstTile = PC.firstTile, lastError = PC.lastError,
    screen = S and { w = S.w, h = S.h, onScreen = S.onScreen, windows = #(S.masks or {}),
      cam = S.cam and { x = S.cam.pos.x, y = S.cam.pos.y, z = S.cam.pos.z, lookY = S.cam.look.y, fov = S.cam.fov } } or nil,
    screenState = scr and scr.state, screenError = scr and scr.err,
  }
end

return PC
