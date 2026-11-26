use super::*;
use serde_json::json;
const A: &str = "So11111111111111111111111111111111111111112";
const B: &str = "11111111111111111111111111111111";
fn account(wallet: &str) -> Account {
    Account {
        source: Source::Pump,
        account_wallet: wallet.into(),
    }
}
fn repo() -> Repository {
    Repository::initialize(Connection::open_in_memory().unwrap()).unwrap()
}
fn connect(r: &Repository, wallet: &str) {
    r.accounts(AccountsRequest {
        expected_revision: Some(r.read(Period::Day, crate::now() as f64).unwrap().revision),
        accounts: vec![account(wallet)],
        removed: vec![],
    })
    .unwrap()
}
fn claim(r: &Repository, p: Period, force: bool, now: f64) -> SyncPlan {
    r.claim(
        SyncRequest {
            period: p,
            available: vec![account(A)],
            force,
        },
        now,
    )
    .unwrap()
}
fn provider(job: &Job, qty: &str, now: f64) -> ProviderInput {
    serde_json::from_value(json!({"source":"pump","accountWallet":job.account_wallet,"period":period(job.period),"fetchedAt":now,
      "data":{"summary":{"wallet":job.account_wallet,"totalValueUsd":qty,"pnl":{"usd":"1"}},
      "positions":[{"coinMint":crate::models::BP_MINT,"chainId":1399811149,"amountHeld":qty,"valueUsd":qty,"tokenPriceUsd":"1","costBasisUsd":"0"}],"history":[]}})).unwrap()
}
fn save(r: &Repository, plan: SyncPlan, qty: &str, now: f64) {
    let results = plan
        .jobs
        .iter()
        .map(|job| Completion {
            job: job.clone(),
            provider: Some(provider(job, qty, now)),
            error: None,
        })
        .collect();
    r.complete(
        CompleteRequest {
            revision: plan.revision,
            results,
        },
        now,
    )
    .unwrap();
}
#[test]
fn restart_preserves_accounts_and_exact_normalized_balances() {
    let dir = std::env::temp_dir().join(format!(
        "trig-portfolio-test-{}-{}",
        std::process::id(),
        crate::now()
    ));
    let path = dir.join("portfolio.sqlite");
    let now = crate::now() as f64;
    {
        let r = Repository::open(&path).unwrap();
        connect(&r, A);
        let plan = claim(&r, Period::Day, false, now);
        save(&r, plan, "9007199254740993.123456789", now);
    }
    {
        let r = Repository::open(&path).unwrap();
        let read = r.read(Period::Day, now + 61.0).unwrap();
        assert!(read.cached);
        assert_eq!(read.accounts, vec![account(A)]);
        assert_eq!(
            read.market.holdings[0].quantity.as_deref(),
            Some("9007199254740993.123456789")
        );
    }
    std::fs::remove_dir_all(dir).unwrap();
}
#[test]
fn fresh_reads_navigation_and_duplicate_claims_do_not_refetch() {
    let r = repo();
    connect(&r, A);
    let now = crate::now() as f64;
    let first = claim(&r, Period::Day, false, now);
    assert_eq!(first.jobs.len(), 1);
    assert!(claim(&r, Period::Day, true, now + 1.0).jobs.is_empty());
    save(&r, first, "5", now + 2.0);
    for _ in 0..5 {
        assert_eq!(
            r.read(Period::Day, now + 3.0)
                .unwrap()
                .views
                .all
                .holdings
                .len(),
            1
        );
        assert!(claim(&r, Period::Day, false, now + 3.0).jobs.is_empty());
    }
    assert_eq!(claim(&r, Period::Day, false, now + 63.0).jobs.len(), 1);
}
#[test]
fn failures_keep_last_success_and_back_off() {
    let r = repo();
    connect(&r, A);
    let now = crate::now() as f64;
    save(&r, claim(&r, Period::Day, false, now), "5", now);
    let retry = claim(&r, Period::Day, true, now + 1.0);
    r.complete(
        CompleteRequest {
            revision: retry.revision,
            results: retry
                .jobs
                .into_iter()
                .map(|job| Completion {
                    job,
                    provider: None,
                    error: Some("Refresh unavailable".into()),
                })
                .collect(),
        },
        now + 1.0,
    )
    .unwrap();
    let read = r.read(Period::Day, now + 2.0).unwrap();
    assert_eq!(read.views.all.total_value_usd.as_deref(), Some("5"));
    assert!(read.cached);
    assert_eq!(read.views.all.warnings, ["Pumpfun: Refresh unavailable"]);
    assert!(claim(&r, Period::Day, false, now + 2.0).jobs.is_empty());
}
#[test]
fn saved_snapshots_recalculate_unrealized_pnl_from_lots() {
    let r = repo();
    connect(&r, A);
    let now = crate::now() as f64;
    save(&r, claim(&r, Period::Day, false, now), "5", now);
    r.db.lock()
        .unwrap()
        .execute(
            "UPDATE portfolio_snapshots SET snapshot=json_set(snapshot,'$.unrealized',NULL,'$.partial',json('true'))",
            [],
        )
        .unwrap();
    let read = r.read(Period::Day, now).unwrap();
    assert_eq!(read.views.pump.unrealized_pnl_usd.as_deref(), Some("5"));
}
#[test]
fn account_switch_and_disconnect_reject_inflight_results_and_remove_old_rows() {
    let r = repo();
    connect(&r, A);
    let now = crate::now() as f64;
    let plan = claim(&r, Period::Day, false, now);
    connect(&r, B);
    let job = plan.jobs[0].clone();
    let value = provider(&job, "99", now);
    assert!(matches!(
        r.complete(
            CompleteRequest {
                revision: plan.revision,
                results: vec![Completion {
                    job,
                    provider: Some(value),
                    error: None
                }]
            },
            now
        ),
        Err(StoreError::Conflict)
    ));
    assert!(r.read(Period::Day, now).unwrap().market.holdings.is_empty());
    r.accounts(AccountsRequest {
        expected_revision: Some(r.read(Period::Day, crate::now() as f64).unwrap().revision),
        accounts: vec![],
        removed: vec![Source::Pump],
    })
    .unwrap();
    assert!(r.read(Period::Day, now).unwrap().accounts.is_empty());
}
#[test]
fn expired_jobs_cannot_overwrite_newer_refreshes() {
    let r = repo();
    connect(&r, A);
    let now = crate::now() as f64;
    let old = claim(&r, Period::Day, false, now);
    let new = claim(&r, Period::Day, false, now + 301.0);
    assert_eq!(new.jobs.len(), 1);
    let job = old.jobs[0].clone();
    let value = provider(&job, "9", now);
    assert!(matches!(
        r.complete(
            CompleteRequest {
                revision: old.revision,
                results: vec![Completion {
                    job,
                    provider: Some(value),
                    error: None
                }]
            },
            now + 301.0
        ),
        Err(StoreError::Conflict)
    ));
}
#[test]
fn current_holdings_stay_global_when_history_period_changes() {
    let r = repo();
    connect(&r, A);
    let now = crate::now() as f64;
    save(&r, claim(&r, Period::Day, false, now), "5", now);
    let mut month = claim(&r, Period::Month, false, now + 1.0);
    month.jobs[0].period = Period::Month;
    save(&r, month, "8", now + 1.0);
    let day = r.read(Period::Day, now + 2.0).unwrap();
    assert_eq!(day.views.all.total_value_usd.as_deref(), Some("8"));
    assert_eq!(day.market.total_value_usd.as_deref(), Some("8"));
    assert_eq!(day.views.all.period_pnl_usd.as_deref(), Some("1"));
}

#[test]
fn stale_account_reconciliation_cannot_resurrect_a_disconnected_account() {
    let r = repo();
    connect(&r, A);
    let rev = r.read(Period::Day, crate::now() as f64).unwrap().revision;
    r.accounts(AccountsRequest {
        expected_revision: None,
        accounts: vec![],
        removed: vec![Source::Pump],
    })
    .unwrap();
    assert!(matches!(
        r.accounts(AccountsRequest {
            expected_revision: Some(rev),
            accounts: vec![account(A)],
            removed: vec![]
        }),
        Err(StoreError::Conflict)
    ));
    assert!(r
        .read(Period::Day, crate::now() as f64)
        .unwrap()
        .accounts
        .is_empty());
}
#[test]
fn invalid_provider_preserves_saved_data_and_raw_credentials_are_never_stored() {
    let r = repo();
    connect(&r, A);
    let now = crate::now() as f64;
    let first = claim(&r, Period::Day, false, now);
    let job = first.jobs[0].clone();
    let mut p = provider(&job, "5", now);
    p.data["authToken"] = json!("synthetic-do-not-persist");
    r.complete(
        CompleteRequest {
            revision: first.revision,
            results: vec![Completion {
                job,
                provider: Some(p),
                error: None,
            }],
        },
        now,
    )
    .unwrap();
    let raw: String =
        r.db.lock()
            .unwrap()
            .query_row("SELECT snapshot FROM portfolio_snapshots", [], |row| {
                row.get(0)
            })
            .unwrap();
    assert!(!raw.contains("synthetic-do-not-persist"));
    let second = claim(&r, Period::Day, true, now + 1.0);
    let job = second.jobs[0].clone();
    let mut p = provider(&job, "99", now + 1.0);
    p.data["summary"]["wallet"] = json!(B);
    r.complete(
        CompleteRequest {
            revision: second.revision,
            results: vec![Completion {
                job,
                provider: Some(p),
                error: None,
            }],
        },
        now + 1.0,
    )
    .unwrap();
    let saved = r.read(Period::Day, now + 2.0).unwrap();
    assert_eq!(saved.market.total_value_usd.as_deref(), Some("5"));
    assert!(saved.cached);
    assert!(!saved.views.all.warnings.is_empty());
}
#[test]
fn batch_commit_rolls_back_if_any_completion_lost_its_lease() {
    let r = repo();
    connect(&r, A);
    let now = crate::now() as f64;
    let rev = r.read(Period::Day, now).unwrap().revision;
    let fomo = Account {
        source: Source::Fomo,
        account_wallet: B.into(),
    };
    r.accounts(AccountsRequest {
        expected_revision: Some(rev),
        accounts: vec![fomo.clone()],
        removed: vec![],
    })
    .unwrap();
    let plan = r
        .claim(
            SyncRequest {
                period: Period::Day,
                available: vec![account(A), fomo],
                force: false,
            },
            now,
        )
        .unwrap();
    let pump = plan
        .jobs
        .iter()
        .find(|j| j.source == Source::Pump)
        .unwrap()
        .clone();
    let mut other = plan
        .jobs
        .iter()
        .find(|j| j.source == Source::Fomo)
        .unwrap()
        .clone();
    other.token += 100;
    let result = r.complete(
        CompleteRequest {
            revision: plan.revision,
            results: vec![
                Completion {
                    provider: Some(provider(&pump, "5", now)),
                    job: pump,
                    error: None,
                },
                Completion {
                    job: other,
                    provider: None,
                    error: None,
                },
            ],
        },
        now,
    );
    assert!(matches!(result, Err(StoreError::Conflict)));
    assert!(r.read(Period::Day, now).unwrap().market.holdings.is_empty());
}
