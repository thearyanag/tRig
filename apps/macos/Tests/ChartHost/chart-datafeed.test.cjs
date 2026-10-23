const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const { pathToFileURL } = require('node:url');
const modulePath = pathToFileURL(path.resolve(__dirname, '../../Sources/AccountWebTest/Workbench/Resources/Chart/datafeed.mjs'));
const asset = { mint: 'selected-mint', pool: 'selected-pool', symbol: 'SOL', name: 'Solana', priceDigits: 6 };
const now = 1800000000000;
function payload(times, fetched_at = 1, close = 1.5) {
  return { mint: asset.mint, pool: asset.pool, fetched_at, bars: times.map(time => ({time, open:1, high:5, low:0.5, close, volume:10})) };
}
async function host(payloads) {
  const { createMarketFeed } = await import(modulePath);
  const requests = [], messages = [], timers = [];
  let resolution = '1', hidden = false;
  const feed = createMarketFeed({ asset, now: () => now,
    report: (phase, message, extra) => messages.push({phase,message,...extra}),
    currentResolution: () => resolution, hidden: () => hidden,
    schedule: fn => { timers.push(fn); return fn; }, cancel: () => {},
    fetcher: async (url, options) => {
      requests.push({url,options});
      const result = payloads.shift();
      const response = typeof result === 'function' ? await result(options) : result;
      return {ok:response.ok !== false,status:response.status || 200,json:async()=>response};
    },
  });
  return { ...feed, requests, messages, timers, resolution: value => resolution = value, hidden: value => hidden = value };
}
test('latest history and polling never emit a bar older than loaded history', async () => {
  const h = await host([payload([now-60000,now]),payload([now-60000,now]),payload([now,now+60000])]);
  await h.provider.getBars(asset.mint,'1',{limit:300});
  assert.equal(new URL(h.requests[0].url,'http://local').searchParams.has('before'),false);
  const emitted=[]; const stop=h.provider.subscribe(asset.mint,'1',bar=>emitted.push(bar.time));
  await h.timers[0](); await h.timers[0]();
  assert.deepEqual(emitted,[now,now,now+60000]); stop(); h.dispose();
});
test('Vela millisecond range is inclusive and converted to backend seconds', async () => {
  const h=await host([payload([1000,2000,3000,4000]),payload([])]);
  const bars=await h.provider.getBars(asset.mint,'1',{from:2000,to:3000,limit:3});
  assert.deepEqual(bars.map(b=>b.time),[2000,3000]);
  assert.equal(new URL(h.requests[0].url,'http://local').searchParams.get('before'),'3');
  assert.deepEqual(await h.provider.getBars(asset.mint,'1',{to:999}),[]);
});
test('provider errors do not masquerade as empty history', async () => {
  const h=await host([{ok:false,status:429,error:'Retry in one minute'}]);
  await assert.rejects(h.provider.getBars(asset.mint,'1',{}),/Retry in one minute/);
  assert.equal(h.messages.at(-1).phase,'error');
});
test('hidden, inactive and unsubscribed charts stop polling; resume catches up', async () => {
  const h=await host([payload([now])]);
  const stop=h.provider.subscribe(asset.mint,'1',()=>{});
  h.setActive(false); await h.timers[0](); assert.equal(h.requests.length,0);
  h.hidden(true); h.setActive(true); await h.timers[0](); assert.equal(h.requests.length,0);
  h.setActive(false); h.hidden(false); h.setActive(true);
  await new Promise(resolve=>setImmediate(resolve));
  assert.equal(new URL(h.requests[0].url,'http://local').searchParams.get('limit'),'300');
  stop(); await h.timers[0](); assert.equal(h.requests.length,1); h.dispose();
});
test('late response after unsubscribe or background does not deliver a tick', async () => {
  let release; const h=await host([()=>new Promise(resolve=>release=resolve)]);
  const emitted=[]; const stop=h.provider.subscribe(asset.mint,'1',b=>emitted.push(b));
  const polling=h.timers[0](); stop(); release(payload([now])); await polling;
  assert.deepEqual(emitted,[]); h.dispose();
});
test('price freshness survives switching intervals, and ignores old-interval history', async () => {
  let release;
  const h=await host([payload([now],10,2),()=>new Promise(resolve=>release=resolve),payload([now],30,4)]);
  await h.provider.getBars(asset.mint,'1',{});
  const stale=h.provider.getBars(asset.mint,'1',{});
  h.resolution('1D'); await h.provider.getBars(asset.mint,'1D',{});
  release(payload([now],40,3)); await stale;
  assert.deepEqual(h.messages.filter(m=>m.lastClose).map(m=>m.lastClose),[2,4]);
});
test('identity mismatches, unknown symbols and unsupported intervals are rejected', async () => {
  const bad=payload([now]); bad.mint='wrong-mint'; const h=await host([bad]);
  await assert.rejects(h.provider.getBars(asset.mint,'1',{}),/identity mismatch/);
  await assert.rejects(h.provider.getBars('unknown','1',{}),/native search/);
  await assert.rejects(h.provider.getBars(asset.mint,'7',{}),/Unsupported/);
  const params=new URL(h.requests[0].url,'http://local').searchParams;
  assert.equal(params.get('mint'),asset.mint); assert.equal(params.get('pool'),asset.pool);
});
test('invalid or unordered candle sequences are rejected', async () => {
  const h=await host([payload([2000,1000])]);
  await assert.rejects(h.provider.getBars(asset.mint,'1',{}),/Invalid candle sequence/);
});
test('dispose aborts in-flight history and suppresses its status update', async () => {
  const h=await host([options=>new Promise((_,reject)=>options.signal.addEventListener('abort',()=>reject(new Error('Aborted'))))]);
  const result=h.provider.getBars(asset.mint,'1',{}); h.dispose();
  await assert.rejects(result,/Aborted/); assert.equal(h.messages.at(-1).phase,'loading');
});
