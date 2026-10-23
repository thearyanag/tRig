import { VelaWorkspace } from '@luxalgo/vela/workspace';
import { registerRendererDefaults } from '@luxalgo/vela';
import { createMarketFeed, resolutions } from './datafeed.mjs';

const settings = new URLSearchParams(location.search);
const referencePrice = Number(settings.get('price'));
const asset = {
  mint: settings.get('mint'), pool: settings.get('pool'),
  symbol: settings.get('symbol') || 'Asset', name: settings.get('name') || 'Asset',
  priceDigits: referencePrice > 0 ? Math.min(12, Math.max(2, 4 - Math.floor(Math.log10(referencePrice)))) : 6,
};
// This provider is scoped to one immutable mint/pool; the ticker is display-only.
asset.ticker = asset.symbol.replace(/[^a-zA-Z0-9._-]/g, '').slice(0, 24) || 'ASSET';
const theme = settings.get('theme') === 'light' ? 'light' : 'dark';
document.documentElement.classList.toggle('light', theme === 'light');
document.title = `${asset.symbol} chart`;
const report = (phase, message, extra = {}) => window.webkit?.messageHandlers?.chartStatus?.postMessage({ phase, message, ...extra });
let workspace;
let disposed = false;
let appActive = true;
const feed = createMarketFeed({ asset, report, currentResolution: () => workspace?.chart.market.timeframe || '1D' });
function updateActivity() {
  const visible = appActive && !document.hidden;
  feed.setActive(visible);
  if (visible && workspace && !disposed) requestAnimationFrame(() => workspace?.chart.resize());
}
window.chartHost = {
  setActive(value) { appActive = value; updateActivity(); },
  dispose() {
    if (disposed) return;
    disposed = true; feed.dispose(); workspace?.destroy();
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
    layout: false, symbol: `gecko:${asset.ticker}`, timeframe: '1D', bars: 300,
    providers: { gecko: () => feed.provider }, live: true, theme, timezone: 'Etc/UTC',
    timeframes: resolutions, persist: false, layoutMode: 'desktop',
    // Native search owns identity. Range presets can select unsupported intervals,
    // so the topbar exposes only the service's explicit timeframe list.
    topbar: { left: ['indicators', 'undo-redo'], right: ['panels', 'screenshot'] },
    bottombar: false, drawings: true, volume: true,
  });
  workspace.chart.on('data:unresolved', () => report('error', 'Choose an asset through native search.'));
  workspace.chart.on('indicator:error', ({ error }) => report('error', `Indicator: ${error.message}`));
  document.getElementById('interval').addEventListener('change', event => {
    workspace.context().setTimeframe(event.target.value);
  });
  document.getElementById('style').addEventListener('change', event => {
    workspace.context().setPriceStyle(event.target.value);
  });
  updateActivity();
  workspace.chart.ready().then(() => { if (!disposed) workspace.chart.resize(); }).catch(error => { if (!disposed) report('error', error.message); });
} catch (error) {
  report('error', `Chart could not start: ${error.message}`);
  const text = document.createElement('p'); text.textContent = error.message;
  document.getElementById('chart').replaceChildren(text);
}
