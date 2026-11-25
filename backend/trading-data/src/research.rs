use std::{
    ffi::{CStr, CString},
    path::{Path, PathBuf},
    process::Stdio,
    sync::Arc,
    time::Duration,
};

use axum::{
    body::{Body, Bytes},
    extract::{DefaultBodyLimit, Path as RoutePath, State},
    http::{header, StatusCode},
    response::Response,
    routing::post,
    Router,
};
use tokio::{
    process::{Child, Command},
    sync::Mutex,
    time::Instant,
};

use crate::ApiError;

pub fn router(support: &Path, data_url: String) -> Router {
    Router::new()
        .route("/api/research/{action}", post(forward))
        .layer(DefaultBodyLimit::max(48 * 1024))
        .with_state(Arc::new(ResearchService {
            host: support.join("DataService/ResearchHost"),
            state: support.join("Research"),
            data_url,
            running: Mutex::new(None),
        }))
}

struct ResearchService {
    host: PathBuf,
    state: PathBuf,
    data_url: String,
    running: Mutex<Option<Running>>,
}

struct Running {
    child: Child,
    client: reqwest::Client,
    _socket: SocketDirectory,
}

struct SocketDirectory(PathBuf);

impl SocketDirectory {
    fn create() -> std::io::Result<Self> {
        // macOS Unix sockets have a short path limit. mkdtemp creates a private directory.
        let mut pattern = CString::new("/tmp/trig-research.XXXXXX")
            .unwrap()
            .into_bytes_with_nul();
        let result = unsafe { libc::mkdtemp(pattern.as_mut_ptr().cast()) };
        if result.is_null() {
            return Err(std::io::Error::last_os_error());
        }
        let path = unsafe { CStr::from_ptr(result) }.to_str().unwrap();
        Ok(Self(PathBuf::from(path)))
    }
}

impl Drop for SocketDirectory {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(self.0.join("host.sock"));
        let _ = std::fs::remove_dir(&self.0);
    }
}

impl ResearchService {
    async fn client(&self) -> Result<reqwest::Client, ApiError> {
        let mut running = self.running.lock().await;
        if let Some(current) = running.as_mut() {
            if matches!(current.child.try_wait(), Ok(None)) {
                return Ok(current.client.clone());
            }
        }
        *running = None;
        let node =
            std::fs::read_to_string(self.host.join("node-path")).map_err(|_| unavailable())?;
        let node = Path::new(node.trim());
        if !node.is_absolute() {
            return Err(unavailable());
        }
        let socket_dir = SocketDirectory::create().map_err(|_| unavailable())?;
        let socket = socket_dir.0.join("host.sock");
        let mut child = Command::new(node)
            .arg(self.host.join("host.mjs"))
            .arg(&socket)
            .arg(&self.state)
            .env("TRIG_RESEARCH_DATA_URL", &self.data_url)
            .stdin(Stdio::piped())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .kill_on_drop(true)
            .spawn()
            .map_err(|_| unavailable())?;
        let deadline = Instant::now() + Duration::from_secs(8);
        while !socket.exists() {
            if Instant::now() >= deadline || !matches!(child.try_wait(), Ok(None)) {
                return Err(unavailable());
            }
            tokio::time::sleep(Duration::from_millis(35)).await;
        }
        let client = reqwest::Client::builder()
            .unix_socket(socket)
            .redirect(reqwest::redirect::Policy::none())
            .timeout(Duration::from_secs(240))
            .build()
            .map_err(|_| unavailable())?;
        *running = Some(Running {
            child,
            client: client.clone(),
            _socket: socket_dir,
        });
        Ok(client)
    }
}

async fn forward(
    State(service): State<Arc<ResearchService>>,
    RoutePath(action): RoutePath<String>,
    body: Bytes,
) -> Result<Response, ApiError> {
    if !matches!(
        action.as_str(),
        "providers" | "probe" | "conversation" | "turn" | "stop" | "tool-result"
    ) {
        return Err(ApiError(
            StatusCode::NOT_FOUND,
            "Research action not found.".into(),
        ));
    }
    let response = service
        .client()
        .await?
        .post(format!("http://research.local/{action}"))
        .header(header::CONTENT_TYPE, "application/json")
        .body(body)
        .send()
        .await
        .map_err(|_| unavailable())?;
    let mut builder = Response::builder()
        .status(response.status())
        .header(header::CACHE_CONTROL, "no-store");
    if let Some(content_type) = response.headers().get(header::CONTENT_TYPE) {
        builder = builder.header(header::CONTENT_TYPE, content_type);
    }
    builder
        .body(Body::from_stream(response.bytes_stream()))
        .map_err(|_| unavailable())
}

fn unavailable() -> ApiError {
    ApiError(
        StatusCode::SERVICE_UNAVAILABLE,
        "The local research service is unavailable. Rebuild the data service and try again.".into(),
    )
}
