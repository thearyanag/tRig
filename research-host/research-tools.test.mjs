import assert from 'node:assert/strict';
import test from 'node:test';
import { createResearchTools } from './research-tools.mjs';

const address = 'BPxxfRCXkUVhig4HS1Lh7kZqV6SPJhzfEk4x6fVBjPCy';
const scope = { asset: `solana:${address}`, symbol: 'BP', name: 'Backpack', signal: new AbortController().signal };

function withData(t, respond) {
  t.mock.method(globalThis, 'fetch', async url => {
    const data = respond(url);
    assert.ok(data, `Unexpected request to ${url}`);
    return Response.json(data);
  });
  return createResearchTools('http://127.0.0.1/');
}

test('uses the open asset alias and distinguishes missing holdings from incomplete data', async t => {
  let cache;
  const paths = [];
  const call = withData(t, url => {
    paths.push(url.pathname);
    if (url.pathname === '/api/portfolio/cache') return cache;
  });
  cache = { accounts: [{ source: 'pump' }], views: { pump: { sourceCount: 1 } },
    market: { asOf: Math.floor(Date.now() / 1000), holdings: [], warnings: [] } };

  const missing = await call('get_my_position', { asset: 'bp' }, scope);
  assert.equal(missing.status, 'no_holding');
  assert.equal(missing.quantity, '0');

  cache.market.asOf -= 90;
  const stale = await call('get_my_position', {}, scope);
  assert.equal(stale.status, 'unknown');
  assert.equal(stale.quantity, null);

  cache.market.asOf += 90;
  cache.accounts.push({ source: 'fomo' });
  const partial = await call('get_my_position', {}, scope);
  assert.equal(partial.status, 'unknown');
  assert.equal(partial.quantity, null);

  cache.market.holdings = [{ chain: 'solana', mint: address, quantity: '731.125', valueUsd: '12.5', sources: ['pump'] }];
  const known = await call('get_my_position', {}, scope);
  assert.equal(known.quantity, '731.125');
  assert.equal(known.coverage.complete, false);
  assert.equal(Object.hasOwn(known, 'valueUsd'), false);
  assert.deepEqual(paths, Array(4).fill('/api/portfolio/cache'));
});

test('asks for clarification when a requested ticker matches multiple chains', async t => {
  const candidates = [{ chainId: 'solana', id: 'ONE', symbol: 'TEST' },
    { chainId: 'eip155:8453', id: '0x01', symbol: 'TEST' }];
  const call = withData(t, url => {
    if (url.pathname === '/api/assets/search' && url.searchParams.get('q') === 'TEST') return { assets: candidates };
  });
  const result = await call('get_market_overview', { asset: 'TEST' }, scope);
  assert.equal(result.status, 'clarify_asset');
  assert.deepEqual(result.candidates.map(item => item.chain), ['solana', 'eip155:8453']);
});

test('passes the canonical open asset to the Telegram adapter', async () => {
  const call = createResearchTools('http://127.0.0.1/');
  const result = await call('get_asset_discussion', {}, {
    ...scope, telegram: async key => ({ threadAsset: key }),
  });
  assert.deepEqual(result, { threadAsset: scope.asset });
});

test('uses the displayed market route for history without resolving it again', async t => {
  const pool = '6qz7THwQvcjF3HyDGLuKaLBUk6EyJKeZXZMWLAeiwfjd';
  const candle = { time: 1710000000000, open: 1, high: 2, low: 1, close: 2, volume: 100 };
  const call = withData(t, url => {
    assert.equal(url.pathname, '/api/chart/bars');
    assert.equal(url.searchParams.get('mint'), address);
    assert.equal(url.searchParams.get('pool'), pool);
    assert.equal(url.searchParams.get('resolution'), '1D');
    return { bars: [candle], fetched_at: 1710000000, cached: true };
  });
  const result = await call('get_price_history', { interval: '1D' }, { ...scope, pool });
  assert.equal(result.candleTimeUnit, 'unix_milliseconds');
  assert.deepEqual(result.candles, [candle]);
});
