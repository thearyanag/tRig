/// Runs in the official Fomo page. Reads its authenticated account state and
/// existing account cache, then uses its read-only profile helper. Only public
/// identity fields return to Swift; credentials and signing methods stay in WebKit.
enum FomoProfileBridge {
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
    if (!fetchURL) return {state: "loading"};
    const api = await import(fetchURL);
    if (typeof api.f !== "function") return {state: "unavailable"};
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), 15000);
    try {
      const result = await api.f("/v2/users/" + id, {method: "GET", signal: controller.signal});
      const body = isFrame ? (result.ok ? await result.json() : null) : result;
      const user = body?.responseObject;
      if (body?.success !== true || user?.id !== id) return {state: "unavailable"};
      const latestState = identityStore.getState();
      const latest = latestState?.snapshot ?? latestState?.session;
      if (latest?.status !== "authenticated" || (latest.fomoUserId ?? latest.privyDid) !== sessionIdentity)
        return {state: "unavailable"};
      return {state: "connected", expectedID: id, id: user.id,
        username: typeof user.userHandle === "string" ? user.userHandle : null,
        wallet: user.address,
        sessionWallet: latest.wallets?.solana?.address ?? null};
    } finally { clearTimeout(timer); }
    """#
}
