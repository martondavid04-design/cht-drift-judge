-- CHT Drift Judge – shared UI helpers (CSP only).

local geom = require('src/geom')

local U = {}

U.col = {
  card = rgbm(0.075, 0.072, 0.095, 0.96),
  cardHi = rgbm(0.16, 0.09, 0.30, 0.96),
  border = rgbm(1, 1, 1, 0.08),
  borderHi = rgbm(0.62, 0.38, 1, 0.9),
  accent = rgbm(0.62, 0.38, 1, 1),
  text = rgbm(0.93, 0.93, 0.96, 1),
  dim = rgbm(0.62, 0.62, 0.70, 1),
  green = rgbm(0.35, 0.88, 0.55, 1),
  red = rgbm(1.0, 0.35, 0.35, 1),
  orange = rgbm(1.0, 0.62, 0.22, 1),
  yellow = rgbm(1.0, 0.86, 0.3, 1),
  cyan = rgbm(0.3, 0.85, 1.0, 1),
  purple = rgbm(0.7, 0.45, 1.0, 1),
  track = rgbm(1, 1, 1, 0.07),
  white = rgbm(1, 1, 1, 1),
}

U.eventColors = {
  correction = U.col.orange, oneWheel = U.col.red, twoWheel = U.col.red, spin = U.col.red,
  overRotation = U.col.yellow, wall = U.col.cyan, wallSave = U.col.orange, carContact = U.col.cyan, nogo = U.col.red, straight = U.col.dim,
  reset = U.col.red, slow = U.col.orange,
}

U.fontBold = 'Segoe UI;Weight=Bold'
U.fontNormal = 'Segoe UI'

-- FullSend-style number display: truncated to tenths.
function U.t1(v)
  if type(v) ~= 'number' then return '–' end
  return string.format('%.1f', geom.truncate1(v))
end

function U.scoreColor(v)
  if v >= 85 then return U.col.green end
  if v >= 65 then return U.col.yellow end
  if v > 0 then return U.col.orange end
  return U.col.red
end

function U.text(text, size, color, bold)
  ui.pushDWriteFont(bold and U.fontBold or U.fontNormal)
  ui.dwriteText(text, size or 14, color or U.col.text)
  ui.popDWriteFont()
end

function U.drawText(text, size, pos, color, bold)
  ui.pushDWriteFont(bold and U.fontBold or U.fontNormal)
  ui.dwriteDrawText(text, size or 14, pos, color or U.col.text)
  ui.popDWriteFont()
end

function U.measure(text, size, bold)
  ui.pushDWriteFont(bold and U.fontBold or U.fontNormal)
  local s = ui.measureDWriteText(text, size or 14)
  ui.popDWriteFont()
  return s
end

-- Draws a stat card at the cursor and advances. Returns true if clicked.
function U.card(id, width, height, title, value, valueColor, highlighted, sub)
  local p = ui.getCursor()
  local clicked = ui.invisibleButton(id, vec2(width, height))
  local hovered = ui.itemHovered()
  ui.drawRectFilled(p, p + vec2(width, height), highlighted and U.col.cardHi or U.col.card, 6)
  ui.drawRect(p, p + vec2(width, height), highlighted and U.col.borderHi or (hovered and U.col.accent or U.col.border), 6, nil, 1)
  U.drawText(title, 13, p + vec2(14, 10), U.col.dim)
  U.drawText(value, 30, p + vec2(14, 28), valueColor or U.col.text, true)
  if sub then U.drawText(sub, 12, p + vec2(14, height - 22), U.col.dim) end
  return clicked
end

function U.bar(width, height, fraction, color, bg)
  local p = ui.getCursor()
  ui.drawRectFilled(p, p + vec2(width, height), bg or rgbm(1, 1, 1, 0.08), height / 2)
  local f = geom.clamp(fraction or 0, 0, 1)
  if f > 0 then ui.drawRectFilled(p, p + vec2(width * f, height), color or U.col.green, height / 2) end
  ui.dummy(vec2(width, height))
end

function U.sectionTitle(text, right)
  U.text(text, 20, U.col.text, true)
  if right then
    ui.sameLine(0, 0)
    local w = ui.availableSpaceX()
    local m = U.measure(right, 13)
    ui.setCursorX(ui.getCursorX() + math.max(0, w - m.x))
    U.text(right, 13, U.col.dim)
  end
end

function U.pill(text, color)
  local p = ui.getCursor()
  local m = U.measure(text, 12, true)
  local size = vec2(m.x + 14, 20)
  ui.drawRectFilled(p, p + size, rgbm(color.r, color.g, color.b, 0.18), 10)
  U.drawText(text, 12, p + vec2(7, 3), color, true)
  ui.dummy(size)
end

-- Number slider row for settings. Returns new value and changed flag.
function U.sliderRow(label, value, min, max, fmt, integer)
  local v, changed = U.sliderInput('row_' .. label, label, value, min, max, fmt, 220, nil, { integer = integer })
  return v, changed
end

-- Number typed by hand: a small text box; Enter (or clicking away) applies it. Accepts a decimal comma.
-- Returns value, changed. hardMin / hardMax limit typed values (default: min / max).
local numEdit = {}
function U.numberBox(id, value, min, max, fmt, width, tip, hardMin, hardMax)
  local nf = (fmt or '%.2f'):match('%%[%-%d%.]*[fdg]') or '%.2f'
  local txt = numEdit[id] or string.format(nf, value or 0)
  ui.setNextItemWidth(width or 64)
  local F = ui.InputTextFlags
  local flags = bit.bor(F.CharsScientific or 0, F.AutoSelectAll or 0)
  local nt, _, enter = ui.inputText('##nb_' .. id, txt, flags)
  local active = ui.itemActive()
  if tip then U.tip(tip .. ' (Írd be a pontos értéket, majd Enter.)') end
  -- while typing the text is kept here; Enter or clicking away applies it
  local commit = nil
  if enter then commit = nt
  elseif active then numEdit[id] = nt
  elseif numEdit[id] ~= nil then commit = numEdit[id] end
  if commit ~= nil then
    local str = tostring(commit):gsub(',', '.'):gsub('[^%d%.%-eE]', '')
    numEdit[id] = nil
    local v = tonumber(str)
    if v then
      local lo, hi = hardMin or min, hardMax or max
      if lo then v = math.max(lo, v) end
      if hi then v = math.min(hi, v) end
      if nf:find('%.0f') or nf:find('d') then v = math.floor(v + 0.5) end
      if math.abs(v - (value or 0)) > 1e-9 then return v, true end
    end
  end
  return value, false
end

-- Slider + a box to type the exact value. Returns value, changed, how ('slider' | 'typed' | nil).
-- label (optional) is shown after the box.
function U.sliderInput(id, label, value, min, max, fmt, width, tip, opts)
  opts = opts or {}
  ui.setNextItemWidth(width or 200)
  local nv, c = ui.slider('##sl_' .. id, value, min, max, fmt or '%.2f', opts.integer and true or 1)
  U.tip(tip)
  local how = c and 'slider' or nil
  ui.sameLine(0, 4)
  local tv, tc = U.numberBox(id, c and nv or value, min, max, fmt, opts.boxWidth or 62, tip, opts.hardMin, opts.hardMax)
  if tc then nv, c, how = tv, true, 'typed' end
  if label then
    ui.sameLine(0, 8)
    U.text(label, 13, U.col.text)
  end
  if opts.integer and c then nv = math.floor(nv + 0.5) end
  return c and nv or value, c, how
end

-- Button with an optional tooltip (shown on hover) explaining what it does.
function U.button(label, width, disabled, tip)
  local r = ui.button(label, vec2(width or 0, 0), disabled and ui.ButtonFlags.Disabled or ui.ButtonFlags.None)
  if tip and ui.itemHovered() then ui.setTooltip(tip) end
  return r
end

function U.tip(text)
  if text and ui.itemHovered() then ui.setTooltip(text) end
end

-- Wrapped DirectWrite text (long descriptions).
function U.wrapped(text, size, color, bold)
  ui.pushDWriteFont(bold and U.fontBold or U.fontNormal)
  ui.dwriteTextWrapped(text, size or 13, color or U.col.dim)
  ui.popDWriteFont()
end

-- Small "(?)" marker after the previous item; hovering shows the description.
function U.help(text)
  ui.sameLine(0, 6)
  ui.textColored('(?)', U.col.dim)
  if ui.itemHovered() then ui.setTooltip(text) end
end

U.levelColors = { error = U.col.red, warn = U.col.orange, info = U.col.cyan, ok = U.col.green }
U.levelNames = { error = 'HIBA', warn = 'FIGYELEM', info = 'INFÓ', ok = 'RENDBEN' }

-- Collapsible section header ("lenyíló fül"). State is remembered in U.openStore (settings.ui.open).
-- opts: { sub, badge, badgeColor, defaultOpen, forceOpen, level, width }
U.openStore = {}
U.onOpenChange = nil
function U.isOpen(id, defaultOpen)
  local v = U.openStore[id]
  if v == nil then return defaultOpen ~= false end
  return v
end
function U.setOpen(id, v)
  U.openStore[id] = v
  if U.onOpenChange then U.onOpenChange() end
end

function U.collapsible(id, title, opts, content)
  opts = opts or {}
  local open = opts.forceOpen or U.isOpen(id, opts.defaultOpen)
  local w = opts.width or ui.availableSpaceX()
  local h = opts.height or 30
  local p = ui.getCursor()
  if ui.invisibleButton(title .. '##col_' .. id, vec2(w, h)) and not opts.forceOpen then
    open = not open
    U.setOpen(id, open)
  end
  local hovered = ui.itemHovered()
  ui.drawRectFilled(p, p + vec2(w, h), hovered and rgbm(0.13, 0.12, 0.17, 1) or rgbm(0.105, 0.10, 0.14, 1), 6)
  if opts.level then
    ui.drawRectFilled(p, p + vec2(4, h), U.levelColors[opts.level] or U.col.accent, 2)
  end
  U.drawText(open and '▾' or '▸', 14, p + vec2(12, (h - 18) / 2), U.col.dim)
  local tm = U.measure(title, 15, true)
  U.drawText(title, 15, p + vec2(30, (h - 19) / 2), U.col.text, true)
  if opts.sub then U.drawText(opts.sub, 12, p + vec2(40 + tm.x, (h - 15) / 2), U.col.dim) end
  if opts.badge then
    local col = opts.badgeColor or U.col.purple
    local bm = U.measure(opts.badge, 12, true)
    local bp = p + vec2(w - bm.x - 24, (h - 20) / 2)
    ui.drawRectFilled(bp, bp + vec2(bm.x + 14, 20), rgbm(col.r, col.g, col.b, 0.18), 10)
    U.drawText(opts.badge, 12, bp + vec2(7, 3), col, true)
  end
  if opts.tip and hovered then ui.setTooltip(opts.tip) end
  if open and content then
    ui.offsetCursorY(4)
    ui.indent(10)
    content()
    ui.unindent(10)
    ui.offsetCursorY(6)
  else
    ui.offsetCursorY(4)
  end
  return open
end

-- Notice box: coloured left bar + title + wrapped text + action buttons.
-- buttons: { { label, tip }, ... }. Returns the index of the clicked button (or nil).
function U.notice(id, level, title, text, buttons)
  local col = U.levelColors[level] or U.col.accent
  local p0 = ui.getCursor()
  ui.beginGroup()
  ui.indent(14)
  ui.offsetCursorY(6)
  U.text((U.levelNames[level] and (U.levelNames[level] .. ' · ') or '') .. title, 14, col, true)
  if text and text ~= '' then U.wrapped(text, 13, U.col.text) end
  local clicked = nil
  if buttons and #buttons > 0 then
    for i, b in ipairs(buttons) do
      if i > 1 then ui.sameLine(0, 8) end
      if U.button(b[1] .. '##n_' .. id .. '_' .. i, 0, false, b[2]) then clicked = i end
    end
  end
  ui.offsetCursorY(6)
  ui.unindent(14)
  ui.endGroup()
  local p1 = ui.itemRectMax()
  if p1 then
    ui.drawRectFilled(p0, vec2(p0.x + 4, p1.y), col, 2)
    ui.drawRect(p0, vec2(p0.x + ui.availableSpaceX(), p1.y), rgbm(col.r, col.g, col.b, 0.35), 6, nil, 1)
  end
  ui.offsetCursorY(6)
  return clicked
end

-- Switchable + reorderable module list editor (HUD, Élő, Eredmény).
-- state: settings table { order, off }; defs: { key, label, desc }; presets optional { id, label, on }
-- Returns true if something changed.
function U.moduleManager(id, state, defs, presets)
  local modlist = require('src/modlist')
  local changed = false
  if presets and #presets > 0 then
    local cur = modlist.matchingPreset(state, defs, presets)
    U.text('Előbeállítás:', 13, U.col.dim)
    for _, pr in ipairs(presets) do
      ui.sameLine(0, 8)
      if U.button(pr.label .. (cur == pr.id and ' (aktív)' or '') .. '##pr_' .. id .. pr.id, 0, false, pr.desc) then
        modlist.applyPreset(state, defs, pr)
        changed = true
      end
    end
    if not cur then ui.sameLine(0, 8); U.text('(egyéni)', 13, U.col.dim) end
  end
  local list = modlist.ordered(state, defs)
  for i, m in ipairs(list) do
    if ui.checkbox(string.format('%d. %s##mod_%s_%s', i, m.label, id, m.key), m.on) then
      modlist.setOn(state, m.key, not m.on)
      changed = true
    end
    if m.desc then U.tip(m.desc) end
    ui.sameLine(math.max(260, ui.availableSpaceX() - 120))
    if U.button('Fel##up_' .. id .. m.key, 50, i == 1, 'Egy hellyel feljebb') then modlist.move(state, defs, m.key, -1); changed = true end
    ui.sameLine(0, 4)
    if U.button('Le##dn_' .. id .. m.key, 50, i == #list, 'Egy hellyel lejjebb') then modlist.move(state, defs, m.key, 1); changed = true end
    if m.desc then
      ui.indent(28)
      U.text(m.desc, 12, U.col.dim)
      ui.unindent(28)
    end
  end
  return changed
end

-- Search box with placeholder text and a clear button. Returns the new text.
function U.searchBox(id, placeholder, value, width)
  local F = ui.InputTextFlags
  local flags = bit.bor(F.Placeholder or 0, F.ClearButton or 0)
  ui.setNextItemWidth(width or ui.availableSpaceX())
  local v = ui.inputText(placeholder .. '##' .. id, value or '', flags)
  return v or ''
end

return U
