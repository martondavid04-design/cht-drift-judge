-- CHT Drift Judge – judges and broadcaster PCs chosen in the game by a server admin (0.3.15).
--
-- No Steam IDs have to be collected: every PC with the program tells the others its own Steam ID on the
-- server (netsync „hello”), so an admin sees everyone in the Versenyzők tab and makes them Bíró /
-- Közvetítő / Pilóta with one click. The choice is kept in the Google sheet (Szerepek lap; latest per
-- Steam ID wins, a row added there by hand counts too), so it holds on every later join and on every CHT
-- server. The public list (…?action=roles) carries only a fingerprint of each Steam ID (hashId), never
-- the ID itself. After a change the admin's PC pings the others, and the PC concerned re-reads the list
-- at once.
-- The judges / broadcasters lists in the server's [SCRIPT_…] section still work and come first.
--
-- Limit: the program is public, so the store cannot prove that a change came from an admin – the program
-- only offers the buttons to admins, and every change is logged with who made it (Szerepek lap).

local callable = require('src/fn').callable
local platform = require('src/platform')
local storage = require('src/storage')
local upload = require('src/upload')

local R = {}
R.list = nil            -- { [fingerprint] = 'judge' | 'streamer' } from the store; nil = not read yet
R.state = 'none'        -- 'none' | 'loading' | 'ok' | 'error'
R.lastError = nil
R.fetchedAt = nil
R.refreshEvery = 600    -- s
R.retryAfter = 30       -- s after a failed read
R.pending = {}          -- [steamId] = role being saved (shown at once in the admin's list)
local app = nil
local nextTry = 0
local again = false

R.clockFn = nil
local function clock() return (R.clockFn or os.clock)() end

-- Same as hashId_ in tools/gsheet_collector.gs: two rolling hashes of 'cht-dj:<Steam ID>'.
function R.hashId(id)
  local s = 'cht-dj:' .. tostring(id)
  local a, b = 7, 11
  for i = 1, #s do
    local c = s:byte(i)
    a = (a * 31 + c) % 2147483647
    b = (b * 131 + c) % 1000000007
  end
  return string.format('%08x%08x', a, b)
end

local function isRole(r) return r == 'judge' or r == 'streamer' end

-- Role of a Steam ID: a change being saved, then the server's lists, then the store.
function R.roleOf(steamId)
  if not steamId or steamId == '' then return nil end
  steamId = tostring(steamId)
  local p = R.pending[steamId]
  if p then return isRole(p) and p or nil end
  local fixed = platform.listedRole and platform.listedRole(steamId)
  if fixed then return fixed end
  if not R.list then return nil end
  return R.list[R.hashId(steamId)]
end

-- This PC's role from the store (until the first answer: what was read last time, if it was for this ID).
function R.own()
  local me = platform.steamID()
  if not me then return nil end
  if R.list then return R.list[R.hashId(me)] end
  local c = app and app.settings and app.settings.ui and app.settings.ui.roleCache
  if type(c) == 'table' and c.h == R.hashId(me) and isRole(c.role) then return c.role end
  return nil
end

local function remember()
  if not app or not app.settings then return end
  local me = platform.steamID()
  if not me then return end
  local h = R.hashId(me)
  local role = R.list and R.list[h] or nil
  local c = app.settings.ui.roleCache
  local cur = type(c) == 'table' and c.h == h and c.role or nil
  if cur ~= role then
    app.settings.ui.roleCache = role and { h = h, role = role } or nil
    if app.saveSettings then pcall(app.saveSettings) end
  end
end

function R.url() return upload.target() .. '?action=roles' end

function R.fetch(why)
  if R.state == 'loading' then again = true return end
  if not upload.target():find('^https://') then return end
  R.state = 'loading'
  storage.fetchJSON(R.url(), function(err, data)
    if err or type(data) ~= 'table' or data.ok ~= true or type(data.roles) ~= 'table' then
      R.state = 'error'
      R.lastError = tostring(err or (type(data) == 'table' and data.error) or 'rossz válasz')
      nextTry = clock() + R.retryAfter
    else
      local list = {}
      for _, r in ipairs(data.roles) do
        if type(r) == 'table' and r.h ~= nil and isRole(r.role) then list[tostring(r.h)] = r.role end
      end
      R.list, R.state, R.lastError, R.fetchedAt = list, 'ok', nil, clock()
      -- a saved change is now in the list (or the list says otherwise: the store wins)
      R.pending = {}
      remember()
    end
    if again then again = false; R.fetch('again') end
  end)
end

-- Every frame. Only on an online server (roles do not matter offline).
function R.update()
  local okS, sim = pcall(ac.getSim)
  local online = platform.online or (okS and sim and sim.isOnlineRace == true)
  if not online then return end
  local t = clock()
  if R.state == 'loading' then return end
  if not R.fetchedAt then
    if t >= nextTry then R.fetch('start') end
  elseif t - R.fetchedAt > R.refreshEvery then
    R.fetch('periodic')
  end
end

-- May this PC hand out roles? (server admin: Admins list of the panel, or „/admin <password>” in the chat)
function R.canAssign()
  return platform.isAdmin() and upload.target():find('^https://') ~= nil and app ~= nil and app.netsync ~= nil
end

-- Admin: give `role` ('judge' | 'streamer' | 'pilot') to the driver in car `carIndex`. cb(ok, err)
function R.assign(carIndex, role, cb)
  local N = app and app.netsync
  local peer = N and N.peers and N.peers[carIndex]
  if not peer or not peer.steamId then if cb then cb(false, 'ettől a pilótától nem jött Steam ID (nem fut nála a program?)') end return false end
  if role ~= 'pilot' and not isRole(role) then if cb then cb(false, 'ismeretlen szerep') end return false end
  local okN, name = pcall(ac.getDriverName, carIndex)
  local steamId = peer.steamId
  R.pending[steamId] = role
  local ok = upload.role({ steamId = steamId, name = okN and name or peer.name or '', role = role }, function(done, err)
    if done then
      if R.list then R.list[R.hashId(steamId)] = isRole(role) and role or nil end
      if N.sendRolePing then N.sendRolePing(steamId) end
      R.fetch('assigned')
    else
      R.pending[steamId] = nil
    end
    if cb then cb(done, err) end
  end)
  if not ok then R.pending[steamId] = nil end
  return ok
end

-- A ping from an admin's PC: re-read the list if it is about this PC (or this PC hands out roles too).
function R.onPing(steamId)
  local me = platform.steamID()
  if (me and tostring(steamId) == me) or platform.isAdmin() then R.fetch('ping') end
end

function R.stateText()
  if R.state == 'loading' then return 'olvasás…' end
  if R.state == 'error' then return 'nem sikerült: ' .. tostring(R.lastError) end
  if R.state == 'ok' then
    local n = 0
    for _ in pairs(R.list or {}) do n = n + 1 end
    return string.format('%d kijelölt bíró / közvetítő', n)
  end
  return 'még nincs beolvasva'
end

function R.init(a)
  app = a
  platform.assignedRole = R.own
end

-- offline tests
function R._reset()
  R.list, R.state, R.lastError, R.fetchedAt, R.pending = nil, 'none', nil, nil, {}
  nextTry, again = 0, false
end

return R
