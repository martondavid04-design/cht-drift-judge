-- CHT Drift Judge – Pálya tab, 6. step: accel / decel map of the layout for tandem (A15, DM 1.11).
--
-- 1. a reference line from a run (the last result on this layout: a point every 2 m),
-- 2. sections along it: green (keep or gain speed), orange (small change, no brake / handbrake),
--    red (may slow down) – by driving to the place („Kezdete itt” / „Vége itt”) or typing the metres.
-- In a tandem run the lead is checked against it; the judges see where it did not follow it.

local U = require('src/ui_common')
local decelmap = require('src/decelmap')

local D = {}

local draft = { from = nil, to = nil, color = 'green' }
local colorOf = { green = U.col.green, orange = U.col.orange, red = U.col.red }

-- Where the car is on the reference line now (m), or nil.
function D.carPosition(app)
  local cm = app.compiled and app.compiled.decel
  local s = app.lastSample
  if not cm or not s or not s.px then return nil end
  local pos, lat = decelmap.project(cm, s.px, s.pz)
  if lat > 25 then return nil, lat end
  return pos, lat
end

function D.summary(l)
  local d = l and l.decelMap
  if not d or #(d.path or {}) < 2 then return 'nincs (nem kötelező)', false end
  return string.format('%.0f m útvonal · %d szakasz', decelmap.pathLength(d.path), #(d.segments or {})), #(d.segments or {}) > 0
end

function D.panel(app, hooks)
  local l = app.layout
  local d = l.decelMap
  U.wrapped('Tandemben a lead pilótának ezt kell követnie (DM 2025): ZÖLD – gyorsítás vagy tempótartás; NARANCS – kis tempóváltás, fék és kézifék nélkül; '
    .. 'PIROS – itt lassíthat (kézifék, fék, gázelvétel). A program a lead futásában megjelöli, hol nem így ment; a pontot a bírók döntik el. '
    .. 'Előbb egy útvonal kell (egy futásból), aztán rá a szakaszok.', 12, U.col.dim)
  local res = app.lastResult
  local tested = res and app.resultLayout == l and res.trace and #res.trace > 10
  if U.button((d and #(d.path or {}) >= 2) and 'Útvonal újra a legutóbbi futásból##dmPath' or 'Útvonal a legutóbbi futásból##dmPath', 0, not tested,
    'A legutóbbi futás (ezzel a pályatervvel) nyomvonala lesz a térkép vonala, 2 méterenként egy pont. A szakaszok méterben vannak a vonal mentén – ha az új vonal más hosszú, ellenőrizd őket.') then
    hooks.pushUndo()
    l.decelMap = l.decelMap or { segments = {} }
    l.decelMap.path = decelmap.pathFromSamples(res.trace, 2)
    l.decelMap.segments = l.decelMap.segments or {}
    hooks.changed()
    d = l.decelMap
  end
  if not tested then
    ui.sameLine(0, 8)
    U.text('(előbb egy futás kell ezzel a pályatervvel)', 12, U.col.dim)
  end
  if not d or #(d.path or {}) < 2 then return end
  local len = decelmap.pathLength(d.path)
  U.text(string.format('Útvonal: %.0f m, %d pont', len, #d.path), 13, U.col.text, true)
  local pos, lat = D.carPosition(app)
  ui.sameLine(0, 16)
  if pos then U.text(string.format('Az autó most: %.0f m (%.1f m-re a vonaltól)', pos, lat or 0), 13, U.col.cyan)
  else U.text('Az autó most nincs a vonal közelében', 13, U.col.dim) end

  -- new segment
  U.text('Új szakasz', 13, U.col.text, true)
  for _, c in ipairs(decelmap.colors) do
    ui.sameLine(0, 6)
    local active = draft.color == c
    if U.button((active and '● ' or '') .. decelmap.short[c] .. '##dmCol_' .. c, 0, false, decelmap.names[c]) then draft.color = c end
  end
  U.text('Kezdete, m:', 12, U.col.dim)
  ui.sameLine(90)
  local v, ch = U.numberBox('dmFrom', draft.from or 0, 0, len, '%.0f', 70, 'A szakasz eleje méterben a vonal elejétől.')
  if ch then draft.from = v end
  ui.sameLine(0, 6)
  if U.button('Itt##dmFromHere', 0, pos == nil, 'A szakasz eleje = ahol az autó most van (állj meg ott, vagy szabad kamerával vidd oda az autót).') then draft.from = math.floor(pos + 0.5) end
  ui.sameLine(0, 18)
  U.text('Vége, m:', 12, U.col.dim)
  ui.sameLine(0, 6)
  local v2, ch2 = U.numberBox('dmTo', draft.to or 0, 0, len, '%.0f', 70, 'A szakasz vége méterben a vonal elejétől.')
  if ch2 then draft.to = v2 end
  ui.sameLine(0, 6)
  if U.button('Itt##dmToHere', 0, pos == nil, 'A szakasz vége = ahol az autó most van.') then draft.to = math.floor(pos + 0.5) end
  ui.sameLine(0, 18)
  local okDraft = draft.from ~= nil and draft.to ~= nil and math.abs(draft.to - draft.from) >= 0.5
  if U.button('Hozzáadás##dmAdd', 0, not okDraft, 'Felveszi a szakaszt; ahol egy másikkal átfed, ott az újé lesz.') then
    hooks.pushUndo()
    decelmap.addSegment(d, draft.color, draft.from, draft.to)
    hooks.changed()
    draft.from, draft.to = draft.to, nil
  end

  -- list
  ui.offsetCursorY(4)
  if #(d.segments or {}) == 0 then
    U.text('Még nincs szakasz – ahol nincs, ott a program nem ellenőriz.', 12, U.col.dim)
  end
  local remove = nil
  for i, sg in ipairs(d.segments or {}) do
    ui.textColored(string.format('%d.', i), U.col.dim)
    ui.sameLine(30)
    if U.button(decelmap.short[sg.color] .. '##dmc' .. i, 80, false, 'Kattintásra a következő szín: ' .. decelmap.names[sg.color]) then
      hooks.pushUndo()
      local nextC = { green = 'orange', orange = 'red', red = 'green' }
      sg.color = nextC[sg.color] or 'green'
      hooks.changed()
    end
    ui.sameLine(0, 8)
    local a, ca = U.numberBox('dmsf' .. i, sg.from, 0, len, '%.0f', 64, 'Eleje (m)')
    ui.sameLine(0, 4)
    U.text('–', 13, U.col.dim)
    ui.sameLine(0, 4)
    local b, cb = U.numberBox('dmst' .. i, sg.to, 0, len, '%.0f', 64, 'Vége (m)')
    if ca or cb then
      hooks.pushUndo()
      sg.from, sg.to = math.min(a, b), math.max(a, b)
      table.sort(d.segments, function(x, y) return x.from < y.from end)
      hooks.changed()
    end
    ui.sameLine(0, 8)
    U.text(string.format('%.0f m', sg.to - sg.from), 12, colorOf[sg.color] or U.col.dim)
    ui.sameLine(0, 12)
    if U.button('Törlés##dmdel' .. i, 0, false, 'A szakasz törlése') then remove = i end
  end
  if remove then hooks.pushUndo(); table.remove(d.segments, remove); hooks.changed() end
  ui.offsetCursorY(4)
  if U.button('Térkép törlése##dmClear', 0, false, 'Az útvonal és minden szakasz törlése ebből a pályatervből.') then
    hooks.pushUndo(); l.decelMap = nil; hooks.changed()
  end
  U.text('A pályán a vonal a Pálya fülön látszik (zöld / narancs / piros, a szürke részen nincs ellenőrzés). Mentés után a bírók gépére is a pályatervvel megy.', 12, U.col.dim)
  if app.dirty then U.text('A változás a pályaterv mentése után marad meg (Mentés fent).', 12, U.col.orange) end
end

return D
