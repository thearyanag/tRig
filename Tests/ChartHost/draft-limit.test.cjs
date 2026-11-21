const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');

function host({ deferred = false, ready = true, multiple = false } = {}) {
  let pending;
  const loaded = new Set();
  const events = new Map();
  const emit = (name, ...args) => { for (const fn of events.get(name) ?? []) fn(...args); };
  const event = (...args) => emit('drawing_event', ...args);
  let next = 1;
  const shapes = new Map(), posts = [], creates = [], removed = [], writes = [];
  const chart = {
    dataReady: () => ready,
    onDataLoaded: () => ({ subscribe(_owner, fn) { loaded.add(fn); }, unsubscribe(_owner, fn) { loaded.delete(fn); } }),
    createShape(point, options) {
      creates.push(options);
      const id = next++;
      shapes.set(id, {
        point: { ...point }, properties: {},
        getPoints() { return [this.point]; },
        setPoints(points) { writes.push('points'); this.point = { ...points[0] }; event?.(id, 'points_changed'); },
        setProperties(value) { writes.push('properties'); this.properties = value; }
      });
      return deferred ? new Promise(resolve => { pending = () => resolve(id); }) : Promise.resolve(id);
    },
    getShapeById: id => shapes.get(id),
    getAllShapes: () => Array.from(shapes.keys(), id => ({ id })),
    removeEntity(id) { shapes.delete(id); removed.push(id); event?.(id, 'remove'); }
  };
  const widget = { activeChart: () => chart,
    subscribe(name, fn) { if (!events.has(name)) events.set(name, new Set()); events.get(name).add(fn); },
    unsubscribe(name, fn) { events.get(name)?.delete(fn); }
  };
  const context = { window: {}, Date, Number, Math, queueMicrotask };
  vm.runInNewContext(fs.readFileSync('Sources/TradingWorkspace/Resources/Chart/draft-limit.js', 'utf8'), context);
  const factory = multiple ? context.window.createDraftLinesController : context.window.createDraftLimitController;
  const control = factory(widget, 'mint', 5, value => posts.push(value));
  return { control, posts, creates, removed, shapes, writes,
    down: () => emit('mouse_down'), up: () => emit('mouse_up'),
    event, undo: () => emit('undo_redo_state_changed'), resolve: () => pending(),
    ready() { ready = true; for (const fn of loaded) fn(); } };
}
const draft = (price = 1, revision = 'r1') => ({ mint: 'mint', side: 'buy', price, revision });
const tick = () => new Promise(resolve => setImmediate(resolve));

test('TP and SL remain independent across drags, native edits, removal, and mode switches', async () => {
  const h = host({ multiple: true });
  const tp = { ...draft(1.1, 'tp'), side: 'sell', id: 'take-profit' };
  const sl = { ...draft(0.9, 'sl'), side: 'sell', id: 'stop-loss' };
  h.control.set([tp, sl]); await tick();
  assert.equal(h.shapes.size, 2);
  assert.equal(h.creates[0].text, 'Draft TP · not placed');
  assert.equal(h.creates[1].text, 'Draft SL · not placed');
  h.down(); h.shapes.get(1).point.price = 1.2; h.event(1, 'move'); h.up(); await tick();
  assert.equal(h.posts[0].id, 'take-profit');
  assert.equal(h.posts[0].price, 1.2);
  assert.equal(h.shapes.get(2).point.price, 0.9);
  assert.deepEqual(h.writes, []);
  h.control.set([{ ...tp, price: 1.2 }, { ...sl, price: 0.8, revision: 'sl-edit' }]); await tick();
  assert.equal(h.shapes.get(1).point.price, 1.2);
  assert.equal(h.shapes.get(2).point.price, 0.8);
  h.shapes.delete(1); h.event(1, 'remove');
  assert.equal(h.posts.at(-1).id, 'take-profit');
  h.control.set([{ ...sl, price: 0.8, revision: 'sl-edit' }]); await tick();
  assert.equal(h.shapes.size, 1);
  h.control.set([{ ...draft(1), id: 'limit' }]); await tick();
  assert.equal(h.shapes.size, 1);
  assert.match(h.creates.at(-1).text, /Draft buy limit/);
  h.control.dispose(); assert.equal(h.shapes.size, 0);
});

test('drag acknowledgements never reset geometry or styling, even when native replies arrive late', async () => {
  const h = host(); h.control.set(draft()); await tick();
  h.down();
  h.shapes.get(1).point.price = 0.9; h.event(1, 'points_changed');
  h.shapes.get(1).point.price = 0.8; h.event(1, 'points_changed');
  h.control.set(draft(0.9)); // delayed native acknowledgement of the first move
  h.ready(); // candle refresh while dragging must not reposition the drawing
  assert.equal(h.shapes.get(1).point.price, 0.8);
  assert.deepEqual(h.writes, []);
  h.up();
  assert.deepEqual(h.writes, []); // mouse_up precedes TradingView's cleanup
  await tick();
  h.control.set(draft(0.8));
  assert.equal(h.shapes.get(1).point.price, 0.8);
  assert.deepEqual(h.writes, []);
  assert.deepEqual(h.posts.map(v => v.price), [0.8]);
});

test('a new native price command waits until the drag event stack has completed', async () => {
  const h = host(); h.control.set(draft()); await tick();
  h.down(); h.shapes.get(1).point.price = 0.9; h.event(1, 'move');
  h.control.set(draft(0.7, 'new-native-edit'));
  assert.equal(h.shapes.get(1).point.price, 0.9);
  assert.deepEqual(h.writes, []);
  h.up(); assert.deepEqual(h.writes, []);
  await tick();
  assert.equal(h.shapes.get(1).point.price, 0.7);
  assert.deepEqual(h.writes, ['points']);
});

test('native price edits move one unsaved draft; drag reports back without echoing native changes', async () => {
  const h = host();
  h.control.set(draft()); await tick();
  assert.equal(h.creates.length, 1);
  assert.equal(h.creates[0].disableSave, true);
  assert.equal(h.creates[0].lock, false);
  assert.match(h.creates[0].text, /Draft buy limit/);
  h.control.set(draft(0.8, 'r2')); await tick();
  assert.equal(h.shapes.get(1).point.price, 0.8);
  assert.equal(h.posts.length, 0);
  h.shapes.get(1).point.price = 0.75;
  h.event(1, 'move');
  await tick();
  assert.equal(h.posts[0].price, 0.75);
  assert.equal(h.posts[0].revision, 'r2');
  h.control.set(draft(0.75, 'r3')); await tick();
  assert.equal(h.posts.length, 1);
  assert.equal(h.creates.length, 1);
  h.event(99, 'remove');
  assert.equal(h.posts.length, 1);
});

test('move events publish the settled price, not TradingView’s temporary doubled offset', async () => {
  const h = host(); h.control.set(draft(1)); await tick();
  h.down();
  h.shapes.get(1).point.price = 1.1;
  h.up(); // mouse_up fires before the library clears its drag offset
  h.shapes.get(1).point.price = 1.2;
  h.event(1, 'move'); h.event(1, 'points_changed');
  assert.equal(h.posts.length, 0);
  h.shapes.get(1).point.price = 1.1; // library finishes endMoving before yielding
  await tick();
  assert.deepEqual(h.posts.map(v => v.price), [1.1]);
  assert.deepEqual(h.writes, []);
  h.control.set(draft(1.1));
  assert.deepEqual(h.writes, []);
  assert.equal(h.shapes.get(1).point.price, 1.1);
});

test('switching Market removes only the draft and does not report a user deletion', async () => {
  const h = host(); h.control.set(draft()); await tick();
  h.control.set(null); await tick();
  assert.deepEqual(h.removed, [1]); assert.equal(h.posts.length, 0);
});

test('deleting a draft reports removal and does not recreate it on data refresh', async () => {
  const h = host(); h.control.set(draft()); await tick();
  h.event(1, 'remove'); h.ready(); await tick();
  assert.equal(h.posts[0].removed, true);
  assert.equal(h.creates.length, 1);
});

test('undo cannot restore a detached old draft or remove unrelated drawings', async () => {
  const h = host(); h.control.set(draft()); await tick();
  const old = h.shapes.get(1);
  h.shapes.delete(1); h.event(1, 'remove');
  h.control.set(null);
  h.shapes.set(1, old); h.shapes.set(999, old);
  h.undo();
  assert.equal(h.shapes.has(1), false);
  assert.equal(h.shapes.has(999), true);
  assert.equal(h.posts.length, 1);
});

test('pending creation cannot leave a ghost line after mode changes or disposal', async () => {
  for (const dispose of [false, true]) {
    const h = host({ deferred: true }); h.control.set(draft());
    if (dispose) h.control.dispose(); else h.control.set(null);
    h.resolve(); await tick();
    assert.equal(h.shapes.size, 0);
    assert.equal(h.posts.length, 0);
  }
});

test('drawing waits for candles and ignores mismatched or non-finite targets', async () => {
  const h = host({ ready: false });
  h.control.set(draft()); await tick(); assert.equal(h.creates.length, 0);
  h.ready(); await tick(); assert.equal(h.creates.length, 1);
  for (const value of [{ ...draft(), mint: 'other' }, draft(-1), draft(NaN)]) {
    h.control.set(value); await tick(); assert.equal(h.shapes.size, 0);
  }
});
