const test = require('node:test');
const assert = require('node:assert/strict');

async function setup() {
  const { createDraftLinesController } = await import(
    '../../Sources/TradingWorkspace/Resources/Chart/draft-lines.mjs');
  let sequence = 0;
  const messages = [];
  const drawings = new Map();
  const handlers = new Map();
  const emit = (event, id) => handlers.get(event)?.({ id });
  const chart = {
    getVisibleRange: () => ({ from: 1000, to: 3000 }),
    on(event, callback) {
      handlers.set(event, callback);
      return () => handlers.delete(event);
    },
    drawings: {
      add(type, options) {
        const drawing = { id: String(++sequence), type, ...options };
        drawings.set(drawing.id, drawing);
        return drawing;
      },
      all: () => [...drawings.values()],
      update(id, patch) {
        Object.assign(drawings.get(id), patch);
        emit('drawing:edited', id);
      },
      remove(id) {
        if (drawings.delete(id)) emit('drawing:removed', id);
      },
    },
  };
  const controller = createDraftLinesController(chart, 'mint', message => messages.push(message));
  return { chart, controller, drawings, emit, messages };
}

function line(id = 'limit', price = 1, revision = 'initial') {
  return { id, price, revision, mint: 'mint', side: 'buy' };
}

test('Vela commits the dragged price without replaying native acknowledgements', async () => {
  const { chart, controller, drawings, messages } = await setup();
  controller.set([line()]);
  const limit = drawings.get('1');
  assert.equal(limit.type, 'hline');
  assert.deepEqual(limit.anchors, [{ time: 2000, price: 1 }]);
  chart.drawings.update(limit.id, { anchors: [{ time: 2000, price: 1.23 }] });
  controller.set([line()]);
  assert.equal(limit.anchors[0].price, 1.23);
  assert.deepEqual(messages, [{ id: 'limit', mint: 'mint', revision: 'initial', price: 1.23 }]);

  controller.set([line('limit', 1.45, 'typed')]);
  assert.equal(limit.anchors[0].price, 1.45);
  assert.equal(messages.length, 1);
});

test('TP and SL are independent with identifiable lines', async () => {
  const { chart, controller, drawings, messages } = await setup();
  const tp = line('take-profit', 1.1, 'tp');
  const sl = line('stop-loss', 0.9, 'sl');
  controller.set([tp, sl]);
  assert.equal(drawings.get('1').text.value, 'Draft TP · not placed');
  assert.equal(drawings.get('2').text.value, 'Draft SL · not placed');

  chart.drawings.update('2', { anchors: [{ time: 2000, price: 0.85 }] });
  controller.set([{ ...tp, price: 1.2, revision: 'new-tp' }, sl]);
  assert.equal(drawings.get('1').anchors[0].price, 1.2);
  assert.equal(drawings.get('2').anchors[0].price, 0.85);
  assert.deepEqual(messages, [{ id: 'stop-loss', mint: 'mint', revision: 'sl', price: 0.85 }]);
});

test('removing a line clears its native draft and ignores acknowledgements and undo ghosts', async () => {
  const { chart, controller, drawings, emit, messages } = await setup();
  controller.set([line()]);
  const old = drawings.get('1');
  chart.drawings.remove(old.id);
  assert.deepEqual(messages, [{ id: 'limit', mint: 'mint', revision: 'initial', removed: true }]);
  controller.set([line()]);
  assert.equal(drawings.size, 0);

  drawings.set(old.id, old);
  emit('drawing:selected');
  await Promise.resolve();
  assert.equal(drawings.size, 0);
  assert.equal(messages.length, 1);

  controller.set([line('limit', 2, 'reenabled')]);
  assert.equal(drawings.get('2').anchors[0].price, 2);
});

test('disabling drafts and closing the chart preserve unrelated drawings and emit no native edits', async () => {
  const { controller, drawings, emit, messages } = await setup();
  drawings.set('manual', { id: 'manual', type: 'trendline' });
  controller.set([line(), { ...line('take-profit'), mint: 'wrong-mint' }]);
  const old = drawings.get('1');
  assert.equal(drawings.size, 2);
  controller.set([]);
  drawings.set(old.id, old);
  emit('drawing:selected');
  await Promise.resolve();
  controller.dispose();
  controller.set([line()]);
  assert.deepEqual([...drawings.keys()], ['manual']);
  assert.deepEqual(messages, []);
});
