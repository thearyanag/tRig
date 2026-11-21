use super::normalize::native_market_mint;
use super::types::*;
use bigdecimal::{BigDecimal as N, Zero};
use serde_json::Value;
use std::collections::{BTreeMap, BTreeSet};

fn parsed(value: &Option<String>) -> Option<N> {
    value
        .as_ref()
        .and_then(|s| number(&Value::String(s.clone())))
}
fn sum(values: impl Iterator<Item = Option<N>>) -> Option<N> {
    let mut total = N::zero();
    let mut any = false;
    for value in values {
        total += value?;
        any = true;
    }
    any.then_some(total)
}
fn group(lots: Vec<Lot>) -> Holding {
    let first = lots
        .iter()
        .find(|l| l.symbol != "Token")
        .unwrap_or(&lots[0]);
    let quantity = sum(lots.iter().map(|l| parsed(&l.quantity)));
    let value = sum(lots.iter().map(|l| parsed(&l.value_usd)));
    let basis = sum(lots.iter().map(|l| parsed(&l.cost_basis_usd)));
    let pnl = sum(lots.iter().map(|l| parsed(&l.pnl_usd)));
    let price = value
        .as_ref()
        .zip(quantity.as_ref())
        .and_then(|(v, q)| (q > &N::zero()).then(|| v / q));
    let avg = basis
        .as_ref()
        .zip(quantity.as_ref())
        .and_then(|(v, q)| (q > &N::zero()).then(|| v / q));
    let return_percent = pnl
        .as_ref()
        .zip(basis.as_ref())
        .and_then(|(p, b)| percent(p, b));
    let sources = lots
        .iter()
        .flat_map(|l| l.sources.iter().copied())
        .collect::<BTreeSet<_>>()
        .into_iter()
        .collect();
    let warnings = lots
        .iter()
        .flat_map(|l| l.warnings.clone())
        .collect::<BTreeSet<_>>()
        .into_iter()
        .collect();
    Holding {
        id: format!("{}:{}", first.chain, address(&first.mint)),
        chain: first.chain.clone(),
        mint: first.mint.clone(),
        market_mint: native_market_mint(&first.chain, &first.mint),
        name: first.name.clone(),
        symbol: first.symbol.clone(),
        image_url: lots.iter().find_map(|l| l.image_url.clone()),
        quantity: string(quantity),
        price_usd: string(price),
        value_usd: string(value),
        average_entry_usd: string(avg),
        pnl_usd: string(pnl),
        pnl_percent: string(return_percent),
        sources,
        lots,
        warnings,
    }
}
fn at(points: &[Point], time: i64) -> Option<N> {
    let index = points.partition_point(|p| p.time < time);
    if let Some(point) = points.get(index).filter(|p| p.time == time) {
        return Some(point.value.clone());
    }
    let left = points.get(index.checked_sub(1)?)?;
    let right = points.get(index)?;
    let gap = right.time - left.time;
    if gap <= 0 || gap > 86400 {
        return None;
    }
    Some(&left.value + (&right.value - &left.value) * N::from(time - left.time) / N::from(gap))
}
fn combined_history(
    snapshots: &[Snapshot],
    period: Period,
    overlap: bool,
) -> (Vec<HistoryPoint>, Option<String>) {
    if snapshots.is_empty() {
        return (
            Vec::new(),
            Some("Connect an account to see portfolio history.".into()),
        );
    }
    if overlap {
        return (
            Vec::new(),
            Some("Select Pumpfun or Fomo to see history for shared wallets.".into()),
        );
    }
    if snapshots.iter().any(|s| s.history.is_empty()) {
        return (
            Vec::new(),
            Some("Portfolio history is unavailable for one or more accounts.".into()),
        );
    }
    let start = snapshots
        .iter()
        .filter_map(|s| s.history.first().map(|p| p.time))
        .max()
        .unwrap();
    let end = snapshots
        .iter()
        .filter_map(|s| s.history.last().map(|p| p.time))
        .min()
        .unwrap();
    if start > end {
        return (
            Vec::new(),
            Some("The accounts do not have a common history range.".into()),
        );
    }
    let times = snapshots
        .iter()
        .flat_map(|s| s.history.iter().map(|p| p.time))
        .filter(|t| *t >= start && *t <= end)
        .chain([start, end])
        .collect::<BTreeSet<_>>();
    let mut missing = false;
    let mut segment = 0;
    let mut last_time: Option<i64> = None;
    let points = times
        .into_iter()
        .filter_map(
            |time| match sum(snapshots.iter().map(|s| at(&s.history, time))) {
                Some(v) => {
                    if last_time.is_some_and(|last| time - last > 86400) {
                        segment += 1;
                        missing = true;
                    }
                    last_time = Some(time);
                    Some(HistoryPoint {
                        time,
                        value_usd: text(&v),
                        segment,
                    })
                }
                None => {
                    missing = true;
                    segment += 1;
                    None
                }
            },
        )
        .collect();
    let requested_start = snapshots.iter().map(|s| s.fetched_at as i64).min().unwrap()
        - period.seconds().unwrap_or(0);
    let truncated = period.seconds().is_some() && start > requested_start + 3600;
    let message = if missing {
        Some("History contains gaps; unavailable intervals are omitted.".into())
    } else if truncated {
        Some("Only the common available history range is shown.".into())
    } else {
        None
    };
    (points, message)
}
pub fn combine(
    snapshots: &[Snapshot],
    issues: &[PortfolioIssue],
    period: Period,
    scope: &str,
) -> PortfolioView {
    let mut seen_wallets = BTreeSet::new();
    let mut overlap = false;
    for snapshot in snapshots {
        for wallet in &snapshot.wallets {
            if !wallet.starts_with("unresolved:") && !seen_wallets.insert(wallet.clone()) {
                overlap = true;
            }
        }
    }
    let mut unique: BTreeMap<String, Lot> = BTreeMap::new();
    for snapshot in snapshots {
        for lot in &snapshot.lots {
            match unique.get_mut(&lot.id) {
                Some(existing) => {
                    let sources: Vec<_> = existing
                        .sources
                        .iter()
                        .chain(lot.sources.iter())
                        .copied()
                        .collect::<BTreeSet<_>>()
                        .into_iter()
                        .collect();
                    if lot.fetched_at > existing.fetched_at {
                        *existing = lot.clone();
                    }
                    existing.sources = sources;
                    existing.warnings.push(
                        "This wallet balance is reported by both platforms and counted once."
                            .into(),
                    );
                }
                None => {
                    unique.insert(lot.id.clone(), lot.clone());
                }
            }
        }
    }
    let mut groups: BTreeMap<String, Vec<Lot>> = BTreeMap::new();
    for lot in unique.into_values() {
        groups
            .entry(format!("{}:{}", lot.chain, address(&lot.mint)))
            .or_default()
            .push(lot);
    }
    let mut holdings: Vec<_> = groups.into_values().map(group).collect();
    holdings.sort_by(|a, b| {
        parsed(&b.value_usd)
            .cmp(&parsed(&a.value_usd))
            .then_with(|| a.id.cmp(&b.id))
    });
    let mut warnings: BTreeSet<_> = snapshots.iter().flat_map(|s| s.warnings.clone()).collect();
    for issue in issues {
        warnings.insert(format!(
            "{}: {}",
            issue.source.name(),
            issue.message.chars().take(240).collect::<String>()
        ));
    }
    let partial = overlap || snapshots.iter().any(|s| s.partial) || !issues.is_empty();
    let total = if overlap {
        warnings.insert("Shared wallets detected. Combined value shows deduplicated priced holdings; select a platform for its full reported total.".into());
        Some(
            holdings
                .iter()
                .filter_map(|h| parsed(&h.value_usd))
                .sum::<N>(),
        )
    } else {
        sum(snapshots.iter().map(|s| s.total.clone()))
    };
    let pnl = if overlap {
        None
    } else {
        sum(snapshots.iter().map(|s| s.pnl.clone()))
    };
    let pnl_percent = if snapshots.len() == 1 {
        snapshots[0].pnl_percent.clone()
    } else {
        None
    };
    let unrealized = if overlap {
        sum(holdings
            .iter()
            .filter(|h| h.pnl_usd.is_some())
            .map(|h| parsed(&h.pnl_usd)))
    } else {
        sum(snapshots.iter().map(|s| s.unrealized.clone()))
    };
    let known_basis = sum(holdings
        .iter()
        .filter(|h| h.pnl_usd.is_some())
        .map(|h| sum(h.lots.iter().map(|l| parsed(&l.cost_basis_usd)))));
    let unrealized_percent = unrealized
        .as_ref()
        .zip(known_basis.as_ref())
        .and_then(|(p, b)| percent(p, b));
    let (history, history_message) = combined_history(snapshots, period, overlap);
    PortfolioView {
        scope: scope.into(),
        period,
        total_value_usd: string(total),
        period_pnl_usd: string(pnl),
        period_pnl_percent: string(pnl_percent),
        unrealized_pnl_usd: string(unrealized),
        unrealized_pnl_percent: string(unrealized_percent),
        holdings,
        history,
        source_count: snapshots.len(),
        as_of: snapshots
            .iter()
            .map(|s| s.fetched_at)
            .min_by(f64::total_cmp),
        warnings: warnings.into_iter().collect(),
        partial,
        history_message,
    }
}
