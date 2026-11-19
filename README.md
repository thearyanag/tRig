# Trading Workspace

A native SwiftUI macOS trading workspace. Requires Xcode with Swift 6.2,
Rust/Cargo, and macOS 14 or newer. Open `Package.swift` in Xcode to
edit the sources and use SwiftUI previews.

## Run

The interface uses bundled Allo v1.0.3 by Josh Puckett. Native text uses its
Regular, Medium, Semibold and Bold faces at the existing macOS type sizes;
TradingView uses the local variable webfont. Prices retain tabular digits.
Font files and the SIL Open Font License are in
`Sources/TradingWorkspace/Resources/Fonts/`. No system font installation or
runtime font download is required.

```sh
./script/build_and_run.sh
```

The script builds Swift and Rust, stages `dist/TradingWorkspace.app`, and launches
the app as a macOS bundle. The Codex Run action uses this same entrypoint.
Optional flags: `--verify`, `--debug`, `--logs`, `--telemetry`.

## Structure

- `Sources/TradingWorkspace/App`: scenes and menu commands.
- `Sources/TradingWorkspace/Models`: local value models.
- `Sources/TradingWorkspace/Components`: reusable native UI components.
- `Sources/TradingWorkspace/Views`: trading shell and component gallery.
- `Sources/TradingWorkspace/Services`: Rust sidecar lifecycle and local discovery client.
- `Sources/TradingWorkspace/Stores`: shared selection and persisted watchlist.
- `Sources/TradingWorkspace/Resources/Chart`: TradingView HTML/JavaScript host.
- `backend/trading-data`: local Rust candle service and provider cache.
- `vendor/tradingview/charting_library`: Advanced Charts v30.3.0 assets.

TradingView runs inside a WKWebView. The bundled Rust service discovers Solana
assets, chooses a liquid active chart route automatically, and fetches keyless
GeckoTerminal candles. Charts and the header use the selected asset's USD data.
Pool routing is internal and has no user-facing selector.

The dark terminal layout uses a full-width 54-point title strip, a full-height
left pane with asset identity, context and watchlist, separate 76-point identity
and 64-point market-stat rows, a dominant chart and a 280–320-point quote panel.
Token artwork comes from discovery metadata; Backpack artwork is also bundled.
24h volume refers to the selected chart source. High/low cells remain unavailable
until their data integration is added. Positions, Orders and
Activity share a compact bottom dock; its chevron collapses the dock to the tab
strip. These tabs currently show empty states because wallet connection and
execution are not available. Research and AI are outside this layout pass.

Use **Command-K** or the toolbar search button to search names/tickers or paste
a Solana contract address. Watchlisted matches are available immediately; press
Return or Search for remote matches. Use up/down arrows to choose a result and
Return to open it. Contract addresses distinguish duplicate tickers.

The header, chart and ticket follow one shared selection. Star/unstar an asset
to change the watchlist; right-click a watched row to remove it. Native list
navigation and **Command-Option-Up/Down** switch watched assets. Watchlist and
selection are saved locally under `workspace.watchlist.v1` in app preferences.
On reopening, market routing is refreshed before showing the chart. Live prices
are never restored as if fresh. Quote callbacks are checked against mint and
route so late responses cannot leak into another asset's view.

The main ticket uses real, read-only Jupiter Swap API V2 quotes for the selected
asset against USDC. Enter an input amount, choose Buy/Sell and slippage, then
press **Get quote**. Quote review has no signing or execution controls.
The ticket uses rectangular Buy/Sell controls, From/To token rows and a compact
price/minimum/impact/fee summary. Token menus switch the USDC/selected-asset pair;
changing sides clears the input amount. Reversing a matching fresh quote carries
its receive amount into the new input token; reversing without one clears it.
USD captions use the displayed reference market price and are approximate.
Market quotes are supported; the Limit label is unavailable.
**Workspace → Component Gallery** (`Shift-Command-G`) retains the old sample
ticket for component fixtures and includes a separate live Swap quotes tab.

## Account connections

Open the top-right Settings gear or press **Command-,**. **Connect Fomo** and
**Connect Pumpfun** open the official website in an in-app sign-in window.
After the signed-in profile is confirmed, the window closes and Settings shows
its username and wallet. Refresh rechecks the profile; Disconnect clears only
that service's app-local website data.

Connections use separate persistent WebKit stores, scoped to this app. Signing
in is required here even if an account is connected in the older tRig prototype.
No Chrome/Safari sessions or other app stores are read. Profile details stay in
memory and are rechecked from the saved website session when Settings opens.

Pumpfun uses the ported session-scoped profile reader, with its cookie sent only
to the fixed Pump API identity endpoint and redirects disabled. Fomo's reader supports both its
legacy Privy session and its newer first-party auth frame. It uses the loaded
official page's account state, the exact session-scoped account cache when needed,
and its GET profile helper. Only the confirmed username
and public wallet identity return to Swift; access tokens remain in WebKit.
The connection layer stays native alongside WebKit; credentials do not pass
through the Rust market-data service.

Fomo and Pumpfun login, connected usernames/wallets, and saved-session restoration
after restarting were verified in Settings during development. Profile refresh
was also exercised for Pumpfun. No trade or signing action was performed.

These are unofficial website integrations and can change upstream. A failed or
ambiguous read leaves the account disconnected. Connections do not enable swaps,
import balances, publish posts, or attach profiles to research/AI. The terminal's
trading-wallet empty states are independent of these account connections.

## Read-only Jupiter quotes

- Rust calls `GET https://api.jup.ag/swap/v2/order` without `taker`, `payer`,
  `receiver`, wallet addresses or a keypair. A non-null transaction response is
  rejected; no transaction payload is returned to the UI.
- Input is exact-in. Token decimals come from Jupiter's exact-mint Tokens V2
  lookup and cache for one day. Human amounts convert to u64 raw units using
  decimal strings, with excess precision/overflow rejected rather than rounded.
- The provider's net output, minimum receive, total fee rate/token, price impact
  in percentage points and venue names are shown. No sample fee is added.
- Requests are keyless and globally spaced at least 2.1 seconds apart, separate
  from GeckoTerminal's limiter. Identical quotes cache for 3 seconds; 429s respect
  Jupiter's reset header. Free keyless access is currently 30 requests/minute.
- A 20-second **app freshness window** controls quote review; this is not a price
  guarantee from Jupiter. Refresh stale quotes. Any amount, side, slippage or
  asset change clears the previous quote, and late replies are discarded.
- No wallet balance is displayed. Percentage/max sizing and fake balances are
  removed from the main ticket. Wallet-dependent network/rent costs are not
  estimated; the quote-only API's zero wallet-fee fields are not presented as free gas.
- Local endpoint: `GET /api/swap/quote?assetMint=...&side=buy&amount=100&slippageBps=50`.
  Unknown wallet fields are rejected. There is no swap build, signing or execute endpoint.

## Chart data and lifecycle

- Intervals: 1m, 5m, 15m, 1h, 4h, 12h, 1D.
- Latest bars refresh every 30 seconds while active/visible.
- Shared provider gate spaces all discovery and candle requests at least 7 seconds apart.
- Searches cache for 60 seconds; exact-address routing caches for five minutes.
- Latest results cache for 25 seconds; historical pages for one hour.
- History is conservatively capped at 180 days within the free provider window.
  Empty older pages end pagination; provider/network failures remain errors.
- A 429 response imposes a one-minute cooldown. The native reload action retries.
- Rust listens only on loopback on an ephemeral port. The app owns its process;
  a parent-process check also prevents orphaned services after the app exits.
- All library and chart host assets are bundled in the generated `.app`.

## Checks

```sh
swift test
cargo test --manifest-path backend/trading-data/Cargo.toml --locked
node --test Tests/ChartHost/chart-datafeed.test.cjs Tests/ConnectionHost/fomo-profile.test.cjs
```

Rust checks cover interval mapping, ranges, candle validation and history bounds.
Chart-host checks cover ordered refreshes, exclusive boundaries, errors and
background/unsubscribe behaviour. No wallet credentials or execution backend
are part of this integration.
