const test = require('node:test');
const assert = require('node:assert');
const { createToolRegistry, TOOLS } = require('../../cep/server/tools-illustrator.js');

function stubHost(responses = {}) {
  const calls = [];
  return {
    calls,
    fn: async (op, args, timeoutMs) => {
      calls.push({ op, args, timeoutMs });
      if (responses[op]) return responses[op];
      return { ok: true, result: { op, echoed: args } };
    },
  };
}

test('every tool has a name, a description and an object schema', () => {
  for (const t of TOOLS) {
    assert.ok(t.name.startsWith('ai_'), `${t.name} should be ai_-prefixed`);
    assert.ok(t.description.length > 100, `${t.name} description is too thin to guide a model`);
    assert.strictEqual(t.inputSchema.type, 'object');
  }
});

test('the tool surface is the ten documented tools', () => {
  assert.deepStrictEqual(
    TOOLS.map((t) => t.name).sort(),
    ['ai_capture', 'ai_create', 'ai_diagnostics', 'ai_document', 'ai_export', 'ai_items',
     'ai_layers', 'ai_layout', 'ai_query', 'ai_set'],
  );
});

test('descriptions state token cost where an agent can blow a context window', () => {
  const query = TOOLS.find((t) => t.name === 'ai_query');
  assert.match(query.description, /maxItems/);
  assert.match(query.description, /start shallow/i);
  const capture = TOOLS.find((t) => t.name === 'ai_capture');
  assert.match(capture.description, /cost scales/i);
});

test('every tool that takes a position states the coordinate convention', () => {
  for (const name of ['ai_create', 'ai_set']) {
    const t = TOOLS.find((x) => x.name === name);
    assert.match(t.description, /y grows DOWN/, `${name} must say y points down`);
    assert.match(t.description, /top-left/, `${name} must say x,y is the top-left`);
  }
});

test('colour docs say 0-255, not the 0-1 scale other tools use', () => {
  for (const name of ['ai_create', 'ai_set']) {
    assert.match(TOOLS.find((x) => x.name === name).description, /0-255/);
  }
});

test('ai_query dispatches read commands straight through as host ops', async () => {
  const host = stubHost();
  const reg = createToolRegistry(host.fn);
  for (const command of ['sessionInfo', 'tree', 'find', 'item', 'selection', 'fonts', 'swatches']) {
    await reg.callTool('ai_query', { command });
  }
  assert.deepStrictEqual(host.calls.map((c) => c.op),
    ['sessionInfo', 'tree', 'find', 'item', 'selection', 'fonts', 'swatches']);
});

test('ai_query cannot be used to reach a mutating op', async () => {
  const host = stubHost();
  const reg = createToolRegistry(host.fn);
  for (const command of ['set', 'items', 'document', 'exportFile']) {
    const res = await reg.callTool('ai_query', { command });
    assert.strictEqual(res.isError, true, `ai_query ${command} must be refused`);
  }
  assert.strictEqual(host.calls.length, 0);
});

test('each write tool maps to its host op', async () => {
  const host = stubHost();
  const reg = createToolRegistry(host.fn);
  await reg.callTool('ai_document', { command: 'new' });
  await reg.callTool('ai_create', { kind: 'rect' });
  await reg.callTool('ai_set', { writes: [] });
  await reg.callTool('ai_items', { command: 'group' });
  await reg.callTool('ai_layers', { command: 'create' });
  await reg.callTool('ai_export', { path: '/tmp/x.png' });
  await reg.callTool('ai_diagnostics', {});
  assert.deepStrictEqual(host.calls.map((c) => c.op),
    ['document', 'create', 'set', 'items', 'layers', 'exportFile', 'problems']);
});

test('ai_layout sends each command to its own op and refuses unknown ones', async () => {
  const host = stubHost();
  const reg = createToolRegistry(host.fn);
  await reg.callTool('ai_layout', { command: 'align', uuids: ['1'] });
  await reg.callTool('ai_layout', { command: 'distribute', uuids: ['1'] });
  await reg.callTool('ai_layout', { command: 'stack', uuids: ['1'] });
  const bad = await reg.callTool('ai_layout', { command: 'set', uuids: ['1'] });
  assert.deepStrictEqual(host.calls.map((c) => c.op), ['align', 'distribute', 'stack']);
  assert.strictEqual(bad.isError, true);
});

test('an unknown tool is an isError result rather than a throw', async () => {
  const reg = createToolRegistry(stubHost().fn);
  const res = await reg.callTool('ai_nope', {});
  assert.strictEqual(res.isError, true);
  assert.match(res.content[0].text, /Unknown tool/);
});

test('a host-side failure surfaces its code and message', async () => {
  const host = stubHost({ sessionInfo: { ok: false, error: { code: 'op_failed', message: 'no document' } } });
  const reg = createToolRegistry(host.fn);
  const res = await reg.callTool('ai_query', { command: 'sessionInfo' });
  assert.strictEqual(res.isError, true);
  assert.match(res.content[0].text, /op_failed/);
  assert.match(res.content[0].text, /no document/);
});

test('ai_capture asks for a sandboxed bare filename, never a caller path', async () => {
  const host = stubHost({ captureArtboard: { ok: false, error: { code: 'op_failed', message: 'stub' } } });
  const reg = createToolRegistry(host.fn);
  await reg.callTool('ai_capture', { command: 'artboard', fileName: '/etc/evil.png' });
  const sent = host.calls[0].args;
  assert.match(sent.fileName, /^cap\d+\.png$/, 'a caller-supplied fileName must be overridden');
  assert.strictEqual(sent.outPath, undefined);
});

test('ai_capture routes each command to its op with the documented default edge', async () => {
  const fail = { ok: false, error: { code: 'x', message: 'y' } };
  const host = stubHost({ captureArtboard: fail, captureRegion: fail, captureItem: fail });
  const reg = createToolRegistry(host.fn);
  await reg.callTool('ai_capture', { command: 'artboard' });
  await reg.callTool('ai_capture', { command: 'region', width: 10, height: 10 });
  await reg.callTool('ai_capture', { command: 'item', uuid: '5' });
  assert.deepStrictEqual(host.calls.map((c) => [c.op, c.args.longEdge]),
    [['captureArtboard', 768], ['captureRegion', 768], ['captureItem', 512]]);
  assert.strictEqual(host.calls[2].args.uuid, '5');
});

test('ai_capture artboards captures every artboard when none are named', async () => {
  const host = stubHost({
    sessionInfo: { ok: true, result: { active: { artboards: [{ index: 0 }, { index: 1 }, { index: 2 }] } } },
    captureArtboard: { ok: false, error: { code: 'x', message: 'y' } },
  });
  const reg = createToolRegistry(host.fn);
  const res = await reg.callTool('ai_capture', { command: 'artboards' });
  const shots = host.calls.filter((c) => c.op === 'captureArtboard');
  assert.deepStrictEqual(shots.map((c) => c.args.artboard), [0, 1, 2]);
  assert.ok(shots.every((c) => c.args.longEdge === 320), 'sheet cells default to 320px');
  assert.strictEqual(res.isError, true, 'all captures failing is an error, not an empty sheet');
});

test('export gets a long timeout; ordinary reads keep the default', async () => {
  const host = stubHost();
  const reg = createToolRegistry(host.fn);
  await reg.callTool('ai_export', { path: '/tmp/x.svg' });
  await reg.callTool('ai_query', { command: 'sessionInfo' });
  assert.ok(host.calls[0].timeoutMs >= 60000, 'a large export must not inherit the default 30s timeout');
  assert.strictEqual(host.calls[1].timeoutMs, undefined);
});

test('ai_export documents why PDF is absent and SVG is routed differently', () => {
  const e = TOOLS.find((t) => t.name === 'ai_export');
  assert.match(e.description, /re-points/);
  assert.match(e.description, /PDF is not/);
});

test('ai_set documents its fixed application order and the point-text re-anchor', () => {
  const s = TOOLS.find((t) => t.name === 'ai_set');
  assert.match(s.description, /order/i);
  assert.match(s.description, /position, then lock/);
  assert.match(s.description, /baseline/);
});

test('ai_diagnostics reloadHost reports a reload only when the load stamp changed', async () => {
  let stamp = 1;
  const reg = createToolRegistry(async (op) => {
    if (op === 'hostInfo') return { ok: true, result: { loadedAt: stamp } };
    if (op === 'reloadHost') return { ok: true, result: { loadedAt: stamp, opCount: 3 } };
    return { ok: true, result: {} };
  });
  const same = JSON.parse((await reg.callTool('ai_diagnostics', { command: 'reloadHost' })).content[0].text);
  assert.strictEqual(same.reloaded, false);
  assert.match(same.error, /restart Illustrator/);
});
