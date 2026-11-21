//! Durable public discovery metadata. Prices and quotes deliberately do not live
//! in this cache: a saved token identity is not a fresh market observation.
use super::networks::{self, Network};
use crate::discovery::{Asset, AssetsResponse};
use rusqlite::{params, Connection, OptionalExtension};
use std::{path::Path, sync::Mutex, time::Duration};

pub struct Repository {
    db: Mutex<Connection>,
}
impl Repository {
    pub fn open(path: &Path) -> rusqlite::Result<Self> {
        let db = Connection::open(path)?;
        db.busy_timeout(Duration::from_secs(3))?;
        db.execute_batch("CREATE TABLE IF NOT EXISTS market_assets(chain TEXT NOT NULL,address TEXT NOT NULL,asset TEXT NOT NULL,updated_at INTEGER NOT NULL,PRIMARY KEY(chain,address));
          CREATE INDEX IF NOT EXISTS market_assets_address ON market_assets(address);
          CREATE TABLE IF NOT EXISTS market_searches(scope TEXT NOT NULL,query TEXT NOT NULL,response TEXT NOT NULL,updated_at INTEGER NOT NULL,PRIMARY KEY(scope,query));
          CREATE TABLE IF NOT EXISTS market_networks(id INTEGER PRIMARY KEY CHECK(id=1),networks TEXT NOT NULL,updated_at INTEGER NOT NULL);")?;
        Ok(Self { db: Mutex::new(db) })
    }
    pub fn asset(&self, chain: &str, address: &str, at: u64, max_age: u64) -> Option<Asset> {
        let db = self.db.lock().ok()?;
        let (raw, updated): (String, u64) = db
            .query_row(
                "SELECT asset,updated_at FROM market_assets WHERE chain=? AND address=?",
                params![chain, networks::canonical(chain, address)],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .optional()
            .ok()??;
        if !fresh(updated, at, max_age) {
            return None;
        }
        let asset: Asset = serde_json::from_str(&raw).ok()?;
        (asset.chain_id == chain
            && networks::canonical(chain, &asset.id) == networks::canonical(chain, address)
            && valid(&asset))
        .then(|| metadata(asset))
    }
    pub fn address_matches(&self, scope: &str, address: &str, at: u64) -> (Vec<Asset>, u64) {
        let Ok(db) = self.db.lock() else {
            return (vec![], at);
        };
        let Ok(mut stmt)=db.prepare("SELECT chain,address,asset,updated_at FROM market_assets WHERE address=? AND (?='all' OR chain=?) ORDER BY chain LIMIT 40") else {return (vec![],at)};
        let key = if address.starts_with("0x") {
            address.to_ascii_lowercase()
        } else {
            address.to_owned()
        };
        let Ok(rows) = stmt.query_map(params![key, scope, scope], |r| {
            Ok((
                r.get::<_, String>(0)?,
                r.get::<_, String>(1)?,
                r.get::<_, String>(2)?,
                r.get::<_, u64>(3)?,
            ))
        }) else {
            return (vec![], at);
        };
        let rows: Vec<(Asset, u64)> = rows
            .filter_map(|row| {
                let (chain, id, raw, updated) = row.ok()?;
                if !fresh(updated, at, 86400) {
                    return None;
                }
                let asset: Asset = serde_json::from_str(&raw).ok()?;
                (valid(&asset)
                    && asset.chain_id == chain
                    && networks::canonical(&chain, &asset.id) == id)
                    .then(|| (metadata(asset), updated))
            })
            .collect();
        let oldest = rows.iter().map(|(_, at)| *at).min().unwrap_or(at);
        (rows.into_iter().map(|(asset, _)| asset).collect(), oldest)
    }
    pub fn save_asset(&self, asset: &Asset, at: u64) -> rusqlite::Result<()> {
        if !valid(asset) {
            return Ok(());
        }
        let db = self.db.lock().map_err(|_| rusqlite::Error::InvalidQuery)?;
        put_asset(&db, asset, at)
    }
    pub fn search(&self, scope: &str, query: &str, at: u64) -> Option<(AssetsResponse, u64)> {
        let db = self.db.lock().ok()?;
        let (raw, updated): (String, u64) = db
            .query_row(
                "SELECT response,updated_at FROM market_searches WHERE scope=? AND query=?",
                params![scope, search_key(query)],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .optional()
            .ok()??;
        if !fresh(updated, at, 86400) {
            return None;
        }
        let mut response: AssetsResponse = serde_json::from_str(&raw).ok()?;
        if response.assets.is_empty()
            || response.assets.len() > 40
            || response
                .assets
                .iter()
                .any(|a| !valid(a) || (scope != "all" && a.chain_id != scope))
        {
            return None;
        }
        response.assets = response.assets.into_iter().map(metadata).collect();
        Some((response, updated))
    }
    pub fn save_search(
        &self,
        scope: &str,
        query: &str,
        response: &AssetsResponse,
    ) -> rusqlite::Result<()> {
        // Empty and failed searches must not become durable negative lookups.
        if response.assets.is_empty() || response.assets.iter().any(|a| !valid(a)) {
            return Ok(());
        }
        let mut db = self.db.lock().map_err(|_| rusqlite::Error::InvalidQuery)?;
        let tx = db.transaction()?;
        for asset in &response.assets {
            put_asset(&tx, asset, response.fetched_at)?;
        }
        let safe = AssetsResponse {
            assets: response.assets.clone().into_iter().map(metadata).collect(),
            fetched_at: response.fetched_at,
        };
        let raw = serde_json::to_string(&safe).map_err(|_| rusqlite::Error::InvalidQuery)?;
        tx.execute("INSERT INTO market_searches VALUES(?,?,?,?) ON CONFLICT(scope,query) DO UPDATE SET response=excluded.response,updated_at=excluded.updated_at WHERE excluded.updated_at>=market_searches.updated_at",params![scope,search_key(query),raw,response.fetched_at])?;
        tx.execute("DELETE FROM market_searches WHERE rowid IN (SELECT rowid FROM market_searches ORDER BY updated_at DESC LIMIT -1 OFFSET 1000)",[])?;
        tx.execute("DELETE FROM market_assets WHERE rowid IN (SELECT rowid FROM market_assets ORDER BY updated_at DESC LIMIT -1 OFFSET 10000)",[])?;
        tx.commit()
    }
    pub fn networks(&self, at: u64) -> Option<(u64, Vec<Network>)> {
        let db = self.db.lock().ok()?;
        let (raw, updated): (String, u64) = db
            .query_row(
                "SELECT networks,updated_at FROM market_networks WHERE id=1",
                [],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .optional()
            .ok()??;
        if !fresh(updated, at, 3600) {
            return None;
        }
        Some((updated, serde_json::from_str(&raw).ok()?))
    }
    pub fn save_networks(&self, rows: &[Network], at: u64) -> rusqlite::Result<()> {
        let raw = serde_json::to_string(rows).map_err(|_| rusqlite::Error::InvalidQuery)?;
        self.db.lock().map_err(|_|rusqlite::Error::InvalidQuery)?.execute("INSERT INTO market_networks VALUES(1,?,?) ON CONFLICT(id) DO UPDATE SET networks=excluded.networks,updated_at=excluded.updated_at WHERE excluded.updated_at>=market_networks.updated_at",params![raw,at])?;
        Ok(())
    }
}
fn fresh(updated: u64, at: u64, max_age: u64) -> bool {
    updated <= at && at - updated < max_age
}
fn search_key(query: &str) -> String {
    let query = query.trim();
    if crate::discovery::is_address(query) {
        query.into()
    } else {
        query.to_ascii_lowercase()
    }
}
fn valid(a: &Asset) -> bool {
    networks::address(&a.chain_id, &a.id)
        && !a.name.is_empty()
        && !a.symbol.is_empty()
        && (a.pool.is_empty() || networks::pool_address(&a.chain_id, &a.pool))
}
fn metadata(mut a: Asset) -> Asset {
    a.price_usd = None;
    a.volume_24h = None;
    a.change24h = None;
    a.liquidity_usd = None;
    a.market_cap_usd = None;
    a.fdv_usd = None;
    a
}
fn put_asset(db: &Connection, a: &Asset, at: u64) -> rusqlite::Result<()> {
    let safe = metadata(a.clone());
    let raw = serde_json::to_string(&safe).map_err(|_| rusqlite::Error::InvalidQuery)?;
    // A background search ranks markets without checking their candles.
    let existing: Option<(String, u64)> = db
        .query_row(
            "SELECT asset,updated_at FROM market_assets WHERE chain=? AND address=?",
            params![a.chain_id, networks::canonical(&a.chain_id, &a.id)],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .optional()?;
    if existing.as_ref().is_some_and(|(raw, updated)| {
        fresh(*updated, at, 300)
            && serde_json::from_str::<Asset>(raw).is_ok_and(|old| old.has_current_market_route())
            && !safe.has_current_market_route()
    }) {
        return Ok(());
    }
    db.execute("INSERT INTO market_assets VALUES(?,?,?,?) ON CONFLICT(chain,address) DO UPDATE SET asset=excluded.asset,updated_at=excluded.updated_at WHERE excluded.updated_at>=market_assets.updated_at",params![safe.chain_id,networks::canonical(&safe.chain_id,&safe.id),raw,at])?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    fn asset(chain: &str) -> Asset {
        serde_json::from_value(serde_json::json!({"id":"0x1111111111111111111111111111111111111111","name":"Token","symbol":"TEST","network":"Network","pool":"0x2222222222222222222222222222222222222222","decimals":18,"priceUsd":2,"chainId":chain,"volume24h":10,"change24h":20,"liquidityUsd":30,"marketCapUsd":40,"fdvUsd":50})).unwrap()
    }
    #[test]
    fn identities_survive_restart_without_turning_saved_marks_into_live_data() {
        let path = std::env::temp_dir().join(format!(
            "trig-market-cache-{}-{}.sqlite",
            std::process::id(),
            crate::now()
        ));
        {
            let db = Repository::open(&path).unwrap();
            db.save_asset(&asset("eip155:1"), 1000).unwrap();
            db.save_asset(&asset("eip155:8453"), 1000).unwrap();
        }
        let db = Repository::open(&path).unwrap();
        let a = db
            .asset(
                "eip155:1",
                "0x1111111111111111111111111111111111111111",
                1001,
                300,
            )
            .unwrap();
        assert_eq!(a.chain_id, "eip155:1");
        assert!(a.price_usd.is_none() && a.market_cap_usd.is_none() && a.change24h.is_none());
        assert!(db.asset("eip155:8453", &a.id, 1001, 300).is_some());
        assert!(db.asset("eip155:56", &a.id, 1001, 300).is_none());
        assert_eq!(db.address_matches("all", &a.id, 1001).0.len(), 2);
        assert_eq!(db.address_matches("eip155:1", &a.id, 1001).0.len(), 1);
        assert!(db.address_matches("all", &a.id, 87400).0.is_empty());
        assert!(db.asset("eip155:1", &a.id, 1300, 300).is_none());
        drop(db);
        let _ = std::fs::remove_file(path);
    }
    #[test]
    fn search_scope_ttl_and_case_are_preserved_and_empty_results_are_not_saved() {
        let db = Repository::open(Path::new(":memory:")).unwrap();
        let response = AssetsResponse {
            assets: vec![asset("eip155:1")],
            fetched_at: 1000,
        };
        db.save_search("eip155:1", "TEST", &response).unwrap();
        assert_eq!(
            db.search("eip155:1", "test", 1001).unwrap().0.assets.len(),
            1
        );
        assert!(db.search("eip155:8453", "test", 1001).is_none());
        assert!(db.search("eip155:1", "test", 87400).is_none());
        db.save_search(
            "all",
            "empty",
            &AssetsResponse {
                assets: vec![],
                fetched_at: 1000,
            },
        )
        .unwrap();
        assert!(db.search("all", "empty", 1001).is_none());
        assert_ne!(
            search_key(crate::models::BP_MINT),
            search_key(&crate::models::BP_MINT.to_lowercase())
        );
    }

    #[test]
    fn old_routes_require_rechecking_and_search_preserves_the_replacement() {
        let db = Repository::open(Path::new(":memory:")).unwrap();
        let mut old = asset("eip155:8453");
        old.market_resolved = true;
        db.save_asset(&old, 1000).unwrap();
        assert!(!db
            .asset(&old.chain_id, &old.id, 1010, 300)
            .unwrap()
            .has_current_market_route());

        old.pool = "0x3333333333333333333333333333333333333333".into();
        let mut resolved = old.clone();
        resolved.pool = "0x4444444444444444444444444444444444444444".into();
        resolved.market_route_version = Some(crate::discovery::MARKET_ROUTE_VERSION);
        db.save_asset(&resolved, 1010).unwrap();
        db.save_search(
            "all",
            "TEST",
            &AssetsResponse {
                assets: vec![old],
                fetched_at: 1020,
            },
        )
        .unwrap();
        let saved = db
            .asset(&resolved.chain_id, &resolved.id, 1020, 300)
            .unwrap();
        assert!(saved.has_current_market_route());
        assert_eq!(saved.pool, resolved.pool);
    }
}
