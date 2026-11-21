# Shared quote providers

The Rust service owns read-only quote requests for Jupiter, Relay and Definitive
Flash. The native ticket's existing Jupiter endpoint delegates to this same
implementation. Signing, setup-transaction broadcasting, order admission,
cancellation and submission endpoints are not mounted.

## Native entry points

In the Markets ticket, **Cross-chain & advanced quotes…** opens the quote-route
composer. **Limit** changes the main ticket in place, retaining the selected
asset, side and amount. Its target price is synchronized with a draggable,
unsaved TradingView draft line; its inline quote uses automatic server routing.
**TP/SL** selects Sell and opens two inline exit editors with independent token
quantities, target prices, enable toggles and quote results. Both draft lines are
visible together. No linked-order or OCO behavior is implied by these previews.
The separate composer accepts
provider, chains, exact token addresses, spend amount, slippage, optional public
address context and a USD limit/stop price. Limit quotes support buy and sell;
stop-loss estimates price the token being sold. Changing side clears the amount
because the spend unit changes. Funding/signing decisions remain deferred.

## Local configuration

Rust reads:

`~/Library/Application Support/com.aryan.TradingWorkspace/quotes.env`

Supported variables are `JUPITER_API_KEY`, `RELAY_API_KEY`, `FLASH_API_KEY`.
Environment values take precedence. Missing Jupiter credentials use its keyless
allowance. Relay/Flash return a clear inactive state without their keys. Restart
the app after changing configuration. `backend/trading-data/quotes.env.example`
contains empty entries only. The supplied local keys were saved outside the
repository with mode 0600 and were verified absent from source, tests and docs.

Native code passes a configuration path to the sidecar, never key values. HTTP
keys are attached only to the fixed provider host, marked sensitive, and redirects
are disabled. Keys are not returned in metadata, quote JSON, logs or SQLite.

## API

`GET /api/quotes/providers` returns configuration status, discovered chains,
order types, context requirements, metadata provenance/age and warnings.

`POST /api/quotes/quote` takes a strict JSON request:

```json
{
  "provider": "jupiter",
  "side": "buy",
  "input": {
    "chain": "solana",
    "address": "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v"
  },
  "output": {
    "chain": "solana",
    "address": "So11111111111111111111111111111111111111112"
  },
  "amount": "100",
  "orderType": "market",
  "slippageBps": 50,
  "context": {}
}
```

- Omit `provider` for capability-based selection. Solana market quotes prefer
  Jupiter, other market pairs prefer Relay, and conditional quotes use Flash.
  Configured chain coverage is checked before selection. Explicit provider
  selection does not silently fall back to another quote source.
- EVM chains use `eip155:<id>`, Solana uses `solana`, and Relay's other VM chains
  use `relay:<provider-id>`. Coverage comes from Relay `/chains` and Flash
  `/chains`; there is no Solana/Base product allowlist. Unconfigured Flash can
  show its public schema's chain names with `flash:<name>` identifiers until a
  key makes live IDs/minimums available. Route availability is still pair/amount
  specific, and temporarily disabled chains are rejected.
- Amount is an exact decimal string in the spent token's human units. No float
  conversion, silent rounding or caller-supplied decimal precision is used.
- `orderType` is `market`, `limit` or `stop-loss`. Conditional quotes require the
  same chain. `limitPriceUsd` prices the receive token on a buy and the spend token
  on a sell; `triggerPriceUsd` prices the spent token for stop-loss. Stop-loss is
  a sell. `side` defaults to buy except for stop-loss.
- Relay requires `context.sender`; cross-chain quotes require
  `context.recipient`. Flash requires both for cross-chain previews, while its
  same-chain indicative quotes work without a funding address. These are public
  quote-estimation inputs, not a wallet connection or execution authorization.
  The app never attaches Pump/Fomo profile wallets automatically.
- Unexpected fields including signatures, signed transactions and provider URLs
  are rejected. Bodies are limited to 16 KiB.

Results contain the chosen provider, exact token identities, quoted spend/net
receive, optional minimum receive, fees with units, optional price impact,
provenance ID, warnings and the echoed request. No transaction instructions,
calldata, typed signing data, setup transactions or permits leave the server.

## Freshness, fees and metadata

All results are indicative, with a **20-second app freshness window**. This is
not a provider expiry guarantee or a resting order's deadline. Successful identical
requests can reuse a three-second in-memory quote; context, provider, chains,
tokens, side, prices and slippage are all part of its identity. Quotes are not
stored in the portfolio database or reused from portfolio snapshots.

Chain metadata caches for ten minutes. Validated token metadata caches for a day;
unknown Flash metadata retries sooner. Jupiter and Relay require confirmed
precision for raw-unit requests and validate response amount/token/chain identity.
Flash uses the API's human-unit contract, so missing metadata is nullable and
explicitly warned rather than being replaced with zero decimals.

Flash's `/search` endpoint is usage-gated even when quoting is authorized. Quote
support does not depend on that entitlement: Solana metadata comes from the
shared Jupiter lookup, EVM metadata can come from Relay, and unconfirmed names
fall back to abbreviated exact addresses. Flash-native EVM addresses use the
provider's documented sentinel; use exact supported asset addresses.

Only provider-reported fees/thresholds are displayed. Flash does not return a
minimum receive field, so it stays absent. We omit Flash's optional integrator-fee
parameter: explicitly sending `"0"` is rejected by the live API. Relay app fees
are an empty list and Jupiter has no referral parameters. Existing provider and
network costs can still apply. Conditional previews do not create resting orders
or guarantee a future fill.

One serialized upstream gate per provider is shared with the legacy ticket:
Jupiter 2.1 seconds keyless / 1.1 seconds keyed, Relay 1.3 seconds, Flash 250 ms.
This is conservative relative to endpoint-specific limits. Rate-limit headers
establish a cooldown; failures are not cached as successful or zero-value quotes.

## Validation — November 20, 2026

Using the configured local keys, through the actual Rust loopback API:

- Capability discovery: Jupiter Solana, 58 enabled Relay chains, 15 Flash chains.
- HTTP 200: Jupiter market; Relay Base → Optimism market; Flash Solana market,
  buy-limit, sell-limit and stop-loss.
- HTTP 200: Flash same-chain Base market and Base USDC → Optimism USDC market
  with public documentation-fixture address context. No user funding wallet was
  selected, connected or signed.
- All successful normalized checks matched request identity, had positive receive
  estimates and exposed no signing payload. The original ticket's Backpack quote
  endpoint also returned 200 through the shared engine.
- Signing fields were rejected with 422; the nonexistent submission route returned
  404/405. No trade was submitted and no approval or delegation was signed.
- 56 Rust tests, 32 Swift tests and 20 JavaScript tests passed. Clippy with warnings
  denied, canonical build/launch and `git diff --check` passed.

The first Flash cross-chain native-ETH fixture was refused as a native/wrapped
route. A stablecoin fixture then exposed the requirement for both address fields,
which is now validated locally and covered by a regression test. This illustrates
why a supported chain list is not a promise of every possible token pair.

Curated temporary API receipts are in `/tmp/trig-execution-contracts/`; they retain
statuses and validation flags, not actual keys or comparable quote prices. These
are functional integration checks, not an execution-quality benchmark.

The native composer was subsequently verified in the running app at 780 × 670
points. Live Jupiter and Flash market estimates, Flash buy-limit and stop-loss
estimates, stale-estimate messaging, side changes, and required conditional-price
input were exercised. At that stage, the ticket's limit entry opened Flash in
Limit mode; the subsequent inline ticket described below replaces that shortcut.
Provider order choices now follow server capabilities: switching from Flash Limit
to Relay resets to Market, and Relay's order menu contains only Market.
Relay's full chain menu and automatic address-context expansion were inspected;
changing the input chain clears its token address and spend amount. Dismissal
returns to Markets. No clipping or overlapping controls was found in this viewport.
Relay's live cross-chain result was verified through the loopback API rather than
the native form. Screenshot: `/tmp/trig-quote-ui-qa/relay-chain-controls.png`.

## Inline Limit ticket and chart interaction

The right-hand native ticket now switches between Market and Limit without a
sheet. Limit inherits the trading asset and spend amount, starts with a 5% target
below market for a buy or above market for a sell, and offers Market/5%/10%/25%
price shortcuts. These are editable draft defaults, not trading recommendations.
Current price updates never move an already entered target. Changing side clears
the spend quantity because its units change and initializes a new target.

`LimitOrderDraft` is window-owned and shared with the chart. The Advanced Charts
Drawings API provides an unsaved horizontal drawing labelled “Draft buy/sell
limit · not placed”. No Trading Platform broker API is used. Native edits move
the existing drawing; dragging updates the numeric price. Messages must match
the current mint and draft revision. Disabling Limit removes the drawing;
deleting it clears the price and invalidates preview. Chart Undo cannot restore
a detached old draft. Unrelated drawings are left alone.

The ticket distinguishes a local, fee-free calculation at the target from the
backend's returned quote. Provider fees/warnings and slippage are in Quote details.
Target/amount/side changes clear the prior quote and discard late responses.
There is no expiry selector because the current preview contract has no expiry
input. Cross-chain previews remain in the separate composer; stop-loss previews
are also available in the inline TP/SL mode described below.

Verified natively: chart drag → numeric price; numeric entry → chart line; live
buy and sell quotes; price-change quote invalidation; side changes; line deletion;
Undo cleanup; Market removal and return to Limit. The final 1512 × 949-point
window capture is `artifacts/inline-limit-2026-11-20/inline-limit.png`.
36 Swift and 13 chart JavaScript tests passed, including draft identity,
asynchronous drawing creation/disposal and Undo regressions. Canonical build and
launch passed. This change does not add signing or order submission.

### Drag offset correction

Live tracing identified a transient TradingView point value during `move` and
`points_changed`: for a short drag from 0.21487, `mouse_up` saw 0.22809756,
the synchronous move callback saw 0.24132512, and the settled drawing returned
to 0.22809756. Reading inside the callback and rendering afterward applied the
drag offset twice. The earlier acknowledgement-only correction did not fix this.

The controller now coalesces move callbacks and reads points in a microtask after
TradingView clears its internal move state. Mouse release does not redraw an
otherwise unchanged draft. Chart-originated prices retain their native edit
revision, so delayed acknowledgements do not become geometry commands. Explicit
native edits made during a gesture wait until it finishes; drawing styles are
only reapplied when the side changes. Temporary diagnostic logging was removed.

Rechecked in the native hourly JTO chart: an upward drag from the left half
shifted the line approximately 20 pixels for a 20-pixel gesture; a downward drag
from the right half did the same, with the native price synchronized and no
second jump. Capture: `artifacts/inline-limit-2026-11-20/drag-fix.png`.
37 Swift tests and 16 chart JavaScript tests passed. The added regression emulates
the observed temporary doubled offset and verifies that only the settled value
is published, without any geometry/style writes from drag acknowledgements.

## Inline TP/SL previews

Each exit has its own token-denominated sell quantity, target price, enable toggle,
quote store and freshness state. Take profit uses a sell-limit quote; stop loss
uses a stop-loss quote, both automatically routed by Rust. Quantities start empty
and are not derived from the unrelated Buy spend amount or saved account balances.
Price defaults/presets are editable offsets from the displayed current market.
The TP target must be above that reference; SL must be below it. Dragging across
the reference shows validation instead of silently changing the order's meaning.

The chart bridge now carries an array of identified drafts (`limit`, `take-profit`,
`stop-loss`). Stable drawing controllers preserve the settled-price drag fix for
each line. TP is green and SL orange, with explicit “Draft TP/SL · not placed”
labels. Native messages match line ID, mint and edit revision. A change/removal
affects only that exit. Mode changes hide outgoing lines and invalidate old events;
returning to TP/SL retains the draft prices, quantities and enabled choices.

Preview exits requests every enabled, valid leg independently. One missing quantity
does not prevent previewing the other leg. Results, failures and stale states stay
per-exit; editing one clears only its prior result. There is no OCO linkage,
funding-wallet selection, balance reservation or order submission. The quantities
are not added together or represented as a guaranteed executable position plan.

Verified natively with JTO: distinct TP (10 JTO) and SL (25 JTO) amounts returned
live estimates; native TP editing cleared only TP's quote; disabling TP left SL
and its result intact. Both chart lines were dragged independently and updated
only their matching native fields. Market/Limit/TP-SL switches displayed zero,
one and two draft drawings respectively, retaining exit quantities on return.
40 Swift tests and 17 chart JavaScript tests passed, including cross-leg identity,
request semantics and drawing independence. Canonical build/launch passed.
Captures: `artifacts/tpsl-2026-11-20/overview.png` and `quote-summaries.png` in the
same directory. Expanded summaries/settings use the ticket's scroll area while
the Preview exits button remains visible.

## Chain-aware market ticket

EVM market orders use named token selectors with network badges; the counter-token
can be on another supported chain. Solana retains its Jupiter market ticket.
Conditional previews use the selected network and its settlement token, and remain
available only on supported Flash networks. See [market-data.md](market-data.md)
for discovery, persistent metadata caching and independent chart availability.
Public address context estimates a route; it does not connect or authorize a wallet.
