-- CHT Drift Judge – Beállítások tab: search, "changed only" filter, collapsible groups, a description and
-- "Mit változtat" line for every setting, per-setting reset, module managers (HUD, Élő, Eredmény). CSP only.

local U = require('src/ui_common')
local schema = require('src/schema')
local storage = require('src/storage')
local colors = require('src/colors')
local visibility = require('src/visibility')
local platform = require('src/platform')
local controls = require('src/controls')

local S = {}

S.query = ''
S.onlyChanged = false
local confirmResetAll = false
local saveTimer = nil
local lastChange = nil -- { text, until }

local function now() return ac.getSim().time / 1000 end

local impactColors = { score = U.col.purple, zero = U.col.red, flag = U.col.dim, detect = U.col.cyan, display = U.col.dim, file = U.col.dim }

-- Opens the tab with a search text (global search) or with the changed-only filter.
function S.focus(query, onlyChanged)
  S.query = query or ''
  S.onlyChanged = onlyChanged == true
end

local function applied(app, it, old, new)
  app.applySettings()
  saveTimer = now() + 1.0
  local msg = schema.changeMessage(it, old, new)
  if app.judge and app.judge.state ~= 'idle' and it.store == 'scoring' then
    msg = msg .. ' A most futó futás még a régi értékkel fejeződik be.'
  elseif it.store == 'scoring' then
    msg = msg .. ' A következő futástól érvényes; régi futást a Futások fülön az Újrapontozással számolhatsz újra.'
  end
  lastChange = { text = msg, untilT = now() + 12 }
  if app.status then app.status(msg, U.col.purple, 8) end
end

local function control(app, it)
  local s = app.settings
  local v = schema.get(s, it)
  if it.kind == 'bool' then
    if ui.checkbox(it.label .. '##set_' .. it.key, v) then
      local old, new = schema.set(s, it, not v)
      applied(app, it, old, new)
    end
  elseif it.kind == 'combo' then
    ui.setNextItemWidth(300)
    ui.combo('##set_' .. it.key, schema.format(it, v), ui.ComboFlags.None, function()
      for _, o in ipairs(it.options) do
        if ui.selectable(o[2], o[1] == v) and o[1] ~= v then
          local old, new = schema.set(s, it, o[1])
          applied(app, it, old, new)
        end
      end
    end)
    ui.sameLine(0, 10)
    U.text(it.label, 14, U.col.text, true)
  else
    ui.setNextItemWidth(260)
    local nv, changed = ui.slider('##set_' .. it.key, v, it.min, it.max, it.fmt or '%.2f', 1)
    U.tip(it.desc)
    -- touch and go lines: moving one moves the other two in the same proportion (if switched on)
    local function setValue(val)
      local old = schema.get(s, it)
      local tierKeys = { tngTier1 = true, tngTier2 = true, tngTier3 = true }
      if tierKeys[it.key] and s.ui.tngProportional ~= false and old > 1e-3 then
        local f = val / old
        for k in pairs(tierKeys) do
          if k ~= it.key then
            local o = schema.byKey[k]
            schema.set(s, o, math.min(o.max, math.max(o.min, schema.get(s, o) * f)))
          end
        end
      end
      schema.set(s, it, val)
      return old
    end
    ui.sameLine(0, 4)
    local tv, tc = U.numberBox('set_' .. it.key, v, it.min, it.max, it.fmt, 62, it.desc)
    if tc then
      if it.int then tv = math.floor(tv + 0.5) end
      local old = setValue(tv)
      app.applySettings()
      applied(app, it, old, schema.get(s, it))
      changed = false
    end
    if changed then
      if it.int then nv = math.floor(nv + 0.5) end
      local old = setValue(nv)
      local new = schema.get(s, it)
      app.applySettings()
      saveTimer = now() + 1.0
      -- sliders change continuously: only the message is updated, the "applied" text says what changes
      lastChange = { text = schema.changeMessage(it, it._dragStart or old, new), untilT = now() + 12 }
      it._dragStart = it._dragStart or old
    elseif it._dragStart ~= nil and not ui.itemActive() then
      local start = it._dragStart
      it._dragStart = nil
      applied(app, it, start, schema.get(s, it))
    end
    ui.sameLine(0, 10)
    U.text(it.label, 14, U.col.text, true)
  end
end

local function row(app, it)
  local s = app.settings
  local changed = schema.isChanged(s, it)
  if it.key == 'tngTier1' then
    local prop = s.ui.tngProportional ~= false
    if ui.checkbox('Touch and go vonalak arányos állítása (egyet állítva a másik kettő is arányosan változik)##tngPropS', prop) then
      s.ui.tngProportional = not prop
      app.saveSettings()
    end
  end
  ui.pushID(it.key)
  control(app, it)
  if changed then
    ui.sameLine(0, 10)
    U.pill('MÓDOSÍTVA · alap: ' .. schema.format(it, schema.default(it)), U.col.purple)
    ui.sameLine(0, 8)
    if U.button('Alapra##rs_' .. it.key, 70, false, 'Visszaállítja az alapértéket: ' .. schema.format(it, schema.default(it))) then
      local old, new = schema.reset(s, it)
      applied(app, it, old, new)
    end
  end
  ui.indent(4)
  U.wrapped(it.desc, 12, U.col.dim)
  U.text('Mit változtat: ' .. it.effect, 12, rgbm(0.56, 0.85, 0.68, 1))
  ui.sameLine(0, 8)
  U.pill(schema.impacts[it.impact] or '', impactColors[it.impact] or U.col.dim)
  ui.unindent(4)
  ui.popID()
  ui.offsetCursorY(8)
end

-- "Adatmappák": open the data folders (also used on the Futások tab, compact = fewer buttons).
function S.foldersRow(app, compact)
  if platform.online then
    U.text('Az online (szerverről kapott) változat nem ment fájlt, ezért itt nincsenek mappák.', 12, U.col.dim)
    return
  end
  local first = true
  for _, f in ipairs(storage.folders()) do
    if not compact or f.id == 'runs' or f.id == 'allRuns' or f.id == 'debug' then
      if not first then ui.sameLine(0, 6) end
      first = false
      if U.button(f.label .. '##fold_' .. f.id .. (compact and 'c' or ''), 0, false, f.tip .. ' (' .. f.path .. ')') then
        if f.file then storage.showFile(f.path) else storage.openFolder(f.path) end
      end
    end
  end
end

function S.drawTab(app)
  local s = app.settings
  U.sectionTitle('Beállítások', 'Minden változás azonnal érvényes, és elmentődik.')
  S.query = U.searchBox('setq', 'Keresés a beállítások között: pl. korrekció, fal, szög, kerék, kuplung…', S.query)
  local changedList = schema.changedList(s)
  local nChanged = #changedList

  if U.button('Mind##fltAll', 60, false, 'Minden beállítás látszik.') then S.onlyChanged = false end
  ui.sameLine(0, 6)
  if U.button(string.format('Csak a módosítottak (%d)##fltCh', nChanged), 0, false, 'Csak azok, amelyek eltérnek az alapértéktől.') then S.onlyChanged = true end
  ui.sameLine(0, 6)
  U.text(S.onlyChanged and 'Szűrő: csak a módosítottak' or 'Szűrő: mind', 13, S.onlyChanged and U.col.purple or U.col.dim)
  ui.sameLine(math.max(420, ui.availableSpaceX() - 260))
  if confirmResetAll then
    if U.button('Igen, mind vissza alapra', 170) then
      schema.resetAll(s)
      app.applySettings()
      app.saveSettings()
      confirmResetAll = false
      lastChange = { text = 'Minden beállítás visszaállt az alapértékre.', untilT = now() + 8 }
    end
    ui.sameLine(0, 6)
    if U.button('Mégse##rsAll', 70) then confirmResetAll = false end
  else
    if U.button('Mind vissza alapra', 140, nChanged == 0, 'Minden pontozási és megjelenítési beállítást visszaállít (a pályaterveket nem érinti).') then confirmResetAll = true end
    if not platform.online then
      ui.sameLine(0, 6)
      if U.button('Mappa', 60, false, 'A beállításokat, pályaterveket és futásokat tartalmazó mappa megnyitása.') then storage.openFolder(storage.root()) end
    end
  end

  if lastChange and now() < lastChange.untilT then
    U.notice('lastChange', 'info', 'Változás', lastChange.text)
  end

  if not S.onlyChanged and schema.textMatches('pályarajz rajz zóna láthatóság ki be kapcsoló gyorsbillentyű billentyű hotkey ablak hud küldés szerver', S.query) then
    U.collapsible('set_draw', 'Pályarajz és gyorsbillentyűk', { sub = visibility.masterOn(s) and 'pályarajz: BE' or 'pályarajz: KI',
      forceOpen = S.query ~= '', defaultOpen = true,
      tip = 'Egy kapcsolóval minden pályarajz elrejthető (E01). A gyorsbillentyűket itt lehet átállítani: kattints a gombra, majd nyomd le az új billentyűt.' }, function()
      if ui.checkbox('Pályarajz bekapcsolva – zónák, színek, kapuk, feliratok, nyomvonal##masterDraw', visibility.masterOn(s)) then
        app.toggleTrackDraw()
      end
      U.wrapped('Kikapcsolva a program semmit nem rajzol a pályára (a pontozás ugyanúgy fut). Bekapcsolva az látszik, amit lent a „Mi látszódjon a pályán” rész a szerepedhez beállít.', 12, U.col.dim)
      ui.offsetCursorY(4)
      if controls.available then
        for _, d in ipairs(controls.defs) do
          if controls.has(d.id) then
            U.text(d.label, 14, U.col.text, true)
            U.tip(d.desc)
            ui.sameLine(190)
            controls.control(d.id, 200)
            ui.sameLine(0, 10)
            U.text('alap: ' .. d.defaultText, 12, U.col.dim)
          end
        end
      else
        U.text('Ebben a CSP-verzióban nincs gyorsbillentyű-kezelés; a pályarajz a fő ablak felső sorában kapcsolható.', 12, U.col.orange)
      end
      if not platform.online then
        ui.offsetCursorY(4)
        if ui.checkbox('Futásaim eredményének küldése a szerverre (a bíróknak)##sendRes', s.ui.sendResults ~= false) then
          if s.ui.sendResults == false then s.ui.sendResults = nil else s.ui.sendResults = false end
          app.saveSettings()
        end
        U.text('Csak AssettoServerrel működik; a bírók a Futások fülön látják a „Szerverről érkezett futások” között.', 12, U.col.dim)
      end
    end)
  end
  if not S.onlyChanged and schema.textMatches('online szerver változat steam bíró közvetítő szerep github pályaterv üzenet csatlakozás verzió csp', S.query) then
    S.serverInfo(app)
  end
  if not S.onlyChanged and schema.textMatches('teszt tesztadat adat küldés feltöltés google táblázat debug hiba napló internet', S.query) then
    S.uploadInfo(app)
  end

  local filtering = S.query ~= '' or S.onlyChanged
  local shown = 0
  for _, g in ipairs(schema.groups) do
    local items = {}
    local groupChanged = 0
    for _, it in ipairs(schema.byGroup[g.id]) do
      if schema.isChanged(s, it) then groupChanged = groupChanged + 1 end
      local ok = schema.visible(s, it) and schema.matches(it, S.query) and (not S.onlyChanged or schema.isChanged(s, it))
      if ok then items[#items + 1] = it end
    end
    if #items > 0 then
      shown = shown + #items
      U.collapsible('set_' .. g.id, g.title, {
        sub = g.sub,
        badge = groupChanged > 0 and string.format('%d módosítva', groupChanged) or nil,
        forceOpen = filtering, defaultOpen = false,
      }, function()
        for _, it in ipairs(items) do row(app, it) end
      end)
    end
  end
  if filtering and shown == 0 then
    U.notice('noHit', 'info', 'Nincs találat', S.onlyChanged and 'Minden beállítás az alapértéken van.' or 'Próbáld egy rövidebb szóval (pl. „szög”, „kerék”, „fal”). Ékezet nélkül is működik.')
  elseif filtering then
    U.text(string.format('%d találat', shown), 12, U.col.dim)
  end

  ui.offsetCursorY(6)
  local Live = require('src/ui_live')
  local Result = require('src/ui_result')
  local modHit = schema.textMatches('hud modul driftszög sebesség fokozat kormány gáz fék kézifék kuplung hajtás kipörgés zóna hiba méret háttér előbeállítás közvetítő minimál részletes', S.query)
  if not S.onlyChanged and modHit then
    U.collapsible('set_hud', 'HUD modulok', { sub = 'ki-be kapcsolás, sorrend, előbeállítás, méret, háttér', forceOpen = S.query ~= '', defaultOpen = true }, function()
      Live.drawHudSettings(app)
    end)
  end
  if schema.textMatches('mi látszik pályán megjelenés zóna név nevek felirat vonal kapu nyomvonal lefedettség kitöltés szín pályaelhagyás sáv szerep pilóta bíró közvetítő szerkesztő elrejtés', S.query) then
    local role = visibility.role(s)
    local nVis = 0
    for _, it in ipairs(visibility.items) do if visibility.isChanged(s, it.key, role) then nVis = nVis + 1 end end
    if not S.onlyChanged or nVis > 0 then
      U.collapsible('set_vis', 'Mi látszódjon a pályán', {
        sub = 'szerepenként: ' .. (visibility.roleLabel[role] or role) .. ' – zónanevek, vonalak, színek, kapuk, nyomvonal',
        badge = nVis > 0 and string.format('%d módosítva', nVis) or nil, forceOpen = S.query ~= '' or S.onlyChanged, defaultOpen = true,
        tip = 'Minden elemnél: Mindig / Csak a Pálya fülön (szerkesztéskor) / Soha – külön a pilóta, a bíró és a közvetítő szerephez.' }, function()
        U.text('Szerepem ezen a gépen:', 13, U.col.text, true)
        for _, r in ipairs(visibility.roles) do
          ui.sameLine(0, 6)
          if U.button(r[2] .. (role == r[1] and ' (aktív)' or '') .. '##role' .. r[1], 0, false, r[3]) then
            visibility.setRole(s, r[1]); app.saveSettings()
            role = visibility.role(s)
          end
        end
        U.wrapped('A szerep most gépenként választható. A 2. fázisban a bíró és a közvetítő szerepet a Steam ID-lista adja – az itt beállított láthatóság akkor is megmarad. '
          .. '„Csak a Pálya fülön” = csak akkor látszik, amikor a fő ablakban a Pálya fül nyitva van (szerkesztés), vezetés / bírálás közben nem.', 12, U.col.dim)
        ui.offsetCursorY(4)
        for _, it in ipairs(visibility.items) do
          local cur = visibility.mode(s, it.key, role)
          U.text(it.label, 14, U.col.text, true)
          U.tip(it.desc)
          ui.sameLine(260)
          for _, m in ipairs(visibility.modes) do
            ui.sameLine(0, 6)
            if U.button(m[2] .. (cur == m[1] and ' (aktív)' or '') .. '##vis_' .. it.key .. m[1], 0, false, it.desc) and cur ~= m[1] then
              visibility.set(s, it.key, m[1], role); app.saveSettings()
              lastChange = { text = string.format('%s (%s): %s → %s.', it.label, visibility.roleLabel[role], visibility.modeLabel[cur], visibility.modeLabel[m[1]]), untilT = now() + 8 }
            end
          end
          if visibility.isChanged(s, it.key, role) then
            ui.sameLine(0, 8)
            U.pill('MÓDOSÍTVA · alap: ' .. visibility.modeLabel[visibility.defaults[role][it.key]], U.col.purple)
          end
        end
        if nVis > 0 and U.button('Ennek a szerepnek az alapbeállítása##visReset', 0, false, 'A kiválasztott szerep láthatósági beállításai vissza az alapra.') then
          visibility.reset(s, role); app.saveSettings()
        end
      end)
    end
  end
  if schema.textMatches('zóna szín színek kitöltés átlátszó sárga kék piros zöld pályaelhagyás sáv határ', S.query) then
    local nCol = 0
    for _, k in ipairs(colors.keys) do if colors.isChanged(s, k) then nCol = nCol + 1 end end
    if not S.onlyChanged or nCol > 0 then
      U.collapsible('set_colors', 'Zónák színei', { sub = 'zónatípusonként – a pályán és a térképen', badge = nCol > 0 and string.format('%d módosítva', nCol) or nil,
        forceOpen = S.query ~= '' or S.onlyChanged, defaultOpen = false }, function()
        U.text('Kattints a színre a módosításhoz. Hogy mikor látszik a kitöltés: „Mi látszódjon a pályán”; az erőssége: Megjelenítés.', 12, U.col.dim)
        local flags = bit.bor(ui.ColorPickerFlags.NoAlpha or 0, ui.ColorPickerFlags.PickerHueBar or 0)
        for _, k in ipairs(colors.keys) do
          local c = colors.get(s, k)
          local col = rgbm(c[1], c[2], c[3], 1)
          if ui.colorButton('##zc_' .. k, col, flags, vec2(44, 22)) then
            colors.set(s, k, col.r, col.g, col.b)
            app.saveSoon()
          end
          ui.sameLine(0, 10)
          U.text(colors.labels[k], 14, U.col.text, true)
          if colors.isChanged(s, k) then
            ui.sameLine(0, 8)
            U.pill('MÓDOSÍTVA', U.col.purple)
            ui.sameLine(0, 6)
            if U.button('Alapra##zcr_' .. k, 0, false, 'Visszaállítja az alapszínt.') then colors.reset(s, k); app.saveSoon() end
          end
        end
        if nCol > 0 and U.button('Minden szín alapra##zcAll', 0, false, 'Minden zónaszín vissza az alapra.') then colors.reset(s); app.saveSoon() end
      end)
    end
  end
  if not S.onlyChanged and schema.textMatches('adatmappa mappa megnyitás fájl futások pályatervek debug beállítások küldés', S.query) then
    U.collapsible('set_folders', 'Adatmappák', { sub = 'futások, pályatervek, debug, beállítások – megnyitás egy gombbal', forceOpen = S.query ~= '', defaultOpen = true }, function()
      U.text('A gomb megnyitja a mappát a Windows Intézőben (innen küldhetők el a fájlok).', 12, U.col.dim)
      S.foldersRow(app, false)
      U.text('Hely: ' .. storage.root(), 12, U.col.dim)
    end)
  end
  if not S.onlyChanged and schema.textMatches('élő fül blokk modul elrendezés hibaszámláló zónák eddig futás kezelése', S.query) then
    U.collapsible('set_live', 'Élő fül blokkjai', { sub = 'ki-be kapcsolás és sorrend', forceOpen = S.query ~= '', defaultOpen = false }, function()
      if U.moduleManager('live', Live.tabState(app), Live.tabBlocks) then app.saveSettings() end
    end)
  end
  if not S.onlyChanged and schema.textMatches('eredmény fül szekció modul összegzés zónák stílus térkép események futás adatai', S.query) then
    U.collapsible('set_result', 'Eredmény fül szekciói', { sub = 'ki-be kapcsolás és sorrend', forceOpen = S.query ~= '', defaultOpen = false }, function()
      if U.moduleManager('result', Result.sectionState(app), Result.sections) then app.saveSettings() end
    end)
  end

  if saveTimer and now() > saveTimer then
    app.saveSettings()
    saveTimer = nil
  end
end

-- Online / server information: which version runs, what the server set, whether messages work.
function S.serverInfo(app)
  local N = app.netsync
  local rows = {}
  local function row(k, v, col) rows[#rows + 1] = { k, v, col } end
  row('Változat', platform.online and ('online (a szerverről kapott), ' .. tostring(app.version)) or ('telepített, ' .. tostring(app.version)))
  local okV, ver = pcall(ac.getPatchVersion)
  local okC, code = pcall(ac.getPatchVersionCode)
  row('CSP', (okV and tostring(ver) or '?') .. (okC and (' (build ' .. tostring(code) .. ')') or ''))
  if platform.online then
    local id = platform.steamID()
    row('Steam ID', id or 'ez a CSP nem adja meg – a szerep a Beállításokban választható', (not id) and U.col.orange or nil)
    local role = platform.serverRole()
    row('Szerep a szervertől', role == 'judge' and 'Bíró' or (role == 'streamer' and 'Közvetítő'
      or (role == 'admin' and 'Szerveradmin – bíróként látja a pontokat' or 'Pilóta (nem admin, nincs a bírók listáján)')),
      role and U.col.green or nil)
    row('Pontok a pilótáknak', platform.flag('pilotScores') and 'látszanak (pilotScores = 1)' or 'csak a bírók látják (pilotScores = 0)')
    local r = app.remote or {}
    local lay = r.state == 'ok' and ('letöltve: ' .. tostring(r.active)) or (r.state == 'loading' and 'letöltés…')
      or (r.state == 'error' and ('nem sikerült: ' .. tostring(r.error))) or '–'
    row('Pályaterv a szerverről', lay, r.state == 'error' and U.col.orange or nil)
    row('Telepített app ezen a gépen', app.passive and 'fut – az online változat ezért csendben marad' or 'nem fut')
  end
  if N then
    row('Üzenetek a szerveren', N.available() and 'működnek (AssettoServer)' or 'nem érhetők el (Kunos szerver vagy offline)', N.available() and U.col.green or U.col.dim)
    if N.lastError then row('Utolsó üzenethiba', N.lastError, U.col.orange) end
  end
  U.collapsible('set_server', 'Online változat és szerver', { sub = platform.online and 'a szerverről kapott változat' or 'telepített változat',
    defaultOpen = platform.online, tip = 'Mit állított be a szerver, és működik-e az adatcsere a gépek között.' }, function()
    for _, r in ipairs(rows) do
      U.text(r[1], 13, U.col.dim)
      ui.sameLine(220)
      U.text(r[2], 13, r[3] or U.col.text)
    end
    if platform.online then
      ui.offsetCursorY(4)
      if U.button('Pályaterv újratöltése a szerverről##reloadSrv', 0, false, 'Újra letölti a pályatervet a szerver GitHub-mappájából, és azt használja.') then
        app.loadServerLayouts(true)
      end
    end
  end)
end

-- Test data to the Google Sheet (src/upload.lua)
function S.uploadInfo(app)
  local up = app.upload
  if not up then return end
  local st = up.stats
  local state = up.stateText()
  local on = state == 'bekapcsolva'
  U.collapsible('set_upload', 'Tesztadatok küldése (Google táblázat)', { sub = state,
    badge = (st.failed or 0) > 0 and string.format('%d hiba', st.failed) or nil, badgeColor = U.col.orange,
    defaultOpen = false, tip = 'A tesztidőszakban a program a futásokat (a teljes felvétellel), a belépéseket és a hibákat elküldi a fejlesztő Google-táblázatába, hogy a gépeden is ellenőrizhető legyen, mi történt. Személyes adatot nem küld: csak a játékbeli nevet, az autót, a pályát és a futás adatait.' }, function()
    if not app.platform.online then
      if ui.checkbox('Tesztadatok küldése (futások, hibák)##uploadOn', app.settings.ui.uploadData ~= false) then
        if app.settings.ui.uploadData == false then app.settings.ui.uploadData = nil else app.settings.ui.uploadData = false end
        app.saveSettings()
      end
    else
      U.text('A szerver állítja (upload = 1 / 0 a szerver beállításaiban).', 12, U.col.dim)
    end
    local function row(k, v, col)
      U.text(k, 13, U.col.dim)
      ui.sameLine(220)
      U.text(v, 13, col or U.col.text)
    end
    row('Állapot', state, on and U.col.green or U.col.dim)
    row('Elküldve', tostring(st.sent or 0) .. (st.lastOkText and ('  (utolsó: ' .. st.lastOkText .. ')') or ''))
    if (st.queued or 0) > 0 then row('Küldésre vár', string.format('%d tétel, %.0f KB', st.queued, (st.bytes or 0) / 1024)) end
    if (st.failed or 0) > 0 or (st.dropped or 0) > 0 then
      row('Nem sikerült / eldobva', string.format('%d / %d', st.failed or 0, st.dropped or 0), U.col.orange)
    end
    if st.lastError then row('Utolsó hiba', tostring(st.lastError), U.col.orange) end
    U.wrapped('Mit küld: belépéskor a verziót, a CSP-t és azt, hogy a CSP mit tud; minden futás végén az eredményt és a teljes felvételt; a program hibáit és a festésfelismerés adatait. A küldés a háttérben megy, a játékot nem lassítja.', 12, U.col.dim)
  end)
end

return S
