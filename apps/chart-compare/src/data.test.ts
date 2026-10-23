import test from 'node:test';
import assert from 'node:assert/strict';
import { normalizeCoinbase, syntheticSnapshot, historyPage, SharedTape } from './data.ts';

test('Coinbase seconds and tuple order normalize to ascending millisecond OHLCV', () => {
  assert.deepEqual(normalizeCoinbase([[200, 2, 5, 3, 4, 20], [100, 1, 4, 2, 3, 10]]), [
    { time: 100000, low: 1, high: 4, open: 2, close: 3, volume: 10 },
    { time: 200000, low: 2, high: 5, open: 3, close: 4, volume: 20 },
  ]);
  assert.throws(() => normalizeCoinbase([[100, 5, 4, 2, 3, 10]]));
});
test('history excludes its right boundary and supplies earlier bars for countBack', () => {
  const { bars } = syntheticSnapshot('SOL-USD', '60', 20);
  assert.deepEqual(historyPage(bars, bars[10].time, 3).map(b => b.time), bars.slice(7, 10).map(b => b.time));
  assert.deepEqual(historyPage(bars, bars[0].time, 10), []);
});
test('replay never exposes future bars; each engine gets independent copies', () => {
  const snapshot = syntheticSnapshot('SOL-USD', '60', 20);
  const tape = new SharedTape(snapshot, 10);
  let received = 0;
  tape.subscribe(bar => { bar.close = -1; });
  const unsubscribe = tape.subscribe(bar => { received++; assert.deepEqual(bar, snapshot.bars[10]); });
  const history = tape.bars; history[0].close = -1;
  assert.notEqual(tape.bars[0].close, -1);
  assert.equal(tape.bars.at(-1)?.time, snapshot.bars[9].time);
  assert.equal(tape.step(), true); assert.equal(received, 1); assert.equal(tape.cursor, 11);
  unsubscribe(); while (tape.step()) {};
  assert.equal(tape.cursor, 20); assert.equal(received, 1);
});
test('synthetic stress input is deterministic, ordered, valid and explicitly labeled', () => {
  const a = syntheticSnapshot('ETH-USD', '1D');
  assert.deepEqual(a, syntheticSnapshot('ETH-USD', '1D'));
  assert.match(a.source, /Synthetic/); assert.equal(a.bars.length, 10000);
  a.bars.forEach((bar, i) => {
    assert.ok(bar.low <= Math.min(bar.open, bar.close));
    assert.ok(bar.high >= Math.max(bar.open, bar.close));
    if (i) assert.equal(bar.time - a.bars[i - 1].time, 86400000);
  });
});
