#[cfg(test)]
mod tests;

use super::{aggregate, normalize, types::*};
use rusqlite::{params, Connection, OptionalExtension, TransactionBehavior};
use serde::{Deserialize, Serialize};
use std::{collections::HashSet, path::Path, sync::Mutex, time::Duration};

const REFRESH_SECONDS: f64 = 60.0;
const LEASE_SECONDS: f64 = 300.0;
type Result<T> = std::result::Result<T, StoreError>;

#[derive(Debug)]
pub enum StoreError {
    Invalid,
    Conflict,
    Database,
}
impl From<rusqlite::Error> for StoreError {
    fn from(_: rusqlite::Error) -> Self {
        Self::Database
    }
}
impl From<serde_json::Error> for StoreError {
    fn from(_: serde_json::Error) -> Self {
        Self::Database
    }
}

#[derive(Clone, Debug, Deserialize, Serialize, Eq, PartialEq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Account {
    pub source: Source,
    pub account_wallet: String,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct AccountsRequest {
    pub expected_revision: Option<i64>,
    pub accounts: Vec<Account>,
    #[serde(default)]
    pub removed: Vec<Source>,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SyncRequest {
    pub period: Period,
    pub available: Vec<Account>,
    #[serde(default)]
    pub force: bool,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Job {
    pub source: Source,
    pub account_wallet: String,
    pub period: Period,
    pub token: i64,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Completion {
    pub job: Job,
    pub provider: Option<ProviderInput>,
    pub error: Option<String>,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct CompleteRequest {
    pub revision: i64,
    pub results: Vec<Completion>,
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CachedPortfolio {
    pub revision: i64,
    pub accounts: Vec<Account>,
    pub views: PortfolioViews,
    pub market: PortfolioView,
    pub cached: bool,
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SyncPlan {
    pub revision: i64,
    pub jobs: Vec<Job>,
}

pub struct Repository {
    db: Mutex<Connection>,
}
fn source(s: Source) -> &'static str {
    match s {
        Source::Pump => "pump",
        Source::Fomo => "fomo",
    }
}
fn period(p: Period) -> &'static str {
    match p {
        Period::Day => "1d",
        Period::Week => "7d",
        Period::Month => "30d",
        Period::All => "all",
    }
}
fn validate(accounts: &[Account]) -> Result<()> {
    let mut seen = HashSet::new();
    if accounts.len() > 2
        || accounts
            .iter()
            .any(|a| !valid_wallet(&a.account_wallet) || !seen.insert(a.source))
    {
        return Err(StoreError::Invalid);
    }
    Ok(())
}
fn active(db: &Connection) -> Result<Vec<Account>> {
    let mut stmt = db.prepare("SELECT source,wallet FROM portfolio_accounts ORDER BY source")?;
    let rows = stmt.query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)))?;
    rows.map(|r| {
        let (s, account_wallet) = r?;
        Ok(Account {
            source: if s == "pump" {
                Source::Pump
            } else {
                Source::Fomo
            },
            account_wallet,
        })
    })
    .collect()
}
fn revision(db: &Connection) -> Result<i64> {
    Ok(
        db.query_row("SELECT revision FROM portfolio_meta WHERE id=1", [], |r| {
            r.get(0)
        })?,
    )
}
fn load(db: &Connection, a: &Account, p: Option<Period>) -> Result<Option<Snapshot>> {
    let json: Option<String> = if let Some(p) = p {
        db.query_row(
            "SELECT snapshot FROM portfolio_snapshots WHERE source=? AND wallet=? AND period=?",
            params![source(a.source), a.account_wallet, period(p)],
            |r| r.get(0),
        )
        .optional()?
    } else {
        db.query_row("SELECT snapshot FROM portfolio_snapshots WHERE source=? AND wallet=? ORDER BY fetched_at DESC,period LIMIT 1",params![source(a.source),a.account_wallet],|r|r.get(0)).optional()?
    };
    json.map(|s| serde_json::from_str(&s).map_err(Into::into))
        .transpose()
}
impl Repository {
    pub fn open(path: &Path) -> Result<Self> {
        if let Some(parent) = path.parent().filter(|p| !p.as_os_str().is_empty()) {
            std::fs::create_dir_all(parent).map_err(|_| StoreError::Database)?;
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                std::fs::set_permissions(parent, std::fs::Permissions::from_mode(0o700))
                    .map_err(|_| StoreError::Database)?;
            }
        }
        let db = Connection::open(path)?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600))
                .map_err(|_| StoreError::Database)?;
        }
        Self::initialize(db)
    }
    fn initialize(db: Connection) -> Result<Self> {
        db.busy_timeout(Duration::from_secs(3))?;
        db.pragma_update(None, "foreign_keys", "ON")?;
        db.pragma_update(None, "journal_mode", "WAL")?;
        let version: i64 = db.pragma_query_value(None, "user_version", |r| r.get(0))?;
        if version > 1 {
            return Err(StoreError::Database);
        }
        db.execute_batch("BEGIN IMMEDIATE;
          CREATE TABLE IF NOT EXISTS portfolio_meta(id INTEGER PRIMARY KEY CHECK(id=1),revision INTEGER NOT NULL,next_token INTEGER NOT NULL);
          INSERT OR IGNORE INTO portfolio_meta VALUES(1,0,0);
          CREATE TABLE IF NOT EXISTS portfolio_accounts(source TEXT PRIMARY KEY CHECK(source IN ('pump','fomo')),wallet TEXT NOT NULL);
          CREATE TABLE IF NOT EXISTS portfolio_snapshots(source TEXT NOT NULL REFERENCES portfolio_accounts(source) ON DELETE CASCADE,wallet TEXT NOT NULL,period TEXT NOT NULL,fetched_at REAL NOT NULL,snapshot TEXT NOT NULL,PRIMARY KEY(source,wallet,period));
          CREATE TABLE IF NOT EXISTS portfolio_sync(source TEXT NOT NULL REFERENCES portfolio_accounts(source) ON DELETE CASCADE,wallet TEXT NOT NULL,period TEXT NOT NULL,token INTEGER NOT NULL,lease_until REAL NOT NULL,retry_after REAL NOT NULL,error TEXT,PRIMARY KEY(source,wallet,period));
          PRAGMA user_version=1;
          COMMIT;")?;
        // Leases belong to the previous server process; retry deadlines survive restart.
        db.execute("UPDATE portfolio_sync SET lease_until=0", [])?;
        Ok(Self { db: Mutex::new(db) })
    }
    pub fn accounts(&self, request: AccountsRequest) -> Result<()> {
        validate(&request.accounts)?;
        if request.removed.len() > 2
            || request
                .accounts
                .iter()
                .any(|a| request.removed.contains(&a.source))
        {
            return Err(StoreError::Invalid);
        }
        let mut db = self.db.lock().map_err(|_| StoreError::Database)?;
        let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
        if let Some(expected) = request.expected_revision {
            if revision(&tx)? != expected {
                return Err(StoreError::Conflict);
            }
        }
        if !request.accounts.is_empty() && request.expected_revision.is_none() {
            return Err(StoreError::Invalid);
        }
        let before = active(&tx)?;
        for s in request.removed {
            tx.execute("DELETE FROM portfolio_accounts WHERE source=?", [source(s)])?;
        }
        for a in request.accounts {
            if before
                .iter()
                .any(|old| old.source == a.source && old.account_wallet == a.account_wallet)
            {
                continue;
            }
            tx.execute(
                "DELETE FROM portfolio_accounts WHERE source=?",
                [source(a.source)],
            )?;
            tx.execute(
                "INSERT INTO portfolio_accounts(source,wallet) VALUES(?,?)",
                params![source(a.source), a.account_wallet],
            )?;
        }
        if before != active(&tx)? {
            tx.execute(
                "UPDATE portfolio_meta SET revision=revision+1 WHERE id=1",
                [],
            )?;
            // Reconciliation invalidates all earlier completion tokens, including retained accounts.
            tx.execute("UPDATE portfolio_sync SET lease_until=0,retry_after=0", [])?;
        }
        tx.commit()?;
        Ok(())
    }
    pub fn read(&self, p: Period, now: f64) -> Result<CachedPortfolio> {
        let db = self.db.lock().map_err(|_| StoreError::Database)?;
        let accounts = active(&db)?;
        let mut snapshots = Vec::new();
        let mut current = Vec::new();
        let mut issues = Vec::new();
        let mut cached = false;
        for a in &accounts {
            let failure: Option<String> = db
                .query_row(
                    "SELECT error FROM portfolio_sync WHERE source=? AND wallet=? AND period=?",
                    params![source(a.source), a.account_wallet, period(p)],
                    |r| r.get(0),
                )
                .optional()?
                .flatten();
            let Some(mut latest) = load(&db, a, None)? else {
                issues.push(PortfolioIssue {
                    source: a.source,
                    message: failure.clone().unwrap_or_else(|| {
                        "Waiting for the first successful portfolio refresh.".into()
                    }),
                });
                continue;
            };
            let history = load(&db, a, Some(p))?;
            if now - latest.fetched_at >= REFRESH_SECONDS {
                cached = true;
            }
            if let Some(message) = failure {
                cached = true;
                issues.push(PortfolioIssue {
                    source: a.source,
                    message,
                });
            }
            current.push(latest.clone());
            if let Some(h) = history {
                latest.pnl = h.pnl;
                latest.pnl_percent = h.pnl_percent;
                latest.history = h.history;
                if now - h.fetched_at >= REFRESH_SECONDS {
                    cached = true;
                }
            } else {
                latest.pnl = None;
                latest.pnl_percent = None;
                latest.history.clear();
            }
            snapshots.push(latest);
        }
        Ok(CachedPortfolio {
            revision: revision(&db)?,
            accounts,
            views: super::views(&snapshots, &issues, p),
            market: aggregate::combine(&current, &issues, Period::Day, "all"),
            cached,
        })
    }
    pub fn claim(&self, request: SyncRequest, now: f64) -> Result<SyncPlan> {
        validate(&request.available)?;
        let mut db = self.db.lock().map_err(|_| StoreError::Database)?;
        let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let accounts = active(&tx)?;
        let mut jobs = Vec::new();
        for a in request.available {
            if !accounts.contains(&a) {
                return Err(StoreError::Conflict);
            }
            let gate:Option<(f64,f64)>=tx.query_row("SELECT lease_until,retry_after FROM portfolio_sync WHERE source=? AND wallet=? AND period=?",params![source(a.source),a.account_wallet,period(request.period)],|r|Ok((r.get(0)?,r.get(1)?))).optional()?;
            if gate.is_some_and(|(lease, retry)| lease > now || (!request.force && retry > now)) {
                continue;
            }
            if !request.force
                && load(&tx, &a, Some(request.period))?
                    .is_some_and(|s| now - s.fetched_at < REFRESH_SECONDS)
            {
                continue;
            }
            tx.execute(
                "UPDATE portfolio_meta SET next_token=next_token+1 WHERE id=1",
                [],
            )?;
            let token = tx.query_row(
                "SELECT next_token FROM portfolio_meta WHERE id=1",
                [],
                |r| r.get(0),
            )?;
            tx.execute("INSERT INTO portfolio_sync(source,wallet,period,token,lease_until,retry_after,error) VALUES(?,?,?,?,?,?,NULL) ON CONFLICT(source,wallet,period) DO UPDATE SET token=excluded.token,lease_until=excluded.lease_until,retry_after=excluded.retry_after",params![source(a.source),a.account_wallet,period(request.period),token,now+LEASE_SECONDS,now+REFRESH_SECONDS])?;
            jobs.push(Job {
                source: a.source,
                account_wallet: a.account_wallet,
                period: request.period,
                token,
            });
        }
        let revision = revision(&tx)?;
        tx.commit()?;
        Ok(SyncPlan { revision, jobs })
    }
    pub fn complete(&self, request: CompleteRequest, now: f64) -> Result<()> {
        if request.results.len() > 2 {
            return Err(StoreError::Invalid);
        }
        let mut seen = HashSet::new();
        let mut parsed = Vec::new();
        for result in request.results {
            let job = result.job;
            if !seen.insert(job.source) || !valid_wallet(&job.account_wallet) {
                return Err(StoreError::Invalid);
            }
            let snapshot = result
                .provider
                .filter(|p| {
                    p.source == job.source
                        && p.account_wallet == job.account_wallet
                        && p.period == job.period
                        && !p.stale
                })
                .and_then(|p| normalize::snapshot(p).ok());
            // Only curated financial data from the normalizer is persisted. Input JSON is discarded.
            let error = if snapshot.is_none() {
                Some(
                    result
                        .error
                        .map(|e| e.chars().take(240).collect::<String>())
                        .unwrap_or_else(|| {
                            "The refresh could not be confirmed. Last successful data is retained."
                                .into()
                        }),
                )
            } else {
                None
            };
            parsed.push((job, snapshot, error));
        }
        let mut db = self.db.lock().map_err(|_| StoreError::Database)?;
        let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
        if revision(&tx)? != request.revision {
            return Err(StoreError::Conflict);
        }
        for (job, snapshot, error) in parsed {
            let lease:Option<(i64,f64)>=tx.query_row("SELECT token,lease_until FROM portfolio_sync WHERE source=? AND wallet=? AND period=?",params![source(job.source),job.account_wallet,period(job.period)],|r|Ok((r.get(0)?,r.get(1)?))).optional()?;
            if !lease.is_some_and(|(token, until)| token == job.token && until > now) {
                return Err(StoreError::Conflict);
            }
            if let Some(snapshot) = snapshot {
                if snapshot.fetched_at > now + 60.0 {
                    return Err(StoreError::Invalid);
                }
                let encoded = serde_json::to_string(&snapshot)?;
                tx.execute("INSERT INTO portfolio_snapshots(source,wallet,period,fetched_at,snapshot) VALUES(?,?,?,?,?) ON CONFLICT(source,wallet,period) DO UPDATE SET fetched_at=excluded.fetched_at,snapshot=excluded.snapshot WHERE excluded.fetched_at>=portfolio_snapshots.fetched_at",params![source(job.source),job.account_wallet,period(job.period),snapshot.fetched_at,encoded])?;
            }
            tx.execute("UPDATE portfolio_sync SET lease_until=0,retry_after=?,error=? WHERE source=? AND wallet=? AND period=?",params![now+REFRESH_SECONDS,error,source(job.source),job.account_wallet,period(job.period)])?;
        }
        tx.commit()?;
        Ok(())
    }
}
