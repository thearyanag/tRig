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
function fixture({legacy = false, changed = false, failure = '', period = '1d', origin = root} = {}) {
  const requests = [], window = {};
  let reads = 0;
  const identity = {status:'authenticated', wallets:{solana:{address:wallet}}, ...(legacy ? {privyDid:'did:privy:fixture'} : {fomoUserId:id})};
  const modules = {
    [legacy ? 'client' : 'sha3']: {state:{getState:() => ({session: reads++ && changed ? {...identity, wallets:{solana:{address:'changed'}}} : identity})}},
    queryClient:{cache:{getQueryData:() => ({id,address:wallet})}},
    chains:{k:full => {assert.equal(full,true); return 'solana,base';}, bB:() => false, l:'cash'},
  };
  modules[legacy ? 'fomoFetch' : 'frameFetch'] = {f:async (url, options) => {
    requests.push({url,options});
    assert.equal(options.method,'GET');
    assert.ok(options.signal instanceof AbortSignal);
    if (failure && url.includes(failure)) throw new Error('unavailable');
    let value;
    if (url.endsWith('/balances')) {
      assert.equal(options.headers['X-Supported-Chains'],'solana,base');
      value = {balances:[{balance:{balance:'9007199254740993123',tokenAddress:wallet,address:wallet,secret:'private'},
        tokenFilterResult:{priceUSD:'2',token:{name:'Example',symbol:'EX',decimals:9,networkId:1399811149,info:{imageLargeUrl:'https://example.com/icon.png'}}},
        userToken:{networkId:1399811149,humanAmountRemaining:'9007199254.740993123',averageEntryPriceUsd:'1',privateThesis:'secret'},
        valuation:{includeInEquity:true},callout:'secret'}],otherEquity:'0',otherPnlV2:'3',livePerpPnl:'0',authToken:'secret'};
    } else if (url.includes('aggregatedSnapshotById')) value = {pnl:'1',equity:'8',private:'secret'};
    else value = [{snapshotId:1700000000,equity:'10',pnl:'2',private:'secret'}];
    const envelope = {success:true,statusCode:200,responseObject:value};
    return legacy ? envelope : {ok:true,json:async () => envelope};
  }};
  return {requests,window,execute:() => run({origin}, {getEntriesByType:() => Object.keys(modules).map(name => ({name:`${root}/assets/${name}-v2-fixture.js`}))},
    async url => modules[new URL(url).pathname.split('/').at(-1).split('-v2-')[0]],window,wallet,period,'read-1')};
}
test('portfolio uses authenticated GETs and returns only financial fields in both Fomo session formats', async () => {
  for (const legacy of [false,true]) {
    const f=fixture({legacy});
    const result=JSON.parse(await f.execute());
    assert.equal(f.requests.length,3);
    assert.equal(result.data.balances.balances[0].balance.balance,'9007199254740993123');
    assert.equal(result.data.baseline.pnl,'1');
    assert.ok(!JSON.stringify(result).includes('secret'));
    const baseline=new URL(f.requests[2].url,root);
    assert.equal(Number(baseline.searchParams.get('snapshotId')) % 3600,0);
    assert.equal(baseline.searchParams.get('tradeType'),'both');
  }
});
test('wrong origins do not issue portfolio requests', async () => {
  const f=fixture({origin:'https://fomo.family.evil.example'});
  assert.deepEqual(await f.execute(),{state:'anonymous'});
  assert.equal(f.requests.length,0);
});
test('account changes during portfolio reads discard the result', async () => {
  await assert.rejects(fixture({changed:true}).execute(),/Session changed/);
});
test('unavailable history preserves balances with a warning; balance failures reject the read', async () => {
  const result=JSON.parse(await fixture({failure:'aggregatedSnapshot'}).execute());
  assert.equal(result.data.balances.balances.length,1);
  assert.equal(result.data.history.length,0);
  assert.equal(result.data.baseline,null);
  assert.equal(result.data.warnings.length,2);
  await assert.rejects(fixture({failure:'/balances'}).execute());
});
test('all-time history uses the interval route and no period baseline', async () => {
  const f=fixture({period:'all'});
  await f.execute();
  assert.equal(f.requests.length,2);
  assert.ok(f.requests[1].url.includes('aggregatedSnapshot/interval?'));
});
