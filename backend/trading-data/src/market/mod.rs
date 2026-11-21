pub mod data;
pub mod networks;
pub mod storage;

use std::collections::HashMap;
use tokio::sync::Mutex;

#[derive(Default)]
pub struct Cache {
    pub pending_networks: std::sync::atomic::AtomicBool,
    pub networks: Mutex<Option<(u64, Vec<networks::Network>)>>,
    pub snapshots: Mutex<HashMap<String, data::Snapshot>>,
    pub trades: Mutex<HashMap<String, data::Trades>>,
    pub info: Mutex<HashMap<String, (u64, Vec<data::AssetLink>)>>,
    pub quote_currencies: Mutex<HashMap<String, (u64, Option<networks::Currency>)>>,
    pub ranges: Mutex<HashMap<String, data::RangeData>>,
    pub pending_searches: Mutex<std::collections::HashSet<String>>,
    pub pending_ranges: Mutex<std::collections::HashSet<String>>,
}
