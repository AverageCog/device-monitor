// Regenerates json-vectors.json for WellFormedJSONTests: JSON as the hub writes it when one of
// its strings was cut inside a surrogate pair, and the text the Swift client must make of it.
//
//   node ios/Packages/DMCore/Tests/DMCoreTests/Fixtures/transport/generate-json-vectors.cjs
//
// The realistic rows come from the hub's own str() and normalizeReport() (security.js) and
// JSON.stringify. The repair is written here a second time, independently of the Swift, and is
// checked against String.prototype.toWellFormed() before anything is written.
'use strict';
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');

const root = path.resolve(__dirname, '../../../../../../..');
const security = require(path.join(root, 'security.js'));

const unit = code => String.fromCharCode(code);
const HIGH = unit(0xD83D), LOW = unit(0xDE00), EMOJI = HIGH + LOW, BACKSLASH = unit(0x5C);
// The six characters of an escape as they appear in JSON text.
const escaped = hex => BACKSLASH + 'u' + hex;

// Every backslash in JSON text starts an escape: an escaped pair, half a pair, or anything else
// (including an escaped backslash, whose second character must not start another escape).
const HEX = '[0-9a-fA-F]';
const ESCAPE = new RegExp(
  '[\\\\]u([dD][89abAB]' + HEX + '{2})[\\\\]u([dD][c-fC-F]' + HEX + '{2})' + '|' + '[\\\\]u([dD][89a-fA-F]' + HEX + '{2})' + '|' + '[\\\\][^]', 'g');
const repair = json => json.replace(ESCAPE, (all, high, low, half) => half ? escaped('fffd') : all);

const wellFormed = value => typeof value === 'string' ? value.toWellFormed()
  : Array.isArray(value) ? value.map(wellFormed)
  : value && typeof value === 'object' ? Object.fromEntries(Object.entries(value).map(([k, v]) => [k.toWellFormed(), wellFormed(v)]))
  : value;

const rows = [];
function row(note, json) {
  const repaired = repair(json);
  assert.strictEqual(repaired.length, json.length, note);
  assert.strictEqual(repair(repaired), repaired, note);
  let parsed, valid = true;
  try { parsed = JSON.parse(json); } catch { valid = false; }
  // What the repaired text parses to is what a browser shows for the original.
  if (valid) assert.deepStrictEqual(JSON.parse(repaired), wellFormed(parsed), note);
  rows.push({ note, json, repaired, valid });
}
const value = (note, v) => row(note, JSON.stringify(v));

// ---- what the hub really sends ---------------------------------------------
const cut = (letter, max) => letter.repeat(max - 1) + EMOJI;       // one UTF-16 unit too long, by half an emoji
const report = security.normalizeReport({
  id: 'ws-1', hostname: cut('a', 64), platform: 'linux', os: cut('b', 120),
  cpu: { name: cut('c', 120), usage: 37 }, memory: { total: 8e9, used: 2e9 },
  gpus: [{ name: cut('d', 120), vendor: cut('e', 20) }],
  disks: [{ name: cut('f', 80), label: cut('g', 80), total: 1e12, used: 5e11 }, { name: 'C:' + BACKSLASH, label: EMOJI + ' intact' }],
  temps: [{ name: cut('h', 80), parent: cut('i', 120), value: 40 }],
  fans: [{ name: cut('j', 80), rpm: 900 }],
  ai: [{ app: cut('k', 40), models: [{ name: cut('l', 200), size: 1, kind: cut('m', 30) }] }],
  actionResult: { id: 'abcdef012345', ok: false, message: cut('n', 200) },
});
value('a report with every string cut inside an emoji (normalizeReport)', report);
value('a device list', [{ id: 'ws-1', hostname: report.hostname, latest: report }, { id: 'nas', hostname: EMOJI + ' intact', latest: null }]);
value('a dashboard label cut to 60 units (cleanText)', { ok: true, name: security.cleanText('x'.repeat(59) + EMOJI, 60) });
value('a label that fits', { ok: true, name: security.cleanText('x'.repeat(58) + EMOJI, 60) });
row('a snapshot frame', '{"type":"snapshot","devices":[' + JSON.stringify({ id: 'ws-1', latest: report }) + ']}');

// ---- every arrangement JSON.stringify can produce ---------------------------
value('nothing to repair', { text: 'plain é ' + EMOJI, n: [1, 2.5, null, true] });
value('half a pair at the end', 'aaa' + HIGH);
value('half a pair at the start', LOW + ' tail');
value('the halves the wrong way round', LOW + HIGH);
value('halves kept apart', HIGH + 'x' + LOW);
value('a half before a whole', HIGH + EMOJI);
value('a whole before a half', EMOJI + LOW);
value('a half before other escapes', HIGH + 'A\n"' + HIGH + BACKSLASH);
value('a backslash followed by the text of an escape', BACKSLASH + 'ud83d');
value('a backslash followed by half a pair', BACKSLASH + HIGH);
value('two backslashes, text, a quote and a half', BACKSLASH + BACKSLASH + 'ud83d "' + HIGH + '"');
value('the neighbours of the surrogate range', unit(0xD7FF) + unit(0xE000) + unit(0xFFFD));
value('the first and last surrogates', unit(0xD800) + ' ' + unit(0xDBFF) + ' ' + unit(0xDC00) + ' ' + unit(0xDFFF));
value('halves as object keys', { [LOW]: HIGH, ['é' + EMOJI]: [unit(0xD800) + unit(0xDFFF), HIGH] });
value('control characters beside a half', unit(0) + HIGH + unit(0x1F) + unit(0x7F));

// ---- JSON another serialiser could produce ----------------------------------
const quoted = text => '"' + text + '"';
row('an escaped pair is left alone', quoted(escaped('d83d') + escaped('de00')));
row('escaped pairs and halves with capital hex digits', quoted(escaped('D83D') + escaped('DE00') + ' ' + escaped('D83D') + ' ' + escaped('De00')));
row('an escaped half before an escaped pair', quoted(escaped('d83d') + escaped('d83d') + escaped('de00')));
row('an escaped high half before an ordinary escape', quoted(escaped('d83d') + escaped('0041')));
row('an escaped half before an escaped backslash and the text of a low half', quoted(escaped('d83d') + BACKSLASH + BACKSLASH + 'ude00'));
row('a capital U is not an escape (and not JSON)', quoted(BACKSLASH + 'Ud83d'));
row('cut short inside an escape', quoted(escaped('d83d') + escaped('de0')).slice(0, -1));
row('cut short after a backslash', '"abc' + BACKSLASH);
row('an escape with a digit that is not hex', quoted(BACKSLASH + 'ud83g' + escaped('d83d')));
row('empty', '');

// The rows from the hub's own code stop needing repair if str() ever stops cutting inside a
// pair; the constructed ones keep both outcomes covered either way.
assert.ok(rows.filter(r => r.json !== r.repaired).length >= 18 && rows.filter(r => r.json === r.repaired).length >= 8);
fs.writeFileSync(path.join(__dirname, 'json-vectors.json'), JSON.stringify(rows, null, 1) + '\n');
console.log('wrote ' + rows.length + ' JSON texts, ' + rows.filter(r => r.json !== r.repaired).length + ' of them repaired');
