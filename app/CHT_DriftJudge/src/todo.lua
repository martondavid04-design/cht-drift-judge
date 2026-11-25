-- CHT Drift Judge – "Teendők": everything the user has to fix or check, with a clear action.
-- Pure Lua (testable offline). The UI only draws what collect() returns.
--
-- ctx = { layout, dirty, result, resultIsCurrent, settings, remoteCar, freeRecording, changedSettings,
--         dismissed = { [itemId] = signature } }
--
-- Approvals ("Rendben, így jó"):
--   • zone problems are approved in the layout itself: zone.ack[kind] = signature of the zone at that
--     moment (point count + first/last point). If the zone line changes, the approval no longer applies.
--   • other warnings / infos can be hidden for this session (ctx.dismissed); they come back when their
--     signature changes (e.g. a different number of changed settings).
--   • real errors (no JUDGING / FINISH, no scoring zone) cannot be approved – the run cannot be judged.

local layoutMod = require('src/layout')

local todo = {}

todo.levelNames = { error = 'HIBA', warn = 'FIGYELEM', info = 'INFÓ' }
local levelRank = { error = 1, warn = 2, info = 3 }

local zoneShort = {
  noLine = 'nincs vonala', twoPoints = 'csak 2 pont hosszú szakaszon', zeroWeight = 'súlya 0', zigzag = 'cikcakkos / visszaforduló vonal',
  zoneLine = 'vonal nem a pálya szélén',
}
todo.zoneShort = zoneShort

-- Zone problem kinds that the user may approve as "fine as it is".
todo.ackableZoneKinds = { noLine = true, twoPoints = true, zeroWeight = true, zoneLine = true, zigzag = true }

-- Signature of a zone's line: an approval stays valid while this does not change.
function todo.zoneSig(z)
  local pts = z.points or {}
  local a, b = pts[1], pts[#pts]
  if not a then return '0' end
  return string.format('%d:%.1f:%.1f:%.1f:%.1f', #pts, a.x, a.z, b.x, b.z)
end

function todo.isAcked(z, kind)
  return z ~= nil and type(z.ack) == 'table' and z.ack[kind] ~= nil and z.ack[kind] == todo.zoneSig(z)
end

-- Per-zone problems: zoneIndex -> list of { level, kind, short, text, fix, acked }
function todo.zoneIssues(ctx)
  local r = {}
  local zones = ctx.layout and ctx.layout.zones or {}
  local function add(i, it)
    it.acked = todo.isAcked(zones[i], it.kind)
    it.ackable = todo.ackableZoneKinds[it.kind] == true
    r[i] = r[i] or {}
    local list = r[i]
    list[#list + 1] = it
  end
  if ctx.layout then
    for _, it in ipairs(layoutMod.validateDetailed(ctx.layout)) do
      if it.zone then
        add(it.zone, { level = it.level, kind = it.kind, short = zoneShort[it.kind] or it.kind, text = it.text, fix = it.fix })
      end
    end
  end
  if ctx.result and ctx.resultIsCurrent then
    for _, w in ipairs(ctx.result.warningItems or {}) do
      if w.kind == 'zoneLine' then
        for _, zi in ipairs(w.zones or {}) do
          add(zi, {
            level = 'error', kind = 'zoneLine', short = zoneShort.zoneLine,
            text = 'A legutóbbi futásban az autó közepe is áthaladt ezen a vonalon, ezért itt nem figyeltem a pályaelhagyást.',
            fix = 'Rajzold újra a vonalat pontosan a pálya szélén (pl. nyomkövetéssel, a hátsó külső kerékkel), majd menj egy tesztkört. Ha ez a vonal szándékosan nem a pálya széle, nyomd meg a „Rendben, így jó” gombot.',
          })
        end
      end
    end
  end
  return r
end

-- Worst level of a zone's issue list, ignoring approved ones (or nil).
function todo.worst(list)
  local best = nil
  for _, it in ipairs(list or {}) do
    if not it.acked and (not best or levelRank[it.level] < levelRank[best]) then best = it.level end
  end
  return best
end

-- Returns items (shown), hidden (approved / dismissed, for the "restore" list).
function todo.collect(ctx)
  local items, hidden = {}, {}
  local dismissed = ctx.dismissed or {}
  local zones = ctx.layout and ctx.layout.zones or {}
  local function add(it)
    if it.zone and it.kind and todo.isAcked(zones[it.zone], it.kind) then
      it.approved = true
      hidden[#hidden + 1] = it
    elseif it.id and it.sig and dismissed[it.id] == it.sig then
      it.dismissedNow = true
      hidden[#hidden + 1] = it
    else
      items[#items + 1] = it
    end
  end
  local l = ctx.layout
  if l then
    for _, it in ipairs(layoutMod.validateDetailed(l)) do
      local z = it.zone and zones[it.zone]
      add({
        level = it.level, area = 'layout', title = it.text, fix = it.fix, kind = it.kind, zone = it.zone,
        ack = (z and todo.ackableZoneKinds[it.kind]) and 'zone' or nil,
        id = 'layout:' .. it.kind .. ':' .. (z and z.id or (it.gate or '')),
        action = it.zone and { kind = 'zone', zone = it.zone, label = 'Zóna megnyitása' } or { kind = 'tab', tab = 'editor', label = 'Javítás a Pálya fülön' },
      })
    end
  end
  if ctx.dirty then
    add({ level = 'warn', area = 'layout', title = 'A pályatervben nem mentett változás van.', id = 'dirty', sig = l and l.name or '', ack = 'session',
      fix = 'Mentsd el, különben a játék bezárásakor elveszik.', action = { kind = 'save', label = 'Mentés most' } })
  end
  if ctx.result then
    for _, w in ipairs(ctx.result.warningItems or {}) do
      if w.kind == 'zoneLine' then
        if ctx.resultIsCurrent then
          for _, zi in ipairs(w.zones or {}) do
            local z = zones[zi]
            add({ level = 'error', area = 'result', kind = 'zoneLine', zone = zi, ack = z and 'zone' or nil,
              title = (z and z.name or '?') .. ': a vonal nem a pálya szélén van – ott nem figyeltem a pályaelhagyást.',
              fix = 'Rajzold újra a vonalat a pálya szélén, majd menj egy tesztkört. Ha szándékosan nem a pálya széle: „Rendben, így jó”.',
              action = { kind = 'zone', zone = zi, label = 'Zóna megnyitása' } })
          end
        end
      else
        add({ level = 'warn', area = 'result', title = w.text, id = 'result:' .. tostring(w.kind), sig = w.text, ack = 'session',
          fix = 'Nézd meg az Eredmény fülön, és ellenőrizd a HATÁR / zónavonalak oldalát.',
          action = { kind = 'tab', tab = 'result', label = 'Eredmény megnyitása' } })
      end
    end
    if not ctx.result.warningItems then
      for k, w in ipairs(ctx.result.warnings or {}) do
        add({ level = 'warn', area = 'result', title = w, id = 'resultw:' .. k, sig = w, ack = 'session',
          action = { kind = 'tab', tab = 'result', label = 'Eredmény megnyitása' } })
      end
    end
  end
  if ctx.remoteCar then
    add({ level = 'warn', area = 'run', title = 'Távoli autót figyelsz: online a pályaelhagyás és az ütközés adata pontatlan lehet.',
      id = 'remote', sig = 'remote', ack = 'session',
      fix = 'Hivatalos pontozáshoz mindenki a saját gépén futtassa az appot (2. fázis).' })
  end
  if ctx.freeRecording then
    add({ level = 'info', area = 'run', title = 'Szabad felvétel fut.', id = 'free', sig = 'free', ack = 'session',
      fix = 'Állítsd le az Élő fülön, és a fájl a Futások közé kerül.', action = { kind = 'tab', tab = 'live', label = 'Élő fül' } })
  end
  local nChanged = ctx.changedSettings or 0
  if nChanged > 0 then
    add({ level = 'info', area = 'settings', title = string.format('%d beállítás eltér az alapértéktől.', nChanged),
      id = 'settings', sig = tostring(nChanged), ack = 'session',
      fix = 'A Beállításokban a „Csak a módosítottak” szűrővel látod, melyek ezek.',
      action = { kind = 'settingsChanged', label = 'Módosítottak megnyitása' } })
  end
  for i, it in ipairs(items) do it.idx = i end
  table.sort(items, function(a, b)
    if levelRank[a.level] ~= levelRank[b.level] then return levelRank[a.level] < levelRank[b.level] end
    return a.idx < b.idx
  end)
  return items, hidden
end

function todo.counts(items)
  local c = { error = 0, warn = 0, info = 0 }
  for _, it in ipairs(items) do c[it.level] = (c[it.level] or 0) + 1 end
  return c
end

return todo
