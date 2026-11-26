-- CHT Drift Judge – hotkeys.
-- Two ways, either one works:
--   1. Ctrl+Shift+<letter> is checked by the program itself every frame (ac.isKeyDown), so it always
--      works, whatever CSP did with the binding (CSP 0.3.0-preview120 turned our Ctrl+Shift default into
--      Alt+<letter> – the test sheet showed „Alt+D”);
--   2. the ac.ControlButton binding, which can be changed in Beállítások (CSP saves it).
-- Every call is guarded: if this CSP version has neither, the keys simply do nothing.

local callable = require('src/fn').callable
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
  if not callable(ac.ControlButton) then return end
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

-- Own Ctrl+Shift+<letter> check ---------------------------------------------------------------------
local wasDown = {}
local comboPressed = {}
local VK_SHIFT, VK_CONTROL, VK_MENU = 16, 17, 18
local function down(k)
  if not callable(ac.isKeyDown) then return false end
  local ok, r = pcall(ac.isKeyDown, k)
  return ok and r == true
end

-- Called once per frame, before C.pressed().
function C.update()
  local mods = down(VK_CONTROL) and down(VK_SHIFT) and not down(VK_MENU)
  for _, d in ipairs(C.defs) do
    local letter = string.byte(d.letter)
    local isDown = mods and down(letter)
    comboPressed[d.id] = isDown and not wasDown[d.id]
    wasDown[d.id] = isDown
  end
end

function C.pressed(id)
  if comboPressed[id] then return true end
  local b = buttons[id]
  if not b then return false end
  local ok, r = pcall(b.pressed, b)
  if not (ok and r == true) then return false end
  -- the CSP binding is the same Ctrl+Shift+<letter> → already counted above (do not toggle twice)
  if down(VK_CONTROL) and down(VK_SHIFT) then
    for _, d in ipairs(C.defs) do if d.id == id and down(string.byte(d.letter)) then return false end end
  end
  return true
end

-- What to show: always Ctrl+Shift+<letter>; plus the CSP binding if it is something else.
function C.text(id)
  local def
  for _, d in ipairs(C.defs) do if d.id == id then def = d end end
  if not def then return '' end
  local b = C.boundTo(id)
  if b and b ~= '' and b:lower():gsub('%s', '') ~= def.defaultText:lower():gsub('%s', '') then
    return def.defaultText .. ' vagy ' .. b
  end
  return def.defaultText
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
