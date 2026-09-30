/*
 * Regressions found by using the Illustrator server on real work - two award
 * graphics built end to end on 2026-09-29/30 - rather than by its own tests.
 * Each is a source check, because the code under test is ExtendScript that
 * only runs inside Illustrator; test/verify-live-illustrator.sh proves the
 * same behaviour against the real app.
 */
const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const { TOOLS } = require('../../cep/server/tools-illustrator.js');

const ROOT = path.join(__dirname, '..', '..');
const code = (p) => fs.readFileSync(path.join(ROOT, p), 'utf8')
  .split('\n').filter((l) => !/^\s*(\/\/|\*|\/\*)/.test(l)).join('\n');
const fnBody = (src, name) => {
  const start = src.indexOf(name);
  assert.ok(start !== -1, `${name} not found`);
  let depth = 0, i = src.indexOf('{', start);
  for (let j = i; j < src.length; j++) {
    if (src[j] === '{') depth++;
    if (src[j] === '}' && --depth === 0) return src.slice(i, j + 1);
  }
  throw new Error(`unbalanced ${name}`);
};

test('text attributes are read from ONE textRange', () => {
  // A second `textRange` invalidates attributes taken from the first ("the
  // value would result in an illegal text range"); every font, size and fill
  // read as null until this was fixed.
  const info = fnBody(code('cep/host/ai/ops-query.jsx'), 'function __mcp_textInfo');
  assert.strictEqual((info.match(/\.textRange\b/g) || []).length, 1, '__mcp_textInfo must ask for textRange once');
  const style = fnBody(code('cep/host/ai/ops-mutate.jsx'), 'function __mcp_applyStyle');
  assert.strictEqual((style.match(/\.textRange\b/g) || []).length, 1, '__mcp_applyStyle must ask for textRange once');
});

test('ai_create can place an image, embedded by default', () => {
  const create = TOOLS.find((t) => t.name === 'ai_create');
  assert.ok(create.inputSchema.properties.kind.enum.includes('image'));
  assert.ok(create.inputSchema.properties.path, 'image needs a path argument');
  const host = code('cep/host/ai/ops-build.jsx');
  assert.match(host, /kind === "image"/);
  const place = fnBody(host, 'function __mcp_placeImage');
  assert.match(place, /args\.embed !== false/, 'embedding must be the default');
  assert.match(place, /\.embed\(\)/);
  assert.match(place, /catch \(e\) \{[\s\S]*it\.remove\(\)/, 'a failed place must not strand an item');
});

test('export reports the file Illustrator actually wrote, and fails when there is none', () => {
  // PNG export writes "Campaign-Tech-Award-2026.png" for "Campaign Tech Award
  // 2026.png", and File.name is URI-encoded, so the lookup used to miss and
  // report path:null for a file that existed.
  const exp = fnBody(code('cep/host/ai/ops-build.jsx'), 'exportFile: function');
  assert.match(exp, /decodeURI\(file\.name\)/);
  assert.match(exp, /replace\(\/ \/g, "-"\)/);
  assert.match(exp, /if \(!written\) \{ throw new Error/, 'no file must be an error, not an empty success');
});

test('artboards outside the canvas get a readable error, not "CoOA"', () => {
  const host = code('cep/host/ai/ops-build.jsx');
  assert.match(fnBody(host, 'function __mcp_setArtboardRect'), /CoOA/);
  const doc = fnBody(host, 'document: function');
  assert.doesNotMatch(doc, /doc\.artboards\.add\(abRect/, 'addArtboard must go through __mcp_setArtboardRect');
  assert.doesNotMatch(doc, /board\.artboardRect = abRect/, 'setArtboard must go through __mcp_setArtboardRect');
});

test('find can tell nested items from top-level ones', () => {
  const query = TOOLS.find((t) => t.name === 'ai_query');
  assert.ok(query.inputSchema.properties.topLevel);
  assert.match(query.description, /parentUuid/);
  assert.match(fnBody(code('cep/host/ai/ops-query.jsx'), 'find: function'), /args\.topLevel === true/);
  assert.match(fnBody(code('cep/host/ai/util.jsx'), 'function __mcp_summary'), /parentUuid/);
});
