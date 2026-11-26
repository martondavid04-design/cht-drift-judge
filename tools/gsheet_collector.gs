/**
 * CHT Drift Judge – adatgyűjtő (Google Apps Script webapp a „CHT Drift Judge – tesztadatok” táblázathoz).
 *
 * A program minden gépen (szerverről kapott vagy telepített változat) ide küldi:
 *   type = 'session'  belépés: verzió, CSP, mód, szerep, mit tud a CSP (Belépések lap)
 *   type = 'run'      befejezett futás: összegzés (Futások lap) + teljes telemetria (Telemetria lap, tömörítve)
 *   type = 'debug'    hibák és a festésfelismerés adatai (Debug lap)
 *   type = 'layout'   „Feltöltés mindenkinek”: egy pályaterv mindenkinek (Pályatervek lap, minden változat megmarad)
 * Pályatervek lekérése (kulcs nélkül, ezt kéri le a program induláskor): ?action=layouts&track=<pálya kulcsa>
 * Olvasás (doGet, külön olvasó kulccsal): ?key=…&action=ping | runs | debug | sessions | telemetry&run=<futás ID>
 *
 * Két kulcs van: a KEY-t (írás) a program is tartalmazza, ezért nyilvános – vele csak sort lehet hozzáadni.
 * A READ_KEY-jel (olvasás) le lehet kérni az adatokat; ez csak a közzétett scriptben van, a GitHubon nincs.
 *
 * @OnlyCurrentDoc  – csak ehhez a táblázathoz kér hozzáférést, a Drive többi fájljához nem.
 */

const KEY = 'Kwu8voShi5BWY71UMngoc6l39j3u';          // írás (a programban is benne van)
const READ_KEY = 'IDE_JON_AZ_OLVASO_KULCS';            // olvasás (csak a közzétett scriptben)
const MAX_BODY = 12 * 1024 * 1024;   // legfeljebb ennyi bájt egy küldésben
const CHUNK = 45000;                 // egy cella legfeljebb 50 000 karakter
const TZ = 'Europe/Budapest';

const SHEETS = {
  'Futások': ['Érkezett', 'Futás ideje', 'Típus', 'Pilóta', 'Autó', 'Pálya', 'Pályaterv', 'Verzió', 'Mód', 'Pont', 'Line', 'Angle',
    'Stílus', 'Nullás', 'Nullás oka', '1 kerék', '2 kerék', 'Korrekció', 'Fal', 'Túldobás', 'Idő (s)', 'Átlagseb. (km/h)',
    'Max. szög', 'Telemetria (KB)', 'Futás ID', 'Munkamenet', 'Eredmény (JSON)'],
  'Debug': ['Érkezett', 'Pilóta', 'Verzió', 'Mód', 'Szint', 'Hol', 'Üzenet', 'Részletek (JSON)', 'Munkamenet'],
  'Belépések': ['Érkezett', 'Pilóta', 'Autó', 'Pálya', 'Pályaterv', 'Verzió', 'Mód', 'CSP', 'Szerep', 'Admin',
    'Képességek (JSON)', 'Munkamenet'],
  'Telemetria': ['Futás ID', 'Érkezett', 'Pilóta', 'Bájt (tömörítve)', 'Részek', 'Adat (gzip, base64) →'],
  'Pályatervek': ['Feltöltve', 'Pálya', 'Név', 'Szerző', 'Verzió', 'Mód', 'Zónák', 'Bájt (tömörítve)', 'Részek', 'Pálya (AC)',
    'Adat (gzip, base64) →'],
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

function doPost(e) {
  try {
    const body = e && e.postData ? e.postData.contents : '';
    if (!body || body.length > MAX_BODY) return out_({ ok: false, error: 'size' });
    const m = JSON.parse(body);
    if (!m || m.key !== KEY) return out_({ ok: false, error: 'key' });
    const lock = LockService.getScriptLock();
    lock.waitLock(25000);
    try {
      if (m.type === 'session') return out_(session_(m));
      if (m.type === 'run') return out_(run_(m));
      if (m.type === 'debug') return out_(debug_(m));
      if (m.type === 'layout') return out_(layout_(m));
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
  sheet_('Belépések').appendRow([now_(), c.driver, txt_(m.car, 80), txt_(m.track, 80), txt_(m.layout, 80), c.version, c.mode,
    txt_(m.csp, 60), txt_(m.role, 20), m.admin ? 'igen' : '', txt_(JSON.stringify(m.caps || {}), 4000), c.session]);
  return { ok: true };
}

function run_(m) {
  const c = common_(m);
  const s = m.summary || {};
  const runId = str_(m.runId, 40);
  let kb = '';
  if (m.record) {
    const json = JSON.stringify(m.record);
    const gz = Utilities.base64Encode(Utilities.gzip(Utilities.newBlob(json, 'application/json')).getBytes());
    const parts = [];
    for (let i = 0; i < gz.length; i += CHUNK) parts.push("'" + gz.slice(i, i + CHUNK)); // a part may start with +
    kb = Math.round(json.length / 1024);
    sheet_('Telemetria').appendRow([txt_(runId, 40), now_(), c.driver, gz.length, parts.length].concat(parts));
  }
  sheet_('Futások').appendRow([now_(), txt_(s.time, 30), txt_(m.tag || 'futás', 20), c.driver, txt_(m.car, 80), txt_(m.track, 80), txt_(m.layout, 80), c.version,
    c.mode, num_(s.final), num_(s.line), num_(s.angle), num_(s.style), s.zero ? 'igen' : '', txt_(s.zeroReason, 300),
    num_(s.oneWheel), num_(s.twoWheel), num_(s.corrections), num_(s.wallSaves), num_(s.overRot), num_(s.duration),
    num_(s.avgSpeed), num_(s.maxAngle), kb, txt_(runId, 40), c.session, txt_(JSON.stringify(m.result || {}), 45000)]);
  return { ok: true, run: runId };
}

function debug_(m) {
  const c = common_(m);
  sheet_('Debug').appendRow([now_(), c.driver, c.version, c.mode, txt_(m.level, 20), txt_(m.where, 80), txt_(m.message, 2000),
    txt_(JSON.stringify(m.details || {}), 45000), c.session]);
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
  sh.appendRow([now_(), txt_(track), txt_(name), c.driver, c.version, c.mode, data.zones.length, gz.length, parts.length,
    txt_(m.trackID, 160)].concat(parts));
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

// Olvasás --------------------------------------------------------------------------------------------
function rows_(name, limit) {
  const sh = sheet_(name);
  const last = sh.getLastRow();
  if (last < 2) return [];
  const n = Math.min(limit, last - 1);
  const head = sh.getRange(1, 1, 1, sh.getLastColumn()).getValues()[0];
  const vals = sh.getRange(last - n + 1, 1, n, head.length).getValues();
  return vals.reverse().map(function (r) { const o = {}; head.forEach(function (h, i) { o[h] = r[i]; }); return o; });
}

function telemetry_(runId) {
  const sh = sheet_('Telemetria');
  const last = sh.getLastRow();
  if (last < 2) return null;
  const ids = sh.getRange(2, 1, last - 1, 1).getValues();
  for (let i = ids.length - 1; i >= 0; i--) {
    if (String(ids[i][0]) === String(runId)) {
      const row = i + 2;
      const parts = Number(sh.getRange(row, 5).getValue());
      const gz = sh.getRange(row, 6, 1, parts).getValues()[0].join('');
      const blob = Utilities.newBlob(Utilities.base64Decode(gz), 'application/x-gzip');
      return JSON.parse(Utilities.ungzip(blob).getDataAsString('UTF-8'));
    }
  }
  return null;
}

function doGet(e) {
  const p = (e && e.parameter) || {};
  // a pályatervek nyilvánosak: ezt kéri le minden gép induláskor (kulcs nélkül)
  if (p.action === 'layouts') {
    try { return out_({ ok: true, track: trackKey_(p.track), layouts: layouts_(p.track) }); }
    catch (err) { return out_({ ok: false, error: String(err) }); }
  }
  if (!READ_KEY || READ_KEY === 'IDE_JON_AZ_OLVASO_KULCS' || p.key !== READ_KEY) return out_({ ok: false, error: 'key' });
  const limit = Math.max(1, Math.min(500, Number(p.limit) || 50));
  try {
    if (p.action === 'runs') return out_({ ok: true, rows: rows_('Futások', limit) });
    if (p.action === 'debug') return out_({ ok: true, rows: rows_('Debug', limit) });
    if (p.action === 'sessions') return out_({ ok: true, rows: rows_('Belépések', limit) });
    if (p.action === 'telemetry') return out_({ ok: true, record: telemetry_(p.run) });
    return out_({ ok: true, pong: now_() });
  } catch (err) {
    return out_({ ok: false, error: String(err) });
  }
}

// Kézzel futtatható: törli a próbasorokat (Mód = „teszt”) minden lapról.
function torolTesztsorok() {
  ['Futások', 'Debug', 'Belépések', 'Pályatervek'].forEach(function (name) {
    const sh = sheet_(name);
    const head = sh.getRange(1, 1, 1, sh.getLastColumn()).getValues()[0];
    const col = head.indexOf('Mód');
    for (let r = sh.getLastRow(); r >= 2 && col >= 0; r--) {
      if (String(sh.getRange(r, col + 1).getValue()) === 'teszt') sh.deleteRow(r);
    }
  });
  const tel = sheet_('Telemetria');
  for (let r = tel.getLastRow(); r >= 2; r--) {
    const id = String(tel.getRange(r, 1).getValue());
    if (id.indexOf('proba-') === 0 || id === '6b0769a9-cb51-1') tel.deleteRow(r);
  }
}

// Kézzel futtatható: létrehozza a lapokat (az első küldés is létrehozza őket).
function setup() {
  Object.keys(SHEETS).forEach(sheet_);
  const def = SpreadsheetApp.getActiveSpreadsheet().getSheetByName('Munkalap1') || SpreadsheetApp.getActiveSpreadsheet().getSheetByName('Sheet1');
  if (def && SpreadsheetApp.getActiveSpreadsheet().getSheets().length > 1) SpreadsheetApp.getActiveSpreadsheet().deleteSheet(def);
}
