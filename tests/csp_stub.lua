-- CSP API stub for offline tests of CHT Drift Judge (runs under LuaJIT via Python lupa).
-- Only what the app uses. Everything visual is a no-op; files live in memory (__FS).
-- Two modes: __STUB_ONLINE = true → behaves like a CSP online script (no io, ac.storage, ac.configValues).

__STUB = true
local STUB = { frame = 0, time = 0, glVerts = 0, glMaxVerts = 0, errors = {}, warnings = {}, clipboard = nil,
  sent = {}, toasts = {}, webRequests = {}, webResponses = {}, keyPressed = {} }
_G.STUB = STUB

-- vectors ------------------------------------------------------------------------------------------
local function mkvec(n, names)
  local mt = {}
  mt.__index = mt
  local function new(...)
    local a = { ... }
    local v = setmetatable({}, mt)
    for i, k in ipairs(names) do v[k] = tonumber(a[i]) or (i == 1 and tonumber(a[1]) or 0) end
    if #a == 1 and type(a[1]) == 'number' then for _, k in ipairs(names) do v[k] = a[1] end end
    return v
  end
  function mt:set(...)
    local a = { ... }
    if type(a[1]) == 'table' then for _, k in ipairs(names) do self[k] = a[1][k] or 0 end return self end
    for i, k in ipairs(names) do if a[i] ~= nil then self[k] = a[i] end end
    return self
  end
  function mt:clone() local v = new() for _, k in ipairs(names) do v[k] = self[k] end return v end
  function mt:length() local s = 0 for _, k in ipairs(names) do s = s + self[k] * self[k] end return math.sqrt(s) end
  function mt:lengthSquared() local s = 0 for _, k in ipairs(names) do s = s + self[k] * self[k] end return s end
  function mt:dot(o) local s = 0 for _, k in ipairs(names) do s = s + self[k] * o[k] end return s end
  function mt:distance(o) local s = 0 for _, k in ipairs(names) do local d = self[k] - o[k]; s = s + d * d end return math.sqrt(s) end
  function mt:distanceSquared(o) local s = 0 for _, k in ipairs(names) do local d = self[k] - o[k]; s = s + d * d end return s end
  function mt:normalize() local l = self:length() if l > 0 then for _, k in ipairs(names) do self[k] = self[k] / l end end return self end
  function mt:add(o, out) out = out or self for _, k in ipairs(names) do out[k] = self[k] + (type(o) == 'number' and o or o[k]) end return out end
  function mt:sub(o, out) out = out or self for _, k in ipairs(names) do out[k] = self[k] - (type(o) == 'number' and o or o[k]) end return out end
  function mt:scale(f, out) out = out or self for _, k in ipairs(names) do out[k] = self[k] * f end return out end
  function mt:mul(o, out) out = out or self for _, k in ipairs(names) do out[k] = self[k] * (type(o) == 'number' and o or o[k]) end return out end
  function mt:addScaled(o, f, out) out = out or self for _, k in ipairs(names) do out[k] = self[k] + o[k] * f end return out end
  function mt:setLerp(a, b, t) for _, k in ipairs(names) do self[k] = a[k] + (b[k] - a[k]) * t end return self end
  function mt:copyTo(o) for _, k in ipairs(names) do o[k] = self[k] end return o end
  if n == 3 then
    function mt:cross(o, out) out = out or new()
      local x, y, z = self.y * o.z - self.z * o.y, self.z * o.x - self.x * o.z, self.x * o.y - self.y * o.x
      out.x, out.y, out.z = x, y, z return out end
  end
  mt.__add = function(a, b) local v = new() for _, k in ipairs(names) do v[k] = (type(a) == 'number' and a or a[k]) + (type(b) == 'number' and b or b[k]) end return v end
  mt.__sub = function(a, b) local v = new() for _, k in ipairs(names) do v[k] = (type(a) == 'number' and a or a[k]) - (type(b) == 'number' and b or b[k]) end return v end
  mt.__mul = function(a, b) local v = new() for _, k in ipairs(names) do v[k] = (type(a) == 'number' and a or a[k]) * (type(b) == 'number' and b or b[k]) end return v end
  mt.__div = function(a, b) local v = new() for _, k in ipairs(names) do v[k] = (type(a) == 'number' and a or a[k]) / (type(b) == 'number' and b or b[k]) end return v end
  mt.__unm = function(a) local v = new() for _, k in ipairs(names) do v[k] = -a[k] end return v end
  mt.__tostring = function(a) local t = {} for _, k in ipairs(names) do t[#t + 1] = tostring(a[k]) end return '(' .. table.concat(t, ', ') .. ')' end
  return new, mt
end
vec2 = mkvec(2, { 'x', 'y' })
vec3 = mkvec(3, { 'x', 'y', 'z' })
vec4 = mkvec(4, { 'x', 'y', 'z', 'w' })
local rgbNew = mkvec(3, { 'r', 'g', 'b' })
rgb = setmetatable({}, { __call = function(_, ...) return rgbNew(...) end })
local rgbmNew, rgbmMt = mkvec(4, { 'r', 'g', 'b', 'mult' })
rgbm = setmetatable({ colors = {} }, { __call = function(_, ...) return rgbmNew(...) end })
for _, k in ipairs({ 'white', 'black', 'red', 'green', 'blue', 'yellow', 'gray', 'transparent' }) do rgbm.colors[k] = rgbmNew(1, 1, 1, 1) end
rgb.colors = rgbm.colors

-- 4x4 transform with only a translation + yaw (enough for the car body transform)
local matMt = {}
matMt.__index = matMt
function matMt:transformPointTo(out, p)
  local c, s = math.cos(self.yaw), math.sin(self.yaw)
  out.x = self.px + p.x * c + p.z * s
  out.y = self.py + p.y
  out.z = self.pz - p.x * s + p.z * c
  return out
end
function matMt:transformPoint(p) return self:transformPointTo(vec3(), p) end
local function newMat(px, py, pz, yaw) return setmetatable({ px = px, py = py, pz = pz, yaw = yaw or 0 }, matMt) end

-- JSON -----------------------------------------------------------------------------------------------
JSON = {}
local function esc(s)
  return (s:gsub('[%c"\\]', function(c)
    local m = { ['"'] = '\\"', ['\\'] = '\\\\', ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t' }
    return m[c] or string.format('\\u%04x', c:byte())
  end))
end
local function isArray(t)
  local n = 0
  for k in pairs(t) do
    if type(k) ~= 'number' or k <= 0 or math.floor(k) ~= k then return false end
    n = math.max(n, k)
  end
  return n == #t
end
local function enc(v, seen)
  local tv = type(v)
  if v == nil then return 'null' end
  if tv == 'boolean' then return tostring(v) end
  if tv == 'number' then
    if v ~= v or v == math.huge or v == -math.huge then return 'null' end
    if math.floor(v) == v and math.abs(v) < 1e15 then return string.format('%d', v) end
    return string.format('%.10g', v)
  end
  if tv == 'string' then return '"' .. esc(v) .. '"' end
  if tv == 'table' then
    if seen[v] then error('JSON: circular reference') end
    seen[v] = true
    local out = {}
    local mt = getmetatable(v)
    if mt == rgbmMt then v = { r = v.r, g = v.g, b = v.b, mult = v.mult } end
    if next(v) == nil then seen[v] = nil return '[]' end
    if isArray(v) then
      for i = 1, #v do out[i] = enc(v[i], seen) end
      seen[v] = nil
      return '[' .. table.concat(out, ',') .. ']'
    end
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    for _, k in ipairs(keys) do
      local val = v[k]
      if type(val) ~= 'function' and type(val) ~= 'userdata' then out[#out + 1] = '"' .. esc(tostring(k)) .. '":' .. enc(val, seen) end
    end
    seen[v] = nil
    return '{' .. table.concat(out, ',') .. '}'
  end
  return 'null'
end
function JSON.stringify(v) return enc(v, {}) end
function JSON.parse(s)
  local pos = 1
  local function ws() pos = s:find('[^ \t\r\n]', pos) or (#s + 1) end
  local val
  local function str()
    local out, i = {}, pos + 1
    while true do
      local c = s:sub(i, i)
      if c == '' then error('JSON: unterminated string') end
      if c == '"' then pos = i + 1 break end
      if c == '\\' then
        local n = s:sub(i + 1, i + 1)
        local map = { n = '\n', r = '\r', t = '\t', b = '\b', f = '\f', ['"'] = '"', ['\\'] = '\\', ['/'] = '/' }
        if n == 'u' then
          local code = tonumber(s:sub(i + 2, i + 5), 16)
          if code < 128 then out[#out + 1] = string.char(code)
          elseif code < 2048 then out[#out + 1] = string.char(192 + math.floor(code / 64), 128 + code % 64)
          else out[#out + 1] = string.char(224 + math.floor(code / 4096), 128 + math.floor(code / 64) % 64, 128 + code % 64) end
          i = i + 6
        else out[#out + 1] = map[n] or n; i = i + 2 end
      else out[#out + 1] = c; i = i + 1 end
    end
    return table.concat(out)
  end
  function val()
    ws()
    local c = s:sub(pos, pos)
    if c == '{' then
      pos = pos + 1
      local t = {}
      ws()
      if s:sub(pos, pos) == '}' then pos = pos + 1 return t end
      while true do
        ws()
        local k = str()
        ws(); pos = pos + 1 -- :
        t[k] = val()
        ws()
        local d = s:sub(pos, pos); pos = pos + 1
        if d == '}' then return t end
      end
    elseif c == '[' then
      pos = pos + 1
      local t = {}
      ws()
      if s:sub(pos, pos) == ']' then pos = pos + 1 return t end
      while true do
        t[#t + 1] = val()
        ws()
        local d = s:sub(pos, pos); pos = pos + 1
        if d == ']' then return t end
      end
    elseif c == '"' then return str()
    elseif s:sub(pos, pos + 3) == 'true' then pos = pos + 4 return true
    elseif s:sub(pos, pos + 4) == 'false' then pos = pos + 5 return false
    elseif s:sub(pos, pos + 3) == 'null' then pos = pos + 4 return nil
    else
      local num = s:match('^-?[%d%.eE%+%-]+', pos)
      if not num then error('JSON: bad value at ' .. pos) end
      pos = pos + #num
      return tonumber(num)
    end
  end
  return val()
end

-- in-memory file system --------------------------------------------------------------------------
__FS = {}
local dirs = {}
local function norm(p) return (tostring(p):gsub('\\', '/'):gsub('//+', '/')) end
local function parent(p) return norm(p):match('^(.*)/[^/]*$') end
local realIO = io
if __STUB_ONLINE then
  -- online scripts have no file access (SDK flag withoutIO): only a few harmless functions exist
  -- (io.load can read some files; STUB.installedManifest = text of apps/lua/CHT_DriftJudge/manifest.ini)
  -- STUB.docsLayouts = { ['Brno.json'] = text } = layouts the installed app saved in Documents
  io = { load = function(p, fb)
    p = norm(p)
    if STUB.installedManifest and p:find('/lua/CHT_DriftJudge/manifest.ini', 1, true) then return STUB.installedManifest end
    local name = p:match('/CHT Drift Judge/layouts/[^/]+/([^/]+)$')
    if name and STUB.docsLayouts and STUB.docsLayouts[name] then return STUB.docsLayouts[name] end
    return fb
  end,
  scanDir = function(d)
    local r = {}
    if STUB.docsLayouts and norm(d):find('/CHT Drift Judge/layouts/', 1, true) then
      for k in pairs(STUB.docsLayouts) do r[#r + 1] = k end
      table.sort(r)
    end
    return r
  end }
else
  io = {
    save = function(p, data) __FS[norm(p)] = tostring(data) return true end,
    saveAsync = function(p, data, cb) __FS[norm(p)] = tostring(data) if cb then cb(nil) end end,
    load = function(p) return __FS[norm(p)] end,
    fileExists = function(p) return __FS[norm(p)] ~= nil end,
    dirExists = function(p) return dirs[norm(p)] == true end,
    createDir = function(p) p = norm(p) while p and p ~= '' do dirs[p] = true; p = parent(p) end return true end,
    createFileDir = function(p) local d = parent(p) if d then io.createDir(d) end return true end,
    scanDir = function(d, mask)
      d = norm(d)
      local ext = mask and mask:match('%*(%..+)$')
      local r = {}
      for p in pairs(__FS) do
        local dir, name = p:match('^(.*)/([^/]+)$')
        if dir == d and (not ext or name:sub(-#ext) == ext) then r[#r + 1] = name end
      end
      table.sort(r)
      return r
    end,
  }
end
os.openInExplorer = function() end
os.showInExplorer = function() end

-- car / sim state --------------------------------------------------------------------------------
local function newWheel(i)
  return { contactPoint = vec3(), surfaceType = 2, surfaceExtendedType = 0, surfaceValidTrack = true,
    velocity = vec3(), angularSpeed = 0, tyreRadius = 0.32, index = i }
end
local function newCar(i)
  local car = {
    index = i, position = vec3(0, 0, 0), localVelocity = vec3(), velocity = vec3(), speedKmh = 0, steer = 0, gas = 0, brake = 0,
    handbrake = 0, clutch = 1, wheelsOutside = 0, collisionDepth = 0, collidedWith = -1, collisionPosition = vec3(),
    gear = 3, rpm = 5000, rpmLimiter = 8000, aabbCenter = vec3(0, 0.6, 0), aabbSize = vec3(1.8, 1.3, 4.4),
    look = vec3(0, 0, 1), side = vec3(1, 0, 0), steerLock = 450, tractionType = 0, resetCounter = 0, isRemote = i > 0,
    wheels = {}, bodyTransform = newMat(0, 0, 0, 0), isConnected = true,
  }
  for w = 0, 3 do car.wheels[w] = newWheel(w) end
  return car
end
STUB.cars = { [0] = newCar(0), [1] = newCar(1) }
STUB.sim = { time = 0, dt = 1 / 60, focusedCar = 0, isReplayActive = false, isPaused = false, systemTime = 1795000000,
  cameraPosition = vec3(0, 50, 0), cameraLook = vec3(0, -1, 0), cameraFOV = 60, carsCount = 2,
  directMessagingAvailable = true, directUDPMessagingAvailable = true, isOnlineRace = __STUB_ONLINE == true }

-- Positions a car: heading yaw (radians, 0 = +z), drift angle (deg, positive = sliding to the right).
function STUB.placeCar(i, x, z, yaw, speedKmh, angleDeg)
  local car = STUB.cars[i]
  car.position:set(x, 0, z)
  car.look:set(math.sin(yaw), 0, math.cos(yaw))
  car.side:set(math.cos(yaw), 0, -math.sin(yaw))
  car.bodyTransform = newMat(x, 0, z, yaw)
  local v = speedKmh / 3.6
  local a = math.rad(angleDeg or 0)
  car.localVelocity:set(v * math.sin(a), 0, v * math.cos(a))
  car.speedKmh = speedKmh
  for w = 0, 3 do
    local wx = (w % 2 == 0) and -0.8 or 0.8
    local wz = (w < 2) and 1.3 or -1.3
    car.bodyTransform:transformPointTo(car.wheels[w].contactPoint, vec3(wx, 0, wz))
    car.wheels[w].velocity:set(car.look.x * v, 0, car.look.z * v)
    car.wheels[w].angularSpeed = v / 0.32
  end
end

ac = {}
ac.FolderID = setmetatable({}, { __index = function(_, k) return k end })
ac.ScreenshotFormat = { PNG = 'png', JPG = 'jpg', BMP = 'bmp' }
ac.SharedNamespace = { Global = '', Shared = 'shared', ServerScript = 'server_script', CarScript = 'car_script', TrackScript = 'track_script' }
function ac.getFolder(id) return id == 'ACDocuments' and 'C:/Users/T/Documents/Assetto Corsa' or ('C:/AC/' .. tostring(id)) end
function ac.getSim() return STUB.sim end
function ac.getCar(i) return STUB.cars[i or 0] end
function ac.getTrackFullID(sep) return 'trackwood_pro_reverse_2026' .. (sep and '' or '') end
function ac.getTrackName() return 'Trackwood Pro Reverse 2026' end
function ac.getCarID(i) return 'cht_mazda_rx8' end
function ac.getCarName(i) return 'CHT Mazda RX-8' end
function ac.getDriverName(i) return i == 0 and 'Teszt Pilóta' or ('Pilóta ' .. tostring(i)) end
function ac.getPatchVersion() return '0.3.0-preview120' end
function ac.getPatchVersionCode() return 3650 end
function ac.getUI() return { windowSize = vec2(1920, 1080) } end
function ac.getAppWindows() return {} end
function ac.onCarJumped(i, cb) return function() end end
function ac.trackProgressToWorldCoordinate(p) return vec3(p * 100, 0, 0) end
function ac.worldCoordinateToTrackProgress(p) return 0.5 end
function ac.warn(...) STUB.warnings[#STUB.warnings + 1] = table.concat({ tostring((...)) }, ' ') end
function ac.error(...) local t = {} for i = 1, select('#', ...) do t[#t + 1] = tostring(select(i, ...)) end STUB.errors[#STUB.errors + 1] = table.concat(t, ' ') end
function ac.log() end
function ac.debug() end
function ac.setClipboardText(t) STUB.clipboard = t end
function ac.findNodes() return setmetatable({}, { __index = function() return function(self) return self end end }) end
function ac.GeometryShot()
  return setmetatable({}, { __index = function(_, k) return function(self, ...) return self end end })
end
function ac.makeSimpleScreenshot(fmt, cb) if cb then cb('stub: no screenshot', nil) end end
if STUB_STEAM_ID then function ac.getUserSteamID() return STUB_STEAM_ID end end
-- admin flag: ac.checkAdminPrivileges() refreshes sim.isAdmin (STUB.makeAdmin = what the server says)
STUB.adminChecks = 0
STUB.sim.isAdmin = false
function ac.checkAdminPrivileges()
  STUB.adminChecks = STUB.adminChecks + 1
  STUB.sim.isAdmin = STUB.makeAdmin == true
  return true
end

-- online-script only APIs
if __STUB_ONLINE then
  -- STUB.storage = the place in use; ac.storageSetPath(p) switches to STUB.storages[p] (CSP: a fixed
  -- subfolder instead of the default one)
  STUB.storages = { [''] = {} }
  STUB.storage = STUB.storages['']
  STUB.storagePath = ''
  function ac.storageSetPath(p)
    STUB.storagePath = tostring(p)
    STUB.storages[STUB.storagePath] = STUB.storages[STUB.storagePath] or {}
    STUB.storage = STUB.storages[STUB.storagePath]
  end
  ac.storage = setmetatable({}, {
    __call = function(_, layout, defaultValue)
      if type(layout) == 'string' then
        local key = layout
        if STUB.storage[key] == nil then STUB.storage[key] = defaultValue end
        return { get = function() return STUB.storage[key] end, set = function(_, v) STUB.storage[key] = v end }
      end
      return setmetatable({}, { __index = function(_, k) local v = STUB.storage[k] if v == nil then return layout[k] end return v end,
        __newindex = function(_, k, v) STUB.storage[k] = v end })
    end,
    __index = function(_, k) return STUB.storage[k] end,
    __newindex = function(_, k, v) STUB.storage[k] = v end,
  })
  STUB.serverConfig = STUB.serverConfig or {}
  function ac.configValues(layout)
    local r = {}
    for k, def in pairs(layout) do
      local v = STUB.serverConfig[k]
      if v == nil then r[k] = def
      elseif type(def) == 'number' then r[k] = tonumber(v) or def
      elseif type(def) == 'boolean' then r[k] = v == true or v == 1 or v == '1' or v == 'true'
      else r[k] = tostring(v) end
    end
    return r
  end
end

web = {}
function web.get(url, headers, cb)
  if type(headers) == 'function' then cb = headers end
  STUB.webRequests[#STUB.webRequests + 1] = url
  local body = STUB.webResponses[url]
  if cb then
    if body then cb(nil, { status = 200, body = body, headers = {} })
    else cb(nil, { status = 404, body = '404: Not Found', headers = {} }) end
  end
end

-- web.post: STUB.webPostMode = 'ok' | 'redirect' | 'error' | 'throw' | 'deferred' | 'badkey' | 'html'
STUB.webPosts = {}
STUB.webPostMode = 'ok'
function web.post(url, headers, data, cb)
  local p = { url = url, headers = headers, body = data, cb = cb }
  STUB.webPosts[#STUB.webPosts + 1] = p
  local m = STUB.webPostMode
  if m == 'deferred' then return end
  if m == 'throw' then error('only two requests can run at once') end
  if m == 'error' then cb('connection failed', nil) return end
  if m == 'redirect' then cb(nil, { status = 302, body = '<HTML>Moved Temporarily</HTML>', headers = {} }) return end
  if m == 'badkey' then cb(nil, { status = 200, body = '{"ok":false,"error":"key"}', headers = {} }) return end
  if m == 'html' then cb(nil, { status = 200, body = '<html>Hiba</html>', headers = {} }) return end
  cb(nil, { status = 200, body = '{"ok":true}', headers = {} })
end

-- online messages: every send is delivered back to the local callbacks too (like CSP does)
local events = {}
ac.StructItem = setmetatable({}, { __index = function(_, k) return function(...) return { kind = k, args = { ... } } end end })
function ac.OnlineEvent(layout, callback, namespace, udp, params)
  local key = tostring(namespace) .. '|'
  local names = {}
  for k, v in pairs(layout) do
    if type(k) == 'number' and type(v) == 'table' and v.args then key = key .. tostring(v.args[1]) .. ';'
    else names[#names + 1] = tostring(k) end
  end
  table.sort(names)
  key = key .. table.concat(names, ',')
  events[key] = events[key] or {}
  table.insert(events[key], callback)
  local function send(msg, repeatForNew, target)
    STUB.sent[#STUB.sent + 1] = { key = key, msg = msg }
    for _, cb in ipairs(events[key]) do cb(STUB.cars[0], msg) end
    return true
  end
  return send
end
function STUB.deliverFrom(carIndex, layoutKeyPart, msg)
  for key, cbs in pairs(events) do
    if key:find(layoutKeyPart, 1, true) then for _, cb in ipairs(cbs) do cb(STUB.cars[carIndex], msg) end end
  end
end

-- ac.connect: one shared table per layout key (tests can fill STUB.connected[key] by hand)
STUB.connected = {}
function ac.connect(layout, keepLive, namespace)
  local key = tostring(namespace) .. '|'
  for k, v in pairs(layout) do if type(k) == 'number' and type(v) == 'table' and v.args then key = key .. tostring(v.args[1]) end end
  STUB.connected[key] = STUB.connected[key] or {}
  return STUB.connected[key]
end

function ac.ControlButton(id, key)
  local b = { id = id }
  function b:pressed() return STUB.keyPressed[id] == true end
  function b:down() return false end
  function b:released() return false end
  function b:control() return false end
  function b:boundTo() return nil end
  function b:setAlwaysActive() return self end
  function b:configured() return true end
  return b
end

-- ui ---------------------------------------------------------------------------------------------
local function enum() return setmetatable({}, { __index = function() return 0 end }) end
ui = {}
for _, e in ipairs({ 'ButtonFlags', 'ColorPickerFlags', 'ComboFlags', 'InputTextFlags', 'TabBarFlags', 'TabItemFlags', 'WindowFlags',
  'KeyIndex', 'Icons', 'Alignment', 'StyleVar', 'StyleColor', 'MouseButton', 'OnlineExtraFlags', 'ControlButtonControlFlags' }) do ui[e] = enum() end
local function call(fn, ...) if type(fn) == 'function' then return fn(...) end end
local returnsFalse = { 'checkbox', 'button', 'invisibleButton', 'selectable', 'itemHovered', 'itemActive', 'colorButton', 'itemClicked',
  'mouseClicked', 'mouseDown', 'isWindowFocused', 'keyboardButtonPressed', 'mouseReleased', 'windowHovered' }
for _, k in ipairs(returnsFalse) do ui[k] = function() return false end end
STUB.uiPress = {} -- label substring → true: ui.button returns true once for a matching label
function ui.button(label)
  for k in pairs(STUB.uiPress) do
    if tostring(label):find(k, 1, true) then STUB.uiPress[k] = nil return true end
  end
  return false
end
-- STUB.uiPress also presses invisible buttons; STUB.uiActive = label substring → ui.itemActive() is true
-- right after that item (dragging)
local lastItem = ''
ui.invisibleButton = function(label)
  lastItem = tostring(label)
  for k in pairs(STUB.uiPress) do
    if lastItem:find(k, 1, true) then STUB.uiPress[k] = nil return true end
  end
  return false
end
STUB.uiActive = nil
function ui.itemActive() return STUB.uiActive ~= nil and lastItem:find(STUB.uiActive, 1, true) ~= nil end
STUB.mouse = vec2(0, 0)
function ui.slider(_, v) return v, false end
function ui.inputText(_, v) return v, false, false end
function ui.combo(_, _, _, fn) end
function ui.tabBar(_, _, fn) call(fn) end
function ui.tabItem(_, _, fn) call(fn) end
function ui.childWindow(_, _, _, _, fn) if type(_) == 'function' then return _() end call(fn) end
function ui.toolWindow(id, pos, size, a, b, c) local fn = c or b or a if type(fn) == 'function' then return fn() end end
function ui.transparentWindow(id, pos, size, a, b, c) local fn = c or b or a if type(fn) == 'function' then return fn() end end
function ui.availableSpaceX() return 640 end
function ui.availableSpaceY() return 420 end
function ui.windowWidth() return 980 end
function ui.windowHeight() return 820 end
function ui.windowSize() return vec2(980, 820) end
function ui.windowPos() return vec2(100, 100) end
function ui.getCursor() return vec2(10, 10) end
function ui.getCursorX() return 10 end
function ui.getCursorY() return 10 end
function ui.measureDWriteText(t, size) return vec2(#tostring(t) * (size or 14) * 0.55, (size or 14) * 1.2) end
function ui.itemRectMax() return vec2(100, 20) end
function ui.itemRectMin() return vec2(0, 0) end
function ui.imageSize() return vec2(0, 0) end
function ui.mousePos() return vec2(STUB.mouse.x, STUB.mouse.y) end
function ui.mouseDelta() return vec2(0, 0) end
function ui.decodeImage() return nil end
function ui.toast(icon, msg) STUB.toasts[#STUB.toasts + 1] = msg return { button = function() end } end
function ui.ExtraCanvas()
  return setmetatable({}, { __index = function(_, k) return function(self) return self end end })
end
function ui.setClipboardText(t) STUB.clipboard = t end
if STUB_ONLINE_EXTRAS then
  STUB.onlineExtras = {}
  function ui.registerOnlineExtra(icon, title, available, uiCb, closeCb, flags)
    STUB.onlineExtras[#STUB.onlineExtras + 1] = { title = title, ui = uiCb, flags = flags }
  end
end
setmetatable(ui, { __index = function(_, k) return function() return nil end end })

-- render -----------------------------------------------------------------------------------------
render = {}
for _, e in ipairs({ 'BlendMode', 'CullMode', 'DepthMode', 'GLPrimitiveType', 'ProjectFace', 'ShadersType' }) do render[e] = enum() end
STUB.renderCallbacks = {}
function render.on(ev, fn) STUB.renderCallbacks[#STUB.renderCallbacks + 1] = fn return function() end end
local inBatch = false
function render.glBegin() inBatch = true; STUB.glVerts = 0 end
function render.glVertex()
  STUB.glVerts = STUB.glVerts + 1
  if STUB.glVerts > 36 then error('GLRenderer::vertex3f currentIndex> 36 (stub)') end
  STUB.glMaxVerts = math.max(STUB.glMaxVerts, STUB.glVerts)
end
function render.glEnd() inBatch = false end
function render.projectPoint(p) return vec2(960, 540) end
function render.createMouseRay() return { track = function() return -1 end, pos = vec3(), dir = vec3(0, -1, 0) } end
setmetatable(render, { __index = function(_, k) return function() return nil end end })

physics = setmetatable({ raycastTrack = function() return -1 end }, { __index = function() return function() end end })

script = {}

-- Advances the simulation one frame (dt seconds) and runs the script's per-frame functions.
function STUB.frameStep(dt)
  dt = dt or (1 / 60)
  STUB.sim.dt = dt
  STUB.sim.time = STUB.sim.time + dt * 1000
  STUB.frame = STUB.frame + 1
  if script.update then script.update(dt) end
  if script.draw3D then script.draw3D() end
  for _, fn in ipairs(STUB.renderCallbacks) do fn() end
  if script.drawUI then script.drawUI() end
end

return STUB
