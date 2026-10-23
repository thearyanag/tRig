(() => {
  "use strict";
  const resolutions = ["1", "5", "15", "60", "240", "720", "1D"];
  const settings = new URLSearchParams(location.search);
  const mint = settings.get("mint") || "BPxxfRCXkUVhig4HS1Lh7kZqV6SPJhzfEk4x6fVBjPCy";
  const pool = settings.get("pool") || "6qz7THwQvcjF3HyDGLuKaLBUk6EyJKeZXZMWLAeiwfjd";
  const assetSymbol = settings.get("symbol") || "BP";
  const assetName = settings.get("name") || "Backpack";
  document.title = `${assetSymbol} chart`;
  const symbol = `${assetSymbol}/USD`;
  const referencePrice = Number(settings.get("price"));
  const priceDigits = referencePrice > 0 ? Math.min(12, Math.max(2, 4 - Math.floor(Math.log10(referencePrice)))) : 6;
  const subscriptions = new Map();
  const controllers = new Set();
  const historyTimes = new Map();
  let active = true;
  let disposed = false;
  let lastQuoteFetch = 0;
  const theme = new URLSearchParams(location.search).get("theme") === "light" ? "Light" : "Dark";
  document.documentElement.classList.toggle("light", theme === "Light");

  function report(phase, message, extra = {}) {
    window.webkit?.messageHandlers?.chartStatus?.postMessage({ phase, message, ...extra });
  }

  async function requestBars(resolution, limit, before) {
    const controller = new AbortController();
    controllers.add(controller);
    const timeout = setTimeout(() => controller.abort(), 90000);
    const params = new URLSearchParams({ resolution, limit: String(limit), mint, pool });
    if (before !== undefined) params.set("before", String(before));
    try {
      const response = await fetch(`/api/chart/bars?${params}`, { signal: controller.signal, cache: "no-store" });
      const payload = await response.json();
      if (!response.ok) throw new Error(payload.error || `Chart request failed (${response.status})`);
      if (payload.mint !== mint || payload.pool !== pool) throw new Error("Chart asset identity mismatch");
      if (!Array.isArray(payload.bars)) throw new Error("Candle response is invalid");
      return payload;
    } finally {
      clearTimeout(timeout);
      controllers.delete(controller);
    }
  }

  function publishQuote(payload, resolution) {
    const latest = payload.bars.at(-1);
    if (latest && payload.fetched_at >= lastQuoteFetch && widget?.activeChart().resolution() === resolution) {
      lastQuoteFetch = payload.fetched_at;
      report("ready", "GeckoTerminal", { lastClose: latest.close, fetchedAt: payload.fetched_at, candleTime: latest.time });
    }
  }

  const datafeed = {
    onReady(callback) {
      setTimeout(() => callback({ supported_resolutions: resolutions, supports_time: false }), 0);
    },
    searchSymbols(_query, _exchange, _type, callback) {
      setTimeout(() => callback([]), 0);
    },
    resolveSymbol(name, onResolve, onError) {
      if (name !== mint && name !== symbol) {
        setTimeout(() => onError("Open assets through native search"), 0); return;
      }
      setTimeout(() => onResolve({
        name: symbol, ticker: mint, description: assetName,
        type: "crypto", session: "24x7", timezone: "Etc/UTC", exchange: "",
        listed_exchange: "", minmov: 1, pricescale: 10 ** priceDigits,
        has_intraday: true, has_daily: true, has_weekly_and_monthly: false,
        intraday_multipliers: ["1", "5", "15", "60", "240", "720"], daily_multipliers: ["1"],
        supported_resolutions: resolutions, volume_precision: 2, data_status: "streaming",
        format: "price", visible_plots_set: "ohlcv"
      }), 0);
    },
    async getBars(_info, resolution, period, onHistory, onError) {
      try {
        report("loading", "Loading candles…");
        const limit = Math.min(1000, Math.max(300, period.countBack || 300));
        // Latest requests share a cache key. Historical requests preserve their right boundary.
        const seconds = { "1": 60, "5": 300, "15": 900, "60": 3600, "240": 14400, "720": 43200, "1D": 86400 }[resolution];
        const nearPresent = period.to >= Date.now() / 1000 - seconds * 2;
        const before = period.firstDataRequest && nearPresent ? undefined : Math.max(1, Math.floor(period.to) - 1);
        const payload = await requestBars(resolution, limit, before);
        if (disposed) return;
        const bars = payload.bars.filter(bar => bar.time < period.to * 1000);
        if (bars.length) historyTimes.set(resolution, Math.max(historyTimes.get(resolution) || 0, bars.at(-1).time));
        if (period.firstDataRequest && nearPresent) publishQuote(payload, resolution);
        onHistory(bars.map(bar => ({ ...bar })), { noData: bars.length === 0 });
        if (!bars.length && period.firstDataRequest) report("empty", "No candles available for this asset.");
        else if (!period.firstDataRequest) report("ready", "GeckoTerminal");
      } catch (error) {
        if (disposed) return;
        const message = error.name === "AbortError" ? "Candle request timed out. Try again." : error.message;
        report("error", message);
        onError(message);
      }
    },
    subscribeBars(_info, resolution, callback, id) {
      this.unsubscribeBars(id);
      const subscription = { stopped: false, running: false, lastTime: historyTimes.get(resolution) || 0, timer: null };
      async function poll() {
        if (subscription.stopped || subscription.running || disposed || !active || document.hidden) return;
        subscription.running = true;
        try {
          const payload = await requestBars(resolution, 2);
          if (subscription.stopped || disposed) return;
          subscription.lastTime = Math.max(subscription.lastTime, historyTimes.get(resolution) || 0);
          for (const bar of payload.bars) {
            if (bar.time >= subscription.lastTime) {
              callback({ ...bar });
              subscription.lastTime = bar.time;
            }
          }
          publishQuote(payload, resolution);
        } catch (error) {
          if (!subscription.stopped && !disposed) report("error", error.name === "AbortError" ? "Candle refresh timed out." : error.message);
        } finally {
          subscription.running = false;
        }
      }
      subscription.timer = setInterval(poll, 30000);
      subscriptions.set(id, subscription);
      // History provides the first price; wait one refresh interval before polling.
    },
    unsubscribeBars(id) {
      const subscription = subscriptions.get(id);
      if (subscription) { subscription.stopped = true; clearInterval(subscription.timer); subscriptions.delete(id); }
    }
  };

  window.chartHost = {
    setActive(value) {
      const resumed = value && !active;
      active = value;
      if (resumed && widget) widget.activeChart().resetData();
    },
    dispose() {
      disposed = true;
      for (const id of subscriptions.keys()) datafeed.unsubscribeBars(id);
      for (const controller of controllers) controller.abort();
      widget?.remove();
    }
  };

  let widget;
  try {
    widget = new TradingView.widget({
      container: "chart", library_path: "/charting_library/", autosize: true,
      symbol: mint, interval: "1D", datafeed, locale: "en", timezone: "Etc/UTC", theme,
      disabled_features: ["header_symbol_search", "header_quick_search", "symbol_search_hot_key", "header_compare", "header_screenshot", "header_saveload", "use_localstorage_for_settings"],
      overrides: {
        "paneProperties.backgroundType": "solid",
        "paneProperties.background": theme === "Dark" ? "#202020" : "#ffffff",
        "paneProperties.vertGridProperties.color": theme === "Dark" ? "#2c2c2e" : "#eeeeee",
        "paneProperties.horzGridProperties.color": theme === "Dark" ? "#2c2c2e" : "#eeeeee"
      },
      loading_screen: { backgroundColor: theme === "Dark" ? "#202020" : "#ffffff" }
    });
  } catch (error) { report("error", `Chart could not start: ${error.message}`); }
})();
