-- CHT Drift Judge – qualifying table, Top 32 / 16 / 8 bracket and battle decisions (phase 2). Pure Lua.
--
-- Rules (archived answers):
--   qualifying: 2 runs, the better counts, two zero runs = out, a 3rd chance only by hand (A02, B01);
--   ranking: best run → second run → best run's Line, Angle, Style → the second's (DM 1.8 / C13);
--   bracket: Top 32 with byes (A11, B06 Challonge), standard seeding (1–32, 16–17, …), DM 1.10;
--   battle: 2 runs, everyone leads once; lead 60 / chase 40 (A05, DM 1.11); 2 judges, the 1st watches
--   the lead, the 2nd the chase; if they disagree: One More Time, at most once per battle, after it a
--   decision is a must (A03, A04, A13, DM 1.11, 1.14).

local B = {}

local function num(v) return tonumber(v) or 0 end

-- Qualifying table ----------------------------------------------------------------------------------
-- drivers: { { name, runs = { { final, zero, line, angle, style, time, source, zeroReason }, ... } }, ... }
-- manual: { [name] = { third = true (3rd chance), out = true (removed), back = true (counts despite 2 zeros) } }
-- Only the first 2 (3 with a 3rd chance) runs count, oldest first. Returns a ranked list:
-- { name, place, best, second, counted = {runs}, all, zeros, status = 'ok' | 'out' | 'norun' | 'removed', why }
function B.qualiTable(drivers, manual, opts)
  manual = manual or {}
  opts = opts or {}
  local list = {}
  for _, d in ipairs(drivers or {}) do
    local m = manual[d.name] or {}
    local runs, pos = {}, {}
    for i, r in ipairs(d.runs or {}) do runs[#runs + 1] = r; pos[r] = i end
    -- oldest first (runs in the same second: newest first in the list, as the Versenyzők tab keeps them)
    table.sort(runs, function(a, b)
      local ta, tb = tostring(a.time or ''), tostring(b.time or '')
      if ta ~= tb then return ta < tb end
      return pos[a] > pos[b]
    end)
    local limit = m.third and 3 or 2
    local counted = {}
    for i = 1, math.min(limit, #runs) do counted[#counted + 1] = runs[i] end
    local zeros = 0
    for _, r in ipairs(counted) do if r.zero then zeros = zeros + 1 end end
    local scored = {}
    for _, r in ipairs(counted) do scored[#scored + 1] = r end
    table.sort(scored, function(a, b)
      local fa, fb = a.zero and 0 or num(a.effective or a.final), b.zero and 0 or num(b.effective or b.final)
      if fa ~= fb then return fa > fb end
      if num(a.line) ~= num(b.line) then return num(a.line) > num(b.line) end
      if num(a.angle) ~= num(b.angle) then return num(a.angle) > num(b.angle) end
      return num(a.style) > num(b.style)
    end)
    local e = { name = d.name, counted = counted, all = #runs, zeros = zeros, best = scored[1], second = scored[2],
      connected = d.connected, carIndex = d.carIndex, third = m.third == true }
    if m.out then e.status, e.why = 'removed', 'kivéve (bírói döntés)'
    elseif #counted == 0 then e.status, e.why = 'norun', 'még nem futott'
    elseif zeros >= 2 and zeros == #counted and not m.back then e.status, e.why = 'out', 'két nullás kör – kiesett'
    else e.status = 'ok' end
    list[#list + 1] = e
  end
  local function val(r, f)
    if not r then return -1 end
    if f == 'final' then return r.zero and 0 or num(r.effective or r.final) end
    return r.zero and 0 or num(r[f])
  end
  table.sort(list, function(a, b)
    local ra, rb = a.status == 'ok' and 0 or (a.status == 'out' and 1 or (a.status == 'norun' and 2 or 3)),
      b.status == 'ok' and 0 or (b.status == 'out' and 1 or (b.status == 'norun' and 2 or 3))
    if ra ~= rb then return ra < rb end
    for _, part in ipairs({ { 'best', 'final' }, { 'second', 'final' }, { 'best', 'line' }, { 'best', 'angle' }, { 'best', 'style' },
      { 'second', 'line' }, { 'second', 'angle' }, { 'second', 'style' } }) do
      local x, y = val(a[part[1]], part[2]), val(b[part[1]], part[2])
      if x ~= y then return x > y end
    end
    return tostring(a.name):lower() < tostring(b.name):lower()
  end)
  local place = 0
  for _, e in ipairs(list) do
    if e.status == 'ok' then place = place + 1; e.place = place end
  end
  return list
end

-- Bracket -------------------------------------------------------------------------------------------
-- Standard seeding order: 1 and 2 meet only in the final, 1–4 only in the semi-finals, …
function B.seedOrder(size)
  local seeds = { 1, 2 }
  while #seeds < size do
    local n = #seeds * 2
    local nxt = {}
    for _, s in ipairs(seeds) do
      nxt[#nxt + 1] = s
      nxt[#nxt + 1] = n + 1 - s
    end
    seeds = nxt
  end
  return seeds
end

-- Bracket size for n qualified drivers: 4, 8, 16 or 32 (Top 32 at most).
function B.sizeFor(n)
  for _, s in ipairs({ 4, 8, 16, 32 }) do if n <= s then return s end end
  return 32
end

B.roundNames = { [32] = 'Top 32', [16] = 'Top 16', [8] = 'Top 8', [4] = 'Elődöntő', [2] = 'Döntő' }

-- seeds: list of names in qualifying order (1st = seed 1). Returns bracket:
-- { size, rounds = { { name, battles = { battle, ... } }, ... } }
-- battle = { id = 'r1b3', round, slot, a, b, seedA, seedB, runs = {}, votes = {}, omt = false, winner, bye }
function B.build(seeds, size)
  size = size or B.sizeFor(#seeds)
  local order = B.seedOrder(size)
  local br = { size = size, rounds = {} }
  local r = 1
  local count = size
  while count >= 2 do
    local round = { name = B.roundNames[count] or ('Top ' .. count), battles = {} }
    for i = 1, count / 2 do
      round.battles[i] = { id = string.format('r%db%d', r, i), round = r, slot = i, runs = {}, votes = {}, omt = false }
    end
    br.rounds[r] = round
    r = r + 1
    count = count / 2
  end
  local first = br.rounds[1].battles
  for i = 1, #first do
    local sa, sb = order[2 * i - 1], order[2 * i]
    local b = first[i]
    b.seedA, b.seedB = sa, sb
    b.a, b.b = seeds[sa], seeds[sb]
  end
  -- byes: the lone driver goes through without a battle (DM: a Bye Run is not judged)
  for _, b in ipairs(first) do
    if b.a and not b.b then b.winner, b.bye = 'a', true
    elseif b.b and not b.a then b.winner, b.bye = 'b', true end
  end
  B.propagate(br)
  return br
end

function B.battle(br, id)
  for _, round in ipairs(br and br.rounds or {}) do
    for _, b in ipairs(round.battles) do if b.id == id then return b end end
  end
  return nil
end

function B.winnerName(b)
  if not b or not b.winner then return nil end
  return b.winner == 'a' and b.a or b.b
end
function B.loserName(b)
  if not b or not b.winner then return nil end
  return b.winner == 'a' and b.b or b.a
end

-- Winners move to the next round (slot i of round r feeds slot ceil(i/2) of round r+1).
function B.propagate(br)
  for r = 1, #br.rounds - 1 do
    for i, b in ipairs(br.rounds[r].battles) do
      local nb = br.rounds[r + 1].battles[math.ceil(i / 2)]
      local w = B.winnerName(b)
      local seed = b.winner == 'a' and b.seedA or (b.winner == 'b' and b.seedB or nil)
      if i % 2 == 1 then
        if nb.a ~= w then nb.a, nb.seedA = w, seed; if not nb.done then nb.winner = nil end end
      else
        if nb.b ~= w then nb.b, nb.seedB = w, seed; if not nb.done then nb.winner = nil end end
      end
    end
  end
end

-- The next battle to run: round by round, the first with two drivers and no winner.
function B.nextBattle(br)
  for _, round in ipairs(br and br.rounds or {}) do
    for _, b in ipairs(round.battles) do
      if b.a and b.b and not b.winner then return b end
    end
  end
  return nil
end

function B.champion(br)
  local last = br and br.rounds[#br.rounds]
  return last and B.winnerName(last.battles[1]) or nil
end

-- Decision from the judges' votes (A03, A13, DM 1.11): votes = { [judge] = 'a' | 'b' | 'omt' }.
-- needed = number of judges. Returns 'a' | 'b' | 'omt' | 'pending' | 'deadlock', and a text.
function B.decide(votes, needed, omtUsed)
  needed = math.max(1, needed or 2)
  local n, ca, cb, co = 0, 0, 0, 0
  for _, v in pairs(votes or {}) do
    n = n + 1
    if v == 'a' then ca = ca + 1 elseif v == 'b' then cb = cb + 1 else co = co + 1 end
  end
  if n < needed then return 'pending', string.format('%d / %d bíró szavazott', n, needed) end
  local half = n / 2
  if ca > half then return 'a', 'többség' end
  if cb > half then return 'b', 'többség' end
  if not omtUsed then return 'omt', 'nincs egyértelmű győztes: One More Time' end
  -- after the OMT a winner must be named (DM 1.11): the judges have to agree, or the race director decides
  return 'deadlock', 'az OMT után dönteni kell: egyezzetek meg, vagy a versenyigazgató dönt'
end

-- Informational tandem score of a battle for each driver: lead part (max 60) from the run where the
-- driver led, chase part (max 40) from the run where the driver chased (DM 1.11 example: 55 + 30 = 85).
-- runs = { { lead = name, chase = name, leadPts = 0..60, chasePts = 0..40 }, ... } – the last pair counts
-- (after an OMT the OMT runs).
function B.suggestion(battle)
  local out = {}
  local runs = battle and battle.runs or {}
  local from = 1
  if #runs >= 4 then from = #runs - 1 end
  for i = from, #runs do
    local r = runs[i]
    if r and r.summary then
      local L, C = r.lead, r.chase
      out[L] = out[L] or { lead = nil, chase = nil }
      out[C] = out[C] or { lead = nil, chase = nil }
      out[L].lead = r.summary.leadPts
      out[C].chase = r.summary.chasePts
    end
  end
  for _, v in pairs(out) do
    if v.lead or v.chase then v.total = (v.lead or 0) + (v.chase or 0) end
  end
  return out
end

-- Rows for Challonge (seeded participant list) and for a results table.
function B.challongeText(seeds)
  local lines = {}
  for i, name in ipairs(seeds or {}) do lines[#lines + 1] = name end
  return table.concat(lines, '\n')
end

function B.resultsText(br)
  local lines = { 'Kör\tCsata\tA (kiemelés)\tB (kiemelés)\tGyőztes\tOMT\tMegjegyzés' }
  for r, round in ipairs(br and br.rounds or {}) do
    for i, b in ipairs(round.battles) do
      lines[#lines + 1] = table.concat({ round.name, tostring(i), (b.a or '–') .. (b.seedA and (' (' .. b.seedA .. ')') or ''),
        (b.b or '–') .. (b.seedB and (' (' .. b.seedB .. ')') or ''), B.winnerName(b) or '', b.omt and 'igen' or '',
        b.bye and 'továbbjutás ellenfél nélkül' or (b.note or '') }, '\t')
    end
  end
  return table.concat(lines, '\n')
end

return B
