/*
 * Guards against the ways this server could damage a user's work.
 *
 * These assert on source text because the code under test is ExtendScript that
 * only runs inside Illustrator. A static check that cannot be fooled is worth
 * more here than no check at all: each of these was either a real bug on the
 * After Effects server this was forked from, or measured on Illustrator 30.8.1
 * while building this one.
 */
const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');

const ROOT = path.join(__dirname, '..', '..');
const read = (p) => fs.readFileSync(path.join(ROOT, p), 'utf8');
const code = (p) => read(p).split('\n').filter((l) => !/^\s*(\/\/|\*|\/\*)/.test(l)).join('\n');

test('no host code ever closes a document with SAVECHANGES', () => {
  // Alerts are suppressed for every op, so a "save changes?" prompt would be
  // answered for the user. Closing must only ever discard, behind a guard.
  for (const f of fs.readdirSync(path.join(ROOT, 'cep/host/ai'))) {
    assert.doesNotMatch(code(`cep/host/ai/${f}`), /SaveOptions\.SAVECHANGES|SaveOptions\.PROMPTTOSAVECHANGES/, f);
  }
});

test('close refuses unsaved changes unless discardUnsaved is passed', () => {
  const src = code('cep/host/ai/ops-build.jsx');
  const close = src.slice(src.indexOf('cmd === "close"'));
  assert.match(close.slice(0, 400), /!doc\.saved && args\.discardUnsaved !== true/);
});

test('save and export never overwrite without overwrite:true', () => {
  const src = code('cep/host/ai/ops-build.jsx');
  const guards = src.match(/file\.exists && args\.overwrite !== true/g) || [];
  assert.ok(guards.length >= 2, 'both save and exportFile must check overwrite');
});

test('SVG never goes through exportFile, which re-points the open document', () => {
  // Measured: exportFile(ExportType.SVG) renamed the document to the .svg and
  // marked it saved, disarming the close guard.
  for (const f of fs.readdirSync(path.join(ROOT, 'cep/host/ai'))) {
    assert.doesNotMatch(code(`cep/host/ai/${f}`), /ExportType\.SVG/, f);
  }
  assert.match(code('cep/host/ai/ops-build.jsx'), /exportForScreens\(/);
});

test('no host code saves to PDF, which would re-point the open document', () => {
  for (const f of fs.readdirSync(path.join(ROOT, 'cep/host/ai'))) {
    assert.doesNotMatch(code(`cep/host/ai/${f}`), /PDFSaveOptions/, f);
  }
});

test('a failed create removes the item it made', () => {
  const src = code('cep/host/ai/ops-build.jsx');
  const create = src.slice(src.indexOf('create: function'));
  assert.match(create, /catch \(e\) \{\s*[^}]*it\.remove\(\)/, 'a bad font or colour must not strand an orphan');
});

test('deleting a layer with artwork needs deleteContents:true', () => {
  assert.match(code('cep/host/ai/ops-mutate.jsx'), /layer\.pageItems\.length && args\.deleteContents !== true/);
});

test('capture writes only bare filenames inside the app-owned folder', () => {
  const src = read('cep/host/ai/util.jsx');
  const fn = src.slice(src.indexOf('function __mcp_safeCaptureFile'));
  assert.match(fn.slice(0, 600), /\^\[A-Za-z0-9\._-\]\+\\\.png\$/);
  assert.match(fn.slice(0, 600), /__mcp_captureDir\(\)/);
});

test('isolated capture restores every hidden flag it changed', () => {
  const src = code('cep/host/ai/ops-capture.jsx');
  assert.match(src, /finally \{[\s\S]*hiddenNow\[j\]\.hidden = false/);
  assert.match(src, /finally \{[\s\S]*layersShown\[k\]\.visible = false/);
});
