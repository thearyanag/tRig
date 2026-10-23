import { defineConfig, type Plugin } from 'vite';
import { createReadStream } from 'node:fs';
import { realpath, stat } from 'node:fs/promises';
import { resolve, sep, extname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { intervals, products, normalizeCoinbase, type Interval, type Product, type Snapshot } from './src/data';

const tvRoot = resolve(process.env.TRIG_TRADINGVIEW_LIBRARY_PATH || fileURLToPath(new URL('../macos/vendor/tradingview/charting_library', import.meta.url)));
function localServices(): Plugin {
  const cache = new Map<string, { until: number; snapshot: Snapshot }>();
  const pending = new Map<string, Promise<Snapshot>>();
  let cooldownUntil = 0;
  return { name: 'local-chart-services', configureServer(server) {
    server.middlewares.use(async (req, res, next) => {
      const url = new URL(req.url || '/', 'http://localhost');
      if (url.pathname === '/api/candles') {
        res.setHeader('Content-Type', 'application/json');
        res.setHeader('Cache-Control', 'no-store');
        if (req.method !== 'GET') { res.statusCode = 405; res.end(JSON.stringify({ error: 'GET only' })); return; }
        const product = url.searchParams.get('product') as Product;
        const interval = url.searchParams.get('interval') as Interval;
        if (!products.includes(product) || !Object.hasOwn(intervals, interval)) {
          res.statusCode = 400; res.end(JSON.stringify({ error: 'Choose a supported market and interval.' })); return;
        }
        const key = `${product}:${interval}`;
        try {
          const saved = cache.get(key);
          if (saved && saved.until > Date.now()) { res.end(JSON.stringify(saved.snapshot)); return; }
          if (cooldownUntil > Date.now()) { res.statusCode = 429; res.setHeader('Retry-After', Math.ceil((cooldownUntil - Date.now()) / 1000)); throw new Error('Coinbase rate limit. Please wait a minute before reloading.'); }
          let request = pending.get(key);
          if (!request) {
            request = (async () => {
              const response = await fetch(`https://api.exchange.coinbase.com/products/${product}/candles?granularity=${intervals[interval]}`, { signal: AbortSignal.timeout(15000), headers: { Accept: 'application/json' } });
              if (response.status === 429) {
                cooldownUntil = Date.now() + 60000;
                throw new Error('Coinbase rate limit. Please wait a minute before reloading.');
              }
              if (!response.ok) throw new Error(`Coinbase returned HTTP ${response.status}. Try again or select synthetic data.`);
              const snapshot = { bars: normalizeCoinbase(await response.json()), product, interval, source: 'Coinbase Exchange snapshot', capturedAt: new Date().toISOString() };
              cache.set(key, { until: Date.now() + 60000, snapshot });
              return snapshot;
            })().finally(() => pending.delete(key));
            pending.set(key, request);
          }
          res.end(JSON.stringify(await request));
        } catch (error) {
          if (res.statusCode === 200) res.statusCode = 502;
          res.end(JSON.stringify({ error: error instanceof Error ? error.message : 'Could not load market data.' }));
        }
        return;
      }
      if (!url.pathname.startsWith('/charting_library/')) { next(); return; }
      if (!['GET', 'HEAD'].includes(req.method || '')) { res.statusCode = 405; res.end(); return; }
      // Serve only the authorized local library, never copy it into public/dist.
      try {
        const root = await realpath(tvRoot);
        const path = await realpath(resolve(root, decodeURIComponent(url.pathname.slice('/charting_library/'.length))));
        if (!path.startsWith(root + sep) || !(await stat(path)).isFile()) throw new Error('Not a library file');
        const types: Record<string, string> = { '.js': 'text/javascript', '.css': 'text/css', '.html': 'text/html', '.json': 'application/json', '.svg': 'image/svg+xml', '.png': 'image/png', '.woff': 'font/woff', '.woff2': 'font/woff2' };
        res.setHeader('Content-Type', types[extname(path)] || 'application/octet-stream');
        res.setHeader('Cache-Control', 'private, max-age=3600');
        if (req.method === 'HEAD') { res.end(); return; }
        createReadStream(path).on('error', () => res.destroy()).pipe(res);
      } catch { res.statusCode = 404; res.end('Local TradingView library unavailable. See README.'); }
    });
  } };
}
export default defineConfig({ plugins: [localServices()], server: { host: '127.0.0.1', port: 5174, strictPort: true } });
