# Market data and multichain terminal

The native terminal uses an app-owned Rust loopback service for market data,
wallet networks, quotes, and supported trade execution.

## Discovery and identity

`backend/trading-data/src/chain-registry.json` defines Solana and the 21 EVM
networks offered by Markets, Wallet, and Quotes. It uses public Relay metadata
for canonical chain IDs, native currencies, RPCs, and explorers, and includes
each network's starting GeckoTerminal mapping. Wallet discovery and Relay's
chain picker use the bundled registry directly. Flash quote coverage is
intersected with the registry.

`GET /api/markets/networks` caches the catalog for one hour. GeckoTerminal may
refresh chart mappings for registered networks in the background. Failed
refreshes retain the bundled or saved mapping and retry after one minute.

`GET /api/assets/search?q=...&chain=all` searches pools and Relay token metadata.
A selected chain narrows discovery; exact addresses keep their network. Resolve
uses `/api/assets/resolve?mint=...&chain=...`. A token can be quoteable without a
chart. Such a result shows a chart-unavailable state and retains its quote ticket.
A provider failure during exact resolution is an error, not proof of no market.

Identity is chain plus canonical address; market identity additionally includes
pool. EVM hex is lowercase, Solana base58 remains case sensitive. Legacy saved
Solana assets remain readable. Watchlists and asynchronous responses use these
identities, so matching contracts on different networks stay separate.

Default EVM pay tokens come from verified chain-specific USDC metadata, falling
back to the chain's native currency. The native token selector can choose a
counter-token on another supported chain. Relay uses the funding wallet and
recipient address to quote and review supported cross-chain routes.

## Durable lookup cache

The Rust service stores public discovery metadata in the existing SQLite database,
using separate `market_assets`, `market_searches` and `market_networks` tables.
Portfolio tables and their schema version are preserved. The asset primary key is
`(chain, canonical address)`, with an address index for All networks searches.
An asset learned from a ticker search can therefore satisfy a later CA lookup,
including after the app restarts.

- Name, symbol, decimals, artwork, market identity and settlement-token metadata
  persist; volatile price, volume, liquidity, change, market cap and FDV are
  stripped from saved records and refreshed through the market-data paths.
- Successful query results can open from SQLite for up to 24 hours. After 60
  seconds they trigger one background refresh per query/scope, without blocking
  the saved results. Known address matches use the same daily metadata window
  and refresh in the background. All networks initially returns known matches;
  the refresh can discover additional networks for that address.
- A resolved asset route can skip discovery for five minutes. Saved selections
  from an older ranking rule are rechecked before opening the chart, statistics
  or recent trades.
- Routing prefers markets with 24-hour volume, then markets old enough to cover
  the chart window or at least seven days. Within a tier, 24-hour volume comes
  first and liquidity breaks ties. If the selected market has at most one daily
  candle, resolution checks one other active market for longer history.
- Successful network catalogs survive restarts for one hour. Failed discovery
  does not replace a successful durable catalog.
- Empty/error searches are not persisted. Writes are transactional, older replies
  cannot overwrite newer records, and invalid/mismatched cached identities are
  discarded. The cache is bounded to 1,000 queries and 10,000 assets.
- No keys, browser sessions, wallet authorization or quote results are written to
  these tables. Cache hits do not make an order preview executable.

## Snapshots and trades

- `GET /api/markets/snapshot?chain=...&address=...&pool=...`
- `GET /api/markets/trades?chain=...&address=...&pool=...`
- `GET /api/chart/bars?chain=...&mint=...&pool=...&resolution=...`

Snapshot/trade requests validate the market and selected token. Pool change,
market cap and FDV describe the base token; they are never assigned to its quote
token. Missing selected-token valuations use independently validated token
metadata. Null market cap remains null; FDV is not a substitute.

The header shows available metrics immediately. High/low are calculated separately
from up to two pages of 1-minute candles over the last 24 hours of completed
minutes, independent of the selected chart interval. The quote-token change
fallback uses that same window. A bounded background task updates the cache;
the UI polls the local result while it is pending. Missing bars yield missing
values, and refresh failures preserve the last result with a warning.

Recent trades are scoped to the chart's market, with buys/sells relative to the
selected token. Event IDs deduplicate fills without dropping multiple fills in
one transaction. Quantities stay decimal strings; abbreviated UI quantities have
exact-value tooltips. Each row links to its chain explorer.

The current public feed is polled, not a streaming order book. Trades include at
most the provider's latest 300 events. The native panel labels its update age,
is collapsible, and preserves saved data on refresh failures. Available Website,
X and explorer links are HTTPS URLs.

## Limits and lifecycle

Public GeckoTerminal requests share a 7-second gate, 60-second raw response cache
and 60-second cooldown after a 429. Snapshot/trade caches live for 60 seconds;
network mappings for one hour and token links for one day. Chart candles retain
the existing interval-specific cache and bounded free history. Vela starts with
the latest candle page and requests older candles as the viewport approaches its
left edge. A short page marks the end of available history. Native market
refreshes run every 60 seconds in the active Markets view. Chart polling remains
30 seconds while visible; the upstream gate/cache still applies.

Cold discovery and 24h ranges can take longer when catalog discovery or provider
cooldowns share that budget. Unavailable values show dashes instead of samples.
Quote availability, conditional-order availability and chart availability are
independent capabilities; a listed network does not guarantee every token has
all three.

## Verification

Focused checks cover cross-chain identity, selected-side metrics, rolling range
boundaries, event deduplication, incorrect response rejection and quote-only
request boundaries. The live pass included Base token search, BNB token market
quotes using public fixture address context, real trades and 24h ranges.
The Base WETH resolver rechecked its saved selection and returned 181 daily
candles from an established WETH/USDC market.
