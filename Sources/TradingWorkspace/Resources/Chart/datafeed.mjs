export const resolutions = ['1', '5', '15', '60', '240', '720', '1D'];
const seconds = { '1': 60, '5': 300, '15': 900, '60': 3600, '240': 14400, '720': 43200, '1D': 86400 };

/** Vela provider over tRig's account-free, loopback market-data service. */
export function createMarketFeed({ asset, report, currentResolution, fetcher = fetch,
  hidden = () => document.hidden, now = Date.now, schedule = setInterval, cancel = clearInterval }) {
  const tickerID = asset.ticker || asset.mint;
  let disposed = false;
  let active = true;
  let lastQuoteFetch = 0;
  const historyTimes = new Map();
  const historyStarts = new Map();
  const controllers = new Set();
  const subscriptions = new Set();
  const relevant = resolution => !disposed && currentResolution() === resolution;
  function validate(ticker, resolution) {
    if (ticker !== tickerID) throw new Error('Open assets through native search');
    if (!resolutions.includes(resolution)) throw new Error('Unsupported chart interval');
  }
  async function request(resolution, limit, before) {
    if (disposed) throw new Error('Chart closed');
    const controller = new AbortController(); controllers.add(controller);
    const timeout = setTimeout(() => controller.abort(), 90000);
    const params = new URLSearchParams({
      resolution, limit: String(limit), mint: asset.mint, pool: asset.pool, chain: asset.chain
    });
    if (before !== undefined) params.set('before', String(before));
    try {
      const response = await fetcher(`/api/chart/bars?${params}`, { signal: controller.signal, cache: 'no-store' });
      const payload = await response.json();
      if (!response.ok) throw new Error(payload.error || `Chart request failed (${response.status})`);
      if (payload.mint !== asset.mint || payload.pool !== asset.pool || (payload.chain ?? 'solana') !== asset.chain) {
        throw new Error('Chart asset identity mismatch');
      }
      if (!Array.isArray(payload.bars) || !Number.isFinite(payload.fetched_at)) throw new Error('Invalid candle response');
      let lastTime = -Infinity;
      for (const bar of payload.bars) {
        if (!['time','open','high','low','close','volume'].every(key => Number.isFinite(bar[key])) || bar.time <= lastTime
          || bar.time <= 0 || bar.low < 0 || bar.low > Math.min(bar.open, bar.close) || bar.high < Math.max(bar.open, bar.close) || bar.volume < 0) {
          throw new Error('Invalid candle sequence');
        }
        lastTime = bar.time;
      }
      return payload;
    } finally { clearTimeout(timeout); controllers.delete(controller); }
  }
  function quote(payload, resolution) {
    const latest = payload.bars.at(-1);
    if (latest && relevant(resolution) && payload.fetched_at >= lastQuoteFetch) {
      lastQuoteFetch = payload.fetched_at;
      report('ready', 'Chart updated', { lastClose: latest.close, fetchedAt: payload.fetched_at, candleTime: latest.time });
    }
  }
  function failure(error, resolution) {
    if (relevant(resolution)) report('error', error.name === 'AbortError' ? 'Candle request timed out. Reload to retry.' : error.message);
  }
  const provider = {
    async listSymbols() { return [{ ticker: tickerID, description: `${asset.symbol} · ${asset.name}`, type: 'crypto' }]; },
    async getSymbolInfo(ticker) {
      validate(ticker, '1D');
      return { ticker, description: asset.name, timezone: 'Etc/UTC', pricescale: 10 ** asset.priceDigits };
    },
    async getBars(ticker, resolution, range = {}) {
      validate(ticker, resolution);
      const latest = range.to === undefined || range.to >= now() - 2000;
      const before = latest ? undefined : Math.max(1, Math.floor(range.to / 1000));
      // Share the validator's initial daily cache entry and load the full free history window.
      const limit = latest && resolution === '1D' ? 300 : Math.min(1000, Math.max(1, range.limit || 300));
      if (latest && relevant(resolution)) report('loading', 'Loading candles…');
      try {
        const payload = await request(resolution, limit, before);
        if (disposed) return [];
        const bars = payload.bars.filter(bar => (range.to === undefined || bar.time <= range.to)
          && (range.from === undefined || bar.time >= range.from));
        if (bars.length && latest) {
          historyTimes.set(resolution, Math.max(historyTimes.get(resolution) || 0, bars.at(-1).time));
        }
        const previous = historyStarts.get(resolution);
        const oldest = payload.bars[0]?.time;
        if (oldest !== undefined && (!previous || oldest < previous.time)) {
          historyStarts.set(resolution, { time: oldest, exhausted: payload.bars.length < limit });
        } else if (previous && before !== undefined && range.to <= previous.time
            && (oldest === undefined || oldest === previous.time)) {
          historyStarts.set(resolution, { ...previous, exhausted: true });
        }
        if (latest) {
          quote(payload, resolution);
          if (!bars.length && relevant(resolution)) report('empty', 'No candles available for this asset.');
        }
        return bars.map(bar => ({ ...bar }));
      } catch (error) { failure(error, resolution); throw error; }
    },
    subscribe(ticker, resolution, callback) {
      validate(ticker, resolution);
      const sub = { stopped: false, running: false, lastTime: historyTimes.get(resolution) || 0, timer: undefined, poll: undefined };
      sub.poll = async (limit = 2) => {
        if (disposed || sub.stopped || sub.running || !active || hidden()) return;
        sub.running = true;
        try {
          const payload = await request(resolution, limit);
          if (disposed || sub.stopped || !active || hidden()) return;
          sub.lastTime = Math.max(sub.lastTime, historyTimes.get(resolution) || 0);
          for (const bar of payload.bars) {
            if (bar.time >= sub.lastTime) { callback({ ...bar }); sub.lastTime = bar.time; }
          }
          quote(payload, resolution);
        } catch (error) { if (!sub.stopped && active) failure(error, resolution); }
        finally { sub.running = false; }
      };
      sub.timer = schedule(() => sub.poll(), 30000);
      subscriptions.add(sub);
      return () => { sub.stopped = true; cancel(sub.timer); subscriptions.delete(sub); };
    },
  };
  return {
    provider,
    shouldLoadOlder(resolution, visibleFrom) {
      const oldest = historyStarts.get(resolution);
      return Boolean(active && !disposed && oldest && !oldest.exhausted
        && visibleFrom <= oldest.time + 20 * seconds[resolution] * 1000);
    },
    setActive(value) {
      const resumed = value && !active; active = value;
      // Catch up after sleep/background without replacing the chart or losing drawings.
      if (resumed && !disposed) for (const sub of subscriptions) void sub.poll(300);
    },
    dispose() {
      disposed = true;
      for (const sub of subscriptions) { sub.stopped = true; cancel(sub.timer); }
      subscriptions.clear(); for (const controller of controllers) controller.abort();
    },
  };
}
