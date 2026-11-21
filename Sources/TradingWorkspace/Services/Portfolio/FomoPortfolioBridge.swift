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
    if (identity.wallets?.solana?.address !== expectedWallet) throw new Error("Account changed");
    const sessionIdentity = identity.fomoUserId ?? identity.privyDid;
    const isFrame = Boolean(id);
    if (!isFrame) {
      const cacheURL = moduleURL("queryClient");
      if (!cacheURL) return {state: "loading"};
      const cacheModule = await import(cacheURL);
      const cache = Object.values(cacheModule).find(value => typeof value?.getQueryData === "function");
      const account = cache?.getQueryData(["account", "v3", identity.privyDid]);
      if (!account) return {state: "loading"};
      if (!identity.wallets?.solana?.address || account.address !== identity.wallets.solana.address)
        return {state: "unavailable"};
      id = account.id;
    }
    if (typeof id !== "string" || !/^[0-9a-f-]{36}$/i.test(id)) return {state: "unavailable"};
    const fetchURL = moduleURL(isFrame ? "frameFetch" : "fomoFetch");
    if (!fetchURL) throw new Error("Reader not ready");
    const api = await import(fetchURL);
    const chains = await import(moduleURL("chains"));
    if (typeof api.f !== "function" || typeof chains.k !== "function" || typeof chains.bB !== "function" || typeof chains.l !== "string")
      throw new Error("Portfolio reader needs an update");
    const previous = window.__trigPortfolioRead;
    previous?.controller?.abort();
    const controllerState = {id: readID, controller: new AbortController()};
    window.__trigPortfolioRead = controllerState;
    const warnings = [];
    async function get(path, headers = {}) {
      controllerState.controller.signal.throwIfAborted();
      const controller = new AbortController(), timer = setTimeout(() => controller.abort(), 25000);
      const cancel = () => controller.abort();
      controllerState.controller.signal.addEventListener("abort", cancel, {once:true});
      try {
        const result = await api.f(path, {method: "GET", headers, signal: controller.signal});
        const body = isFrame ? (result.ok ? await result.json() : null) : result;
        if (body?.success !== true || body.statusCode !== 200) throw new Error("Portfolio request failed");
        return body.responseObject;
      } finally { clearTimeout(timer); controllerState.controller.signal.removeEventListener("abort", cancel); }
    }
    const balances = await get("/v2/users/" + id + "/balances", {"X-Supported-Chains": chains.k(true)});
    if (!Array.isArray(balances?.balances)) throw new Error("Invalid balance response");
    const seconds = {"1d":86400,"7d":604800,"30d":2592000};
    const now = Date.now(), start = now - (seconds[period] ?? 0) * 1000;
    const historyPath = period === "all"
      ? "/v2/userTokens/aggregatedSnapshot/interval?userId=" + id
      : "/v2/userTokens/aggregatedSnapshot?userId=" + id + "&timestamp=" + encodeURIComponent(new Date(start).toISOString()) + (period === "30d" ? "&interval=4" : "");
    let history = [], baseline = null;
    try { history = await get(historyPath); } catch { controllerState.controller.signal.throwIfAborted(); warnings.push("Fomo's portfolio history could not refresh."); }
    if (period !== "all") {
      const snapshot = Math.floor(start / 3600000) * 3600;
      try { baseline = await get("/v2/userTokens/aggregatedSnapshotById?userId=" + id + "&snapshotId=" + snapshot + "&tradeType=both"); }
      catch { controllerState.controller.signal.throwIfAborted(); warnings.push("Fomo's P&L baseline is unavailable for this period."); }
    }
    function pick(value, keys) {
      if (!value || typeof value !== "object") return null;
      return Object.fromEntries(keys.filter(key => value[key] !== undefined).map(key => [key,value[key]]));
    }
    const rows = balances.balances.slice(0,4000).map(row => {
      const token = row.tokenFilterResult?.token ?? {};
      const info = token.info ?? {};
      return {
        balance: pick(row.balance,["balance","shiftedBalance","address","tokenAddress"]),
        tokenFilterResult: {priceUSD: row.tokenFilterResult?.priceUSD,
          token: pick(token,["name","symbol","decimals","networkId"])},
        imageUrl: info.imageLargeUrl ?? info.imageSmallUrl ?? info.imageUrl ?? null,
        userToken: pick(row.userToken,["networkId","tokenAddress","averageEntryPriceUsd","currentCostBasisUsd","currentRealizedPnlUsd","humanAmountRemaining"]),
        activeTrade: pick(row.activeTrade,["humanTokenAmount","displayAvgEntryPriceUsd","avgEntryPrice","realizedPnlUsd"]),
        valuation: pick(row.valuation,["includeInEquity","useLivePrice","includeRealizedPnl","includeUnrealizedPnl"]),
        isCash: row.balance?.tokenAddress === chains.l,
        excludedFromEquity: chains.bB(row.userToken?.networkId,row.balance?.tokenAddress)
      };
    });
    const cleaned = {
      balances: rows, otherEquity: balances.otherEquity, otherPnlV2: balances.otherPnlV2,
      livePerpPnl: balances.livePerpPnl,
      nativeEvmBalances: (balances.nativeEvmBalances ?? []).map(() => ({present:true})),
      hyperliquidPerps: balances.hyperliquidPerps ? {
        ...pick(balances.hyperliquidPerps,["quoteBalance"]),
        marginSummary: pick(balances.hyperliquidPerps.marginSummary,["accountValue"]),
        positions: (balances.hyperliquidPerps.positions ?? []).map(p => pick(p,["size","side","markPriceUsd"]))
      } : null
    };
    controllerState.controller.signal.throwIfAborted();
    const latestState = identityStore.getState(), latest = latestState?.snapshot ?? latestState?.session;
    if (latest?.status !== "authenticated" || (latest.fomoUserId ?? latest.privyDid) !== sessionIdentity || latest.wallets?.solana?.address !== expectedWallet)
      throw new Error("Session changed during read");
    return JSON.stringify({
      evmWallet: latest.wallets?.evm?.address ?? null,
      data: {balances:cleaned, history:Array.isArray(history) ? history.map(p => pick(p,["snapshotId","equity","pnl"])) : [],
        baseline:pick(baseline,["pnl","equity","snapshotId"]),warnings}
    });
    """#
}
