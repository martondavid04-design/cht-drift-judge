-- CHT Drift Judge – files on disk (CSP only).
-- Everything lives in “Documents/Assetto Corsa/CHT Drift Judge/” so testers can easily find and send files:
--   settings.json
--   layouts/<track id>/<layout name>.json
--   runs/<track id>/<date>_<driver>.json   (result + embedded layout + full telemetry)

local storage = {}
local callable = require('src/fn').callable
local platform = require('src/platform')

-- File backend -------------------------------------------------------------------------------------
-- Installed app: the real files (io). Online script (sent by the server): no file access, so the same
-- functions work on an in-memory store; settings, layouts and the judges' deductions are kept between
-- sessions in CSP's own storage (ac.storage: Documents/Assetto Corsa/cfg/extension/state/lua), runs only
-- for the session (the last MAX_MEM_RUNS with telemetry).
local fs = io
local MAX_MEM_RUNS = 15
storage.online = platform.online

if platform.online then
  local mem = {}
  local dirs = {}
  local function norm(p) return (tostring(p):gsub('\\', '/'):gsub('//+', '/')) end
  local function parentOf(p) return norm(p):match('^(.*)/[^/]*$') end
  local function persistent(p) return p:find('/settings%.json$') or p:find('/layouts/') or p:find('/biroi_levonasok%.json$') end

  -- ac.storage keeps strings in an INI file: keys are slot numbers, values are escaped
  local okS, store = pcall(function() return ac.storage end)
  if not okS then store = nil end
  local function enc(v) return (v:gsub('[%%;\r\n"\'\\]', function(c) return string.format('%%%02X', c:byte()) end)) end
  local function dec(v) return (v:gsub('%%(%x%x)', function(h) return string.char(tonumber(h, 16)) end)) end
  local index = {}
  local function sget(k) if not store then return nil end local ok, v = pcall(function() return store[k] end) if ok then return v end end
  local function sset(k, v) if store then pcall(function() store[k] = v end) end end

  -- 0.3.11: one fixed storage place (ac.storageSetPath), so a new program version (a new file from the
  -- server) always finds the layouts and settings saved by the earlier ones. What 0.3.8–0.3.10 saved in
  -- CSP's default place is copied over once.
  do
    local oldRaw = sget('cht_index')
    local old = {}
    if type(oldRaw) == 'string' and oldRaw ~= '' then
      old.cht_index = oldRaw
      local okO, t = pcall(JSON.parse, dec(oldRaw))
      if okO and type(t) == 'table' then
        for _, slot in pairs(t) do
          local v = sget('cht_f' .. tostring(slot))
          if type(v) == 'string' then old['cht_f' .. tostring(slot)] = v end
        end
      end
    end
    storage.fixedPlace = callable(ac.storageSetPath) and pcall(ac.storageSetPath, 'cht_drift_judge') or false
    if storage.fixedPlace and old.cht_index and sget('cht_index') == nil then
      for k, v in pairs(old) do sset(k, v) end
      storage.movedOld = true
    end
  end

  do
    local raw = sget('cht_index')
    local ok, t = pcall(JSON.parse, raw and dec(raw) or '')
    if ok and type(t) == 'table' then index = t end
    for path, slot in pairs(index) do
      local v = sget('cht_f' .. tostring(slot))
      if type(v) == 'string' then mem[path] = dec(v) end
    end
  end
  local function saveIndex() local ok, t = pcall(JSON.stringify, index) if ok then sset('cht_index', enc(t)) end end
  local function persist(p, text)
    local slot = index[p]
    if not slot then
      local used = {}
      for _, s_ in pairs(index) do used[s_] = true end
      slot = 1
      while used[slot] do slot = slot + 1 end
      index[p] = slot
      saveIndex()
    end
    sset('cht_f' .. tostring(slot), enc(text))
  end
  local function dropOldRuns(dir)
    local names = {}
    for p in pairs(mem) do
      local d, n = p:match('^(.*)/([^/]+)$')
      if d == dir and n ~= 'index.json' and n ~= 'biroi_levonasok.json' then names[#names + 1] = n end
    end
    table.sort(names)
    while #names > MAX_MEM_RUNS do mem[dir .. '/' .. table.remove(names, 1)] = nil end
  end
  fs = {
    load = function(p) return mem[norm(p)] end,
    save = function(p, text)
      p = norm(p)
      mem[p] = tostring(text)
      if persistent(p) then persist(p, mem[p]) end
      if p:find('/runs/') then dropOldRuns(parentOf(p)) end
      return true
    end,
    fileExists = function(p) return mem[norm(p)] ~= nil end,
    dirExists = function(p) return dirs[norm(p)] == true end,
    createDir = function(p) p = norm(p) while p and p ~= '' do dirs[p] = true; p = parentOf(p) end return true end,
    createFileDir = function(p) local d = parentOf(p) if d then dirs[d] = true end return true end,
    scanDir = function(d, mask)
      d = norm(d)
      local ext = mask and mask:match('%*(%..+)$')
      local r = {}
      for p in pairs(mem) do
        local dir, name = p:match('^(.*)/([^/]+)$')
        if dir == d and (not ext or name:sub(-#ext) == ext) then r[#r + 1] = name end
      end
      table.sort(r)
      return r
    end,
  }
  fs.saveAsync = function(p, text, cb) local ok = fs.save(p, text) if cb then cb(not ok and 'Mentési hiba' or nil) end end
end
storage.fs = fs

local function sanitizeName(s)
  s = tostring(s or '')
  s = s:gsub('[\\/:%*%?"<>|%c]', '_'):gsub('^%s+', ''):gsub('%s+$', '')
  if s == '' then s = 'nevtelen' end
  return s
end
storage.sanitizeName = sanitizeName

local root
function storage.root()
  if root then return root end
  if platform.online then
    root = 'online:/CHT Drift Judge'
    return root
  end
  local docs = ac.getFolder(ac.FolderID.ACDocuments)
  local candidate = docs .. '/CHT Drift Judge'
  if fs.dirExists(candidate) or fs.createDir(candidate) then
    root = candidate
  else
    root = ac.getFolder(ac.FolderID.ScriptConfig)
    fs.createDir(root)
  end
  return root
end

function storage.trackKey()
  local id = ac.getTrackFullID('__')
  return sanitizeName(id)
end

function storage.layoutsDir()
  local d = storage.root() .. '/layouts/' .. storage.trackKey()
  fs.createDir(d)
  return d
end

function storage.runsDir()
  local d = storage.root() .. '/runs/' .. storage.trackKey()
  fs.createDir(d)
  return d
end

function storage.debugDir()
  local d = storage.root() .. '/debug'
  fs.createDir(d)
  return d
end

function storage.readJSON(path)
  local data = fs.load(path)
  if not data or data == '' then return nil end
  local ok, parsed = pcall(JSON.parse, data)
  if ok then return parsed end
  return nil
end

function storage.writeJSON(path, value, async, callback)
  local ok, text = pcall(JSON.stringify, value)
  if not ok then
    ac.warn('CHT Drift Judge: JSON hiba', text)
    if callback then callback('JSON hiba') end
    return false
  end
  fs.createFileDir(path)
  if async then
    fs.saveAsync(path, text, function(err) if callback then callback(err) end end, true)
    return true
  end
  local saved = fs.save(path, text, true)
  if callback then callback(not saved and 'Mentési hiba' or nil) end
  return saved
end

-- Settings ------------------------------------------------------------------------------------------

function storage.loadSettings()
  local s = storage.readJSON(storage.root() .. '/settings.json')
  if type(s) ~= 'table' then s = {} end
  if type(s.scoring) ~= 'table' then s.scoring = {} end
  if type(s.ui) ~= 'table' then s.ui = {} end
  if type(s.activeLayouts) ~= 'table' then s.activeLayouts = {} end
  return s
end

function storage.saveSettings(s)
  return storage.writeJSON(storage.root() .. '/settings.json', s)
end

-- Layouts -------------------------------------------------------------------------------------------

function storage.listLayouts()
  local dir = storage.layoutsDir()
  local files = fs.scanDir(dir, '*.json') or {}
  local names = {}
  for _, f in ipairs(files) do
    names[#names + 1] = f:gsub('%.json$', '')
  end
  table.sort(names)
  return names
end

function storage.layoutPath(name)
  return storage.layoutsDir() .. '/' .. sanitizeName(name) .. '.json'
end

function storage.loadLayout(name)
  return storage.readJSON(storage.layoutPath(name))
end

function storage.saveLayout(l)
  l.modified = os.time()
  if not l.created then l.created = l.modified end
  return storage.writeJSON(storage.layoutPath(l.name), l)
end

-- Runs ----------------------------------------------------------------------------------------------

local function timestampForFile()
  local ok, s = pcall(os.date, '%Y-%m-%d_%H-%M-%S')
  if ok and type(s) == 'string' then return s end
  return tostring(math.floor(ac.getSim().systemTime))
end

local function timestampHuman()
  local ok, s = pcall(os.date, '%Y.%m.%d. %H:%M:%S')
  if ok and type(s) == 'string' then return s end
  return ''
end
storage.timestampHuman = timestampHuman

function storage.saveRun(record, callback)
  local name = timestampForFile() .. '_' .. sanitizeName(record.header and record.header.driver or 'pilota')
  if record.tag then name = name .. '_' .. record.tag end
  local path = storage.runsDir() .. '/' .. name .. '.json'
  storage.writeJSON(path, record, true, function(err)
    if callback then callback(err, path) end
  end)
  return path
end

-- The runs folder also holds the run index, the judges' deductions and the results received from the
-- server: those are not runs.
local notRuns = { ['index.json'] = true, ['biroi_levonasok.json'] = true, ['szerver_futasok.json'] = true }
function storage.isRunFile(name) return not notRuns[name] end

-- Lightweight index of saved runs (reads files; called on demand from the Runs tab).
function storage.listRuns()
  local dir = storage.runsDir()
  local all = fs.scanDir(dir, '*.json') or {}
  local files = {}
  for _, f in ipairs(all) do if storage.isRunFile(f) then files[#files + 1] = f end end
  table.sort(files, function(a, b) return a > b end)
  return dir, files
end

function storage.allRunsDir()
  local d = storage.root() .. '/runs'
  fs.createDir(d)
  return d
end

function storage.allLayoutsDir()
  local d = storage.root() .. '/layouts'
  fs.createDir(d)
  return d
end

function storage.settingsPath() return storage.root() .. '/settings.json' end

-- Windows Explorer wants backslashes (the folders are built with "/").
function storage.nativePath(p) return (tostring(p or ''):gsub('/', '\\')) end

function storage.openFolder(path)
  if platform.online then return false end
  fs.createDir(path)
  if os.openInExplorer then pcall(os.openInExplorer, storage.nativePath(path)) end
  return true
end

-- Opens the folder of a file with the file selected.
function storage.showFile(path)
  if platform.online then return false end
  if os.showInExplorer and fs.fileExists and fs.fileExists(path) then
    pcall(os.showInExplorer, storage.nativePath(path))
  else
    storage.openFolder((tostring(path):gsub('[/\\][^/\\]*$', '')))
  end
end

-- The data folders, for the "Adatmappák" buttons.
function storage.folders()
  return {
    { id = 'root', label = 'Fő mappa', path = storage.root(), tip = 'Dokumentumok / Assetto Corsa / CHT Drift Judge – minden adat itt van.' },
    { id = 'layouts', label = 'Pályatervek (ez a pálya)', path = storage.layoutsDir(), tip = 'Az aktuális pálya pályatervei (.json).' },
    { id = 'runs', label = 'Futások (ez a pálya)', path = storage.runsDir(), tip = 'Az aktuális pályán mentett futások, teljes telemetriával – ezeket kell elküldeni hangoláshoz.' },
    { id = 'allRuns', label = 'Összes futás', path = storage.allRunsDir(), tip = 'Minden pálya futásai, pályánként külön mappában.' },
    { id = 'allLayouts', label = 'Összes pályaterv', path = storage.allLayoutsDir(), tip = 'Minden pálya pályatervei.' },
    { id = 'debug', label = 'Debug', path = storage.debugDir(), tip = 'A festésfelismerés képei és adatai (festes_*.png, festes_utolso.json) – hibánál ezeket küldd el.' },
    { id = 'settings', label = 'Beállítások fájl', path = storage.settingsPath(), file = true, tip = 'A settings.json fájl (kijelölve mutatja a mappájában).' },
  }
end

-- Judges' deductions (A12, A16): per run file, { amount = points, note = text }. Kept next to the runs.
function storage.deductionsPath() return storage.runsDir() .. '/biroi_levonasok.json' end
function storage.loadDeductions()
  local t = storage.readJSON(storage.deductionsPath())
  return type(t) == 'table' and t or {}
end
function storage.saveDeductions(t) return storage.writeJSON(storage.deductionsPath(), t) end

-- Layouts on the server (GitHub) --------------------------------------------------------------------
-- base/layouts/<track key>/index.json  = list of layout names (optional)
-- base/layouts/<track key>/<name>.json = the layout
local function urlEncode(s)
  return (tostring(s):gsub('[^%w%-%._~]', function(c) return string.format('%%%02X', c:byte()) end))
end
storage.urlEncode = urlEncode

function storage.remoteLayoutURL(name, base)
  base = base or platform.server.base or platform.defaultBase
  if base:sub(-1) ~= '/' then base = base .. '/' end
  return base .. 'layouts/' .. urlEncode(storage.trackKey()) .. '/' .. urlEncode(name) .. '.json'
end

function storage.remoteIndexURL(base)
  base = base or platform.server.base or platform.defaultBase
  if base:sub(-1) ~= '/' then base = base .. '/' end
  return base .. 'layouts/' .. urlEncode(storage.trackKey()) .. '/index.json'
end

-- Online: layouts the installed app saved on this PC (Documents/Assetto Corsa/CHT Drift Judge/layouts/<track>)
-- are taken over (read only), if this CSP lets the online script read them. A layout already in the online
-- storage under the same name is kept. Returns the names taken over and the reason when it was not possible.
function storage.importInstalledLayouts()
  if not platform.online then return {}, 'nem online' end
  local ok, res, why = pcall(function()
    if type(io) ~= 'table' or not callable(io.load) or not callable(io.scanDir) then return {}, 'nincs fájlolvasás' end
    local docs = ac.getFolder(ac.FolderID and ac.FolderID.ACDocuments or 'ACDocuments')
    if type(docs) ~= 'string' or docs == '' then return {}, 'nincs Dokumentumok mappa' end
    local dir = docs .. '/CHT Drift Judge/layouts/' .. storage.trackKey()
    local files = io.scanDir(dir, '*.json')
    if type(files) ~= 'table' then return {}, 'a mappa nem olvasható' end
    local names = {}
    for _, f in ipairs(files) do
      local name = tostring(f):gsub('%.json$', '')
      local target = storage.layoutPath(name)
      if not fs.fileExists(target) then
        local text = io.load(dir .. '/' .. f)
        local okP, data = pcall(JSON.parse, text or '')
        if okP and type(data) == 'table' and type(data.zones) == 'table' then
          fs.save(target, text)
          names[#names + 1] = name
        end
      end
    end
    return names, (#files == 0) and 'nincs ilyen pályaterv' or nil
  end)
  if not ok then return {}, tostring(res) end
  return res or {}, why
end

-- Downloads go one at a time (CSP allows two requests at once; the test-data upload uses the other one).
-- A request without an answer for 30 s counts as failed, so one stuck request never blocks the rest.
local webQueue, webCurrent = {}, nil
local function webNext()
  if webCurrent then return end
  local job = table.remove(webQueue, 1)
  if not job then return end
  local done = false
  local function finish(err, response)
    if done then return end
    done = true
    if webCurrent == job then webCurrent = nil end
    pcall(job.cb, err, response)
    webNext()
  end
  job.finish, job.started = finish, os.clock()
  webCurrent = job
  local ok, e = pcall(web.get, job.url, finish)
  if not ok then finish(tostring(e)) end
end

local function webGet(url, cb)
  if type(web) ~= 'table' or not callable(web.get) then cb('nincs web.get') return end
  webQueue[#webQueue + 1] = { url = url, cb = cb }
  webNext()
end

-- Called every frame: gives up on a request that got no answer in 30 s.
function storage.webTick()
  if webCurrent and os.clock() - (webCurrent.started or 0) > 30 then webCurrent.finish('nincs válasz 30 mp alatt') end
end

-- callback(err, text). Follows redirects itself too (the Google script answers with one).
function storage.fetchText(url, callback, hops)
  hops = hops or 0
  webGet(url, function(err, response)
    if err then callback(tostring(err)) return end
    local status = response and response.status or 0
    if (status == 301 or status == 302 or status == 303 or status == 307 or status == 308) and hops < 3 then
      local loc = nil
      pcall(function() for k, v in pairs(response.headers or {}) do if tostring(k):lower() == 'location' then loc = tostring(v) end end end)
      if loc and loc ~= '' then storage.fetchText(loc, callback, hops + 1) return end
    end
    if status ~= 200 then callback('HTTP ' .. tostring(status)) return end
    callback(nil, tostring(response.body or ''))
  end)
end

-- callback(err, parsedJSON, text). Only for small JSON files; errors are strings.
function storage.fetchJSON(url, callback)
  storage.fetchText(url, function(err, text)
    if err then callback(err) return end
    local okP, data = pcall(JSON.parse, text)
    if not okP or data == nil then callback('hibás JSON') return end
    callback(nil, data, text)
  end)
end

-- A file's text as it is (layout sync compares texts, so it must not be re-encoded).
function storage.readText(path) return fs.load(path) end
function storage.writeText(path, text)
  fs.createFileDir(path)
  return fs.save(path, text, true)
end

-- Short, stable fingerprint of a text (djb2, within the exact range of Lua numbers) + its length.
function storage.textHash(text)
  text = tostring(text or '')
  local h = 5381
  for i = 1, #text do h = (h * 33 + text:byte(i)) % 2147483647 end
  return string.format('%x-%d', h, #text)
end

return storage
