-- CHT Drift Judge – where the program runs: installed Lua app, or online script sent by the server.
--
-- Installed app: apps/lua/CHT_DriftJudge (windows from manifest.ini, files in Documents).
-- Online script: the server's csp_extra_options.ini has a [SCRIPT_…] section with a GitHub link; CSP
-- downloads one bundled file when the player joins. Online scripts have no file access (SDK flag
-- withoutIO), no app windows and read their settings from the [SCRIPT_…] section (ac.configValues).
-- The bundle sets the global __CHT_ONLINE__ before anything else runs.

local callable = require('src/fn').callable
local P = {}

P.online = rawget(_G, '__CHT_ONLINE__') == true
P.bundleVersion = rawget(_G, '__CHT_BUNDLE_VERSION__')

-- Default address of the program's files on GitHub (layouts are fetched from here online).
P.defaultBase = 'https://raw.githubusercontent.com/martondavid04-design/cht-drift-judge/main/'

-- Values of the server's [SCRIPT_…] section (online only; defaults otherwise). Keys are lowerCamelCase,
-- as the SDK recommends, so they never collide with CSP's own keys.
local defaults = {
  base = P.defaultBase,      -- where layouts/ is (raw GitHub link of the repository, ending with /)
  layout = '',               -- layout name to load for this track ('' = first one found / 'Alap')
  judges = '',               -- Steam64 IDs of the judges, separated by commas or spaces
  broadcasters = '',         -- Steam64 IDs of the broadcaster (streamer) PCs
  pilotScores = 1,           -- 1 = pilots see their own points; 0 = only judges and broadcasters
  sendResults = 1,           -- 1 = finished runs are sent to everyone (the judges collect them)
  showWelcome = 1,           -- 1 = a short message on joining (how to open the program)
  upload = 1,                -- 1 = test data (runs, errors) go to the Google Sheet (src/upload.lua)
  uploadUrl = '',            -- other receiving address for the test data ('' = the built-in one)
}
P.server = {}
for k, v in pairs(defaults) do P.server[k] = v end
if P.online and ac.configValues then
  local ok, vals = pcall(ac.configValues, defaults)
  if ok and type(vals) == 'table' then
    for k, v in pairs(vals) do P.server[k] = v end
  end
end
local function flag(v) return v == true or v == 1 or v == '1' or v == 'true' end
function P.flag(key) return flag(P.server[key]) end

-- Own Steam ID, if this CSP version can tell it (nil otherwise).
function P.steamID()
  if P._steam ~= nil then return P._steam or nil end
  local id = nil
  if callable(ac.getUserSteamID) then
    local ok, v = pcall(ac.getUserSteamID)
    if ok and v ~= nil and tostring(v) ~= '' and tostring(v) ~= '0' then id = tostring(v) end
  end
  P._steam = id or false
  return id
end

local function idList(s)
  local r = {}
  for id in tostring(s or ''):gmatch('%d+') do r[id] = true end
  return r
end

-- Server admin? (AssettoServer: Steam IDs in the panel's Admins list are admins as soon as they join;
-- anyone else after „/admin <password>” in the chat.) CSP refreshes the flag on ac.checkAdminPrivileges().
function P.isAdmin()
  local ok, sim = pcall(ac.getSim)
  return ok and sim ~= nil and sim.isAdmin == true
end

P.adminCheckAt = 3                -- os.clock() of the next admin check
function P.updateAdmin()
  if not P.online or not callable(ac.checkAdminPrivileges) then return end
  local t = os.clock()
  if t < P.adminCheckAt then return end
  P.adminCheckAt = t + (P.isAdmin() and 300 or 60)
  pcall(ac.checkAdminPrivileges)
end

-- Role of a Steam ID in the server's own lists ([SCRIPT_…] judges / broadcasters), or nil.
function P.listedRole(steamId)
  if not steamId then return nil end
  steamId = tostring(steamId)
  if idList(P.server.judges)[steamId] then return 'judge' end
  if idList(P.server.broadcasters)[steamId] then return 'streamer' end
  return nil
end

-- Role chosen in the game by an admin (src/roles.lua sets this function): 'judge' | 'streamer' | nil.
P.assignedRole = nil

-- Role on the server (online): 'judge' | 'streamer' | 'admin' | nil (= pilot), and where it comes from.
-- Order: the server's lists, then what an admin chose in the game (0.3.15), then being a server admin.
function P.serverRole()
  local role = P.roleSource()
  return role
end
function P.roleSource()
  if not P.online then return nil, nil end
  local me = P.steamID()
  if me then
    local listed = P.listedRole(me)
    if listed then return listed, 'list' end
    local a = P.assignedRole and P.assignedRole()
    if a == 'judge' or a == 'streamer' then return a, 'assigned' end
  end
  if P.isAdmin() then return 'admin', 'admin' end
  return nil, nil
end

-- May this PC see points? Installed app: always (the role is chosen on the PC). Online: judges and
-- broadcasters always, pilots only if the server allows it (pilotScores = 1).
function P.canSeeScores()
  if not P.online then return true end
  if P.serverRole() then return true end
  return P.flag('pilotScores')
end

P.canWriteFiles = not P.online

-- Version numbers: '0.3.10' > '0.3.9' (compared part by part as numbers).
function P.versionLess(a, b)
  local pa, pb = {}, {}
  for n in tostring(a or ''):gmatch('%d+') do pa[#pa + 1] = tonumber(n) end
  for n in tostring(b or ''):gmatch('%d+') do pb[#pb + 1] = tonumber(n) end
  for i = 1, math.max(#pa, #pb) do
    local x, y = pa[i] or 0, pb[i] or 0
    if x ~= y then return x < y end
  end
  return false
end

-- Online: is the installed app (apps/lua/CHT_DriftJudge) also on this PC, and which version?
-- Returns the version string, false (not installed) or nil (this CSP does not let the online script look).
-- Installed 0.3.8+ tells the online copy that it runs (src/netsync.lua presence), older ones do not –
-- then both would run, so the online copy warns about it.
local installedChecked, installedVersion = false, nil
function P.installedAppVersion()
  if installedChecked then return installedVersion end
  installedChecked = true
  local ok, v = pcall(function()
    if type(io) ~= 'table' or not callable(io.load) or not callable(ac.getFolder) then return nil end
    local apps = ac.getFolder(ac.FolderID and ac.FolderID.ACApps or 23)
    if type(apps) ~= 'string' or apps == '' then return nil end
    local text = io.load(apps .. '/lua/CHT_DriftJudge/manifest.ini')
    if type(text) ~= 'string' or text == '' then
      if callable(io.dirExists) and io.dirExists(apps .. '/lua/CHT_DriftJudge') then return '?' end
      return false
    end
    return text:match('VERSION%s*=%s*([%w%.%-]+)') or '?'
  end)
  installedVersion = ok and v or nil
  return installedVersion
end

-- Online: an installed app that runs next to us without telling it (older than 0.3.8, or unknown).
function P.oldInstalledApp()
  if not P.online then return nil end
  local v = P.installedAppVersion()
  if not v then return nil end
  if v == '?' or P.versionLess(v, '0.3.8') then return v end
  return nil
end

return P
