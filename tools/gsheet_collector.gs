/**
 * CHT Drift Judge – adatgyűjtő, 2. táblázat (Google Apps Script webapp a „CHT Drift Judge – adatok (2)” táblázathoz).
 *
 * Miért új: az első táblázatban a futások teljes felvétele (tömörítve) a cellákban volt; 2026-11-26-án a
 * táblázat túl nagy lett, és a Google véglegesen csak olvashatóra állította. Itt a felvételek külön
 * fájlok egy Drive-mappában („CHT Drift Judge – felvételek”), a táblázatban csak a rövid sorok vannak.
 *
 * A program minden gépen (szerverről kapott vagy telepített változat) ide küldi:
 *   type = 'session'  belépés: verzió, CSP, mód, szerep, Steam ID, mit tud a CSP (Belépések lap)
 *   type = 'run'      befejezett futás: összegzés (Futások lap) + a teljes felvétel fájlként a Drive-mappába
 *   type = 'debug'    hibák és a festésfelismerés adatai (Debug lap, a legutóbbi 3000 sor marad)
 *   type = 'layout'   „Feltöltés mindenkinek”: egy pályaterv mindenkinek (Pályatervek lap, minden változat megmarad)
 *   type = 'role'     egy szerveradmin a játékban bíróvá / közvetítővé / pilótává teszi valakit (Szerepek lap)
 * Kulcs nélkül (ezt kéri le a program): ?action=layouts&track=<pálya kulcsa> · ?action=roles
 *   (a szerepeknél a Steam ID helyett csak egy ujjlenyomat megy ki, lásd hashId_)
 * Olvasás (olvasó kulccsal): ?key=…&action=ping | stats | runs | debug | sessions | roles_full | telemetry&run=<futás ID>
 *
 * Két kulcs van: a KEY-t (írás) a program is tartalmazza, ezért nyilvános – vele csak sort lehet hozzáadni.
 * A READ_KEY-jel (olvasás) le lehet kérni az adatokat; ez csak a közzétett scriptben van, a GitHubon nincs.
 * Engedélyek (appsscript.json): csak ez a táblázat, csak a script által létrehozott Drive-fájlok, és
 * kimenő kérés (a Drive-hoz és az átvételhez a régi webappból).
 */

const KEY = 'Kwu8voShi5BWY71UMngoc6l39j3u';          // írás (a programban is benne van)
const READ_KEY = 'IDE_JON_AZ_OLVASO_KULCS';            // olvasás (csak a közzétett scriptben)
// Az első (most már csak olvasható) táblázat webappja: innen veszi át az adatokat az atvetel(), és innen
// olvassa a régi futások felvételét.
const OLD_URL = 'https://script.google.com/macros/s/AKfycbx6H9E260jLGFlsHgxQuXOaNtfdQwWnAeWquPwv07lk8VayG8zfsf7z1PmXXhuOFWmM/exec';
const MAX_BODY = 12 * 1024 * 1024;   // legfeljebb ennyi bájt egy küldésben
const CHUNK = 45000;                 // egy cella legfeljebb 50 000 karakter
const JSON_CELL = 8000;              // a táblázatba kerülő JSON legfeljebb ennyi (a teljes a felvétel-fájlban)
const DEBUG_KEEP = 3000;             // a Debug lapon ennyi legutóbbi sor marad
const TZ = 'Europe/Budapest';
const FOLDER_NAME = 'CHT Drift Judge – felvételek';
const ROLES = ['pilot', 'judge', 'streamer'];

const SHEETS = {
  'Futások': ['Érkezett', 'Futás ideje', 'Típus', 'Pilóta', 'Autó', 'Pálya', 'Pályaterv', 'Verzió', 'Mód', 'Pont', 'Line', 'Angle',
    'Stílus', 'Nullás', 'Nullás oka', '1 kerék', '2 kerék', 'Korrekció', 'Fal', 'Túldobás', 'Idő (s)', 'Átlagseb. (km/h)',
    'Max. szög', 'Felvétel (KB)', 'Futás ID', 'Munkamenet', 'Bírálta (néző gépe)', 'Felvétel fájl', 'Eredmény (JSON, rövidítve)'],
  'Debug': ['Érkezett', 'Pilóta', 'Verzió', 'Mód', 'Szint', 'Hol', 'Üzenet', 'Részletek (JSON)', 'Munkamenet'],
  'Belépések': ['Érkezett', 'Pilóta', 'Steam ID', 'Autó', 'Pálya', 'Pályaterv', 'Verzió', 'Mód', 'CSP', 'Szerep', 'Admin',
    'Szerver', 'Képességek (JSON)', 'Munkamenet'],
  'Pályatervek': ['Feltöltve', 'Pálya', 'Név', 'Szerző', 'Verzió', 'Mód', 'Zónák', 'Bájt (tömörítve)', 'Részek', 'Pálya (AC)',
    'Adat (gzip, base64) →'],
  'Szerepek': ['Idő', 'Steam ID', 'Név', 'Szerep', 'Kijelölte', 'Kijelölő Steam ID', 'Kijelölő admin', 'Szerver', 'Verzió', 'Munkamenet'],
};
const LAYOUT_MAX = 3 * 1024 * 1024;  // egy pályaterv legfeljebb ennyi karakter

function sheet_(name) {
  const ss = SpreadsheetApp.getActiveSpreadsheet();
  let sh = ss.getSheetByName(name);
  if (!sh) {
    sh = ss.insertSheet(name);
    const head = SHEETS[name];
    sh.getRange(1, 1, 1, head.length).setValues([head]).setFontWeight('bold');
    sh.setFrozenRows(1);
  }
  return sh;
}

function now_() { return Utilities.formatDate(new Date(), TZ, 'yyyy-MM-dd HH:mm:ss'); }
function str_(v, max) { v = v === undefined || v === null ? '' : String(v); return v.length > (max || 2000) ? v.slice(0, max || 2000) + '…' : v; }
// Text into a cell: the leading ' keeps it text, so the sheet never turns it into a date or a number
// (e.g. version 0.3.9) and never runs it as a formula (a player name starting with = or +).
function txt_(v, max) { v = str_(v, max); return v === '' ? '' : "'" + v; }
function num_(v) { const n = Number(v); return isFinite(n) ? Math.round(n * 1000) / 1000 : ''; }
function out_(obj) { return ContentService.createTextOutput(JSON.stringify(obj)).setMimeType(ContentService.MimeType.JSON); }
function common_(m) { return { driver: txt_(m.driver, 80), version: txt_(m.version, 20), mode: txt_(m.mode, 20), session: txt_(m.session, 40) }; }
function steam_(v) { v = String(v === undefined || v === null ? '' : v).trim(); return /^\d{15,20}$/.test(v) ? v : ''; }

// The same fingerprint as the program's src/roles.lua (hashId): two rolling hashes of 'cht-dj:<Steam ID>'.
// The public role list carries only this, never the Steam ID itself.
function hashId_(id) {
  const s = 'cht-dj:' + String(id);
  let a = 7, b = 11;
  for (let i = 0; i < s.length; i++) {
    const c = s.charCodeAt(i) & 255;
    a = (a * 31 + c) % 2147483647;
    b = (b * 131 + c) % 1000000007;
  }
  return ('00000000' + a.toString(16)).slice(-8) + ('00000000' + b.toString(16)).slice(-8);
}

// Drive (only the folder and files this script creates: drive.file) -----------------------------------
function token_() { return ScriptApp.getOAuthToken(); }
function drive_(url, opts) {
  opts = opts || {};
  opts.headers = Object.assign({ Authorization: 'Bearer ' + token_() }, opts.headers || {});
  opts.muteHttpExceptions = true;
  const res = UrlFetchApp.fetch(url, opts);
  if (res.getResponseCode() >= 300) throw new Error('Drive ' + res.getResponseCode() + ': ' + res.getContentText().slice(0, 300));
  return res;
}
function folderId_() {
  const props = PropertiesService.getScriptProperties();
  const id = props.getProperty('FOLDER_ID');
  if (id) return id;
  const res = drive_('https://www.googleapis.com/drive/v3/files?fields=id', {
    method: 'post', contentType: 'application/json',
    payload: JSON.stringify({ name: FOLDER_NAME, mimeType: 'application/vnd.google-apps.folder' }),
  });
  const fid = JSON.parse(res.getContentText()).id;
  props.setProperty('FOLDER_ID', fid);
  return fid;
}
function saveFile_(name, bytes) {
  const boundary = 'chtdj' + Utilities.getUuid().replace(/-/g, '');
  const meta = JSON.stringify({ name: name, parents: [folderId_()], mimeType: 'application/gzip' });
  const head = Utilities.newBlob('--' + boundary + '\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n' + meta +
    '\r\n--' + boundary + '\r\nContent-Type: application/gzip\r\n\r\n').getBytes();
  const tail = Utilities.newBlob('\r\n--' + boundary + '--').getBytes();
  const res = drive_('https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart&fields=id', {
    method: 'post', contentType: 'multipart/related; boundary=' + boundary, payload: head.concat(bytes, tail),
  });
  return JSON.parse(res.getContentText()).id;
}
function loadFile_(id) {
  const res = drive_('https://www.googleapis.com/drive/v3/files/' + encodeURIComponent(id) + '?alt=media', { method: 'get' });
  const blob = Utilities.newBlob(res.getBlob().getBytes(), 'application/x-gzip');
  return JSON.parse(Utilities.ungzip(blob).getDataAsString('UTF-8'));
}
function fileName_(s) { return String(s || '').replace(/[\u0000-\u001f\\/:*?"<>|]/g, '_').slice(0, 60); }

// Írás -----------------------------------------------------------------------------------------------
function doPost(e) {
  try {
    const body = e && e.postData ? e.postData.contents : '';
    if (!body || body.length > MAX_BODY) return out_({ ok: false, error: 'size' });
    const m = JSON.parse(body);
    if (!m || m.key !== KEY) return out_({ ok: false, error: 'key' });
    // the recording goes to Drive before the lock (a slow upload must not hold up the other senders)
    let file = null;
    if (m.type === 'run' && m.record) file = saveRecord_(m);
    const lock = LockService.getScriptLock();
    lock.waitLock(25000);
    try {
      if (m.type === 'session') return out_(session_(m));
      if (m.type === 'run') return out_(run_(m, file));
      if (m.type === 'debug') return out_(debug_(m));
      if (m.type === 'layout') return out_(layout_(m));
      if (m.type === 'role') return out_(role_(m));
      return out_({ ok: false, error: 'type' });
    } finally {
      lock.releaseLock();
    }
  } catch (err) {
    return out_({ ok: false, error: String(err) });
  }
}

function session_(m) {
  const c = common_(m);
  const caps = m.caps || {};
  sheet_('Belépések').appendRow([now_(), c.driver, txt_(steam_(m.steamId || caps.steamID), 24), txt_(m.car, 80), txt_(m.track, 80),
    txt_(m.layout, 80), c.version, c.mode, txt_(m.csp, 60), txt_(m.role, 20), m.admin ? 'igen' : '', txt_(m.server, 120),
    txt_(JSON.stringify(caps), JSON_CELL), c.session]);
  return { ok: true };
}

function saveRecord_(m) {
  const json = JSON.stringify({ runId: m.runId, driver: m.driver, car: m.car, track: m.track, layout: m.layout, version: m.version,
    mode: m.mode, tag: m.tag, judgedBy: m.judgedBy, summary: m.summary, result: m.result, record: m.record });
  const gz = Utilities.gzip(Utilities.newBlob(json, 'application/json')).getBytes();
  const s = m.summary || {};
  const name = fileName_(String(s.time || now_()).replace(/[: ]/g, '-')) + '_' + fileName_(m.driver) + '_' + fileName_(m.runId) + '.json.gz';
  return { id: saveFile_(name, gz), kb: Math.round(json.length / 1024) };
}

function run_(m, file) {
  const c = common_(m);
  const s = m.summary || {};
  const runId = str_(m.runId, 40);
  sheet_('Futások').appendRow([now_(), txt_(s.time, 30), txt_(m.tag || 'futás', 30), c.driver, txt_(m.car, 80), txt_(m.track, 80), txt_(m.layout, 80), c.version,
    c.mode, num_(s.final), num_(s.line), num_(s.angle), num_(s.style), s.zero ? 'igen' : '', txt_(s.zeroReason, 300),
    num_(s.oneWheel), num_(s.twoWheel), num_(s.corrections), num_(s.wallSaves), num_(s.overRot), num_(s.duration),
    num_(s.avgSpeed), num_(s.maxAngle), file ? file.kb : '', txt_(runId, 40), c.session, txt_(m.judgedBy, 80),
    file ? txt_(file.id, 80) : '', txt_(JSON.stringify(m.result || {}), JSON_CELL)]);
  return { ok: true, run: runId, file: file ? file.id : null };
}

function debug_(m) {
  const c = common_(m);
  const sh = sheet_('Debug');
  sh.appendRow([now_(), c.driver, c.version, c.mode, txt_(m.level, 20), txt_(m.where, 80), txt_(m.message, 2000),
    txt_(JSON.stringify(m.details || {}), JSON_CELL), c.session]);
  const last = sh.getLastRow();
  if (last > DEBUG_KEEP + 500) sh.deleteRows(2, last - 1 - DEBUG_KEEP);
  return { ok: true };
}

// Pályatervek („Feltöltés mindenkinek”) --------------------------------------------------------------
function trackKey_(v) { v = String(v || ''); return /^[A-Za-z0-9_.\-]{1,160}$/.test(v) ? v : ''; }
function layoutName_(v) {
  v = String(v || '').replace(/[\u0000-\u001f\\/:*?"<>|]/g, '_').trim();
  return v.length > 0 && v.length <= 80 ? v : '';
}

function layout_(m) {
  const c = common_(m);
  const track = trackKey_(m.track);
  const name = layoutName_(m.name);
  if (!track || !name) return { ok: false, error: 'name' };
  const sh = sheet_('Pályatervek');
  if (m.deleted) {
    sh.appendRow([now_(), txt_(track), txt_(name), c.driver, c.version, c.mode, txt_('törölve'), 0, 0, txt_(m.trackID, 160)]);
    return { ok: true, deleted: true };
  }
  const text = String(m.layoutText || '');
  if (!text || text.length > LAYOUT_MAX) return { ok: false, error: 'size' };
  let data;
  try { data = JSON.parse(text); } catch (err) { return { ok: false, error: 'json' }; }
  if (!data || data.format !== 'cht-drift-layout' || !Array.isArray(data.zones)) return { ok: false, error: 'format' };
  const gz = Utilities.base64Encode(Utilities.gzip(Utilities.newBlob(text, 'application/json')).getBytes());
  const parts = [];
  for (let i = 0; i < gz.length; i += CHUNK) parts.push("'" + gz.slice(i, i + CHUNK));
  sh.appendRow([m.uploaded ? txt_(m.uploaded, 30) : now_(), txt_(track), txt_(name), c.driver, c.version, c.mode, data.zones.length,
    gz.length, parts.length, txt_(m.trackID, 160)].concat(parts));
  return { ok: true, name: name };
}

// A pálya legújabb pályatervei névenként (a törölt nevek nélkül), a feltöltött szöveggel együtt.
function layouts_(track) {
  track = trackKey_(track);
  if (!track) return [];
  const sh = sheet_('Pályatervek');
  const last = sh.getLastRow();
  if (last < 2) return [];
  const meta = sh.getRange(2, 1, last - 1, 9).getValues();
  const latest = {};
  for (let i = 0; i < meta.length; i++) {
    if (String(meta[i][1]) === track) latest[String(meta[i][2])] = i;
  }
  const out = [];
  Object.keys(latest).sort().forEach(function (name) {
    const i = latest[name];
    const r = meta[i];
    if (String(r[6]) === 'törölve') return;
    const parts = Number(r[8]);
    if (!parts) return;
    const gz = sh.getRange(i + 2, 11, 1, parts).getValues()[0].join('');
    const text = Utilities.ungzip(Utilities.newBlob(Utilities.base64Decode(gz), 'application/x-gzip')).getDataAsString('UTF-8');
    const t = r[0] instanceof Date ? Utilities.formatDate(r[0], TZ, 'yyyy-MM-dd HH:mm:ss') : String(r[0]);
    out.push({ name: name, author: String(r[3]), time: t, version: String(r[4]), text: text });
  });
  return out;
}

// Szerepek (a szerveradmin jelöli ki a játékban) --------------------------------------------------------
function role_(m) {
  const c = common_(m);
  const id = steam_(m.steamId);
  const role = String(m.role || '');
  if (!id) return { ok: false, error: 'steam' };
  if (ROLES.indexOf(role) < 0) return { ok: false, error: 'role' };
  sheet_('Szerepek').appendRow([now_(), txt_(id, 24), txt_(m.name, 80), role, c.driver, txt_(steam_(m.bySteamId), 24),
    m.admin ? 'igen' : '', txt_(m.server, 120), c.version, c.session]);
  return { ok: true, h: hashId_(id), role: role };
}

// The latest role per Steam ID (rows added by hand in the sheet count too: Steam ID + Szerep).
function rolesLatest_() {
  const sh = sheet_('Szerepek');
  const last = sh.getLastRow();
  if (last < 2) return {};
  const vals = sh.getRange(2, 1, last - 1, 4).getValues();
  const latest = {};
  vals.forEach(function (r) {
    const id = steam_(r[1]);
    const role = String(r[3]).trim();
    if (id && ROLES.indexOf(role) >= 0) latest[id] = { role: role, name: String(r[2]), time: String(r[0]) };
  });
  return latest;
}
function roles_() {
  const latest = rolesLatest_();
  const out = [];
  Object.keys(latest).forEach(function (id) {
    if (latest[id].role !== 'pilot') out.push({ h: hashId_(id), role: latest[id].role });
  });
  return out;
}

// Olvasás --------------------------------------------------------------------------------------------
function rows_(name, limit) {
  const sh = sheet_(name);
  const last = sh.getLastRow();
  if (last < 2) return [];
  const n = Math.min(limit, last - 1);
  const head = sh.getRange(1, 1, 1, sh.getLastColumn()).getValues()[0];
  const vals = sh.getRange(last - n + 1, 1, n, head.length).getValues();
  return vals.reverse().map(function (r) { const o = {}; head.forEach(function (h, i) { if (h) o[h] = r[i]; }); return o; });
}

function telemetry_(runId) {
  const sh = sheet_('Futások');
  const last = sh.getLastRow();
  if (last >= 2) {
    const head = SHEETS['Futások'];
    const idCol = head.indexOf('Futás ID') + 1, fileCol = head.indexOf('Felvétel fájl') + 1;
    const ids = sh.getRange(2, idCol, last - 1, 1).getValues();
    for (let i = ids.length - 1; i >= 0; i--) {
      if (String(ids[i][0]) === String(runId)) {
        const fid = String(sh.getRange(i + 2, fileCol).getValue());
        if (fid) return loadFile_(fid).record;
      }
    }
  }
  // a régi táblázat futásai
  if (OLD_URL && READ_KEY) {
    const res = UrlFetchApp.fetch(OLD_URL + '?key=' + encodeURIComponent(READ_KEY) + '&action=telemetry&run=' + encodeURIComponent(runId), { muteHttpExceptions: true });
    const d = JSON.parse(res.getContentText());
    if (d && d.ok) return d.record;
  }
  return null;
}

function stats_() {
  const ss = SpreadsheetApp.getActiveSpreadsheet();
  const out = { sheets: {}, cells: 0 };
  ss.getSheets().forEach(function (sh) {
    const n = sh.getMaxRows() * sh.getMaxColumns();
    out.sheets[sh.getName()] = { rows: sh.getLastRow() - 1, cells: n };
    out.cells += n;
  });
  return out;
}

function doGet(e) {
  const p = (e && e.parameter) || {};
  // nyilvános: ezt kéri le minden gép (kulcs nélkül)
  if (p.action === 'layouts') {
    try { return out_({ ok: true, track: trackKey_(p.track), layouts: layouts_(p.track) }); }
    catch (err) { return out_({ ok: false, error: String(err) }); }
  }
  if (p.action === 'roles') {
    try { return out_({ ok: true, roles: roles_() }); }
    catch (err) { return out_({ ok: false, error: String(err) }); }
  }
  if (!READ_KEY || READ_KEY === 'IDE_JON_AZ_OLVASO_KULCS' || p.key !== READ_KEY) return out_({ ok: false, error: 'key' });
  const limit = Math.max(1, Math.min(2000, Number(p.limit) || 50));
  try {
    if (p.action === 'runs') return out_({ ok: true, rows: rows_('Futások', limit) });
    if (p.action === 'debug') return out_({ ok: true, rows: rows_('Debug', limit) });
    if (p.action === 'sessions') return out_({ ok: true, rows: rows_('Belépések', limit) });
    if (p.action === 'roles_full') return out_({ ok: true, roles: rolesLatest_() });
    if (p.action === 'telemetry') return out_({ ok: true, record: telemetry_(p.run) });
    if (p.action === 'stats') return out_({ ok: true, stats: stats_() });
    return out_({ ok: true, pong: now_() });
  } catch (err) {
    return out_({ ok: false, error: String(err) });
  }
}

// Kézzel futtatható ------------------------------------------------------------------------------------

// Létrehozza a lapokat és a felvételek mappáját (ez kéri az engedélyt is).
function setup() {
  const ss = SpreadsheetApp.getActiveSpreadsheet();
  Object.keys(SHEETS).forEach(sheet_);
  ['Munkalap1', 'Sheet1', 'Lap1'].forEach(function (n) {
    const def = ss.getSheetByName(n);
    if (def && ss.getSheets().length > 1) ss.deleteSheet(def);
  });
  Logger.log('Felvételek mappa: ' + folderId_());
}

// Átveszi a régi (csak olvasható) táblázatból a belépéseket, futásokat, hibákat (lapokként a legutóbbi
// 500-at – ennyit ad a régi webapp) és minden pálya legújabb pályaterveit. Egyszer kell futtatni, az üres új táblázatban.
function atvetel() {
  if (!READ_KEY || READ_KEY === 'IDE_JON_AZ_OLVASO_KULCS') throw new Error('READ_KEY hiányzik');
  function old(q) {
    const res = UrlFetchApp.fetch(OLD_URL + '?key=' + encodeURIComponent(READ_KEY) + '&' + q, { muteHttpExceptions: true });
    const d = JSON.parse(res.getContentText());
    if (!d || !d.ok) throw new Error('régi webapp: ' + res.getContentText().slice(0, 200));
    return d;
  }
  function t(v) { return v === undefined || v === null ? '' : v; }
  function tx(v, max) { return txt_(t(v), max); }
  function date(v) { v = String(t(v)); const d = new Date(v); return isNaN(d.getTime()) ? tx(v) : Utilities.formatDate(d, TZ, 'yyyy-MM-dd HH:mm:ss'); }
  const log = [];
  const tracks = {};
  ['vdc_brno_2022', 'cds_brno_reverse', 'vdc_autopolis_2022', 'trackwood_pro_reverse_2026', 'indonesia_circuit24__vdc_layout_a',
    'dcgp13_tosfed_istanbul_park__dcgp13'].forEach(function (k) { tracks[k] = true; });
  function trackOf(v) {
    v = String(t(v));
    const k = v.replace('/', '__');
    if (trackKey_(k)) tracks[k] = true;
    const base = v.split('/')[0];
    if (trackKey_(base)) tracks[base] = true;
  }

  const sessions = old('action=sessions&limit=500').rows.reverse();
  const bel = sessions.map(function (r) {
    const raw = String(t(r['Képességek (JSON)']));
    let caps = {};
    try { caps = JSON.parse(raw || '{}'); } catch (err) { caps = {}; }
    // a régi cellát 4000 karakternél levágta – a Steam ID-t akkor a szövegből veszi ki
    const sm = raw.match(/"steamID"\s*:\s*"?(\d{15,20})/);
    const sid = steam_(caps.steamID) || (sm ? sm[1] : '');
    trackOf(r['Pálya']);
    return [date(r['Érkezett']), tx(r['Pilóta'], 80), tx(sid, 24), tx(r['Autó'], 80), tx(r['Pálya'], 80), tx(r['Pályaterv'], 80),
      tx(r['Verzió'], 20), tx(r['Mód'], 20), tx(r['CSP'], 60), tx(r['Szerep'], 20), t(r['Admin']), '', tx(JSON.stringify(caps), JSON_CELL), tx(r['Munkamenet'], 40)];
  });
  if (bel.length) sheet_('Belépések').getRange(2, 1, bel.length, bel[0].length).setValues(bel);
  log.push('Belépések: ' + bel.length + (bel.length >= 500 ? ' (a régi webapp a legutóbbi 500-at adja)' : ''));

  const runs = old('action=runs&limit=500').rows.reverse();
  const fut = runs.map(function (r) {
    trackOf(r['Pálya']);
    return [date(r['Érkezett']), tx(r['Futás ideje'], 30), tx(r['Típus'], 30), tx(r['Pilóta'], 80), tx(r['Autó'], 80), tx(r['Pálya'], 80),
      tx(r['Pályaterv'], 80), tx(r['Verzió'], 20), tx(r['Mód'], 20), t(r['Pont']), t(r['Line']), t(r['Angle']), t(r['Stílus']), t(r['Nullás']),
      tx(r['Nullás oka'], 300), t(r['1 kerék']), t(r['2 kerék']), t(r['Korrekció']), t(r['Fal']), t(r['Túldobás']), t(r['Idő (s)']),
      t(r['Átlagseb. (km/h)']), t(r['Max. szög']), t(r['Telemetria (KB)']), tx(r['Futás ID'], 40), tx(r['Munkamenet'], 40), '',
      '', tx(r['Eredmény (JSON)'], JSON_CELL)];   // a régi futások felvételét a telemetry_ a régi webappból kéri le
  });
  if (fut.length) sheet_('Futások').getRange(2, 1, fut.length, fut[0].length).setValues(fut);
  log.push('Futások: ' + fut.length + (fut.length >= 500 ? ' (a legutóbbi 500)' : ''));

  const dbg = old('action=debug&limit=500').rows.reverse().map(function (r) {
    return [date(r['Érkezett']), tx(r['Pilóta'], 80), tx(r['Verzió'], 20), tx(r['Mód'], 20), tx(r['Szint'], 20), tx(r['Hol'], 80),
      tx(r['Üzenet'], 2000), tx(r['Részletek (JSON)'], JSON_CELL), tx(r['Munkamenet'], 40)];
  });
  if (dbg.length) sheet_('Debug').getRange(2, 1, dbg.length, dbg[0].length).setValues(dbg);
  log.push('Debug: ' + dbg.length);

  let nl = 0;
  Object.keys(tracks).forEach(function (track) {
    const d = old('action=layouts&track=' + encodeURIComponent(track));
    (d.layouts || []).forEach(function (l) {
      const r = layout_({ track: track, name: l.name, layoutText: l.text, driver: l.author, version: l.version, mode: 'átvéve', uploaded: l.time });
      if (r.ok) nl++;
    });
  });
  log.push('Pályatervek: ' + nl + ' (' + Object.keys(tracks).length + ' pálya átnézve)');
  Logger.log(log.join(' · '));
  return log.join(' · ');
}

// Próba: egy futás felvétele a Drive-mappába és vissza (utána a próbasor törölhető).
function proba() {
  const r = saveRecord_({ runId: 'proba-' + Date.now(), driver: 'Próba', summary: { time: now_() }, record: { fields: ['t'], samples: [[0], [1]] } });
  const back = loadFile_(r.id);
  Logger.log('Felvétel: ' + r.id + ' · vissza: ' + JSON.stringify(back.record));
  Logger.log('Szerep ujjlenyomat (próba): ' + hashId_('76561198000000000'));
}

// Kézzel futtatható: törli a próbasorokat (Mód = „teszt” vagy Munkamenet = „proba”) minden lapról,
// a próbafelvételeket pedig a Drive kukájába teszi.
function torolTesztsorok() {
  Object.keys(SHEETS).forEach(function (name) {
    const sh = sheet_(name);
    const head = SHEETS[name];
    const mode = head.indexOf('Mód'), sess = head.indexOf('Munkamenet');
    const last = sh.getLastRow();
    if (last < 2) return;
    const vals = sh.getRange(2, 1, last - 1, head.length).getValues();
    for (let i = vals.length - 1; i >= 0; i--) {
      if ((mode >= 0 && String(vals[i][mode]) === 'teszt') || (sess >= 0 && String(vals[i][sess]) === 'proba')) sh.deleteRow(i + 2);
    }
  });
  const q = "'" + folderId_() + "' in parents and name contains 'proba' and trashed = false";
  const res = drive_('https://www.googleapis.com/drive/v3/files?fields=files(id,name)&q=' + encodeURIComponent(q), { method: 'get' });
  (JSON.parse(res.getContentText()).files || []).forEach(function (f) {
    drive_('https://www.googleapis.com/drive/v3/files/' + f.id, { method: 'patch', contentType: 'application/json', payload: JSON.stringify({ trashed: true }) });
    Logger.log('Kukába: ' + f.name);
  });
}
