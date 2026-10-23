const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');

function host(payloads) {
  let options;
  let timer;
  let resets = 0;
  const requests = [];
  const messages = [];
  const chart = { resetData() { resets++; }, resolution() { return '1'; } };
  const context = {
    URLSearchParams, Date, Map, Set, AbortController, console,
    location: { search: '?theme=dark' },
    document: { hidden: false, documentElement: { classList: { toggle() {} } } },
    window: { webkit: { messageHandlers: { chartStatus: { postMessage(v) { messages.push(v); } } } } },
    TradingView: { widget: function(value) { options = value; this.activeChart = () => chart; this.remove = () => {}; } },
    setTimeout(fn, delay) { if (delay === 0) queueMicrotask(fn); return 1; },
    clearTimeout() {},
    setInterval(fn) { timer = fn; return 1; },
    clearInterval() {},
    async fetch(url) {
      requests.push(url);
      const response = payloads.shift();
      return { ok: response.ok !== false, status: response.status || 200, async json() { return response; } };
    }
  };
  vm.runInNewContext(fs.readFileSync('Sources/AccountWebTest/Workbench/Resources/Chart/chart.js', 'utf8'), context);
  return { feed: options.datafeed, requests, messages, poll: () => timer(), context, chart, resets: () => resets };
}
function payload(times) { return { mint: "BPxxfRCXkUVhig4HS1Lh7kZqV6SPJhzfEk4x6fVBjPCy", pool: "6qz7THwQvcjF3HyDGLuKaLBUk6EyJKeZXZMWLAeiwfjd", bars: times.map(time => ({time, open:1, high:2, low:0.5, close:1.5, volume:10})), fetched_at:1 }; }
function history(feed, period) {
  return new Promise((resolve, reject) => feed.getBars({}, '1', period, (bars, meta) => resolve({bars,meta}), reject));
}

test('initial history and refresh never insert an older bar', async () => {
  const now = Math.floor(Date.now() / 1000);
  const latest = (now - now % 60) * 1000;
  const h = host([payload([latest - 60000, latest]), payload([latest - 60000, latest]), payload([latest, latest + 60000])]);
  const first = await history(h.feed, {firstDataRequest:true, to:now + 60, countBack:10});
  assert.equal(first.bars.length, 2);
  assert.equal(h.requests[0].includes('before='), false);
  const emitted = [];
  h.feed.subscribeBars({}, '1', bar => emitted.push(bar.time), 'main');
  await h.poll();
  assert.deepEqual(emitted, [latest]);
  await h.poll();
  assert.deepEqual(emitted, [latest, latest, latest + 60000]);
});

test('historical right boundary is exclusive, and empty history ends pagination', async () => {
  const h = host([payload([1000,2000,3000]), payload([])]);
  const result = await history(h.feed, {firstDataRequest:false,to:3,countBack:3});
  assert.deepEqual(Array.from(result.bars, bar => bar.time), [1000,2000]);
  assert.ok(h.requests[0].includes('before=2'));
  const empty = await history(h.feed, {firstDataRequest:false,to:1,countBack:3});
  assert.equal(empty.meta.noData, true);
});

test('errors remain errors rather than becoming empty chart data', async () => {
  const h = host([{ok:false,status:429,error:'Retry in one minute'}]);
  await assert.rejects(history(h.feed, {firstDataRequest:true,to:Date.now()/1000,countBack:1}), /Retry in one minute/);
  assert.equal(h.messages.at(-1).phase, 'error');
});

test('background and unsubscribed charts stop polling; resume reloads history', async () => {
  const h = host([payload([1000])]);
  h.feed.subscribeBars({}, '1', () => {}, 'main');
  h.context.window.chartHost.setActive(false);
  await h.poll();
  assert.equal(h.requests.length, 0);
  h.context.window.chartHost.setActive(true);
  assert.equal(h.resets(), 1);
  h.feed.unsubscribeBars('main');
  await h.poll();
  assert.equal(h.requests.length, 0);
});


test('a newer daily quote can follow a minute quote without regressing freshness', async () => {
  const first = payload([60000]); first.fetched_at = 10; first.bars[0].close = 2;
  const minute = payload([120000]); minute.fetched_at = 20; minute.bars[0].close = 3;
  const daily = payload([60000]); daily.fetched_at = 30; daily.bars[0].close = 4;
  const h = host([first, minute, daily]);
  const period = {firstDataRequest:true, to:Date.now()/1000 + 60, countBack:1};
  const get = resolution => new Promise((resolve, reject) => h.feed.getBars({}, resolution, period, resolve, reject));
  h.chart.resolution = () => '1D';
  await get('1D');
  h.chart.resolution = () => '1';
  await get('1');
  h.chart.resolution = () => '1D';
  await get('1D');
  assert.deepEqual(h.messages.filter(message => message.lastClose).map(message => message.lastClose), [2,3,4]);
});

test('candle requests carry asset identity and reject a mismatched response', async () => {
  const bad = payload([1000]); bad.mint = 'another-asset';
  const h = host([bad]);
  await assert.rejects(history(h.feed, {firstDataRequest:true,to:Date.now()/1000,countBack:1}), /identity mismatch/);
  assert.ok(h.requests[0].includes('mint=BPxxfRCX'));
  assert.ok(h.requests[0].includes('pool=6qz7THw'));
});

test('unknown TradingView symbols cannot silently resolve to the current asset', async () => {
  const h = host([]);
  await assert.rejects(new Promise((resolve, reject) => h.feed.resolveSymbol('unknown', resolve, reject)), /native search/);
});
