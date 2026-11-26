-- CHT Drift Judge – is this CSP function there?
-- CSP gives many API functions as FFI function pointers (type 'cdata'), not as Lua functions, so a plain
-- type(x) == 'function' check wrongly says „missing” (0.3.9–0.3.12 thought e.g. ui.mouseDelta,
-- ac.checkAdminPrivileges and ac.storageSetPath were missing on CSP 0.3.0-preview120).
local F = {}

function F.callable(f)
  local t = type(f)
  if t == 'function' or t == 'cdata' then return true end
  if t == 'table' or t == 'userdata' then
    local ok, mt = pcall(getmetatable, f)
    return ok and type(mt) == 'table' and mt.__call ~= nil
  end
  return false
end

return F
