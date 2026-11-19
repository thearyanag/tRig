use serde::{Deserialize, Serialize};

pub const BP_MINT: &str = "BPxxfRCXkUVhig4HS1Lh7kZqV6SPJhzfEk4x6fVBjPCy";
pub const BP_POOL: &str = "6qz7THwQvcjF3HyDGLuKaLBUk6EyJKeZXZMWLAeiwfjd";

#[derive(Clone, Debug, Serialize, PartialEq)]
pub struct Bar {
    pub time: i64,
    pub open: f64,
    pub high: f64,
    pub low: f64,
    pub close: f64,
    pub volume: f64,
}

#[derive(Clone, Serialize)]
pub struct BarsResponse {
    pub bars: Vec<Bar>,
    pub fetched_at: u64,
    pub cached: bool,
    pub pool: String,
    pub mint: String,
    pub provider: &'static str,
}

#[derive(Deserialize, Clone, Debug, Default)]
pub struct BarsQuery {
    pub mint: Option<String>,
    pub pool: Option<String>,
    pub resolution: String,
    pub before: Option<u64>,
    pub limit: Option<usize>,
}

#[derive(Clone, Debug, Hash, Eq, PartialEq)]
pub struct CacheKey {
    pub mint: String,
    pub pool: String,
    pub resolution: String,
    pub before: Option<u64>,
    pub limit: usize,
}

#[derive(Deserialize)]
pub struct ProviderResponse {
    pub data: ProviderData,
}
#[derive(Deserialize)]
pub struct ProviderData {
    pub attributes: ProviderAttributes,
}
#[derive(Deserialize)]
pub struct ProviderAttributes {
    pub ohlcv_list: Vec<[f64; 6]>,
}
