# Local portfolio data layer

Rust owns the SQLite repository, normalization, aggregation, freshness rules and
refresh leases. The native connection adapter owns the existing authenticated
Pumpfun/Fomo reads. An app-wide Swift store observes the server and supplies both
Portfolio and Markets. UI components neither fetch provider data nor open SQLite.

## Persistence and ownership

The app passes an explicit `--database` path when it starts the bundled server:

`~/Library/Application Support/com.aryan.TradingWorkspace/portfolio.sqlite`

The directory is restricted to its user and the database is created with mode
0600. SQLite uses WAL, a busy timeout, foreign keys, immediate transactions for
mutations, and a versioned schema. A newer unsupported schema fails to open
rather than being overwritten. Database work runs on Tokio's blocking pool.
The existing loopback-only server lifecycle remains app-owned.

Schema version 1 stores:

- `portfolio_accounts`: the active confirmed profile wallet per platform.
- `portfolio_snapshots`: one last successful normalized snapshot per platform,
  wallet and period. Decimal balances/basis remain exact strings; snapshots
  contain lots, token metadata, warnings and provider history.
- `portfolio_sync`: refresh tokens, lease/retry deadlines and curated errors.
- `portfolio_meta`: the account revision and monotonically increasing job token.

Only normalized output is saved. Raw provider payloads, authentication cookies,
access tokens, usernames and social/callout content are not persisted here.
The persistent WebKit stores continue to own authentication. This is a cache of
read-only portfolio data, not a transaction ledger or an execution authorization.

## Read and refresh flow

1. App startup reads saved state immediately, before restoring connections.
   Saved accounts are labeled while session identity is being confirmed.
2. Confirmed native identities reconcile with the repository using an expected
   account revision. The UI hides a previous wallet when a different one is
   confirmed. Explicit Disconnect removes that platform's active account,
   snapshots and refresh records before clearing its website session.
3. While foregrounded, the shared native coordinator checks the local server
   every five seconds. Rust issues jobs only for confirmed accounts whose selected
   period is missing/due. Successful snapshots are fresh for 60 seconds. Merely
   navigating or changing platform filters does not request new provider data.
4. Each job has a unique persisted token and a five-minute lease. Manual refresh
   can bypass freshness/backoff but cannot duplicate an in-flight job. A failed
   read retains the last success and has a 60-second retry delay. Startup releases
   leases left by the previous server process while retaining retry deadlines.
5. The native adapter returns sanitized results for the issued jobs. Rust checks
   the account revision, wallet, period, token and lease, normalizes each result,
   and commits the batch atomically. An invalid source preserves its prior data;
   a lost lease/revision rolls back the batch. Older timestamps cannot replace
   newer snapshots.
6. Both screens receive the committed views together. Current holdings come from
   the newest successful snapshot for each active account, independently of the
   history period selected in Portfolio. Period P&L/history retain their own
   coverage and freshness. Aggregation retains chain/mint identities and the
   existing shared-wallet deduplication rules.

Failed saved-session restoration is retried at most once per minute while active;
services without saved cookies do not make profile requests. The coordinator is
shared across windows and stays mounted when the selected navigation tab changes.
Swap quotes and live chart prices keep their own freshness paths.

## Loopback API

| Endpoint | Responsibility |
| --- | --- |
| `GET /api/portfolio/cache?period=1d` | Saved accounts, selected-period views, unified current holdings, revision and cache status |
| `POST /api/portfolio/accounts` | Reconcile confirmed identities with `expectedRevision`, or explicitly remove sources |
| `POST /api/portfolio/sync` | Claim due jobs for available authenticated accounts; optional manual force |
| `POST /api/portfolio/sync/complete` | Validate issued jobs and atomically ingest successful normalized snapshots/errors |

Periods are `1d`, `7d`, `30d`, `all`. The UI receives prebuilt All/Pumpfun/Fomo
views. Markets always uses the complete current view, with the selected asset
first and expandable per-source lots. Portfolio filters do not narrow Markets.
The older stateless `/api/portfolio/view` endpoint is removed.

## Verification

- Rust repository tests cover on-disk reopen and exact decimal preservation,
  freshness/duplicate claims, failure retention/backoff, expired leases, current
  holdings across history periods, account switching/disconnect, stale account
  reconciliation, credential stripping and atomic rollback of a mixed batch.
- Native tests cover saved reads without restored identity, old-response and
  old-period rejection, and retaining the last good view after a local failure.
- Live app: both provider snapshots saved; SQLite `quick_check` returned `ok`
  and file permissions were 0600. A Fomo-filtered Portfolio returned to Markets
  as the full 102-asset combined view. An 18-second navigation check left the
  refresh counter unchanged at 7. Manual refresh updated the shared snapshot.
- After rebuilding/restarting both app and server, Portfolio showed 102 cached
  holdings and history with “2 saved platforms” before connection confirmation.
  Confirmed sessions subsequently resumed normal updates.

No live account was disconnected for testing, and no transaction/signing action
was performed. Disconnect/switch races use synthetic repository tests. A fully
network-disabled restart and automatic recovery from a real expired session were
not manually exercised. The cache currently supports the app's one connected
profile per platform; additional imported wallets require a later schema/API step.
