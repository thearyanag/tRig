const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const source = fs.readFileSync(path.join(__dirname, '../../Sources/TradingWorkspace/Services/Connections/FomoProfileBridge.swift'), 'utf8');
const body = source.match(/static let read = #"""([\s\S]*?)"""#/)[1].replace(/await import\(/g, 'await loadModule(');
const AsyncFunction = Object.getPrototypeOf(async function() {}).constructor;
const run = new AsyncFunction('location', 'performance', 'loadModule', body);
const id = '11111111-1111-4111-8111-111111111111';
const other = '22222222-2222-4222-8222-222222222222';
const wallet = 'So11111111111111111111111111111111111111112';
const root = 'https://fomo.family';
const snapshot = {status: 'authenticated', fomoUserId: id, wallets: {solana: {address: wallet}}, privateTestValue: 'must-not-leave-page'};
function fixture({origin = root, states = [snapshot], profileID = id, resourceOrigin = root, source = 'sha3', status = 200} = {}) {
  let reads = 0;
  const requests = [];
  const performance = {getEntriesByType: () => [source, 'frameFetch'].map(name => ({name: `${resourceOrigin}/assets/${name}-v2-publicHash.js`}))};
  const loadModule = async url => {
    assert.equal(new URL(url).origin, root);
    if (url.includes('frameFetch-')) return {f: async (url, options) => {
      requests.push({url, method: options.method});
      return {ok: status === 200, json: async () => ({success: true, responseObject: {id: profileID, userHandle: 'example', address: wallet, unrelatedPrivateField: 'ignored'}})};
    }};
    return {opaqueExport: {getState: () => ({[source === 'sha3' ? 'session' : 'snapshot']: states[Math.min(reads++, states.length - 1)]})},
      signTransaction: () => {throw new Error('must never sign');}, getAccessToken: () => {throw new Error('must never extract tokens');}};
  };
  return {execute: () => run({origin}, performance, loadModule), requests};
}
test('only official Fomo pages and their loaded modules are read', async () => {
  for (const options of [{origin: 'https://fomo.family.evil.example'}, {resourceOrigin: 'https://evil.example'}]) {
    const f = fixture(options);
    assert.deepEqual(await f.execute(), {state: 'anonymous'});
    assert.deepEqual(f.requests, []);
  }
});
test('a browser session is required before a profile can be connected', async () => {
  const f = fixture({states: [{status: 'anonymous'}]});
  assert.deepEqual(await f.execute(), {state: 'anonymous'});
  assert.deepEqual(f.requests, []);
});
test('reads the authenticated account and returns only public identity fields', async () => {
  for (const source of ['sha3', 'client']) {
    const f = fixture({source});
    assert.deepEqual(await f.execute(), {state: 'connected', expectedID: id, id, username: 'example', wallet, sessionWallet: wallet});
    assert.deepEqual(f.requests, [{url: `/v2/users/${id}`, method: 'GET'}]);
  }
});
test('an account change during the read discards the previous profile', async () => {
  const f = fixture({states: [snapshot, {...snapshot, fomoUserId: other}]});
  assert.deepEqual(await f.execute(), {state: 'unavailable'});
});
test('a mismatched profile or failed request cannot mark a connection successful', async () => {
  for (const options of [{profileID: other}, {status: 401}]) {
    assert.deepEqual(await fixture(options).execute(), {state: 'unavailable'});
  }
});

const legacyIdentity = {status: 'authenticated', privyDid: 'did:privy:synthetic-account', wallets: {solana: {address: wallet}}};
function legacyFixture({cachedWallet = wallet, changed = false} = {}) {
  let checks = 0;
  const requests = [];
  const urls = ['client', 'queryClient', 'fomoFetch'].map(name => `${root}/assets/${name}-v2-publicHash.js`);
  const modules = {
    client: {opaqueExport: {getState: () => ({snapshot: changed && checks++ > 0 ? {...legacyIdentity, privyDid: 'did:privy:other'} : legacyIdentity})}},
    queryClient: {cache: {getQueryData: key => {
      assert.deepEqual(key, ['account', 'v3', legacyIdentity.privyDid]);
      return {id, address: cachedWallet};
    }}},
    fomoFetch: {f: async (url, options) => {
      requests.push({url, method: options.method});
      return {success: true, responseObject: {id, userHandle: 'example', address: wallet}};
    }},
  };
  return {requests, execute: () => run({origin: root}, {getEntriesByType: () => urls.map(name => ({name}))},
    async url => modules[new URL(url).pathname.split('/').at(-1).split('-v2-')[0]])};
}
test('legacy Fomo sessions bind the cached account to the signed-in wallet and only GET the profile', async () => {
  const f = legacyFixture();
  assert.deepEqual(await f.execute(), {state: 'connected', expectedID: id, id, username: 'example', wallet, sessionWallet: wallet});
  assert.deepEqual(f.requests, [{url: `/v2/users/${id}`, method: 'GET'}]);
});
test('legacy account-cache mismatches never connect another profile', async () => {
  const f = legacyFixture({cachedWallet: 'another-wallet'});
  assert.deepEqual(await f.execute(), {state: 'unavailable'});
  assert.deepEqual(f.requests, []);
});
test('legacy session changes discard the completed profile read', async () => {
  assert.deepEqual(await legacyFixture({changed: true}).execute(), {state: 'unavailable'});
});
