-- CHT Drift Judge – hotkeys (ac.ControlButton: the binding can be changed in Beállítások, CSP saves it).
-- Every call is guarded: if this CSP version has no ac.ControlButton, the buttons simply do nothing.

local C = {}

local function key(letter)
  local k = ui.KeyIndex and ui.KeyIndex[letter]
  if type(k) ~= 'number' or k == 0 then k = string.byte(letter) end
  return { keyboard = { key = k, ctrl = true, shift = true } }
end

-- onlineOnly: only the online version has no app window of its own, so it needs these two.
C.defs = {
  { id = 'zones', label = 'Pályarajz ki-be', defaultText = 'Ctrl+Shift+Z', letter = 'Z',
    desc = 'Egy gombnyomással elrejti / megmutatja mindazt, amit a program a pályára rajzol (zónák, színek, kapuk, feliratok, nyomvonal).' },
  { id = 'main', label = 'Fő ablak ki-be', defaultText = 'Ctrl+Shift+D', letter = 'D', onlineOnly = true,
    desc = 'Az online (szerverről kapott) változat fő ablaka: Élő, Eredmény, Futások, Pálya, Beállítások.' },
  { id = 'hud', label = 'HUD ki-be', defaultText = 'Ctrl+Shift+H', letter = 'H', onlineOnly = true,
    desc = 'Az online változat HUD-ja (szögmérő, sebesség, zóna, pont…).' },
}

local buttons = {}
C.available = false

function C.init(online)
  if type(ac.ControlButton) ~= 'function' then return end
  for _, d in ipairs(C.defs) do
    if online or not d.onlineOnly then
      local ok, b = pcall(ac.ControlButton, '__CHT_DRIFT_JUDGE_' .. d.id:upper(), key(d.letter))
      if ok and b then
        buttons[d.id] = b
        C.available = true
      end
    end
  end
end

function C.pressed(id)
  local b = buttons[id]
  if not b then return false end
  local ok, r = pcall(b.pressed, b)
  return ok and r == true
end

function C.boundTo(id)
  local b = buttons[id]
  if not b then return nil end
  local ok, r = pcall(b.boundTo, b)
  if ok and r then return tostring(r) end
  return nil
end

-- Draws the binding button (click, then press the new key). Returns true if it changed.
function C.control(id, width)
  local b = buttons[id]
  if not b then return false end
  local ok, r = pcall(b.control, b, vec2(width or 160, 0), nil, 'Kattints, majd nyomd le a gombot')
  return ok and r == true
end

function C.has(id) return buttons[id] ~= nil end

return C
