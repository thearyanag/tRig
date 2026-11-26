/// Scoped, read-only portfolio reads in Fomo's own authenticated page. No credential
/// or social-content fields are returned to Swift.
enum FomoPortfolioBridge {
  static let read = #"""
    if (location.origin !== "https://fomo.family") return {state: "anonymous"};
    const resources = performance.getEntriesByType("resource").map(item => item.name);
    function moduleURL(prefix) {
      return resources.find(value => {
        const url = new URL(value);
        return url.origin === location.origin &&
          new RegExp("^/assets/" + prefix + "-v2-[A-Za-z0-9_-]+\\.js$").test(url.pathname);
      });
    }
    const stateURLs = [moduleURL("sha3"), moduleURL("client")].filter(Boolean);
    let identity;
    let identityStore;
    for (const source of stateURLs) {
      const module = await import(source);
      for (const exported of Object.values(module)) {
        if (typeof exported?.getState !== "function") continue;
        const state = exported.getState();
        const candidate = state?.snapshot ?? state?.session;
        if (candidate?.status === "authenticated" && (candidate.fomoUserId || candidate.privyDid)) {
          identity = candidate; identityStore = exported; break;
        }
      }
      if (identity) break;
    }
    if (!identity) return {state: "anonymous"};
    let id = identity.fomoUserId;
    if (identity.wallets?.solana?.address !== expectedWallet) return {state: "accountChanged"};
    const sessionIdentity = identity.fomoUserId ?? identity.privyDid;
    const isFrame = Boolean(id);
    if (!isFrame) {
      const cacheURL = moduleURL("queryClient");
      if (!cacheURL) return {state: "loading"};
      const cacheModule = await import(cacheURL);
      const cache = Object.values(cacheModule).find(value => typeof value?.getQueryData === "function");
      const account = cache?.getQueryData(["account", "v3", identity.privyDid]);
      if (!account) return {state: "loading"};
      if (account.address !== expectedWallet) return {state: "accountChanged"};
      id = account.id;
    }
    if (typeof id !== "string" || !/^[0-9a-f-]{36}$/i.test(id)) return {state: "unavailable"};
    const fetchURL = moduleURL(isFrame ? "frameFetch" : "fomoFetch");
    if (!fetchURL) return {state: "loading"};
    const api = await import(fetchURL);
    if (typeof api.f !== "function") return {state: "readerChanged"};

    // Request these networks and exclude their EVM cash tokens from spot equity.
    // Solana USDC is the unified cash balance and is counted separately.
    const hyperliquid = "1337";
    const solanaUSDC = "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v";
    const networks = new Map([
      ["1", "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48"],     // Ethereum
      ["56", "0x8ac76a51cc950d9822d68b83fe1ad97b32cd580d"],    // BNB Chain
      ["143", "0x754704bc059f8c67012fed69bc8a327a5aafb603"],   // Monad
      [hyperliquid, null],
      ["4663", "0x5fc5360d0400a0fd4f2af552add042d716f1d168"],   // Robinhood Chain
      ["5042", "0x3600000000000000000000000000000000000000"],   // Arc
      ["8453", "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913"],   // Base
      ["99901", "0xb47c4c8f73f009cc0c0d3f92b388d13e293f0b65"],  // Elysium
      ["1399811149", null],                                  // Solana
    ]);
    const chainIDs = [...networks.keys()];
    const balancesChainHeader = chainIDs.join(",");
    const historyChainHeader = chainIDs.filter(chain => chain !== hyperliquid).join(",");
    const previous = window.__trigPortfolioRead;
    previous?.controller?.abort();
    const controllerState = {id: readID, controller: new AbortController()};
    window.__trigPortfolioRead = controllerState;
    async function get(path, chainHeader = historyChainHeader) {
      controllerState.controller.signal.throwIfAborted();
      const controller = new AbortController(), timer = setTimeout(() => controller.abort(), 25000);
      const cancel = () => controller.abort();
      controllerState.controller.signal.addEventListener("abort", cancel, {once:true});
      try {
        const result = await api.f(path, {
          method: "GET", headers: {"X-Supported-Chains": chainHeader}, signal: controller.signal
        });
        if (isFrame && !result?.ok) throw {status: result?.status};
        const body = isFrame ? await result.json() : result;
        if (body?.success !== true || body.statusCode !== 200) throw {status: body?.statusCode};
        return body.responseObject;
      } catch (error) {
        controllerState.controller.signal.throwIfAborted();
        if (controller.signal.aborted) throw {state: "timeout"};
        if (error instanceof SyntaxError) throw {state: "invalidResponse"};
        const status = error?.status ?? error?.statusCode;
        if (Number.isInteger(status) && status >= 400 && status <= 599)
          throw {state: "apiError", status};
        throw {state: "requestFailed"};
      } finally { clearTimeout(timer); controllerState.controller.signal.removeEventListener("abort", cancel); }
    }
    let balances;
    try { balances = await get("/v2/users/" + id + "/balances", balancesChainHeader); }
    catch (failure) { controllerState.controller.signal.throwIfAborted(); return failure; }
    if (!Array.isArray(balances?.balances)) return {state: "invalidResponse"};
    const seconds = {"1d":86400,"7d":604800,"30d":2592000};
    const now = Date.now(), start = now - (seconds[period] ?? 0) * 1000;
    const historyPath = period === "all"
      ? "/v2/userTokens/aggregatedSnapshot/interval?userId=" + id
      : "/v2/userTokens/aggregatedSnapshot?userId=" + id + "&timestamp=" + encodeURIComponent(new Date(start).toISOString()) + (period === "30d" ? "&interval=4" : "");
    let history = [], baseline = null;
    try { history = await get(historyPath); } catch { controllerState.controller.signal.throwIfAborted(); }
    if (period !== "all") {
      const snapshot = Math.floor(start / 3600000) * 3600;
      try { baseline = await get("/v2/userTokens/aggregatedSnapshotById?userId=" + id + "&snapshotId=" + snapshot + "&tradeType=both"); }
      catch { controllerState.controller.signal.throwIfAborted(); }
    }
    function pick(value, keys) {
      if (!value || typeof value !== "object") return null;
      return Object.fromEntries(keys.filter(key => value[key] !== undefined).map(key => [key,value[key]]));
    }
    const rows = balances.balances.slice(0,4000).map(row => {
      const token = row.tokenFilterResult?.token ?? {};
      const info = token.info ?? {};
      const network = row.userToken?.networkId ?? token.networkId;
      const address = row.balance?.tokenAddress ?? row.userToken?.tokenAddress;
      return {
        balance: pick(row.balance,["balance","shiftedBalance","address","tokenAddress"]),
        tokenFilterResult: {priceUSD: row.tokenFilterResult?.priceUSD,
          token: pick(token,["name","symbol","decimals","networkId"])},
        imageUrl: info.imageLargeUrl ?? info.imageSmallUrl ?? info.imageUrl ?? null,
        userToken: pick(row.userToken,["networkId","tokenAddress","averageEntryPriceUsd","currentCostBasisUsd","currentRealizedPnlUsd","humanAmountRemaining"]),
        activeTrade: pick(row.activeTrade,["humanTokenAmount","displayAvgEntryPriceUsd","avgEntryPrice","realizedPnlUsd"]),
        valuation: pick(row.valuation,["includeInEquity","useLivePrice","includeRealizedPnl","includeUnrealizedPnl"]),
        isCash: address === solanaUSDC,
        excludedFromEquity: typeof address === "string" &&
          networks.get(String(network)) === address.toLowerCase()
      };
    });
    const cleaned = {
      balances: rows, otherEquity: balances.otherEquity, otherPnlV2: balances.otherPnlV2,
      livePerpPnl: balances.livePerpPnl,
      hyperliquidPerps: balances.hyperliquidPerps ? {
        ...pick(balances.hyperliquidPerps,["quoteBalance"]),
        marginSummary: pick(balances.hyperliquidPerps.marginSummary,["accountValue"]),
        positions: (balances.hyperliquidPerps.positions ?? []).map(p => pick(p,["size","side","markPriceUsd"]))
      } : null
    };
    controllerState.controller.signal.throwIfAborted();
    const latestState = identityStore.getState(), latest = latestState?.snapshot ?? latestState?.session;
    if (latest?.status !== "authenticated" || (latest.fomoUserId ?? latest.privyDid) !== sessionIdentity || latest.wallets?.solana?.address !== expectedWallet)
      return {state: "accountChanged"};
    return JSON.stringify({
      evmWallet: latest.wallets?.evm?.address ?? null,
      data: {balances:cleaned, history:Array.isArray(history) ? history.map(p => pick(p,["snapshotId","equity","pnl"])) : [],
        baseline:pick(baseline,["pnl","equity","snapshotId"])}
    });
    """#
}
