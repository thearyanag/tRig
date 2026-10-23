# tRig chart lab

Local side-by-side comparison of **Vela 0.9.0** and the authorized **TradingView Advanced Charts** library previously used by tRig. The macOS app now bundles Vela; this experiment preserves the original side-by-side comparison.

## Run

Requires Node.js 22.12+ and npm.

```sh
cd apps/chart-compare
npm ci
npm run dev
```

Open **http://127.0.0.1:5174**. The server binds to loopback only.

TradingView assets are served directly from `../macos/vendor/tradingview/charting_library/`. For another authorized local installation:

```sh
TRIG_TRADINGVIEW_LIBRARY_PATH=/absolute/path/to/charting_library npm run dev
```

The proprietary library is never copied into this project or its build output. If absent, the TradingView panel shows setup instructions and Vela remains usable. Vela's visible attribution is retained. No Pine scripting addon is installed.

## What to test

- Select SOL, BTC or ETH, with 15-minute, hourly or daily candles.
- Coinbase mode captures one public market snapshot shared by both charts. Requests are cached for 60 seconds, deduplicated and bounded by a timeout. There is no live polling or account connection.
- Synthetic mode generates 10,000 deterministic bars, explicitly labeled as generated prices. Use it for deep scrolling and heavier indicator workloads.
- Pan and zoom independently, then use either **Match** button to copy its visible time range to the other engine. **Reset view** returns both to the latest 100 bars.
- Use each library's own indicator, drawing and chart-style controls. These remain independent so you can compare their interactions.
- **Start replay** hides the final 60 candles. Step or play to deliver each next candle to both engines through their streaming callbacks. This reveals existing candles; it does not model intrabar ticks. **Show all** restores the complete snapshot.
- Try single-chart layouts and light/dark themes. Shared data, market, interval, theme and replay-reset changes recreate the charts, clearing drawings and studies.
- **Export candles** downloads the complete source snapshot. The displayed SHA-256 prefix identifies that exact OHLCV array, not the chart's rendering or visible range.

History is bounded to the captured dataset. Source changes never silently fall back to synthetic data. Neither panel opens a trading session or submits orders.

## Validation

```sh
npm test
npm run build
```

Tests cover provider tuple/time conversion, valid deterministic candles, history boundaries, replay visibility and mutation isolation between engines. The build checks TypeScript and bundles the frontend. **Use `npm run dev` to run the experiment:** `dist/` alone does not contain the local library or candle API middleware and is not a deployable comparison.
