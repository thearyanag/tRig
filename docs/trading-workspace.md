# Trading Workspace

A native SwiftUI macOS trading workspace. Requires Xcode with Swift 6.2,
Rust/Cargo, Node.js with npm, and macOS 14 or newer. Open `Package.swift` in Xcode to
edit the sources and use SwiftUI previews.

## Run

The interface uses bundled Allo v1.0.3 by Josh Puckett. Native text uses its
Regular, Medium, Semibold and Bold faces at the existing macOS type sizes;
The Vela chart host uses the local variable webfont. Prices retain tabular digits.
Font files and the SIL Open Font License are in
`Sources/TradingWorkspace/Resources/Fonts/`. No system font installation or
runtime font download is required.

```sh
./script/build_and_run.sh
```

The script builds Swift, Rust, and the pinned Vela chart host, stages `dist/TradingWorkspace.app`, and launches
the app as a macOS bundle. The Codex Run action uses this same entrypoint.
Optional flags: `--verify`, `--debug`, `--logs`, `--telemetry`.

## Structure

- `Sources/TradingWorkspace/App`: scenes and menu commands.
- `Sources/TradingWorkspace/Models`: local value models.
- `Sources/TradingWorkspace/Components`: reusable native UI components.
- `Sources/TradingWorkspace/Views`: trading shell and component gallery.
- `Sources/TradingWorkspace/Services`: local Rust connection and market discovery clients.
- `Sources/TradingWorkspace/Stores`: shared selection, persisted watchlist and app-wide portfolio state.
- `Sources/TradingWorkspace/Resources/Chart`: Vela HTML/JavaScript host.
- `chart-host`: Pinned chart dependencies and the app-bundle build.
- `backend/trading-data`: local Rust candle service and provider cache.

Vela 0.9.0 runs inside a WKWebView. Chart resources are served by the local Rust
service, which fetches USD candles for the selected Solana or EVM market. The
app bundle includes dependency licenses and Vela's NOTICE. The chart status bar
links to Vela for visible attribution. No proprietary chart download is required.
Pool routing is internal and has no user-facing selector. Provider names remain
internal; the asset header and chart footer show asset identity and update status.

The dark terminal layout uses a full-width 54-point title strip with its sidebar
toggle at the top left beside Workspace, a full-height
left pane with asset identity, context and watchlist, separate 76-point identity
and 64-point market-stat rows, a dominant chart and a 280–320-point quote panel.
Token artwork comes from discovery metadata; Backpack artwork is also bundled.
24h volume refers to the selected chart source. High and low appear when
the rolling range is available. Positions, Orders and
Activity share a compact bottom dock; its chevron collapses the dock to the tab
strip. Positions combines tRig wallet holdings with connected accounts,
with the selected asset first and expandable source rows. Orders tracks Jupiter
Trigger and Flash orders. Activity tracks wallet transfers, approvals, swaps,
bridges, and vault transactions.

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

The Solana ticket uses Jupiter Swap API V2 quotes for the selected
asset against USDC. Enter an input amount, choose Buy/Sell and slippage, then
press **Get quote**. A tRig wallet can review and confirm supported swaps.
The ticket uses rectangular Buy/Sell controls, From/To token rows and a compact
price/minimum/impact/fee summary. Token menus switch the USDC/selected-asset pair;
changing sides clears the input amount. Reversing a matching fresh quote carries
its receive amount into the new input token; reversing without one clears it.
USD captions use the displayed reference market price and are approximate.
**Cross-chain & advanced…** opens the route composer for Jupiter, Relay and
Definitive Flash. **Limit** adds a draggable draft-price line to Vela. **TP/SL**
gives each exit its own target price, quantity, and chart line. Solana conditionals
use Jupiter Trigger V2 with automatic wallet sign-in after unlock. The review
shows the deposit into the wallet’s Privy-managed vault. Use **Orders → Jupiter**
to track an order or review its withdrawal after cancellation or expiry.
Supported EVM conditionals use Flash. See [quote-providers.md](quote-providers.md)
for the quote API contracts.
**Workspace → Component Gallery** (`Shift-Command-G`) retains the old sample
ticket for component fixtures and includes a separate live Swap quotes tab.

## Account connections

For read-only Telegram discussion in Markets → Context, see
[Telegram discussion setup](telegram-discussion.md).

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
publish posts, or attach profiles to research/AI. Portfolio reads use these saved sessions. The terminal's
trading-wallet empty states are independent of these account connections.

## Portfolio

The top navigation opens a native Portfolio workspace using the existing Allo
font and terminal theme. **All accounts** is the default; Pumpfun and Fomo filter
the same refresh immediately. The sidebar retains the existing watchlist.

The screen has a three-column summary, native portfolio value chart with
24h/7d/30d/All periods, and a grouped holdings table. Search matches names,
symbols, contracts and chains. Hide small balances excludes priced assets below
$1; unknown values remain visible. Sort by value, symbol or P&L, expand source
breakdowns, or double-click a supported Solana holding to open Markets.
Usernames and wallet addresses remain confined to Settings.

- Pumpfun's native reader uses its scoped app-local cookie with redirects
  disabled. It reads the account summary, paginated open positions and value
  history from the fixed Pump API. Fomo uses its own loaded authenticated GET
  helper, supported-chain header, balances, equity history and P&L baseline.
- Swift returns sanitized financial fields to the loopback Rust endpoint
  `POST /api/portfolio/sync/complete`. Credentials and social/callout fields do not enter
  Rust. Validated financial snapshots are persisted by Rust in local SQLite.
- Rust preserves decimal quantities, groups by chain and mint, and retains
  account lots. Shared wallet balances are counted once. When shared wallets
  prevent safe combination of platform totals/history, All accounts shows a
  clearly marked priced-holdings subtotal; select a platform for its history.
- Platform totals can include non-spot exposure that is not expanded in the
  holdings table. Data notices explain this, missing prices, incomplete
  pagination and missing history/basis. Unknown values display a dash.
- Period P&L uses provider profit/baselines, never an equity delta that could
  confuse deposits with gains. Combined percentages are omitted without a
  common denominator. Fomo unrealized P&L follows its tracked quantities.
- Rust owns the SQLite repository, account revisions, refresh leases and a
  60-second freshness/backoff policy. An app-wide coordinator checks for due work
  while foregrounded; screen navigation uses the shared cache. Saved holdings
  load before session restoration after a restart. Failed reads preserve the
  previous successful data with notices; explicit disconnect removes its cache.
- Current holdings are shared with Markets independently of Portfolio filters
  and history periods. The native adapter retains authentication in WebKit.
  See [portfolio-data-layer.md](portfolio-data-layer.md) for ownership, schema,
  API contracts and validation evidence.

These website endpoints are unofficial and may change. Pumpfun, Fomo and All accounts were verified live with the saved app sessions,
including source breakdowns, search, sorting, small-balance filtering, refresh,
and 24h/7d/All history.

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
- The ticket shows the funding wallet’s available balance when loaded. The swap
  review validates the wallet, exact input, minimum output, and network costs.
- Local endpoint: `GET /api/swap/quote?assetMint=...&side=buy&amount=100&slippageBps=50`.
  Wallet-bound review and submission use separate Jupiter swap endpoints.

## Chart data and lifecycle

- Intervals: 1m, 5m, 15m, 1h, 4h, 12h, 1D.
- Latest bars refresh every 30 seconds while active/visible.
- Shared provider gate spaces all discovery and candle requests at least 7 seconds apart.
- Searches cache for 60 seconds; exact-address routing caches for five minutes.
- Latest results cache for 25 seconds; historical pages for one hour.
- History is conservatively capped at 180 days within the free provider window.
  Empty older pages end pagination; provider/network failures remain errors.
- A 429 response imposes a one-minute cooldown. The native reload action retries.
- For development, `./script/build_and_run.sh` installs and starts a per-user
  LaunchAgent on first run. Later UI builds leave its Rust process running.
  The agent runs `~/Library/Application Support/com.aryan.TradingWorkspace/DataService/trading-data-service`
  while signed in. It listens only on loopback on an ephemeral port and publishes
  its connection details to a user-private file. The app discovers the new endpoint
  automatically after the agent restarts. Pump and Fomo sign-in and authenticated
  refreshes continue in the app. The agent serves chart assets staged by the UI build.
- Packaged releases still bundle the Rust executable and chart assets and start
  the helper when the app opens.

Use these commands to work on the development service independently of the Mac app:

```sh
./script/data_service.sh build      # Rebuild and restart Rust only
./script/data_service.sh restart    # Restart the installed build
./script/data_service.sh status     # Inspect the launchd job and current PID
./script/data_service.sh uninstall  # Unload it and remove its login registration
```

## Asset research in development builds

Rebuild the service with `./script/data_service.sh build` using Node.js 22.13 or later. The build stages the pinned ACPX helper alongside the LaunchAgent. In **Settings → AI Providers**, check an existing sign-in for Codex, Grok Build, or Antigravity. Ask a question in the floating bar at the bottom of Markets. The conversation opens upward and stays attached to the bar. tRig restores one conversation from Application Support and keeps its provider fixed after the first message. Each new message uses the market open when it was sent. The selected provider receives the question, the open market’s identity, and the results of the read-only MCP tools it calls.

## Checks

```sh
swift test
cargo test --manifest-path backend/trading-data/Cargo.toml --locked
cargo test --manifest-path backend/wallet-signer/Cargo.toml --locked
node --test Tests/ChartHost/*.test.cjs Tests/ConnectionHost/*.test.cjs
node --test research-host/*.test.mjs
```

Rust checks cover interval mapping, ranges, candle validation, portfolio accounting,
source isolation, exact quantities, shared-wallet deduplication and history bounds.
Chart-host checks cover ordered refreshes, exclusive boundaries, errors and
background/unsubscribe behaviour. The local signer checks wallet operations
against the reviewed transactions. Provider API keys are read by the local
Rust service from private configuration.

## Multichain market terminal

The header now includes available 24h change, rolling high/low, volume, market cap,
FDV, liquidity and asset links. A collapsible Recent trades panel sits beside the
chart. Native search and token selectors support Solana and provider-supported
EVM networks with chain badges and separate quote/chart capabilities. See
[market-data.md](market-data.md) for API contracts, identity, cache and freshness
semantics.
