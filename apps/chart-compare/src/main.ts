import { VelaWorkspace } from '@luxalgo/vela/workspace';
import type { DataProvider } from '@luxalgo/vela';
import { SharedTape, syntheticSnapshot, historyPage, fingerprint, intervals, type Bar, type Snapshot, type Product, type Interval } from './data';
import './style.css';

// Minimal host-owned interface; proprietary TradingView code stays outside this app.
interface TVChart {
  setVisibleRange(range: { from: number; to: number }): Promise<void>;
  getVisibleRange(): { from: number; to: number };
}
interface TVWidget { onChartReady(callback: () => void): void; activeChart(): TVChart; remove(): void; }
declare global { interface Window { TradingView?: { widget: new (options: Record<string, unknown>) => TVWidget }; } }
const el = <T extends HTMLElement = HTMLElement>(id: string) => document.getElementById(id) as T;
const selected = (id: string) => el<HTMLSelectElement>(id).value;
const message = (error: unknown) => error instanceof Error ? error.message : String(error);
let snapshot: Snapshot | undefined;
let tape: SharedTape | undefined;
let vela: VelaWorkspace | undefined;
let tv: TVWidget | undefined;
let tvReady = false;
let velaReady = false;
let generation = 0;
let busy = false;
let light = false;
let replaying = false;
let timer: ReturnType<typeof setInterval> | undefined;
let request: AbortController | undefined;
let tvScript: Promise<void> | undefined;

function note(text: string) { el('action-status').textContent = text; }
async function withTimeout<T>(task: Promise<T>, label: string): Promise<T> {
  let timeout: ReturnType<typeof setTimeout> | undefined;
  try {
    return await Promise.race([task, new Promise<never>((_, reject) => {
      timeout = setTimeout(() => reject(new Error(`${label} timed out. Reload data to retry.`)), 20000);
    })]);
  } finally { clearTimeout(timeout); }
}
function showError(id: string, error: unknown) {
  const box = document.createElement('div'); box.className = 'error-box';
  const heading = document.createElement('strong'); heading.textContent = 'Chart could not load';
  const detail = document.createElement('p'); detail.textContent = message(error);
  box.append(heading, detail); el(id).replaceChildren(box);
}
function pause() { clearInterval(timer); timer = undefined; el('play').textContent = 'Play'; }
function updateControls() {
  for (const id of ['symbol', 'interval', 'source', 'reload', 'theme']) (el(id) as HTMLButtonElement).disabled = busy;
  for (const id of ['reset', 'export', 'replay']) el<HTMLButtonElement>(id).disabled = busy || !snapshot;
  for (const id of ['step', 'play', 'finish']) el<HTMLButtonElement>(id).disabled = busy || !replaying;
  if (tape && tape.cursor === tape.snapshot.bars.length) {
    el<HTMLButtonElement>('step').disabled = true; el<HTMLButtonElement>('play').disabled = true;
  }
  el<HTMLButtonElement>('match-vela').disabled = !tvReady || !velaReady || busy;
  el<HTMLButtonElement>('match-tv').disabled = !tvReady || !velaReady || busy;
  if (snapshot && tape) {
    el('replay-label').textContent = replaying
      ? `${tape.cursor.toLocaleString()} / ${snapshot.bars.length.toLocaleString()} candles revealed · ${new Date(snapshot.bars[tape.cursor - 1].time).toLocaleString()}`
      : 'Reveal the final 60 candles, one at a time.';
  }
}
function destroyCharts() {
  pause(); tape?.dispose(); vela?.destroy(); tv?.remove();
  vela = undefined; tv = undefined; velaReady = false; tvReady = false;
  el('vela-chart').replaceChildren(); el('tv-chart').replaceChildren();
}
function loadTV(): Promise<void> {
  if (window.TradingView) return Promise.resolve();
  if (!tvScript) tvScript = new Promise<void>((resolve, reject) => {
    const script = document.createElement('script');
    const timeout = setTimeout(() => { script.remove(); reject(new Error('TradingView library timed out. Reload data to retry.')); }, 15000);
    script.src = '/charting_library/charting_library.standalone.js';
    script.onload = () => { clearTimeout(timeout); window.TradingView ? resolve() : reject(new Error('TradingView library did not initialize.')); };
    script.onerror = () => { clearTimeout(timeout); script.remove(); reject(new Error('Place your authorized charting_library in apps/macos/vendor/tradingview, or set TRIG_TRADINGVIEW_LIBRARY_PATH before running npm run dev.')); };
    document.head.append(script);
  }).catch(error => { tvScript = undefined; throw error; });
  return tvScript;
}
function makeProvider(current: SharedTape): DataProvider {
  const { product, interval } = current.snapshot;
  return {
    async getBars(ticker, tf, range) {
      if (ticker !== product || tf !== interval) throw new Error('Use the shared market and interval controls.');
      return current.bars.filter(bar => (range.from === undefined || bar.time >= range.from) && (range.to === undefined || bar.time <= range.to)).slice(-(range.limit || current.cursor));
    },
    async listSymbols() { return [{ ticker: product, description: product, type: 'crypto' }]; },
    async getSymbolInfo() { return { ticker: product, timezone: 'Etc/UTC', pricescale: 100 }; },
    subscribe(_ticker, _tf, callback) { return current.subscribe(callback); },
  };
}
function makeDatafeed(current: SharedTape) {
  const subscriptions = new Map<string, () => void>();
  const { product, interval } = current.snapshot;
  return {
    onReady(callback: (config: unknown) => void) { setTimeout(() => callback({ supported_resolutions: [interval], supports_time: false }), 0); },
    searchSymbols(_q: string, _e: string, _t: string, callback: (results: unknown[]) => void) { setTimeout(() => callback([]), 0); },
    resolveSymbol(_symbol: string, callback: (info: unknown) => void) {
      setTimeout(() => callback({ name: product, ticker: product, description: product, type: 'crypto', session: '24x7', timezone: 'Etc/UTC', exchange: 'tRig snapshot', listed_exchange: '', minmov: 1, pricescale: 100, has_intraday: true, has_daily: true, has_weekly_and_monthly: false, intraday_multipliers: ['15', '60'], daily_multipliers: ['1'], supported_resolutions: [interval], volume_precision: 2, data_status: 'streaming', format: 'price', visible_plots_set: 'ohlcv' }), 0);
    },
    getBars(_info: unknown, resolution: string, period: { to: number; countBack: number }, callback: (bars: Bar[], meta: { noData: boolean }) => void, onError: (error: string) => void) {
      setTimeout(() => {
        if (resolution !== interval) { onError('Use the shared interval control.'); return; }
        const bars = historyPage(current.bars, period.to * 1000, period.countBack || 300);
        callback(bars, { noData: bars.length === 0 });
      }, 0);
    },
    subscribeBars(_info: unknown, _resolution: string, callback: (bar: Bar) => void, id: string) {
      subscriptions.get(id)?.(); subscriptions.set(id, current.subscribe(callback));
    },
    unsubscribeBars(id: string) { subscriptions.get(id)?.(); subscriptions.delete(id); },
  };
}
function initialRange() {
  const bars = tape!.bars;
  return { from: bars[Math.max(0, bars.length - 100)].time, to: bars.at(-1)!.time + intervals[snapshot!.interval] * 2000 };
}
async function resetView() {
  if (!tape) return;
  const range = initialRange();
  if (velaReady) vela?.chart.setVisibleRange(range);
  if (tvReady) await tv?.activeChart().setVisibleRange({ from: range.from / 1000, to: range.to / 1000 });
}
async function render(cursor?: number) {
  if (!snapshot) return;
  const run = ++generation;
  busy = true; destroyCharts();
  const current = new SharedTape(snapshot, cursor); tape = current;
  updateControls();
  el('vela-status').textContent = 'Loading shared tape…'; el('tv-status').textContent = 'Loading shared tape…';
  const startVela = async () => {
    try {
      const workspace = new VelaWorkspace(el('vela-chart'), {
        layout: false, symbol: `comparison:${snapshot!.product}`, timeframe: snapshot!.interval,
        bars: current.cursor, live: true, theme: light ? 'light' : 'dark',
        providers: { comparison: () => makeProvider(current) }, persist: false,
        topbar: { left: ['style', 'indicators', 'undo-redo'], right: ['panels'] },
        bottombar: false, layoutMode: 'desktop', timezone: 'Etc/UTC', drawings: true, volume: true,
      });
      vela = workspace;
      await withTimeout(workspace.chart.ready(), 'Vela initialization');
      if (run !== generation) return;
      velaReady = true; workspace.chart.setVisibleRange(initialRange());
      el('vela-status').textContent = `${current.cursor.toLocaleString()} bars available`;
    } catch (error) { if (run === generation) { vela?.destroy(); vela = undefined; velaReady = false; showError('vela-chart', error); el('vela-status').textContent = 'Load failed'; } }
  };
  const startTV = async () => {
    try {
      await loadTV(); if (run !== generation) return;
      const widget = new window.TradingView!.widget({
        container: 'tv-chart', library_path: '/charting_library/', autosize: true,
        symbol: snapshot!.product, interval: snapshot!.interval, datafeed: makeDatafeed(current),
        locale: 'en', timezone: 'Etc/UTC', theme: light ? 'Light' : 'Dark',
        enabled_features: ['iframe_loading_same_origin'],
        disabled_features: ['header_symbol_search', 'header_quick_search', 'symbol_search_hot_key', 'header_compare', 'header_resolutions', 'header_saveload', 'header_screenshot', 'timeframes_toolbar', 'use_localstorage_for_settings'],
        overrides: { 'paneProperties.backgroundType': 'solid', 'paneProperties.background': light ? '#ffffff' : '#101722', 'paneProperties.vertGridProperties.color': light ? '#e7ecf2' : '#243145', 'paneProperties.horzGridProperties.color': light ? '#e7ecf2' : '#243145' },
        loading_screen: { backgroundColor: light ? '#ffffff' : '#101722' },
      });
      tv = widget;
      await new Promise<void>((resolve, reject) => {
        const timeout = setTimeout(() => reject(new Error('TradingView initialization timed out. Reload data to retry.')), 20000);
        widget.onChartReady(() => { clearTimeout(timeout); resolve(); });
      });
      if (run !== generation) return;
      tvReady = true;
      const range = initialRange();
      await widget.activeChart().setVisibleRange({ from: range.from / 1000, to: range.to / 1000 });
      el('tv-status').textContent = `${current.cursor.toLocaleString()} bars available`;
    } catch (error) { if (run === generation) { tv?.remove(); tv = undefined; tvReady = false; showError('tv-chart', error); el('tv-status').textContent = 'Load failed'; } }
  };
  await Promise.all([startVela(), startTV()]);
  if (run === generation) { busy = false; updateControls(); }
}
async function loadData() {
  request?.abort(); const controller = new AbortController(); request = controller;
  const run = ++generation;
  busy = true; replaying = false; destroyCharts(); snapshot = undefined; tape = undefined; updateControls();
  el('vela-status').textContent = 'Waiting for data…'; el('tv-status').textContent = 'Waiting for data…';
  el('status').textContent = 'Loading one shared candle snapshot…'; el('fingerprint').textContent = '';
  el('status').parentElement!.dataset.error = 'false'; note('');
  const product = selected('symbol') as Product;
  const interval = selected('interval') as Interval;
  try {
    let data: Snapshot;
    if (selected('source') === 'synthetic') data = syntheticSnapshot(product, interval);
    else {
      const response = await fetch(`/api/candles?${new URLSearchParams({ product, interval })}`, { signal: controller.signal });
      const body = await response.json();
      if (!response.ok) throw new Error(body.error || 'Could not load market data.');
      data = body;
    }
    if (controller.signal.aborted || run !== generation) return;
    const hash = await fingerprint(data.bars);
    if (controller.signal.aborted || run !== generation) return;
    snapshot = data;
    el('status').textContent = `${data.source} · ${data.bars.length.toLocaleString()} candles · ${product} · ${selected('source') === 'market' ? 'captured ' + new Date(data.capturedAt).toLocaleTimeString() : 'generated prices, not market history'}`;
    el('fingerprint').textContent = `Shared data · SHA-256 ${hash}`;
    await render();
  } catch (error) {
    if (controller.signal.aborted || run !== generation) return;
    el('status').textContent = message(error); el('status').parentElement!.dataset.error = 'true';
    showError('vela-chart', 'No shared data loaded. Try Reload data, or select the synthetic stress fixture.');
    showError('tv-chart', 'No shared data loaded. Both charts wait for the same snapshot.');
    busy = false; updateControls();
  }
}
function step() {
  if (!tape || busy || !replaying) return;
  if (!tape.step() || tape.cursor === tape.snapshot.bars.length) pause();
  if (velaReady) el('vela-status').textContent = `${tape.cursor.toLocaleString()} bars available`;
  if (tvReady) el('tv-status').textContent = `${tape.cursor.toLocaleString()} bars available`;
  updateControls();
}
function action(work: () => Promise<unknown> | void) { Promise.resolve().then(work).catch(error => note(message(error))); }
for (const id of ['symbol', 'interval', 'source']) el(id).addEventListener('change', () => void loadData());
el('reload').onclick = () => void loadData();
el('reset').onclick = () => action(resetView);
el('theme').onclick = () => action(async () => {
  light = !light; document.body.classList.toggle('light', light);
  el('theme').textContent = light ? 'Dark theme' : 'Light theme';
  el('theme').setAttribute('aria-label', `Switch to ${light ? 'dark' : 'light'} theme`);
  await render(tape?.cursor);
});
el('match-vela').onclick = () => action(async () => {
  const range = vela?.chart.getVisibleRange();
  if (range && tvReady) { await tv!.activeChart().setVisibleRange({ from: range.from / 1000, to: range.to / 1000 }); note('TradingView now uses Vela’s visible time range.'); }
});
el('match-tv').onclick = () => action(() => {
  if (tvReady && velaReady) { const range = tv!.activeChart().getVisibleRange(); vela!.chart.setVisibleRange({ from: range.from * 1000, to: range.to * 1000 }); note('Vela now uses TradingView’s visible time range.'); }
});
document.querySelectorAll<HTMLButtonElement>('[data-layout]').forEach(button => button.onclick = () => {
  el('charts').dataset.layout = button.dataset.layout;
  document.querySelectorAll('[data-layout][aria-pressed]').forEach(b => b.setAttribute('aria-pressed', String(b === button)));
  requestAnimationFrame(() => { vela?.chart.resize(); window.dispatchEvent(new Event('resize')); });
});
el('replay').onclick = () => action(async () => { if (!snapshot) return; replaying = true; await render(Math.max(1, snapshot.bars.length - 60)); });
el('step').onclick = step;
el('play').onclick = () => {
  if (timer) pause();
  else { timer = setInterval(step, Number(selected('speed'))); el('play').textContent = 'Pause'; }
};
el('speed').onchange = () => { if (timer) { clearInterval(timer); timer = setInterval(step, Number(selected('speed'))); } };
el('finish').onclick = () => action(async () => { replaying = false; await render(); });
el('export').onclick = () => {
  if (!snapshot) return;
  const url = URL.createObjectURL(new Blob([JSON.stringify(snapshot, null, 2)], { type: 'application/json' }));
  const link = document.createElement('a'); link.href = url; link.download = `trig-${snapshot.product}-${snapshot.interval}.json`; link.click(); setTimeout(() => URL.revokeObjectURL(url), 1000);
  note('Exported the complete shared snapshot, including candles not yet revealed in replay.');
};
document.addEventListener('visibilitychange', () => { if (document.hidden) pause(); });
window.addEventListener('beforeunload', () => { request?.abort(); destroyCharts(); });
void loadData();
