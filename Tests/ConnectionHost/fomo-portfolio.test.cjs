const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const source = fs.readFileSync(path.join(__dirname, '../../Sources/TradingWorkspace/Services/Portfolio/FomoPortfolioBridge.swift'), 'utf8');
const body = source.match(/static let read = #"""([\s\S]*?)"""#/)[1].replace(/await import\(/g, 'await loadModule(');
const AsyncFunction = Object.getPrototypeOf(async function() {}).constructor;
const run = new AsyncFunction('location', 'performance', 'loadModule', 'window', 'expectedWallet', 'period', 'readID', body);
const root = 'https://fomo.family', wallet = 'So11111111111111111111111111111111111111112';
const id = '11111111-1111-4111-8111-111111111111';
const solanaUSDC = 'EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v';
const baseUSDC = '0x833589fcd6edb6e08f4c7c32d4f71b54bda02913';
const balancesChainHeader = '1,56,143,1337,4663,5042,8453,99901,1399811149';
const historyChainHeader = '1,56,143,4663,5042,8453,99901,1399811149';
function fixture({legacy = false, changedReader = false, changed = false, signedOut = false,
  failure = '', status = 0, invalidBalances = false, extraBalances = [], period = '1d', origin = root} = {}) {
  const requests = [], window = {};
  let reads = 0;
  const identity = {status:signedOut ? 'anonymous' : 'authenticated', wallets:{solana:{address:wallet}}, ...(legacy ? {privyDid:'did:privy:fixture'} : {fomoUserId:id})};
  const modules = {
    [legacy ? 'client' : 'sha3']: {state:{getState:() => ({session: reads++ && changed ? {...identity, wallets:{solana:{address:'changed'}}} : identity})}},
    queryClient:{cache:{getQueryData:() => ({id,address:wallet})}},
  };
  modules[legacy ? 'fomoFetch' : 'frameFetch'] = {f:changedReader ? undefined : async (url, options) => {
    requests.push({url,options});
    assert.equal(options.method,'GET');
    assert.ok(options.signal instanceof AbortSignal);
    assert.equal(options.headers['X-Supported-Chains'],
      url.endsWith('/balances') ? balancesChainHeader : historyChainHeader);
    if (failure && url.includes(failure)) throw new Error('provider detail stays in WebKit');
    if (status && url.endsWith('/balances')) {
      if (legacy) throw Object.assign(new Error('private upstream error'), {status});
      return {ok:false,status};
    }
    let value;
    if (url.endsWith('/balances')) {
      value = {balances:invalidBalances ? null : [{balance:{balance:'9007199254740993123',tokenAddress:wallet,address:wallet,secret:'private'},
        tokenFilterResult:{priceUSD:'2',token:{name:'Example',symbol:'EX',decimals:9,networkId:1399811149,info:{imageLargeUrl:'https://example.com/icon.png'}}},
        userToken:{networkId:1399811149,humanAmountRemaining:'9007199254.740993123',averageEntryPriceUsd:'1',privateThesis:'secret'},
        valuation:{includeInEquity:true},callout:'secret'},
      {balance:{tokenAddress:solanaUSDC}, userToken:{networkId:1399811149}},
      {balance:{tokenAddress:baseUSDC}, userToken:{networkId:8453}}, ...extraBalances],
      otherEquity:'0',otherPnlV2:'3',livePerpPnl:'0',authToken:'secret'};
    } else if (url.includes('aggregatedSnapshotById')) value = {pnl:'1',equity:'8',private:'secret'};
    else value = [{snapshotId:1700000000,equity:'10',pnl:'2',private:'secret'}];
    const envelope = {success:true,statusCode:200,responseObject:value};
    return legacy ? envelope : {ok:true,json:async () => envelope};
  }};
  return {requests,window,execute:() => run({origin}, {getEntriesByType:() => Object.keys(modules).map(name => ({name:`${root}/assets/${name}-v2-fixture.js`}))},
    async url => modules[new URL(url).pathname.split('/').at(-1).split('-v2-')[0]],window,wallet,period,'read-1')};
}
test('portfolio uses the local chain config for both Fomo session formats without a chains module', async () => {
  for (const legacy of [false,true]) {
    const f=fixture({legacy});
    const result=JSON.parse(await f.execute());
    assert.equal(f.requests.length,3);
    assert.equal(result.data.balances.balances[0].balance.balance,'9007199254740993123');
    assert.equal(result.data.balances.balances[1].isCash,true);
    assert.equal(result.data.balances.balances[2].excludedFromEquity,true);
    assert.equal(result.data.baseline.pnl,'1');
    assert.ok(!JSON.stringify(result).includes('secret'));
    const baseline=new URL(f.requests[2].url,root);
    assert.equal(Number(baseline.searchParams.get('snapshotId')) % 3600,0);
    assert.equal(baseline.searchParams.get('tradeType'),'both');
  }
});
test('only the configured EVM cash token on its own chain is excluded from equity', async () => {
  const extraBalances = [
    {userToken:{tokenAddress:baseUSDC.toUpperCase(),networkId:'8453'}},
    {balance:{tokenAddress:baseUSDC},userToken:{networkId:56}},
    {balance:{tokenAddress:'0x754704bc059f8c67012fed69bc8a327a5aafb603'},userToken:{networkId:143}},
    {balance:{tokenAddress:'0x5fc5360d0400a0fd4f2af552add042d716f1d168'},userToken:{networkId:4663}},
  ];
  const result=JSON.parse(await fixture({extraBalances}).execute());
  assert.deepEqual(result.data.balances.balances.slice(3).map(row => row.excludedFromEquity),
    [true,false,true,true]);
});
test('wrong origins do not issue portfolio requests', async () => {
  const f=fixture({origin:'https://fomo.family.evil.example'});
  assert.deepEqual(await f.execute(),{state:'anonymous'});
  assert.equal(f.requests.length,0);
});
test('account changes during portfolio reads discard the result', async () => {
  assert.deepEqual(await fixture({changed:true}).execute(),{state:'accountChanged'});
});
test('unavailable history preserves balances; balance failures report an error', async () => {
  const result=JSON.parse(await fixture({failure:'aggregatedSnapshot'}).execute());
  assert.equal(result.data.balances.balances.length,3);
  assert.equal(result.data.history.length,0);
  assert.equal(result.data.baseline,null);
  assert.deepEqual(await fixture({failure:'/balances'}).execute(),{state:'requestFailed'});
});
test('distinguishes a signed-out session, changed reader, API errors, and unreadable balances', async () => {
  const signedOut = fixture({signedOut:true});
  assert.deepEqual(await signedOut.execute(),{state:'anonymous'});
  assert.equal(signedOut.requests.length,0);
  const broken = fixture({changedReader:true});
  assert.deepEqual(await broken.execute(),{state:'readerChanged'});
  assert.equal(broken.requests.length,0);
  for (const status of [401,403,429,503]) {
    for (const legacy of [false,true]) {
      assert.deepEqual(await fixture({legacy,status}).execute(),{state:'apiError',status});
    }
  }
  assert.deepEqual(await fixture({invalidBalances:true}).execute(),{state:'invalidResponse'});
});
test('all-time history uses the interval route and no period baseline', async () => {
  const f=fixture({period:'all'});
  await f.execute();
  assert.equal(f.requests.length,2);
  assert.ok(f.requests[1].url.includes('aggregatedSnapshot/interval?'));
});
