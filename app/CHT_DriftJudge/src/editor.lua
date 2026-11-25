-- CHT Drift Judge – in-game layout editor (CSP only).
--
-- Ways to place points:
--  • Mouse: arm a placing mode, then click on the track (free camera F7 is the most comfortable).
--  • Car: “Pont az autóhoz” adds a point at a chosen point of the car (rear corner, front wheel, centre).
--  • Trace: while driving slowly along a painted line / wall, a point is added every few metres.

local geom = require('src/geom')
local layoutMod = require('src/layout')
local storage = require('src/storage')
local draw3d = require('src/draw3d')
local U = require('src/ui_common')

local editor = {}

local app
local mode = 'idle'        -- 'idle' | 'gateA' | 'gateB' | 'zone' | 'nogo'
local modeGate = nil
local gateDraftA = nil
local selectedZone = nil
local selectedGate = nil
local nogoDraft = {}
local hover = nil          -- {x,y,z} under the mouse
local undoStack, redoStack = {}, {}
local carSource = 'rearOuter'
local traceOn = false
local traceStep = 2.0
local traceLast = nil
local gateWidth = 16
local newLayoutName = ''
local confirmDelete = nil
local lastCarPoint = nil
local zoneQuery = ''
local schema = require('src/schema')
local zedit = require('src/zoneedit')
local movePick = nil          -- index of the point being moved (mode 'movePoint')
local PD = require('src/paintdetect')
local PC = require('src/paintcapture')
-- automatic zone from the painted marking (experimental)
local paint = { status = 'idle', type = 'OZ', tol = 0.12, target = 'new', edge = 'auto' }
local sliderDrag = {}         -- slider key -> true while dragging (one undo step per drag)
local icNudge = 0.10          -- metres per arrow press when moving an IC point

local sources = {
  { id = 'rearOuter', label = 'Hátsó sarok – külső (a pálya közepétől távolabbi)' },
  { id = 'rearInner', label = 'Hátsó sarok – belső' },
  { id = 'frontOuter', label = 'Első sarok – külső' },
  { id = 'frontInner', label = 'Első sarok – belső' },
  { id = 'wheelOuter', label = 'Első kerék – külső' },
  { id = 'wheelInner', label = 'Első kerék – belső' },
  { id = 'center', label = 'Autó közepe' },
}

function editor.init(a) app = a end

-- Selects a zone (used by the Teendők panel, the global search and the Eredmény tab).
function editor.selectZone(i)
  if not app.layout.zones[i] then return end
  selectedZone = i
  selectedGate = nil
  if mode == 'gateA' or mode == 'gateB' then mode = 'idle' end
  U.setOpen('ed_step3', true)
end

local function snapshot()
  local ok, text = pcall(JSON.stringify, app.layout)
  return ok and text or nil
end

local function pushUndo()
  local s = snapshot()
  if s then
    undoStack[#undoStack + 1] = s
    if #undoStack > 40 then table.remove(undoStack, 1) end
    redoStack = {}
  end
end

local function changed()
  app.dirty = true
  app.recompile()
end

local function restore(text)
  local parsed = JSON.parse(text)
  local l = layoutMod.sanitize(parsed)
  app.layout = l
  changed()
end

-- Raises a point onto the track surface (so lines are drawn on the asphalt).
local function snapToTrack(x, y, z)
  local hit = vec3()
  local d = physics.raycastTrack(vec3(x, y + 3, z), vec3(0, -1, 0), 20, hit)
  if d >= 0 then return { x = hit.x, y = hit.y, z = hit.z } end
  return { x = x, y = y, z = z }
end

-- Point of the car selected as source (world coords). “Outer” / “inner” are measured from the track's
-- AI spline (centre line), so the choice does not depend on left/right conventions.
local function carPoint(car, which, ref)
  local s = app.lastSample
  if not s then return nil end
  local p = car.position
  local x, z
  if which == 'center' then
    x, z = p.x, p.z
  else
    local ax, az, bx, bz
    if which == 'rearOuter' or which == 'rearInner' then
      ax, az, bx, bz = s.rlx, s.rlz, s.rrx, s.rrz
    elseif which == 'frontOuter' or which == 'frontInner' then
      ax, az, bx, bz = s.flx, s.flz, s.frx, s.frz
    else
      ax, az, bx, bz = s.w0x, s.w0z, s.w1x, s.w1z
    end
    -- once a line has been started, follow the corner closest to its last point (no side flips)
    if ref then
      local da = geom.dist(ax, az, ref.x, ref.z)
      local db = geom.dist(bx, bz, ref.x, ref.z)
      if da <= db then x, z = ax, az else x, z = bx, bz end
      return snapToTrack(x, p.y, z)
    end
    local outerWanted = which:find('Outer') ~= nil
    local cx, cz
    local prog = ac.worldCoordinateToTrackProgress(p)
    if prog >= 0 then
      local c = ac.trackProgressToWorldCoordinate(prog)
      cx, cz = c.x, c.z
    else
      -- no AI spline: use the point the car slides away from as “inside”
      local lv = car.localVelocity
      cx, cz = p.x - car.side.x * lv.x, p.z - car.side.z * lv.x
    end
    local da = geom.dist(ax, az, cx, cz)
    local db = geom.dist(bx, bz, cx, cz)
    local aOuter = da > db
    if outerWanted == aOuter then x, z = ax, az else x, z = bx, bz end
  end
  return snapToTrack(x, p.y, z)
end

-- Picks a default band side: towards the track centre (AI spline) from the reference line.
local function autoSide(zone)
  local pts = zone.points
  if #pts < 2 then return end
  local a, b = pts[#pts - 1], pts[#pts]
  local mid = vec3((a.x + b.x) / 2, (a.y + b.y) / 2, (a.z + b.z) / 2)
  local prog = ac.worldCoordinateToTrackProgress(mid)
  if prog < 0 then return end
  local c = ac.trackProgressToWorldCoordinate(prog)
  local side = geom.sideOf(a.x, a.z, b.x, b.z, c.x, c.z)
  -- geom.sideOf > 0 means left of a->b in (x right, z forward) terms, matching the scorer's side = +1
  if math.abs(side) > 1e-3 then zone.side = side > 0 and 1 or -1 end
end

-- carPos: position of the car when the point came from the car (the car is always on the track
-- side of the line, so it decides the band side reliably, even without an AI spline)
local function addPointToZone(zi, p, carPos)
  local z = app.layout.zones[zi]
  if not z then return end
  pushUndo()
  if z.type == 'IC' then
    -- an IC zone is one point: placing it again moves it
    z.points = { { x = p.x, y = p.y, z = p.z } }
    changed()
    return
  end
  z.points[#z.points + 1] = { x = p.x, y = p.y, z = p.z }
  if not z.sideSet and #z.points >= 2 then
    if carPos then
      local a, b = z.points[#z.points - 1], z.points[#z.points]
      local sd = geom.sideOf(a.x, a.z, b.x, b.z, carPos.x, carPos.z)
      if math.abs(sd) > 1e-3 then z.side = sd > 0 and 1 or -1 end
    elseif #z.points == 2 then
      autoSide(z)
    end
  end
  changed()
end

local function setGate(key, a, b)
  pushUndo()
  app.layout.gates[key] = { a = { x = a.x, y = a.y, z = a.z }, b = { x = b.x, y = b.y, z = b.z } }
  changed()
end

local function gateAtCar(key)
  local car = app.car()
  if not car then return end
  local p, side = car.position, car.side
  local h = gateWidth / 2
  local a = snapToTrack(p.x - side.x * h, p.y, p.z - side.z * h)
  local b = snapToTrack(p.x + side.x * h, p.y, p.z + side.z * h)
  setGate(key, a, b)
end

local function nextZoneName(t)
  local n = #app.layout.zones + 1
  return (layoutMod.zoneTypeShort[t] or t) .. ' ' .. n
end

local function addZone(t)
  pushUndo()
  local defaults = { OZ = 30, IZ = 20, WALL = 30, TNG = 20, IC = 15, LIMIT = 0 }
  local z = { id = 'z' .. tostring(math.floor(os.clock() * 1000)) .. tostring(#app.layout.zones + 1),
    name = nextZoneName(t), type = t, maxPoints = defaults[t] or 20, side = 1, points = {}, nogo = {} }
  app.layout.zones[#app.layout.zones + 1] = z
  selectedZone = #app.layout.zones
  selectedGate = nil
  mode = 'zone'
  changed()
end

---------------------------------------------------------------------------------------------------
-- Automatic zone from the painted marking (experimental)
---------------------------------------------------------------------------------------------------

local paintErrors = {
  nocolor = 'A kattintott ponton nem találtam festést (vagy a kép üres). Kattints pontosan a festett részre, ha kell, közelebbről.',
  flood = 'A festés színe túl hasonló a környezetéhez (az egész pályát elárasztaná). Csökkentsd a Színtűrést, vagy kattints a festés közepére.',
  open = 'A kattintás helyét nem zárja körbe festés, és a festett vonalak végei között sem találtam egyértelmű lezárást. Kattints a keret belsejébe, közel a közepéhez; ha a keretből nagyon sok hiányzik, rajzold kézzel.',
  blank = 'A felülnézeti kép üres: a CSP ezen a gépen / pályán nem rajzolta ki a pályát a képre (mind az 5 beállítást kipróbáltam).',
  network = 'Egy festett keret (vagy több összefutó vonal) VONALÁRA kattintottál. Kattints a keret BELSEJÉBE: a program a keretet a belsejéből ismeri fel.',
  small = 'Túl kicsi festett foltot találtam. Kattints a festés közepére, vagy növeld a Színtűrést.',
  capture = 'Nem sikerült képet készíteni a pályáról ebben a CSP-verzióban.',
  mapping = 'A felülnézeti kép és a pálya nem illeszkedik (a program nem tudta beazonosítani a kép irányát).',
  timeout = 'Túl sokáig tartott, megszakítottam.',
  icarea = 'IC pontnál a festett JELRE kattints (pötty, kis négyzet vagy a vonal azon része, ahol az érintési pont van) – nem az aszfaltra.',
  notVisible = 'A kattintott hely nem látszik jól a képernyőn. Állítsd a kamerát (F7) felülről a festett zóna fölé, hogy az egész zóna látszódjon, és ne takarja ablak.',
  cameraMoving = 'A kamera mozgott a képkészítés közben. Tartsd mozdulatlanul (egy pillanatra engedd el az egeret / billentyűket), és próbáld újra.',
  screenTimeout = 'A képernyőkép nem érkezett meg időben.',
  decode = 'A képernyőképet nem sikerült beolvasni.',
}
local function paintErrorText(code)
  if not code then return '?' end
  if paintErrors[code] then return paintErrors[code] end
  if tostring(code):find('^screenshot') then return 'A képernyőkép nem készült el (' .. tostring(code) .. ').' end
  return tostring(code)
end

local function isIC(t) return t == 'IC' end

local function writePaintDebug()
  pcall(function()
    local r, ch = paint.result, paint.choice
    storage.writeJSON(storage.debugDir() .. '/festes_utolso.json', {
      appVersion = app.version, csp = ac.getPatchVersion and ac.getPatchVersion() or nil, track = ac.getTrackFullID('/'),
      seed = paint.seed and { x = paint.seed.x, y = paint.seed.y, z = paint.seed.z }, type = paint.type, tol = paint.tol,
      status = paint.status, error = paint.err, shotError = paint.shotErr, errorInfo = paint.errInfo,
      sourceSetting = app.settings.ui.paintSource or 'auto', capture = PC.debugInfo(), pixels = paint.pixels,
      result = r and (r.kind and { kind = r.kind, x = r.x, z = r.z, extent = r.extent } or {
        mode = r.mode, length = r.length, width = r.width, thin = r.thin, pixels = r.pixels, color = r.color,
        paintBounded = r.paintBounded, freeEnds = r.freeEnds, walls = r.walls, mid = r.mid, left = r.left, right = r.right }) or nil,
      choice = ch and { edge = ch.edge, side = ch.side, zeroDist = ch.zeroDist, points = ch.simple } or nil,
    }, true)
  end)
end

-- which image source to use first: settings (auto / shot / screen) + what worked on this track before
local function paintRemembered()
  local t = app.settings.ui.paintCapture
  return type(t) == 'table' and t[storage.trackKey()] or nil
end

local function paintRemember(what)
  if type(app.settings.ui.paintCapture) ~= 'table' then app.settings.ui.paintCapture = {} end
  if app.settings.ui.paintCapture[storage.trackKey()] ~= what then
    app.settings.ui.paintCapture[storage.trackKey()] = what
    app.saveSoon()
  end
end

local function paintBeginDetect()
  paint.status = 'running'
  paint.waitNeed = nil
  local seed = paint.seed
  local opts = { h = PC.h, tol = paint.tol }
  local ic = isIC(paint.type)
  paint.co = coroutine.create(function()
    if ic then return PD.detectMark(seed.x, seed.z, PC.colorAt, opts) end
    return PD.detect(seed.x, seed.z, PC.colorAt, opts)
  end)
end

local function paintBeginScreen()
  PC.reset(true)   -- the shot attempts stay in the debug file
  PC.debugDir = storage.debugDir()
  PC.useScreen = true
  paint.usedScreen = true
  PC.requestScreen(paint.seed)
  paint.status = 'capturing'
end

local function paintStart(seed)
  PC.reset()
  PC.debugDir = storage.debugDir()
  paint.seed = seed
  paint.result, paint.choice, paint.err, paint.errInfo, paint.shotErr = nil, nil, nil, nil, nil
  paint.pixels, paint.frames = 0, 0
  paint.edge = 'auto'
  paint.usedScreen = false
  local src = app.settings.ui.paintSource or 'auto'
  local remembered = paintRemembered()
  if remembered and remembered ~= 'screen' then PC.setVariant(remembered) else PC.variantIndex = 1 end
  if src == 'screen' or (src == 'auto' and remembered == 'screen') then
    paintBeginScreen()
  else
    PC.useScreen = false
    paintBeginDetect()
  end
end

local function drivingDir(res)
  local a, b = res.mid[1], res.mid[#res.mid]
  local pa = ac.worldCoordinateToTrackProgress(vec3(a.x, paint.seed.y, a.z))
  local pb = ac.worldCoordinateToTrackProgress(vec3(b.x, paint.seed.y, b.z))
  if pa >= 0 and pb >= 0 and math.abs(pb - pa) > 1e-4 and math.abs(pb - pa) < 0.5 then
    if pb > pa then return b.x - a.x, b.z - a.z end
    return a.x - b.x, a.z - b.z
  end
  local car = app.car()
  if car then return car.look.x, car.look.z end
  return b.x - a.x, b.z - a.z
end

local function paintChoose()
  local res = paint.result
  if not res then return end
  local car = app.car()
  local cx, cz = car and car.position.x or paint.seed.x, car and car.position.z or paint.seed.z
  paint.carFar = car == nil or geom.dist(cx, cz, paint.seed.x, paint.seed.z) > 40
  if res.kind then
    -- IC: a single point
    paint.choice = { points = { { x = res.x, z = res.z } }, simple = { { x = res.x, z = res.z } }, edge = res.kind }
    return
  end
  local dx, dz = drivingDir(res)
  local edge = paint.edge
  if edge == 'auto' and paint.type == 'TNG' and res.thin then edge = 'mid' end
  paint.choice = PD.choose(res, dx, dz, cx, cz, edge)
  paint.choice.simple = PD.simplify(paint.choice.points, 0.04, 3.0)
end

-- errors after which the screen image is worth a try (the paint may be missing from the 3D shot)
local retryOnScreen = { nocolor = true, flood = true, open = true, small = true, blank = true, capture = true, mapping = true }

local function paintFail(code, info)
  local src = app.settings.ui.paintSource or 'auto'
  if not paint.usedScreen and src == 'auto' and retryOnScreen[code] then
    paint.shotErr = code
    writePaintDebug()
    paintBeginScreen()
    return
  end
  paint.status, paint.err, paint.errInfo = 'error', code, info
  writePaintDebug()
end

local function paintUpdate()
  if paint.status == 'capturing' then
    PC.updateScreen()
    local st, err = PC.screenState()
    if st == 'ready' then paintBeginDetect()
    elseif st == 'error' then paint.status, paint.err = 'error', err; writePaintDebug() end
    return
  end
  if paint.status ~= 'running' then return end
  paint.frames = paint.frames + 1
  if paint.frames > 60 * 120 then paint.status, paint.err = 'error', 'timeout'; writePaintDebug() return end
  if not PC.useScreen then
    if PC.busy() then return end
    if PC.blank then paintFail('blank') return end
    if paint.waitNeed and PC.colorAt(paint.waitNeed.x, paint.waitNeed.z) == nil then
      -- the requested tile arrived but still does not cover the point: capture failed / mapping wrong
      paintFail(PC.lastError and 'capture' or 'mapping')
      return
    end
  end
  paint.waitNeed = nil
  local t0 = os.clock()
  while os.clock() - t0 < 0.004 do
    local ok, what, x, z = coroutine.resume(paint.co)
    if not ok then
      PC.lastError = tostring(what)
      ac.error('CHT paint detect:', what)
      paint.status, paint.err = 'error', 'capture'
      writePaintDebug()
      return
    end
    if coroutine.status(paint.co) == 'dead' then
      -- `what` / `x` / `z` are the returned result / error code / error details
      if what then
        paint.result = what
        paint.status = 'preview'
        paintChoose()
        paintRemember(PC.useScreen and 'screen' or (PC.workingVariant or PC.variant().id))
        writePaintDebug()
      else
        paintFail(x or 'small', z)
      end
      return
    end
    if what == 'need' then
      paint.waitNeed = { x = x, z = z }
      if not PC.request(x, z, paint.seed.y) then paintFail(PC.blank and 'blank' or 'capture') end
      return
    elseif what == 'busy' then
      paint.pixels = x or paint.pixels
    end
  end
end

local zoneDefaults = { OZ = 30, IZ = 20, WALL = 30, TNG = 20, IC = 15, LIMIT = 0 }

local function paintAccept()
  local ch = paint.choice
  if not ch then return end
  pushUndo()
  local pts = {}
  for _, p in ipairs(ch.simple or ch.points) do pts[#pts + 1] = snapToTrack(p.x, paint.seed.y, p.z) end
  local z
  if paint.target == 'selected' and selectedZone and app.layout.zones[selectedZone] then
    z = app.layout.zones[selectedZone]
  else
    z = { id = 'z' .. tostring(math.floor(os.clock() * 1000)) .. tostring(#app.layout.zones + 1),
      name = nextZoneName(paint.type), type = paint.type, maxPoints = zoneDefaults[paint.type] or 20, points = {}, nogo = {} }
    app.layout.zones[#app.layout.zones + 1] = z
    selectedZone = #app.layout.zones
  end
  z.points = pts
  if ch.side then
    z.side = ch.side
    z.sideSet = true
  end
  if ch.zeroDist and (z.type == 'OZ' or z.type == 'IZ' or z.type == 'WALL') then
    z.zeroDist = math.floor(ch.zeroDist * 100 + 0.5) / 100
    local defFull = z.type == 'IZ' and app.cfg.izFullDist or (z.type == 'WALL' and app.cfg.wallFullDist or app.cfg.ozFullDist)
    if defFull > z.zeroDist * 0.5 then z.fullDist = math.floor(z.zeroDist * 0.3 * 100 + 0.5) / 100 end
  end
  selectedGate = nil
  mode = 'idle'
  paint.status = 'idle'
  PC.reset()
  changed()
  if isIC(z.type) then
    app.status(string.format('%s létrehozva a festésből (belső érintési pont).', z.name), U.col.green, 10)
  else
    app.status(string.format('%s létrehozva a festésből: %.1f m hosszú%s. A „Méret és helyzet” részben finomíthatod.', z.name,
      zedit.length(z.points), ch.zeroDist and string.format(', %.2f m széles', ch.zeroDist) or ''), U.col.green, 10)
  end
end

local function drawPolyline(pts, color, y, thick)
  for k = 1, #pts - 1 do
    local a, b = pts[k], pts[k + 1]
    for t = 0, (thick or 0) do
      render.debugLine(vec3(a.x, y + 0.08 + t * 0.03, a.z), vec3(b.x, y + 0.08 + t * 0.03, b.z), color)
    end
  end
end

local function paintRender3D()
  if paint.status == 'preview' and paint.result then
    local y = paint.seed.y
    render.setDepthMode(render.DepthMode.Off)
    local r = paint.result
    if r.kind then
      draw3d.marker({ x = r.x, y = y, z = r.z }, rgbm(0.4, 4, 4, 1), 'IC pont')
    else
      if not r.thin then
        drawPolyline(r.left, rgbm(0.3, 2.5, 3, 1), y)
        drawPolyline(r.right, rgbm(0.3, 2.5, 3, 1), y)
      end
      drawPolyline(r.mid, rgbm(1.5, 1.5, 1.5, 0.6), y)
      -- closed sides of an open frame (virtual walls): orange
      for _, w in ipairs(r.walls or {}) do drawPolyline({ w.a, w.b }, rgbm(4, 1.6, 0.2, 1), y, 1) end
      if paint.choice then drawPolyline(paint.choice.simple or paint.choice.points, rgbm(4, 0.4, 4, 1), y, 3) end
    end
    render.setDepthMode(render.DepthMode.Normal)
  elseif (paint.status == 'running' or paint.status == 'capturing') and paint.seed and not PC.overlaysHidden() then
    draw3d.marker(paint.seed, rgbm(4, 4, 0.5, 1), 'Felismerés…')
  end
end

function editor.overlaysHidden() return PC.overlaysHidden() end

---------------------------------------------------------------------------------------------------
-- 3D: hover + clicks (called from the render callback)
---------------------------------------------------------------------------------------------------

function editor.isPlacing() return mode ~= 'idle' end

function editor.render3D()
  local uis = ac.getUI()
  hover = nil
  if mode ~= 'idle' and not uis.wantCaptureMouse then
    local ray = render.createMouseRay()
    local d = ray:track()
    if d > 0 then
      local hp = ray.pos + ray.dir * d
      hover = { x = hp.x, y = hp.y, z = hp.z }
    end
  end

  local zsel = selectedZone and app.layout.zones[selectedZone]
  if hover and zsel and (mode == 'movePoint' or mode == 'insertPoint' or mode == 'deletePoint') then
    local pts = zsel.points
    local near = zedit.nearestPoint(pts, hover.x, hover.z, 2.5)
    if mode == 'movePoint' then
      if movePick and pts[movePick] then
        draw3d.marker(pts[movePick], rgbm(3, 1, 3, 1), string.format('%d. pont – kattints az új helyére', movePick))
        draw3d.marker(hover, rgbm(4, 4, 4, 1), 'Új hely')
      else
        if near then draw3d.marker(pts[near], rgbm(3, 3, 0.5, 1), string.format('%d. pont – kattints a mozgatáshoz', near)) end
        draw3d.marker(hover, rgbm(2, 2, 2, 1), (not near) and 'Kattints egy pont közelébe' or nil)
      end
    elseif mode == 'insertPoint' then
      local i = zedit.insertIndex(pts, hover.x, hover.z)
      draw3d.marker(hover, rgbm(0.5, 3, 0.5, 1), string.format('Új pont (%d. helyre)', i))
    else
      if near then draw3d.marker(pts[near], rgbm(3, 0.3, 0.3, 1), string.format('%d. pont törlése', near)) end
      draw3d.marker(hover, rgbm(2, 2, 2, 1), (not near) and 'Kattints egy pont közelébe' or nil)
    end
    if uis.isMouseLeftKeyClicked then
      if mode == 'movePoint' then
        if movePick and pts[movePick] then
          pushUndo(); pts[movePick] = { x = hover.x, y = hover.y, z = hover.z }; movePick = nil; changed()
        elseif near then
          movePick = near
        end
      elseif mode == 'insertPoint' then
        pushUndo(); zedit.insertPoint(pts, hover); changed()
      elseif near then
        pushUndo(); table.remove(pts, near); changed()
      end
    end
    hover = nil
  end

  if hover and mode == 'paint' then
    draw3d.marker(hover, rgbm(4, 4, 0.5, 1), 'Kattints a festett keret belsejébe / a festésre (' .. (layoutMod.zoneTypeShort[paint.type] or paint.type) .. ')')
    if uis.isMouseLeftKeyClicked then
      mode = 'idle'
      paintStart(hover)
    end
    hover = nil
  end
  paintRender3D()

  if hover then
    local label = ({ gateA = 'Kapu 1. pont', gateB = 'Kapu 2. pont', zone = 'Zóna pont', nogo = 'No-go pont' })[mode]
    local z = selectedZone and app.compiledByIndex and app.compiledByIndex[selectedZone]
    if z and mode == 'zone' then
      if z.type == 'IC' then
        local p = z.pl.pts[1]
        label = p and string.format('IC pont áthelyezése (most %.2f m-re van)', geom.dist(p.x, p.z, hover.x, hover.z)) or 'IC pont'
      else
        local _, lat = geom.project(z.pl, hover.x, hover.z)
        if lat then label = string.format('%s – %.2f m a vonaltól', label, math.abs(lat)) end
      end
    elseif mode == 'zone' and selectedZone and app.layout.zones[selectedZone] and app.layout.zones[selectedZone].type == 'IC' then
      label = 'IC pont'
    end
    draw3d.marker(hover, rgbm(4, 4, 4, 1), label)
    if mode == 'gateB' and gateDraftA then
      draw3d.drawDraft({ gateDraftA, hover }, false, rgbm(3, 3, 3, 1))
    end
    if uis.isMouseLeftKeyClicked then
      if mode == 'gateA' then
        gateDraftA = hover
        mode = 'gateB'
      elseif mode == 'gateB' then
        setGate(modeGate, gateDraftA, hover)
        gateDraftA = nil
        mode = 'idle'
      elseif mode == 'zone' and selectedZone then
        addPointToZone(selectedZone, hover)
      elseif mode == 'nogo' then
        nogoDraft[#nogoDraft + 1] = hover
      end
    end
  end
  if mode == 'gateB' and gateDraftA and not hover then
    draw3d.marker(gateDraftA, rgbm(3, 3, 3, 1), 'Kapu 1. pont')
  end
  if #nogoDraft > 0 then draw3d.drawDraft(nogoDraft, true) end
  if lastCarPoint and (traceOn or app.settings.ui.showCarPoint) then
    draw3d.marker(lastCarPoint, rgbm(0.3, 3, 3, 1), traceOn and 'Nyomkövetés' or nil)
  end
end

function editor.drawOptions()
  return { selectedZone = selectedZone, selectedGate = selectedGate, showPoints = mode ~= 'idle' }
end

-- Called every frame (trace while driving)
function editor.update(car)
  paintUpdate()
  if not car then return end
  if traceOn or app.settings.ui.showCarPoint then
    local ref = nil
    local z = selectedZone and app.layout.zones[selectedZone]
    if traceOn then
      ref = traceLast or (z and z.points[#z.points])
      -- only use a reference that is close by (a fresh start elsewhere should use outer/inner again)
      if ref and lastCarPoint and geom.dist(ref.x, ref.z, lastCarPoint.x, lastCarPoint.z) > 8 then ref = nil end
    end
    lastCarPoint = carPoint(car, carSource, ref)
  end
  if traceOn and selectedZone and lastCarPoint then
    if not traceLast or geom.dist(traceLast.x, traceLast.z, lastCarPoint.x, lastCarPoint.z) >= traceStep then
      addPointToZone(selectedZone, lastCarPoint, { x = car.position.x, z = car.position.z })
      traceLast = lastCarPoint
    end
  end
end

---------------------------------------------------------------------------------------------------
-- Tab UI
---------------------------------------------------------------------------------------------------

local function layoutFiles()
  ui.text('Pályaterv:')
  ui.sameLine()
  ui.setNextItemWidth(220)
  local names = storage.listLayouts()
  ui.combo('##layoutSel', app.layout.name .. (app.dirty and ' *' or ''), ui.ComboFlags.None, function()
    for _, n in ipairs(names) do
      if ui.selectable(n, n == app.layout.name) then
        app.loadLayout(n)
        undoStack, redoStack = {}, {}
        selectedZone, selectedGate, mode = nil, nil, 'idle'
      end
    end
  end)
  ui.sameLine()
  if U.button('Mentés', 70, false, storage.online and 'A pályaterv mentése ezen a gépen (a CSP saját tárolójába).' or 'A pályaterv mentése a Dokumentumok / CHT Drift Judge / layouts mappába.') then app.saveLayout() end
  ui.sameLine()
  if U.button('Visszavonás', 0, #undoStack == 0) then
    local s = snapshot()
    if s then redoStack[#redoStack + 1] = s end
    restore(table.remove(undoStack))
  end
  ui.sameLine()
  if U.button('Újra', 0, #redoStack == 0) then
    local s = snapshot()
    if s then undoStack[#undoStack + 1] = s end
    restore(table.remove(redoStack))
  end
  if not storage.online then
    ui.sameLine()
    if U.button('Mappa', 0, false, 'A pályatervek mappájának megnyitása (innen küldhető el a fájl).') then storage.openFolder(storage.layoutsDir()) end
  end
  ui.sameLine()
  if U.button('Másolás', 0, false, 'A pályaterv (JSON) a vágólapra kerül: így küldhető el, és így kerülhet fel a szerverre (GitHub layouts mappa), hogy mindenki megkapja.') then
    local ok, text = pcall(JSON.stringify, app.layout)
    if ok and type(ac.setClipboardText) == 'function' and pcall(ac.setClipboardText, text) then
      app.status('A pályaterv a vágólapon (' .. tostring(#text) .. ' karakter). Küldd el, vagy töltsd fel a GitHubra: layouts/' .. storage.trackKey() .. '/' .. app.layout.name .. '.json', U.col.green, 10)
    else
      app.status('Nem sikerült a vágólapra másolni.', U.col.red)
    end
  end
  if storage.online then
    U.text('Online változat: a pályaterv a szerverről (GitHub) jön' .. (app.serverLayouts[app.layout.name] and ' – ez a szerver változata.' or '.') ..
      ' A mentés csak ezen a gépen marad meg; a véglegeset a „Másolás” gombbal küldd el.', 12, U.col.dim)
  end

  ui.setNextItemWidth(220)
  newLayoutName = U.searchBox('newname', 'Új név…', newLayoutName, 220)
  ui.sameLine()
  if U.button('Új üres terv', 0, newLayoutName == '') then
    app.newLayout(newLayoutName)
    undoStack, redoStack = {}, {}
    selectedZone, selectedGate, mode = nil, nil, 'idle'
    newLayoutName = ''
  end
  ui.sameLine()
  if U.button('Mentés másként', 0, newLayoutName == '') then
    app.layout.name = newLayoutName
    app.saveLayout()
    newLayoutName = ''
  end
  if ui.itemHovered() then ui.setTooltip('Írj be egy nevet a mezőbe, utána ezzel a névvel menti el a tervet.') end

  if app.layout.weighting == 'auto' then
    ui.textColored(string.format('Zónák súlyozása: automatikus (hossz, ív, típus) → a zónák összesen %g pontot érnek, a stílus a többit (összesen 100). Részletek: 3. Zónák → Súlyozás.', layoutMod.zonePoints(app.cfg)), U.col.dim)
  elseif app.cfg.normalizeTotal ~= false then
    ui.textColored(string.format('Zónák súlya összesen: %g (kézi súlyozás) → a zónák összesen %g pontra arányosítva, a stílus a többit adja (összesen 100).', layoutMod.totalMaxPoints(app.layout, app.cfg), layoutMod.zonePoints(app.cfg)), U.col.dim)
  else
    ui.textColored(string.format('Zónák max pontja összesen: %g (arányosítás kikapcsolva).', layoutMod.totalMaxPoints(app.layout, app.cfg)), U.col.dim)
  end
end

-- Label of a zone in the zone list (also used by the offline tests).
function editor.zoneLabel(i)
  local z = app.layout.zones[i]
  if not z then return '' end
  if z.type == 'LIMIT' then
    return string.format('%d. %s  [HATÁR]  pályahatár  (%d pont a vonalon)###zone%d', i, z.name, #z.points, i)
  end
  local w = layoutMod.zoneWeight(app.layout, z, app.cfg)
  local wtxt = layoutMod.isAutoWeighted(app.layout, z) and string.format('auto súly %.1f', w) or string.format('súly %g', z.maxPoints or 0)
  local eff = app.cfg.normalizeTotal ~= false and layoutMod.effectivePoints(app.layout, z, app.cfg) or w
  if z.type == 'IC' then
    return string.format('%d. %s  [IC]  %s → %.1f pont  (%s)###zone%d', i, z.name, wtxt, eff, #z.points > 0 and 'pont lerakva' or 'nincs pontja', i)
  end
  return string.format('%d. %s  [%s]  %s → %.1f pont  (%d pont a vonalon)###zone%d', i, z.name, layoutMod.zoneTypeShort[z.type], wtxt, eff, #z.points, i)
end

-- Zone weights: automatic (from length, curve and type) or manual, and per zone a fixed weight.
local function weightPanel()
  local l = app.layout
  local auto = l.weighting == 'auto'
  U.collapsible('ed_weights', 'Súlyozás – melyik zóna mennyit ér', { defaultOpen = false,
    sub = auto and 'automatikus: hossz, ív, típus (zónánként felülírható)' or 'kézi: minden zóna súlyát te adod meg',
    tip = 'A zónák súlyából lesz a zónák pontja (alap: 80 a 100-ból, a többi 20 a stílus). Automatikusan a hosszabb és jobban kanyarodó zóna többet ér; zónánként saját súly is megadható.' }, function()
    U.text('Súlyozás módja:', 13, U.col.text)
    ui.sameLine(0, 6)
    if U.button('Automatikus' .. (auto and ' (aktív)' or '') .. '##wAuto', 0, false,
      'A program a zóna hossza, íve és típusa alapján súlyoz. A képletet a Beállítások → Zónák automatikus súlyozása részben hangolhatod.') and not auto then
      pushUndo(); l.weighting = 'auto'; changed()
    end
    ui.sameLine(0, 6)
    if U.button('Kézi' .. (not auto and ' (aktív)' or '') .. '##wManual', 0, false,
      'Minden zóna súlyát te adod meg. Átváltáskor a mostani automatikus arányok maradnak meg kiindulásnak.') and auto then
      pushUndo(); layoutMod.freezeAutoWeights(l, app.cfg); l.weighting = 'manual'; changed()
    end
    if auto then
      U.wrapped(string.format('Képlet: súly = típusszorzó × hossz^%.2f × (1 + %.2f × ív / 90°); %.0f m-nél rövidebb zóna %.0f m-nek számít. '
        .. 'A „Saját” pipával egy zónának fix súlyt adhatsz – a többi automatikus marad.',
        app.cfg.autoLengthExp, app.cfg.autoCurveFactor, app.cfg.autoMinLength, app.cfg.autoMinLength), 12, U.col.dim)
    else
      U.text('Kézi súlyozás: a csúszkával add meg a zónák súlyát; a zónák pontja ezek arányában oszlik el.', 12, U.col.dim)
    end
    local total = layoutMod.totalMaxPoints(l, app.cfg)
    for i, z in ipairs(l.zones) do
      if z.type ~= 'LIMIT' then
        ui.pushID('w' .. i)
        local w, parts = layoutMod.autoWeight(z, app.cfg)
        local eff = total > 0 and layoutMod.zoneWeight(l, z, app.cfg) / total * 100 or 0
        U.text(string.format('%s  [%s]', z.name, layoutMod.zoneTypeShort[z.type] or z.type), 14, U.col.text, true)
        ui.sameLine(170)
        U.text(string.format('%.1f m · ív %.0f°', parts.length, parts.turn), 12, U.col.dim)
        ui.sameLine(300)
        if layoutMod.isAutoWeighted(l, z) then
          U.text(string.format('auto súly %.2f', w), 13, U.col.cyan)
          U.tip(string.format('hossz: %.1f m%s → %.2f · ív %.0f° → ×%.2f · típus ×%.2f', parts.length,
            parts.lengthUsed > parts.length + 1e-6 and string.format(' (min. %.0f m-nek számít)', parts.lengthUsed) or '', parts.lenPart,
            parts.turn, parts.curvePart, parts.typePart))
        else
          ui.setNextItemWidth(130)
          local nv, c = ui.slider('##wv', z.maxPoints or 20, 0, 100, 'súly %.0f', 1)
          U.tip('A zóna saját súlya. A zónák pontja a súlyok arányában oszlik el.')
          if c then z.maxPoints = math.floor(nv + 0.5); changed() end
        end
        ui.sameLine(450)
        U.text(string.format('→ %.1f pont', eff), 14, U.col.green, true)
        if auto then
          ui.sameLine(560)
          if ui.checkbox('Saját##wl', z.weightLock == true) then
            pushUndo()
            if z.weightLock then z.weightLock = nil
            else z.weightLock = true; z.maxPoints = math.floor(w / math.max(total, 1e-6) * 100 + 0.5) end
            changed()
          end
          U.tip('Bepipálva ennek a zónának saját, fix súlya van (kiindulásnak a mostani pontja); a többi zóna automatikus marad.')
        end
        ui.popID()
      end
    end
  end)
end

local function modeHint()
  if mode == 'gateA' then return 'Kattints a pályára: kapu első pontja (' .. layoutMod.gateNames[modeGate] .. ')' end
  if mode == 'gateB' then return 'Kattints a pályára: kapu második pontja' end
  if mode == 'zone' then
    local z = selectedZone and app.layout.zones[selectedZone]
    if z and z.type == 'IC' then return 'Kattints a pályára oda, ahol a belső érintési pont (IC) van – újra kattintva áthelyezed.' end
    return 'Kattintással pontokat adsz a kijelölt zóna vonalához (a haladási irányban haladj).'
  end
  if mode == 'nogo' then return 'Kattints a no-go terület sarkaira, majd „Sokszög lezárása”.' end
  if mode == 'paint' then return 'Kattints: festett keretnél a keret BELSEJÉBE, teli festésnél a festésre, vonalnál a vonalra (szabad kamera, F7, felülről a legjobb).' end
  if mode == 'movePoint' then return movePick and 'Kattints a pályán oda, ahová a kijelölt pontot tenni akarod.' or 'Kattints a mozgatandó pont közelébe (2,5 m-en belül).' end
  if mode == 'insertPoint' then return 'Kattints a vonal mellé: az új pont a két legközelebbi pont közé kerül (a végeken túl kattintva a vonalat hosszabbítja).' end
  if mode == 'deletePoint' then return 'Kattints a törlendő pont közelébe (2,5 m-en belül).' end
  return nil
end

local function gatesSection()
  U.text('START (opcionális) → JUDGING (itt kezdődik a bírálat) → FINISH (vége). Állj az autóval a vonalra, és nyomd meg „Az autó helyére” gombot.', 12, U.col.dim)
  ui.setNextItemWidth(120)
  gateWidth = ui.slider('##gw', gateWidth, 4, 40, 'Kapu szélesség: %.0f m')
  for _, key in ipairs(layoutMod.gateOrder) do
    local g = app.layout.gates[key]
    ui.text(string.format('%-8s', layoutMod.gateNames[key]))
    ui.sameLine(90)
    ui.textColored(g and 'megvan' or 'nincs', g and U.col.green or U.col.orange)
    ui.sameLine(160)
    if U.button('Egérrel##' .. key, 70, false, 'Kattints két pontot a pályán (szabad kamera: F7).') then mode, modeGate, gateDraftA = 'gateA', key, nil; selectedGate = key end
    ui.sameLine()
    if U.button('Az autó helyére##' .. key, 110, false, 'Az autó jelenlegi helyére teszi a kaput, merőlegesen a haladási irányra.') then gateAtCar(key); selectedGate = key end
    ui.sameLine()
    if U.button('Törlés##g' .. key, 60, not g) then pushUndo(); app.layout.gates[key] = nil; changed() end
  end
  ui.textColored('A START opcionális: ha nincs, a futás a JUDGING vonalnál indul.', U.col.dim)
end

local paintSources = {
  { id = 'auto', label = 'Automatikus', tip = 'Először a pálya felülnézeti képét próbálja (5 beállítással); ha az üres, vagy nem találja rajta a festést, a képernyőn látható képből dolgozik. Ami egyszer bevált, azt a pályán legközelebb is azzal kezdi.' },
  { id = 'shot', label = 'Felülnézeti kép', tip = 'Csak a pálya 3D modelljéből készített felülnézeti kép (árnyék nélkül; a kamera állása mindegy).' },
  { id = 'screen', label = 'Képernyő (amit látsz)', tip = 'A képernyőn látható kép: állítsd a kamerát (F7) felülről a festett zóna fölé, és ne takarja ablak. Ez a szerver / pálya script által rajzolt festést is látja.' },
}

local function paintPanel()
  U.collapsible('ed_paint', 'Zóna a festésből (automatikus, kísérleti)', { defaultOpen = false,
    sub = 'kattints a festett zónára – a program lerakja és beállítja a méretét',
    tip = 'A festett vonalakból készít zónát: a hosszát és a szélességét is a festés adja. Nyitott (egy oldalán hiányzó) vagy kopott, hézagos keretet is lezár.' }, function()
    U.wrapped('1) Állj az autóval a pályán a festett zóna mellé, menetirányba nézve (ebből tudja, melyik oldal a pálya), de ne takarja az autó a festést. '
      .. '2) Válaszd ki a zóna típusát. 3) Állítsd a kamerát (F7) felülről a zóna fölé, nyomd meg az „Indítás” gombot, és kattints: '
      .. 'FESTETT KERETNÉL a keret BELSEJÉBE; teli festett területnél a festésre; egyetlen festett vonalnál a vonalra; IC pontnál a festett jelre. '
      .. 'A keretnek nem kell zártnak lennie: ha egy oldala hiányzik vagy kopott, a vonalvégek között lezárja (narancs vonal az előnézetben). '
      .. '4) Nézd meg az előnézetet (lila vonal = a zóna vonala), és fogadd el. Keretnél a zóna vonala az autótól távolabbi oldal, a szélessége a keret szélessége.', 12, U.col.dim)
    U.text('Típus:', 13, U.col.text)
    for _, t in ipairs({ 'OZ', 'IZ', 'TNG', 'IC', 'LIMIT' }) do
      ui.sameLine(0, 6)
      if U.button((layoutMod.zoneTypeShort[t] or t) .. (paint.type == t and ' (kiválasztva)' or '') .. '##pt' .. t, 0, false, layoutMod.zoneTypeNames[t]) then paint.type = t end
    end
    U.text('Kép forrása:', 13, U.col.text)
    local src = app.settings.ui.paintSource or 'auto'
    for _, ps in ipairs(paintSources) do
      ui.sameLine(0, 6)
      if U.button(ps.label .. (src == ps.id and ' (aktív)' or '') .. '##psrc' .. ps.id, 0, false, ps.tip) then
        app.settings.ui.paintSource = ps.id
        app.saveSoon()
      end
    end
    local rem = paintRemembered()
    if rem then
      U.text('Ezen a pályán legutóbb bevált: ' .. (rem == 'screen' and 'képernyőkép' or ('felülnézeti kép (' .. rem .. ')')), 12, U.col.dim)
      ui.sameLine(0, 8)
      if U.button('Elfelejt##psForget', 0, false, 'Legközelebb újra az elejéről próbálja a képkészítési módokat.') then
        app.settings.ui.paintCapture[storage.trackKey()] = nil
        app.saveSoon()
      end
    end
    if ui.checkbox('A kijelölt zóna vonalát cserélje (új zóna helyett)##ptsel', paint.target == 'selected') then
      paint.target = paint.target == 'selected' and 'new' or 'selected'
    end
    U.tip('Bekapcsolva nem új zóna készül: a listában kijelölt zóna kapja meg a felismert vonalat és szélességet.')
    paint.tol = U.sliderInput('ptTol', 'Színtűrés', paint.tol, 0.04, 0.30, '%.2f', 200,
      'Mennyire térhet el a szín a kattintott ponttól. Ha a felismerés túl kevés festést talál, növeld; ha az aszfaltra is ráfolyik, csökkentsd.')
    if paint.status == 'capturing' then
      U.text('Képernyőkép készül… tartsd mozdulatlanul a kamerát.', 13, U.col.yellow, true)
      if U.button('Mégse##ptCancel', 0) then paint.status = 'idle'; PC.reset() end
    elseif paint.status == 'running' then
      U.text(string.format('Felismerés folyamatban… %d képpont · forrás: %s', paint.pixels or 0,
        PC.useScreen and 'képernyő' or ('felülnézeti kép, ' .. PC.variant().label)), 13, U.col.yellow, true)
      if U.button('Mégse##ptCancel', 0) then paint.status = 'idle'; PC.reset() end
    else
      if U.button(mode == 'paint' and 'Kattints a festésre… (mégse)##ptGo' or 'Indítás – kattintás a festett zónára##ptGo', 0, false,
        'Utána kattints a pályán a festett zóna közepére (keretnél a belsejébe).') then
        mode = mode == 'paint' and 'idle' or 'paint'
        if mode == 'paint' then paint.status = 'idle' end
      end
    end
    if paint.status == 'error' then
      local extra = ''
      local info = paint.errInfo
      if paint.err == 'open' and type(info) == 'table' then
        if info.unknown then extra = extra .. ' A zóna egy része nem látszott a képen (kilóg a képernyőről, vagy ablak / autó takarja) – állítsd a kamerát úgy, hogy az egész keret látszódjon.' end
        if (info.freeEnds or 0) > 0 then extra = extra .. string.format(' %d szabad vonalvéget találtam, de nem tudtam egyértelműen párosítani.', info.freeEnds) end
      end
      if paint.shotErr then extra = extra .. ' (A felülnézeti képpel sem sikerült: ' .. paintErrorText(paint.shotErr) .. ')' end
      local b = U.notice('ptErr', 'warn', 'Nem sikerült a felismerés', paintErrorText(paint.err) .. extra
        .. (PC.lastError and (' (' .. PC.lastError .. ')') or '')
        .. ' A képek és az adatok elmentve: Dokumentumok / CHT Drift Judge / debug (festes_*.png és festes_utolso.json) – ezeket küldd el, ha nem érted, mi a baj.',
        { { 'Debug mappa megnyitása', 'Megnyitja a mappát, ahol a képek vannak.' } })
      if b == 1 then storage.openFolder(storage.debugDir()) end
    end
    if paint.status == 'preview' and paint.result and paint.choice then
      local r, ch = paint.result, paint.choice
      local srcTxt = PC.useScreen and 'képernyőkép' or 'felülnézeti kép'
      if r.kind then
        U.notice('ptPrev', 'info', r.kind == 'mark' and 'Felismerve: festett jel (IC pont a közepén)' or 'Felismerve: festett vonal (IC pont a vonalon, a kattintás mellett)',
          string.format('Forrás: %s. ', srcTxt) .. (r.kind == 'mark' and string.format('A jel mérete kb. %.2f m. ', r.extent or 0) or '')
          .. 'Az IC pontot a pályán türkiz kereszt mutatja.')
      else
        local kind = r.thin and string.format('festett vonal, %.2f m széles', r.width)
          or (r.mode == 'area' and string.format('festett keret / terület, %.2f m széles', r.width) or string.format('festett terület, %.2f m széles', r.width))
        local edgeTxt = ({ far = 'az autótól távolabbi oldal' .. (r.mode == 'area' and ' (keretnél a festett vonal közepe)' or ''),
          near = 'az autóhoz közelebbi oldal', mid = 'a festés / keret közepe' })[ch.edge] or ch.edge
        local walls = #(r.walls or {})
        U.notice('ptPrev', 'info', string.format('Felismerve: %s, %.1f m hosszú', kind, r.length),
          'A zóna vonala (lila a pályán): ' .. edgeTxt .. '. ' .. (ch.zeroDist and string.format('A zóna szélessége: %.2f m. ', ch.zeroDist) or '')
          .. (walls > 0 and string.format('A keret nyitott / hézagos volt: %d helyen lezártam a vonalvégek között (narancs vonal). ', walls) or '')
          .. string.format('%d pontból áll. Forrás: %s. Ha nem a festésen fut, vagy rossz széle lett kiválasztva, használd a lenti gombokat.', #(ch.simple or ch.points), srcTxt)
          .. (paint.carFar and ' FIGYELEM: az autó messze van – a pálya oldalát lehet, hogy rosszul találta ki.' or '')
          .. (PC.guessedMapping and not PC.useScreen and ' FIGYELEM: a kép irányát becsülni kellett – nézd meg, a lila vonal tényleg a festésen fut-e.' or ''))
      end
      local label = paint.target == 'selected' and selectedZone and app.layout.zones[selectedZone]
        and ('Elfogadás: ' .. app.layout.zones[selectedZone].name .. ' vonala lesz##ptOk') or ('Elfogadás: új ' .. (layoutMod.zoneTypeShort[paint.type] or paint.type) .. ' zóna##ptOk')
      if U.button(label, 0, false, 'Létrehozza (vagy frissíti) a zónát a felismert vonallal és szélességgel. Visszavonható.') then paintAccept() end
      if not r.kind then
        if not r.thin then
          ui.sameLine(0, 6)
          if U.button('Másik szél##ptEdge', 0, false, 'A festett terület másik széle legyen a zóna vonala.') then
            paint.edge = (ch.edge == 'near') and 'far' or 'near'
            paintChoose()
          end
        end
        ui.sameLine(0, 6)
        if U.button((ch.edge == 'mid' and 'Szél használata' or 'Középvonal') .. '##ptMid', 0, false, 'A festés közepe legyen a vonal (vagy vissza a szélre).') then
          paint.edge = ch.edge == 'mid' and 'far' or 'mid'
          paintChoose()
        end
      end
      ui.sameLine(0, 6)
      if U.button('Elvetés##ptNo', 0) then paint.status = 'idle'; PC.reset() end
    end
  end)
end

local function zoneList(zoneIss)
  paintPanel()
  weightPanel()
  U.text('Új zóna:', 13, U.col.dim)
  for _, t in ipairs(layoutMod.zoneTypes) do
    ui.sameLine(0, 6)
    if U.button('+ ' .. (layoutMod.zoneTypeShort[t]), 64, false, layoutMod.zoneTypeNames[t]) then addZone(t) end
  end
  if #app.layout.zones > 5 or zoneQuery ~= '' then
    zoneQuery = U.searchBox('zoneq', 'Zóna keresése (név, típus, hiba)…', zoneQuery, 320)
  end
  if #app.layout.zones == 0 then
    U.text('Még nincs zóna. Adj hozzá egyet a fenti gombokkal, majd rajzold meg a vonalát.', 13, U.col.dim)
  end
  for i, z in ipairs(app.layout.zones) do
    local iss = zoneIss[i]
    local hay = z.name .. ' ' .. (layoutMod.zoneTypeShort[z.type] or '') .. ' ' .. (layoutMod.zoneTypeNames[z.type] or '')
    for _, it in ipairs(iss or {}) do hay = hay .. ' ' .. it.short .. ' hiba javít' end
    if schema.textMatches(hay, zoneQuery) then
      local label = editor.zoneLabel(i)
      if ui.selectable(label, selectedZone == i) then editor.selectZone(i) end
      for _, it in ipairs(iss or {}) do
        ui.indent(18)
        if it.acked then
          U.text('jóváhagyva: ' .. it.short, 12, U.col.dim)
        else
          U.text((it.level == 'error' and 'HIBA: ' or 'FIGYELEM: ') .. it.short, 12, U.levelColors[it.level], true)
        end
        ui.unindent(18)
      end
    end
  end
end

local function startTrace()
  traceOn = true
  traceLast = nil
  pushUndo()
end

local function zoneDetails(zoneIss)
  local z = selectedZone and app.layout.zones[selectedZone]
  if not z then
    U.text('Jelölj ki egy zónát a listában a szerkesztéshez.', 13, U.col.dim)
    return
  end
  ui.separator()
  U.text('Kijelölt zóna: ' .. z.name, 17, U.col.text, true)
  ui.sameLine(0, 10)
  U.text(layoutMod.zoneTypeNames[z.type] or z.type, 12, U.col.dim)
  for k, it in ipairs(zoneIss[selectedZone] or {}) do
    if it.acked then
      U.text('Jóváhagyva: ' .. it.short .. ' – rendben van így.', 12, U.col.dim)
      ui.sameLine(0, 8)
      if U.button('Jóváhagyás visszavonása##unack' .. k, 0, false, 'Újra figyelmeztet erre a Teendők között.') then app.ackZoneIssue(selectedZone, it.kind, false) end
    else
      local lineFix = it.kind == 'zoneLine' or it.kind == 'twoPoints' or it.kind == 'noLine' or it.kind == 'zigzag'
      local buttons = {}
      if lineFix and z.type == 'IC' then
        buttons[#buttons + 1] = { 'Pont kattintással', 'Kattints a pályára oda, ahol az érintési pont van (szabad kamera, F7).' }
        lineFix = false
      end
      if lineFix then
        buttons[#buttons + 1] = { 'Nyomkövetés indítása', 'Lassan vezess végig a vonalon: a kiválasztott autópontból folyamatosan rajzol.' }
        buttons[#buttons + 1] = { 'Pontok törlése és újrarajzolás', 'Törli a zóna pontjait (visszavonható), és bekapcsolja a kattintásos pontfelvételt.' }
      end
      if it.ackable then
        buttons[#buttons + 1] = { 'Rendben, így jó', 'Jóváhagyod, hogy ez így rendben van. A pályatervbe mentődik; ha a zóna vonala megváltozik, újra szól.' }
      end
      local b = U.notice('zi' .. k, it.level, (it.level == 'error' and 'Ezt javítani kell: ' or 'Ellenőrizd: ') .. it.short,
        it.text .. (it.fix and (' Teendő: ' .. it.fix) or ''), buttons)
      local which = b and buttons[b][1]
      if which == 'Pont kattintással' then mode = 'zone'
      elseif which == 'Nyomkövetés indítása' then startTrace()
      elseif which == 'Pontok törlése és újrarajzolás' then pushUndo(); z.points = {}; changed(); mode = 'zone'
      elseif which == 'Rendben, így jó' then app.ackZoneIssue(selectedZone, it.kind, true) end
    end
  end

  U.collapsible('ed_z_basic', 'Alapadatok', { sub = 'név, típus, súly' }, function()
  ui.setNextItemWidth(180)
  local name, nameChanged = ui.inputText('Név##zn', z.name)
  if nameChanged then z.name = name; app.dirty = true end

  ui.setNextItemWidth(180)
  ui.combo('Típus##zt', layoutMod.zoneTypeShort[z.type] .. ' – ' .. layoutMod.zoneTypeNames[z.type], ui.ComboFlags.None, function()
    for _, t in ipairs(layoutMod.zoneTypes) do
      if ui.selectable(layoutMod.zoneTypeNames[t], z.type == t) then pushUndo(); z.type = t; changed() end
    end
  end)

  if z.type == 'LIMIT' then
    ui.textColored('Pályahatár: ha egy kerék a vonalon túlra kerül (a sávval ellentétes oldalra), az pályaelhagyásnak számít.', U.col.dim)
    ui.textColored('A rövid piros jelek a pálya (bent) felé mutatnak. Ha fordítva állnak: „Oldal megfordítása”.', U.col.dim)
  else
    if layoutMod.isAutoWeighted(app.layout, z) then
      local w, parts = layoutMod.autoWeight(z, app.cfg)
      U.text(string.format('Súly: automatikus %.2f  (%.1f m, ív %.0f°, %s)', w, parts.length, parts.turn, layoutMod.zoneTypeShort[z.type] or z.type), 13, U.col.cyan)
    else
      local mp, mpc = U.sliderRow(app.layout.weighting == 'auto' and 'Saját súly' or 'Max pont (súly)', z.maxPoints or 20, 0, 100, '%.0f', true)
      if mpc then z.maxPoints = mp; changed() end
    end
    if app.layout.weighting == 'auto' then
      if ui.checkbox('Saját súly ennél a zónánál (különben automatikus)##wlock', z.weightLock == true) then
        pushUndo()
        if z.weightLock then z.weightLock = nil
        else
          local total = layoutMod.totalMaxPoints(app.layout, app.cfg)
          z.weightLock = true
          z.maxPoints = math.floor(layoutMod.zoneWeight(app.layout, z, app.cfg) / math.max(total, 1e-6) * 100 + 0.5)
        end
        changed()
      end
    end
    if app.cfg.normalizeTotal ~= false then
      ui.textColored(string.format('A 100-ból ennyit ér: %.1f pont (a zónák összesen %g, a stílus %g)', layoutMod.effectivePoints(app.layout, z, app.cfg), layoutMod.zonePoints(app.cfg), 100 - layoutMod.zonePoints(app.cfg)), U.col.dim)
    end
    U.text(string.format('A súlyokból lesz a zónák pontja: a zóna súlya / az összes súly × %g. Az összes zóna: 3. Zónák → Súlyozás.', layoutMod.zonePoints(app.cfg)), 12, U.col.dim)
  end
  end)

  local sizeSub = z.type == 'IC' and 'a pont körüli sávok, a pont helye' or string.format('hossz %.1f m · szélesség, hossz, eltolás, pontok', zedit.length(z.points))
  U.collapsible('ed_z_size', 'Méret és helyzet', { sub = sizeSub }, function()
    local cfg = app.cfg
    local function snap(x, y, zz) return snapToTrack(x, y, zz) end
    -- slider + typed value; one undo step per drag or per typed value
    local function sliderOverride(label, key, def, min, max, fmt, tip)
      local v = z[key] ~= nil and z[key] or def
      local nv, c, how = U.sliderInput('sz_' .. key, label, v, min, max, fmt, 220, tip, { hardMin = min, hardMax = max })
      if c then
        if how == 'typed' then pushUndo()
        elseif not sliderDrag[key] then pushUndo(); sliderDrag[key] = true end
        z[key] = nv; changed()
      elseif sliderDrag[key] and not ui.itemActive() then
        sliderDrag[key] = nil
      end
      if z[key] ~= nil then
        ui.sameLine(0, 8)
        U.pill('saját · általános: ' .. string.format(fmt, def), U.col.purple)
        ui.sameLine(0, 6)
        if U.button('Alapra##sza_' .. key, 0, false, 'Visszaáll a Beállítások értékére.') then pushUndo(); z[key] = nil; changed() end
      end
    end
    U.text('Minden érték csúszkával vagy a mellette lévő mezőbe beírva is megadható (Enter).', 12, U.col.dim)
    if z.type == 'IC' then
      U.text('IC pont: az első lökhárító legkisebb távolsága a ponttól. A pályán a türkiz körök mutatják a két távolságot.', 12, U.col.dim)
      sliderOverride('Zóna sugara (itt már 0% Line)', 'zeroDist', cfg.icZeroDist, 0.3, 8, '%.2f m',
        'Ennél messzebb a lökhárító a ponttól = 0% Line. A pályán a halvány külső kör.')
      sliderOverride('Teljes pont sugara (eddig 100% Line)', 'fullDist', cfg.icFullDist, 0, 3, '%.2f m',
        'Eddig a távolságig jár a teljes Line pont. A pályán az erősebb belső kör.')
      local p = z.points[1]
      if p then
        U.text(string.format('A pont helye: x %.2f, z %.2f', p.x, p.z), 12, U.col.dim)
        U.text('Áthelyezés pontosan (m):', 13, U.col.text)
        icNudge = U.numberBox('icNudge', icNudge, 0.01, 5, '%.2f', 62, 'Ennyi métert lép a pont a nyilakkal.', 0.01, 5)
        local car = app.car()
        local fx, fz = car and car.look.x or 0, car and car.look.z or 1
        local fl = math.sqrt(fx * fx + fz * fz)
        if fl > 1e-6 then fx, fz = fx / fl, fz / fl end
        for _, d in ipairs({ { 'Előre', fx, fz }, { 'Hátra', -fx, -fz }, { 'Balra', -fz, fx }, { 'Jobbra', fz, -fx } }) do
          ui.sameLine(0, 6)
          if U.button(d[1] .. '##icn' .. d[1], 0, false, 'Az autó menetirányához képest mozgatja a pontot.') then
            pushUndo()
            z.points[1] = snap(p.x + d[2] * icNudge, p.y, p.z + d[3] * icNudge)
            changed()
          end
        end
      end
    elseif z.type == 'OZ' or z.type == 'IZ' or z.type == 'WALL' then
      local full, zero = cfg.ozFullDist, cfg.ozZeroDist
      if z.type == 'IZ' then full, zero = cfg.izFullDist, cfg.izZeroDist
      elseif z.type == 'WALL' then full, zero = cfg.wallFullDist, cfg.wallZeroDist end
      U.text('Szélesség: meddig ér ki a zóna a vonaltól a pálya felé (a pályán a színes sáv mutatja). Ha a sáv nem a pálya felé esik: „Oldal megfordítása” a Vonal és pontok részben.', 12, U.col.dim)
      sliderOverride('Zóna szélessége (itt már 0% Line)', 'zeroDist', zero, 0.3, 8, '%.2f m',
        'Ennél messzebb a vonaltól a Line 0. A pályán a halvány sáv széle.')
      sliderOverride('Teljes pont sávja (eddig 100% Line)', 'fullDist', full, 0, 3, '%.2f m',
        'A vonaltól eddig a távolságig jár a teljes Line pont. A pályán az erősebb színű sáv.')
    elseif z.type == 'TNG' then
      U.text('Touch and go: az első kerék távolsága a vonaltól, három lépcső (100 / 66 / 33 %).', 12, U.col.dim)
      local tiers = z.tiers or { cfg.tngTier1, cfg.tngTier2, cfg.tngTier3 }
      local prop = app.settings.ui.tngProportional ~= false
      if ui.checkbox('Arányosan: egy vonal állítása a másik kettőt is ugyanolyan arányban viszi##tngProp', prop) then
        app.settings.ui.tngProportional = not prop
        app.saveSoon()
      end
      U.tip('Bekapcsolva a három vonal együtt mozog (pl. az 1. vonalat 0,30-ról 0,45 m-re állítva a 2. és a 3. is másfélszeres lesz). Kikapcsolva külön-külön állíthatók.')
      for k = 1, 3 do
        local nv, c, how = U.sliderInput('sz_tier' .. k, ({ '1. vonal (100%)', '2. vonal (66%)', '3. vonal (33%)' })[k], tiers[k], 0.02, 6, '%.2f m', 220, nil, { hardMin = 0.02, hardMax = 6 })
        if c then
          if how == 'typed' then pushUndo()
          elseif not sliderDrag['tier'] then pushUndo(); sliderDrag['tier'] = true end
          z.tiers = { tiers[1], tiers[2], tiers[3] }
          if prop and tiers[k] > 1e-3 then
            local f = nv / tiers[k]
            for j = 1, 3 do z.tiers[j] = math.min(6, tiers[j] * f) end
          else
            z.tiers[k] = nv
            for j = 2, 3 do if z.tiers[j] < z.tiers[j - 1] then z.tiers[j] = z.tiers[j - 1] end end
          end
          changed()
        elseif sliderDrag['tier'] and not ui.itemActive() and k == 3 then
          sliderDrag['tier'] = nil
        end
      end
      if z.tiers then
        if U.button('Vonalak vissza a Beállítások értékére##tiersReset', 0, false, 'A saját vonaltávolságok törlése.') then pushUndo(); z.tiers = nil; changed() end
      end
    end
    if z.type == 'OZ' or z.type == 'IZ' or z.type == 'TNG' or z.type == 'LIMIT' then
      ui.offsetCursorY(4)
      U.text('Pályaelhagyás ennél a zónánál (a pályán a piros sáv mutatja):', 13, U.col.text, true)
      local globalOn = draw3d.isLimitLine(z.type, cfg, nil)
      local on = draw3d.isLimitLine(z.type, cfg, z)
      if z.type ~= 'LIMIT' then
        if ui.checkbox('A vonalon túl pályaelhagyás##zlim', on) then
          pushUndo()
          local v = not on
          if v == globalOn then z.limit = nil else z.limit = v end
          changed()
        end
        U.tip('Ha be van pipálva, a vonalon túlra kerülő kerék pályaelhagyás. Alapból a Beállítások → Pályaelhagyás szerint (OZ és IZ: igen, TNG: nem).')
        if z.limit ~= nil then
          ui.sameLine(0, 8)
          U.pill('saját · általános: ' .. (globalOn and 'igen' or 'nem'), U.col.purple)
          ui.sameLine(0, 6)
          if U.button('Alapra##zlimr', 0, false, 'Vissza a Beállítások szerinti értékre.') then pushUndo(); z.limit = nil; changed() end
        end
      end
      if on then
        sliderOverride('Pályaelhagyás kezdete a vonaltól', 'offTol', z.type == 'LIMIT' and 0 or cfg.zoneLimitTolerance, -1, 3, '%.2f m',
          'Ennyivel a vonalon TÚL kezdődik a pályaelhagyás (a kerék közepe). 0 = pont a vonalon; negatív = már a vonal előtt, a pálya felé. A piros sáv azonnal követi.')
      end
    end
    if #z.points >= 2 and z.type ~= 'IC' then
      ui.offsetCursorY(4)
      -- exact length
      local curLen = zedit.length(z.points)
      local nl, lc = U.numberBox('zlen', curLen, 0.5, 500, '%.2f', 70, 'A zóna teljes hossza méterben: beírva a VÉGÉT hosszabbítja / rövidíti.', 0.5, 500)
      ui.sameLine(0, 8)
      U.text(string.format('Hossz: %.2f m (írd be a pontos hosszt – a végén változik)', curLen), 13, U.col.text)
      if lc then
        pushUndo()
        if zedit.extendEnd(z.points, nl - curLen, snap) then changed() else app.status('Ennél rövidebb nem lehet (legalább 0,5 m kell).', U.col.orange) end
      end
      local function lenButtons(label, fn, id)
        U.text(label, 13, U.col.text)
        for _, d in ipairs({ { -1, '−1 m' }, { -0.25, '−25 cm' }, { 0.25, '+25 cm' }, { 1, '+1 m' } }) do
          ui.sameLine(0, 6)
          if U.button(d[2] .. '##len' .. id .. d[1], 64, false, d[1] < 0 and 'Rövidebb lesz ezen a végén.' or 'Hosszabb lesz ezen a végén (az utolsó szakasz irányában).') then
            pushUndo()
            if fn(z.points, d[1], snap) then changed() else app.status('Ennél rövidebb nem lehet (legalább 0,5 m kell).', U.col.orange) end
          end
        end
        ui.sameLine(0, 10)
        local v, c = U.numberBox('zext' .. id, 0, -50, 50, '%.2f', 62, 'Saját érték méterben: + hosszabb, − rövidebb ezen a végén.', -50, 50)
        if c and math.abs(v) > 1e-6 then
          pushUndo()
          if fn(z.points, v, snap) then changed() else app.status('Ennél rövidebb nem lehet (legalább 0,5 m kell).', U.col.orange) end
        end
        ui.sameLine(0, 4)
        U.text('m', 13, U.col.dim)
      end
      lenButtons('Eleje:', zedit.extendStart, 's')
      lenButtons('Vége: ', zedit.extendEnd, 'e')
      U.text('Eltolás oldalra (az egész vonal):', 13, U.col.text)
      local sd = z.side or 1
      for _, d in ipairs({ { 0.10, 'Pálya felé 10 cm' }, { 0.02, 'Pálya felé 2 cm' }, { -0.02, 'Kifelé 2 cm' }, { -0.10, 'Kifelé 10 cm' } }) do
        ui.sameLine(0, 6)
        if U.button(d[2] .. '##off' .. d[1], 0, false, 'A vonal minden pontját ennyivel tolja el (a pálya felé = a zóna sávja felé).') then
          pushUndo()
          if zedit.offset(z.points, d[1] * sd, snap) then changed() end
        end
      end
      ui.sameLine(0, 10)
      local ov, oc = U.numberBox('zoff', 0, -10, 10, '%.2f', 62, 'Saját eltolás méterben: + a pálya (a zóna sávja) felé, − kifelé.', -10, 10)
      if oc and math.abs(ov) > 1e-6 then
        pushUndo()
        if zedit.offset(z.points, ov * sd, snap) then changed() end
      end
      ui.sameLine(0, 4)
      U.text('m', 13, U.col.dim)
    end
    ui.offsetCursorY(4)
    U.text('Pontok szerkesztése egérrel:', 13, U.col.text)
    local modes = z.type == 'IC' and { { 'movePoint', 'Pont mozgatása', 'Kattints a pontra, majd az új helyére.' } } or {
      { 'movePoint', 'Pont mozgatása', 'Kattints egy pontra, majd az új helyére.' },
      { 'insertPoint', 'Pont beszúrása', 'Kattints a vonal mellé: új pont a két legközelebbi közé.' },
      { 'deletePoint', 'Pont törlése', 'Kattints a törlendő pontra.' } }
    for _, m in ipairs(modes) do
      ui.sameLine(0, 6)
      if U.button(m[2] .. (mode == m[1] and ': BE' or '') .. '##pe' .. m[1], 0, false, m[3]) then
        movePick = nil
        mode = mode == m[1] and 'idle' or m[1]
      end
    end
  end)

  U.collapsible('ed_z_line', 'Vonal és pontok', { sub = string.format('%d pont', #z.points) }, function()
  U.text(({
    OZ = 'Az OZ vonala a pálya KÜLSŐ széle: a hátsó lökhárító távolságát mérjük tőle.',
    IZ = 'Az IZ vonala a pálya BELSŐ széle (clipping pont): az első lökhárító távolságát mérjük tőle.',
    WALL = 'A falas zóna vonala maga a fal: a hátulja minél közelebb (4 cm-en belül) és minél hosszabban.',
    TNG = 'A touch and go vonala: az első kerék közelségét mérjük (100 / 66 / 33 / 0 %).',
    IC = 'Az IC a belső érintési pont: az első lökhárító legkisebb távolságát mérjük tőle (a kör közepéig közel = 100%). Egy pontból áll; újra lerakva áthelyeződik.',
    LIMIT = 'Pályahatár: ha egy kerék a vonalon túlra kerül, az pályaelhagyás (nem pontoz).',
  })[z.type] or '', 12, U.col.dim)
  local isICz = z.type == 'IC'

  if U.button(mode == 'zone' and 'Kattintásos pontozás: BE' or (isICz and 'Pont kattintással' or 'Pontok kattintással'), 170, false,
    isICz and 'Bekapcsolva a pályára kattintva teszed le (vagy helyezed át) az IC pontot.' or 'Bekapcsolva a pályára kattintva pontot adsz a vonalhoz (a haladás irányában haladj).') then
    mode = mode == 'zone' and 'idle' or 'zone'
  end
  ui.sameLine()
  if U.button('Pont az autóhoz', 120, false, isICz and 'Az autó belső első sarkához (a pálya közepe felőli első lökhárító-sarokhoz) teszi az IC pontot.'
    or 'Az autó kiválasztott pontjánál (lásd: Autó pontja) tesz le egy pontot.') then
    local car = app.car()
    local last = z.points[#z.points]
    local ref = nil
    if car and last and geom.dist(last.x, last.z, car.position.x, car.position.z) < 8 and not isICz then ref = last end
    local p = car and carPoint(car, isICz and 'frontInner' or carSource, ref)
    if p then addPointToZone(selectedZone, p, { x = car.position.x, z = car.position.z }) end
  end
  ui.sameLine()
  if U.button('Utolsó pont törlése', 0, #z.points == 0) then
    pushUndo(); table.remove(z.points); changed()
  end
  if not isICz then
  ui.sameLine()
  if U.button('Irány megfordítása', 0, #z.points < 2) then
    pushUndo()
    local r = {}
    for k = #z.points, 1, -1 do r[#r + 1] = z.points[k] end
    z.points = r
    z.side = -(z.side or 1)
    changed()
  end

  if U.button('Oldal megfordítása', 140, #z.points < 2) then
    pushUndo(); z.side = -(z.side or 1); z.sideSet = true; changed()
  end
  if ui.itemHovered() then ui.setTooltip('A halvány vonalak a zóna sávját mutatják: arra az oldalra kerüljenek, ahol az autó halad.') end
  ui.sameLine()
  if U.button('Pontok törlése', 0, #z.points == 0) then pushUndo(); z.points = {}; changed() end

  -- Trace while driving
  ui.setNextItemWidth(300)
  ui.combo('Autó pontja##src', (function() for _, s in ipairs(sources) do if s.id == carSource then return s.label end end return carSource end)(), ui.ComboFlags.None, function()
    for _, s in ipairs(sources) do
      if ui.selectable(s.label, s.id == carSource) then carSource = s.id end
    end
  end)
  if ui.checkbox('Nyomkövetés vezetés közben (pont ' .. string.format('%.1f', traceStep) .. ' méterenként)', traceOn) then
    if traceOn then traceOn = false else startTrace() end
  end
  if ui.itemHovered() then ui.setTooltip('Lassan vezess végig a felfestett vonal / fal mentén: a kiválasztott autópontból folyamatosan rajzolja a zóna vonalát.') end
  ui.setNextItemWidth(160)
  traceStep = ui.slider('##ts', traceStep, 0.5, 5, 'Lépésköz: %.1f m')
  ui.sameLine()
  if ui.checkbox('Autópont mutatása', app.settings.ui.showCarPoint == true) then
    app.settings.ui.showCarPoint = not app.settings.ui.showCarPoint
    app.saveSettings()
  end
  end

  end)

  -- Overrides
  if z.type ~= 'LIMIT' then U.collapsible('ed_z_over', 'Egyedi pontozás', { sub = 'felülírja a Beállítások értékét ennél a zónánál', defaultOpen = false }, function()
    U.text('Pipáld be, amit ennél a zónánál másképp szeretnél. Üresen hagyva a Beállítások értéke érvényes.', 12, U.col.dim)
    local cfg = app.cfg
    local function override(label, key, def, min, max, fmt)
      local has = z[key] ~= nil
      if ui.checkbox('##ov' .. key, has) then
        pushUndo()
        if has then z[key] = nil else z[key] = def end
        changed()
      end
      ui.sameLine()
      if z[key] ~= nil then
        local v, c = U.sliderRow(label, z[key], min, max, fmt)
        if c then z[key] = v; changed() end
      else
        ui.textColored(label .. ': általános (' .. string.format(fmt, def) .. ')', U.col.dim)
      end
    end
    U.text('A zóna szélessége és a TNG vonalak a „Méret és helyzet” részben állíthatók.', 12, U.col.dim)
    if z.type == 'TNG' then
      if ui.checkbox('Folyamatos pontozás (lépcsős helyett)', (z.tngMode or cfg.tngMode) == 'linear') then
        pushUndo()
        z.tngMode = ((z.tngMode or cfg.tngMode) == 'linear') and 'step' or 'linear'
        changed()
      end
    end
    override('Célszög, °', 'angleTarget', cfg.angleTarget, 20, 95, '%.0f')
    override('Minimális szög, °', 'angleMin', cfg.angleMin, 0, 60, '%.0f')
  end) end

  -- No-go
  if z.type ~= 'LIMIT' and z.type ~= 'IC' then U.collapsible('ed_z_nogo', 'Tiltott terület (no-go)', { sub = string.format('%d terület', #(z.nogo or {})), defaultOpen = false }, function()
  U.text('Ha az autó a zónán belül egy no-go területre ér, az ott lévő rész nem ér Line pontot.', 12, U.col.dim)
  if U.button(mode == 'nogo' and 'No-go rajzolás: BE' or 'No-go terület rajzolása', 170) then
    mode = mode == 'nogo' and 'idle' or 'nogo'
    nogoDraft = {}
  end
  ui.sameLine()
  if U.button('Sokszög lezárása', 0, #nogoDraft < 3) then
    pushUndo()
    z.nogo = z.nogo or {}
    z.nogo[#z.nogo + 1] = nogoDraft
    nogoDraft = {}
    mode = 'idle'
    changed()
  end
  ui.sameLine()
  if U.button('Utolsó no-go törlése', 0, #(z.nogo or {}) == 0) then
    pushUndo(); table.remove(z.nogo); changed()
  end
  end) end
  ui.separator()
  if confirmDelete == selectedZone then
    ui.textColored('Biztosan törlöd a(z) ' .. z.name .. ' zónát?', U.col.red)
    ui.sameLine()
    if U.button('Igen, törlés') then
      pushUndo()
      table.remove(app.layout.zones, selectedZone)
      selectedZone, confirmDelete, mode = nil, nil, 'idle'
      changed()
    end
    ui.sameLine()
    if U.button('Mégse') then confirmDelete = nil end
  else
    if U.button('Zóna törlése', 110) then confirmDelete = selectedZone end
    ui.sameLine()
    if U.button('Feljebb', 0, selectedZone <= 1) then
      pushUndo()
      local zs = app.layout.zones
      zs[selectedZone], zs[selectedZone - 1] = zs[selectedZone - 1], zs[selectedZone]
      selectedZone = selectedZone - 1
      changed()
    end
    ui.sameLine()
    if U.button('Lejjebb', 0, selectedZone >= #app.layout.zones) then
      pushUndo()
      local zs = app.layout.zones
      zs[selectedZone], zs[selectedZone + 1] = zs[selectedZone + 1], zs[selectedZone]
      selectedZone = selectedZone + 1
      changed()
    end
  end
end

local function stepOpts(sub, ok, badge, level)
  return { sub = sub, badge = badge, badgeColor = U.levelColors[level] or U.col.green, level = level }
end

function editor.drawTab()
  local l = app.layout
  local issues = layoutMod.validateDetailed(l)
  local zoneIss = app.zoneIssues and app.zoneIssues() or {}

  local hint = modeHint()
  if hint then
    local b = U.notice('mode', 'info', 'Pontfelvétel aktív', hint .. ' Tipp: szabad kamera (F7); a kattintás akkor kerül a pályára, ha az egér nem az ablak fölött van.',
      { { 'Mégse', 'Kilép a pontfelvételből.' } })
    if b == 1 then mode = 'idle'; gateDraftA = nil; nogoDraft = {} end
  end
  if traceOn then
    local b = U.notice('trace', 'info', 'Nyomkövetés fut', 'Lassan vezess végig a vonalon; ' .. string.format('%.1f', traceStep) .. ' méterenként kerül le pont a kijelölt zónába.',
      { { 'Nyomkövetés leállítása', 'Leállítja a pontok lerakását.' } })
    if b == 1 then traceOn = false end
  end

  -- 1. Pályaterv
  U.collapsible('ed_step1', '1. Pályaterv', stepOpts(l.name .. (app.dirty and ' · nem mentett változás' or ' · mentve'), not app.dirty,
    app.dirty and 'NEM MENTETT' or 'KÉSZ', app.dirty and 'warn' or 'ok'), layoutFiles)

  -- 2. Kapuk
  local missing = {}
  for _, it in ipairs(issues) do if it.kind == 'gate' then missing[#missing + 1] = layoutMod.gateNames[it.gate] end end
  U.collapsible('ed_step2', '2. Kapuk', stepOpts('START, JUDGING, FINISH', #missing == 0,
    #missing == 0 and 'KÉSZ' or ('HIÁNYZIK: ' .. table.concat(missing, ', ')), #missing == 0 and 'ok' or 'error'), gatesSection)

  -- 3. Zónák
  local nErr, nWarn = 0, 0
  for _, it in ipairs(issues) do
    if it.kind ~= 'gate' and not it.zone then if it.level == 'error' then nErr = nErr + 1 else nWarn = nWarn + 1 end end
  end
  for _, list in pairs(zoneIss) do
    for _, it in ipairs(list) do
      if not it.acked then if it.level == 'error' then nErr = nErr + 1 else nWarn = nWarn + 1 end end
    end
  end
  local zBadge, zLevel = 'KÉSZ', 'ok'
  if nErr > 0 then zBadge, zLevel = string.format('%d HIBA', nErr), 'error'
  elseif nWarn > 0 then zBadge, zLevel = string.format('%d FIGYELMEZTETÉS', nWarn), 'warn' end
  U.collapsible('ed_step3', '3. Zónák', stepOpts(string.format('%d zóna · súlyozás: %s', #l.zones, l.weighting == 'auto' and 'automatikus' or 'kézi'), nErr == 0, zBadge, zLevel), function()
    zoneList(zoneIss)
    zoneDetails(zoneIss)
  end)

  -- 4. Ellenőrzés
  local res = app.lastResult
  local tested = res and app.resultLayout == l
  local nResWarn = 0
  if tested then
    for _, it in ipairs((app.todoItems())) do if it.area == 'result' then nResWarn = nResWarn + 1 end end
  end
  local cBadge, cLevel = 'TESZTKÖR AJÁNLOTT', 'warn'
  if tested and nResWarn == 0 then cBadge, cLevel = 'RENDBEN', 'ok' elseif tested then cBadge, cLevel = string.format('%d TEENDŐ', nResWarn), 'warn' end
  U.collapsible('ed_step4', '4. Ellenőrzés', stepOpts('tesztkör a kész pályatervvel', tested and nResWarn == 0, cBadge, cLevel), function()
    local function check(ok, text)
      U.text((ok and 'KÉSZ  ' or 'HIÁNYZIK  ') .. text, 13, ok and U.col.green or U.col.orange, true)
    end
    check(l.gates.judging ~= nil, 'JUDGING vonal')
    check(l.gates.finish ~= nil, 'FINISH vonal')
    local scoringZones, lined = 0, true
    for _, z in ipairs(l.zones) do
      if z.type ~= 'LIMIT' then scoringZones = scoringZones + 1 end
      if #z.points < layoutMod.minPoints(z) then lined = false end
    end
    check(scoringZones > 0, 'legalább egy pontozó zóna')
    check(lined and #l.zones > 0, 'minden zónának van vonala')
    check(not app.dirty, 'elmentve')
    ui.offsetCursorY(4)
    if tested then
      U.text(string.format('Utolsó tesztkör ezzel a tervvel: %s', res.zeroRun and 'NULLÁS' or (U.t1(res.final) .. ' pont')), 14, U.col.text, true)
      if nResWarn == 0 then
        U.text('Nem volt gyanús adat. Ha a pontok reálisak, a pályaterv kész.', 13, U.col.green)
      else
        U.text('A tesztkörben gyanús adat volt – a teendők a Teendők panelen és az Eredmény fülön.', 13, U.col.orange)
      end
    else
      U.wrapped('Menj egy tesztkört START → JUDGING → FINISH között. Utána itt és a Teendők panelen látod, ha egy vonal nem a pálya szélén van, vagy gyanús a pályaelhagyás.', 13, U.col.dim)
    end
  end)

  -- 5. Tempó (optional)
  local tSub = l.tempoMin and string.format('minimum %.0f km/h · teljes pont %.0f km/h', l.tempoMin, l.tempoFull or (l.tempoMin + 10)) or 'nincs megadva (nem kötelező)'
  U.collapsible('ed_step5', '5. Minimális tempó', stepOpts(tSub, true, l.tempoMin and 'BEÁLLÍTVA' or 'NEM KÖTELEZŐ', l.tempoMin and 'ok' or 'info'), function()
    editor.tempoPanel()
  end)
end

-- Minimum tempo of the layout: below the minimum the run gets a flag, and between the minimum and the
-- full tempo it counts in Style / Commitment (the run's average speed over its distance).
function editor.tempoPanel()
  local l = app.layout
  U.wrapped('A futás átlagsebessége (út szerint, JUDGING–FINISH) ehhez mérve számít az Elkötelezettségbe (Stílus): a minimumon 0%, a teljes pont tempón 100%. '
    .. 'A minimum alatt a futás jelzést kap („Minimális tempó alatt”), a bírók dönthetnek a levonásról. Pályánként más, ezért a pályatervben tárolódik.', 12, U.col.dim)
  local tmin, tfull = l.tempoMin, l.tempoFull or (l.tempoMin and l.tempoMin + 10)
  U.text('Minimális tempó, km/h:', 13, U.col.text)
  ui.sameLine(190)
  local v, c = U.numberBox('tempoMin', tmin or 0, 0, 300, '%.0f', 70, 'A minimális átlagsebesség (km/h). 0 = nincs minimum.')
  if c then
    pushUndo()
    if v <= 0 then l.tempoMin, l.tempoFull = nil, nil
    else
      l.tempoMin = v
      if not l.tempoFull or l.tempoFull <= v then l.tempoFull = v + 10 end
    end
    changed()
  end
  if l.tempoMin then
    U.text('Teljes pont tempó, km/h:', 13, U.col.text)
    ui.sameLine(190)
    local v2, c2 = U.numberBox('tempoFull', tfull, l.tempoMin + 1, 320, '%.0f', 70, 'Ezen az átlagsebességen (vagy fölötte) 100% a tempó.')
    if c2 then pushUndo(); l.tempoFull = v2; changed() end
    ui.sameLine(0, 12)
    if U.button('Kikapcsolás##tempoOff', 0, false, 'Nincs minimális tempó ezen a pályán.') then
      pushUndo(); l.tempoMin, l.tempoFull = nil, nil; changed()
    end
  end
  local res = app.lastResult
  if res and app.resultLayout == l and not res.zeroRun and (res.avgSpeed or 0) > 10 then
    local full = math.floor(res.avgSpeed + 0.5)
    local mn = math.floor(full * 0.9 + 0.5)
    if U.button(string.format('A legutóbbi futásból: minimum %d, teljes pont %d km/h##tempoFromRun', mn, full), 0, false,
      'A legutóbbi (nem nullás) futás átlagsebessége lesz a teljes pont tempó, a 90%-a a minimum. Egy jó referencia-futás után érdemes használni.') then
      pushUndo(); l.tempoMin, l.tempoFull = mn, full; changed()
    end
  end
  if app.dirty then U.text('A változás a pályaterv mentése után marad meg (Mentés fent).', 12, U.col.orange) end
end

-- Sets the layout's tempo from a result (used by the Eredmény tab).
function editor.setTempoFromResult(res)
  if not res or (res.avgSpeed or 0) <= 10 then return false end
  pushUndo()
  local full = math.floor(res.avgSpeed + 0.5)
  app.layout.tempoMin, app.layout.tempoFull = math.floor(full * 0.9 + 0.5), full
  changed()
  return true
end

return editor
