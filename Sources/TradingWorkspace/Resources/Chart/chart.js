import { VelaWorkspace } from '@luxalgo/vela/workspace';
import { registerRendererDefaults } from '@luxalgo/vela';
import { createMarketFeed, resolutions } from './datafeed.mjs';
import { createDraftLinesController } from './draft-lines.mjs';

const settings = new URLSearchParams(location.search);
const referencePrice = Number(settings.get('price'));
const initialBars = 300;
const asset = {
  mint: settings.get('mint'), pool: settings.get('pool'), chain: settings.get('chain') || 'solana',
  symbol: settings.get('symbol') || 'Asset', name: settings.get('name') || 'Asset',
  priceDigits: referencePrice > 0 ? Math.min(12, Math.max(2, 4 - Math.floor(Math.log10(referencePrice)))) : 6,
};
// This provider is scoped to one immutable mint/pool; the ticker is display-only.
asset.ticker = asset.symbol.replace(/[^a-zA-Z0-9._-]/g, '').slice(0, 24) || 'ASSET';
const venue = settings.get('network')?.toLowerCase().replace(/[^a-z0-9-]/g, '')
  || (asset.chain === 'solana' ? 'solana' : 'market');
const theme = settings.get('theme') === 'light' ? 'light' : 'dark';
document.documentElement.classList.toggle('light', theme === 'light');
document.title = `${asset.symbol} chart`;
const report = (phase, message, extra = {}) => window.webkit?.messageHandlers?.chartStatus?.postMessage({ phase, message, ...extra });
let workspace;
let draftLines;
let pendingDrafts = [];
let disposed = false;
let appActive = true;
let extending = false;
const feed = createMarketFeed({ asset, report, currentResolution: () => workspace?.chart.market.timeframe || '1D' });
function updateActivity() {
  const visible = appActive && !document.hidden;
  feed.setActive(visible);
  if (visible && workspace && !disposed) requestAnimationFrame(() => workspace?.chart.resize());
}
window.chartHost = {
  setActive(value) { appActive = value; updateActivity(); },
  setDraftLines(lines) {
    pendingDrafts = lines;
    draftLines?.set(lines);
  },
  dispose() {
    if (disposed) return;
    disposed = true;
    feed.dispose();
    draftLines?.dispose();
    workspace?.destroy();
    document.removeEventListener('visibilitychange', updateActivity);
  },
};
document.addEventListener('visibilitychange', updateActivity);
try {
  if (!asset.mint || !asset.pool) throw new Error('Choose an asset through native search.');
  // The native chart status bar supplies the visible, linked attribution.
  // Keep Vela's own mark when this host is opened without the native shell.
  if (window.webkit?.messageHandlers?.chartStatus) registerRendererDefaults({ attribution: false });
  workspace = new VelaWorkspace('#chart', {
    layout: false, symbol: `${venue}:${asset.ticker}`, timeframe: '1D', bars: initialBars,
    providers: { [venue]: () => feed.provider }, live: true, theme, timezone: 'Etc/UTC',
    timeframes: resolutions, persist: false, layoutMode: 'desktop',
    // Native search owns identity. Range presets can select unsupported intervals,
    // so the topbar exposes only the service's explicit timeframe list.
    topbar: { left: ['indicators', 'undo-redo'], right: ['panels', 'screenshot'] },
    bottombar: false, drawings: true, volume: true,
  });
  const chart = workspace.chart;
  draftLines = createDraftLinesController(chart, asset.mint, value => {
    window.webkit?.messageHandlers?.limitDraft?.postMessage(value);
  });
  draftLines.set(pendingDrafts);
  chart.on('load:end', () => draftLines.set(pendingDrafts));
  chart.on('data:unresolved', () => report('error', 'Choose an asset through native search.'));
  chart.on('indicator:error', ({ error }) => report('error', `Indicator: ${error.message}`));
  chart.on('viewport:changed', async ({ from }) => {
    const { timeframe, bars } = chart.market;
    if (disposed || !appActive || document.hidden || extending || !feed.shouldLoadOlder(timeframe, from)) return;
    extending = true;
    try {
      await chart.setMarket({ bars: (bars ?? initialBars) + initialBars });
      await chart.historyComplete();
    } catch (error) {
      if (!disposed) report('error', error.message);
    } finally {
      extending = false;
    }
  });
  document.getElementById('interval').addEventListener('change', event => {
    void chart.setMarket({ timeframe: event.target.value, bars: initialBars });
  });
  document.getElementById('style').addEventListener('change', event => {
    workspace.context().setPriceStyle(event.target.value);
  });
  updateActivity();
  chart.ready().then(() => {
    if (disposed) return;
    chart.resize();
    draftLines.set(pendingDrafts);
  }).catch(error => { if (!disposed) report('error', error.message); });
} catch (error) {
  report('error', `Chart could not start: ${error.message}`);
  const text = document.createElement('p'); text.textContent = error.message;
  document.getElementById('chart').replaceChildren(text);
}
