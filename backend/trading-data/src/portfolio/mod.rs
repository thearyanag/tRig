mod aggregate;
pub mod api;
mod normalize;
pub mod storage;
#[cfg(test)]
mod tests;
mod types;

pub use types::*;

pub fn build(request: PortfolioRequest) -> Result<PortfolioViews, String> {
    if request.providers.len() > 2 || request.issues.len() > 8 {
        return Err("Invalid portfolio request".into());
    }
    let mut seen = std::collections::HashSet::new();
    let mut snapshots = Vec::new();
    let mut issues = request.issues;
    for input in request.providers {
        if input.period != request.period || !seen.insert(input.source) {
            return Err("Portfolio source or period mismatch".into());
        }
        let source = input.source;
        match normalize::snapshot(input) {
            Ok(snapshot) => snapshots.push(snapshot),
            Err(_) => issues.push(PortfolioIssue {
                source,
                message: "Portfolio data could not be confirmed. Refresh to retry.".into(),
            }),
        }
    }
    Ok(views(&snapshots, &issues, request.period))
}

fn views(snapshots: &[Snapshot], issues: &[PortfolioIssue], period: Period) -> PortfolioViews {
    PortfolioViews {
        all: aggregate::combine(snapshots, issues, period, "all"),
        pump: aggregate::combine(
            &snapshots
                .iter()
                .filter(|s| s.source == Source::Pump)
                .cloned()
                .collect::<Vec<_>>(),
            &issues
                .iter()
                .filter(|i| i.source == Source::Pump)
                .cloned()
                .collect::<Vec<_>>(),
            period,
            "pump",
        ),
        fomo: aggregate::combine(
            &snapshots
                .iter()
                .filter(|s| s.source == Source::Fomo)
                .cloned()
                .collect::<Vec<_>>(),
            &issues
                .iter()
                .filter(|i| i.source == Source::Fomo)
                .cloned()
                .collect::<Vec<_>>(),
            period,
            "fomo",
        ),
    }
}
